unit HW.SH2;

interface

uses
  System.SysUtils, System.Classes, Core.Snapshots;

type
  ESH2Address = class(Exception);

  TSH2Read = function(User: Pointer; Address: Cardinal; Size: Integer): Cardinal;

  TSH2Write = procedure(User: Pointer; Address, Value: Cardinal; Size: Integer);

  TSH2OpcodeDecoder = function(User: Pointer; Address: Cardinal; Opcode: Word): Word;

  TSH2DataCacheView = record
    Line: Cardinal;
    Data: Pointer;
    LRU: PByte;
    Mask, Bits: Byte;
  end;

  PSH2DataCacheView = ^TSH2DataCacheView;

  // Hardware-owned arrays; pointers remain stable across reset/state load.
  TSH2CacheBank = record
    Tags: PCardinal;
    RAM, LRU, CCR: PByte;
  end;

  PSH2CacheBank = ^TSH2CacheBank;

  TSH2State = record
    R: array[0..15] of Cardinal;
    PC, PR, SR, GBR, VBR, MACH, MACL, DelayTarget: Cardinal;
    DelayPending, Sleeping: Boolean;
    Cycles: UInt64;
  end;

  TSH2 = class
  private
    FState: TSH2State;
    FRead, FFetch: TSH2Read;
    FOpcodeDecoder: TSH2OpcodeDecoder;
    FDecodeUser: Pointer;
    FWrite: TSH2Write;
    FUser: Pointer;
    FIRQLevel, FIRQVector: Integer;
    FInterruptAccepted: Boolean;
    FSH1: Boolean;
    FCodeLine: Cardinal;
    FCodeData: Pointer;
    FCodeLRU: PByte;
    FCodeMask, FCodeBits: Byte;
    FByteReadAddress: Cardinal;
    FDataView: PSH2DataCacheView;
    FDataIndexed: Boolean;
    FCacheBank: PSH2CacheBank;
    FByteReadValue, FByteReadLatch: PByte; // derived native read/latch view
    function SelectInstructionLine(Address: Cardinal): Boolean;
    function Read(Address: Cardinal; Size: Integer): Cardinal; inline;
    procedure Write(Address, Value: Cardinal; Size: Integer); inline;
    procedure SetT(Value: Boolean); inline;
    procedure ExceptionVector(Vector: Integer; PC: Cardinal);
    function TryNativeRead(Address: Cardinal; Size: Integer; out Value: Cardinal): Boolean; inline;
    function ExecuteOpcode(Op: Word; At, Target: Cardinal; WasSlot: Boolean): Integer;
  public
    constructor Create(ReadCallback: TSH2Read; WriteCallback: TSH2Write; User: Pointer; FetchCallback: TSH2Read = nil; SH1: Boolean = False);
    // Optional native hardware-cache view, derived and never serialized.
    procedure InvalidateInstructionLine; inline;
    // Fixed on-chip byte reads with a read-to-clear latch and no bus wait.
    // The hardware owner retains the storage for the lifetime of this CPU.
    procedure SetByteReadLatch(Address: Cardinal; Value, Latch: PByte);
    procedure SetDataCacheView(View: PSH2DataCacheView; Indexed: Boolean = False);
    // Cache selection is optional; boards without hardware cache use StepChecked.
    procedure SetCacheBank(Bank: PSH2CacheBank);
    procedure SetInstructionLine(Line: Cardinal; Data: Pointer; LRU: PByte; Mask, Bits: Byte); inline;
    procedure Reset;
    procedure SetOpcodeDecoder(Decoder: TSH2OpcodeDecoder; User: Pointer);
    function Step: Integer;
    // Zero means no instruction was issued; the checked executor is required.
    function StepCached: Integer;
    function StepChecked: Integer;
    function Run(Cycles: Integer): Integer;
    procedure AddWaitCycles(Count: Integer); inline;
    procedure Interrupt(Level, Vector: Integer);
    procedure SerializeState(Archive: TStateArchive);
    property State: TSH2State read FState write FState;
    property InterruptAccepted: Boolean read FInterruptAccepted;
  end;

implementation

// Native interpreter for the SH-2 ISA. Reference: Renesas REJ09B0171,
// SH-1/SH-2/SH-DSP Software Manual. Architectural arithmetic wraps at 32 bits.
{$Q+}{$R+}

// Cycle counters wrap modulo 2^64, exactly as unsigned hardware arithmetic.
{$Q-}

function Add64(A, B: UInt64): UInt64; inline;
begin
  Result := A + B;
end;
{$Q+}

function SX8(Value: Cardinal): Cardinal; inline;
begin
  Result := Cardinal(Integer(ShortInt((Value and $FF))));
end;

function SX16(Value: Cardinal): Cardinal; inline;
begin
  Result := Cardinal(Integer(SmallInt((Value and $FFFF))));
end;

constructor TSH2.Create(ReadCallback: TSH2Read; WriteCallback: TSH2Write; User: Pointer; FetchCallback: TSH2Read; SH1: Boolean);
begin
  inherited Create;
  if not Assigned(ReadCallback) or not Assigned(WriteCallback) then
    raise EArgumentException.Create('SH-2 requires memory callbacks');
  FRead := ReadCallback;
  FWrite := WriteCallback;
  FUser := User;
  FSH1 := SH1;
  FByteReadAddress := High(Cardinal);
  FCodeLine := High(Cardinal);
  FFetch := FetchCallback;
  if not Assigned(FFetch) then
    FFetch := FRead;
end;

function TSH2.Read(Address: Cardinal; Size: Integer): Cardinal;
begin
  if Address and Cardinal(Size - 1) <> 0 then
    raise ESH2Address.Create('SH-2 address error');
  Result := FRead(FUser, Address, Size);
end;

procedure TSH2.SetByteReadLatch(Address: Cardinal; Value, Latch: PByte);
begin
  FByteReadAddress := High(Cardinal);
  FByteReadValue := nil;
  FByteReadLatch := nil;
  if (Value = nil) or (Latch = nil) then
    Exit;
  FByteReadAddress := Address;
  FByteReadValue := Value;
  FByteReadLatch := Latch;
end;

procedure TSH2.SetCacheBank(Bank: PSH2CacheBank);
begin
  FCacheBank := Bank;
end;

procedure TSH2.SetDataCacheView(View: PSH2DataCacheView; Indexed: Boolean);
begin
  FDataView := View;
  FDataIndexed := Indexed and (View <> nil);
end;

procedure TSH2.Write(Address, Value: Cardinal; Size: Integer);
begin
  if Address and Cardinal(Size - 1) <> 0 then
    raise ESH2Address.Create('SH-2 address error');
  FWrite(FUser, Address, Value, Size);
end;

procedure TSH2.SetT(Value: Boolean);
begin
  FState.SR := ((FState.SR and (not Cardinal(1))) or Cardinal(Ord(Value)));
end;

procedure TSH2.InvalidateInstructionLine;
begin
  FCodeLine := High(Cardinal);
end;

procedure TSH2.SetInstructionLine(Line: Cardinal; Data: Pointer; LRU: PByte; Mask, Bits: Byte);
begin
  FCodeLine := Line;
  FCodeData := Data;
  FCodeLRU := LRU;
  FCodeMask := Mask;
  FCodeBits := Bits;
end;

procedure TSH2.SetOpcodeDecoder(Decoder: TSH2OpcodeDecoder; User: Pointer);
begin
  FOpcodeDecoder := Decoder;
  FDecodeUser := User;
  InvalidateInstructionLine;
end;

procedure TSH2.Reset;
begin
  InvalidateInstructionLine;
  FInterruptAccepted := False;
  FState := Default(TSH2State);
  FState.SR := $F0;
  FState.PC := Read(0, 4);
  FState.R[15] := Read(4, 4);
  FIRQLevel := 0;
  FIRQVector := 0;
end;

procedure TSH2.Interrupt(Level, Vector: Integer);
begin
  if (Level < 0) or (Level > 16) or (Vector < 0) or (Vector > 255) then
    raise EArgumentOutOfRangeException.Create('Invalid SH-2 interrupt');
  FIRQLevel := Level;
  FIRQVector := Vector;
end;

procedure TSH2.ExceptionVector(Vector: Integer; PC: Cardinal);
begin
  FState.R[15] := Cardinal(((Int64(FState.R[15]) - 4) and $FFFFFFFF));
  Write(Cardinal(FState.R[15]), Cardinal(FState.SR), 4);
  FState.R[15] := Cardinal(((Int64(FState.R[15]) - 4) and $FFFFFFFF));
  Write(Cardinal(FState.R[15]), PC, 4);
  FState.PC := Cardinal((Read(Cardinal((Int64(FState.VBR) + (Int64(Cardinal(Vector)) * 4))), 4) and $FFFFFFFF));
  FState.DelayPending := False;
  FState.Sleeping := False;
end;

// Only the instruction executor uses wrapping arithmetic and masked register
// indices. Bus alignment, callbacks, state loading and public APIs stay checked.
{$Q-}{$R-}
function TSH2.ExecuteOpcode(Op: Word; At, Target: Cardinal; WasSlot: Boolean): Integer;
var
  N, M: Integer;
  A, B, V, OldSR, Carry: Cardinal;
  Branch, Valid, OldQ, Q, MFlag, C: Boolean;
  Product: UInt64;
  Accumulator: Int64;

  procedure Delay(Address: Cardinal);
  begin
    if WasSlot then
    begin
      Valid := False;
      Exit;
    end;
    FState.DelayTarget := Address;
    FState.DelayPending := True;
    Branch := True;
    Result := 2;
  end;

begin
  Result := 1;
  N := ((Op shr 8) and 15);
  M := ((Op shr 4) and 15);
  A := FState.R[N];
  B := FState.R[M];
  OldSR := FState.SR;
  Branch := False;
  // Reject branches before they can alter PR, SR or the RTE stack pointer.
  // SH-2 slot exceptions save the preceding branch destination (not the slot).
  Valid := not (WasSlot and
    ((Op shr 12 = 10) or (Op shr 12 = 11) or
    (Op and $F0FF = $0003) or (Op and $F0FF = $0023) or
    (Op and $F0FF = $400B) or (Op and $F0FF = $402B) or
    (Op = $000B) or (Op = $002B) or
    (Op and $FF00 = $8900) or (Op and $FF00 = $8B00) or
    (Op and $FF00 = $8D00) or (Op and $FF00 = $8F00) or
    (Op and $FF00 = $C300)));
  if FSH1 and (((Op and $F00F = $0007) or (Op and $F00F = $000F) or
    (Op and $F00F = $3005) or (Op and $F00F = $300D)) or
    (Op and $F0FF = $0003) or (Op and $F0FF = $0023) or (Op and $F0FF = $4010) or
    (Op and $FF00 = $8D00) or (Op and $FF00 = $8F00)) then
    Valid := False;
  if Valid then
    case Op shr 12 of
      0:
        case Op and $F of
          4:
            Write(Cardinal((Cardinal(A) + FState.R[0])), B, 1);
          5:
            Write(Cardinal((Cardinal(A) + FState.R[0])), B, 2);
          6:
            Write(Cardinal((Cardinal(A) + FState.R[0])), B, 4);
          7:
            begin
              FState.MACL := Cardinal(((UInt64(A) * B) and $FFFFFFFF));
              Result := 2;
            end;
          12:
            FState.R[N] := Cardinal((SX8(Read(Cardinal((Cardinal(B) + FState.R[0])), 1)) and $FFFFFFFF));
          13:
            FState.R[N] := Cardinal((SX16(Read(Cardinal((Cardinal(B) + FState.R[0])), 2)) and $FFFFFFFF));
          14:
            FState.R[N] := Cardinal((Read(Cardinal((Cardinal(B) + FState.R[0])), 4) and $FFFFFFFF));
          15:
            begin
              A := Read(FState.R[M], 4);
              FState.R[M] := Cardinal(((Cardinal(FState.R[M]) + 4) and $FFFFFFFF));
              B := Read(FState.R[N], 4);
              FState.R[N] := Cardinal(((Cardinal(FState.R[N]) + 4) and $FFFFFFFF));
              Accumulator := (Int64(Integer(A)) * Integer(B));
              Accumulator := Int64(Add64(UInt64(Accumulator), ((UInt64(FState.MACH) shl 32) or FState.MACL)));
              if FState.SR and 2 <> 0 then
              begin
              // Saturating MAC.L uses a signed 48-bit accumulator.
                Accumulator := (Int64(SmallInt(FState.MACH)) shl 32) + FState.MACL +
                  Int64(Integer(A)) * Integer(B);
                if Accumulator > Int64($7FFFFFFFFFFF) then
                  Accumulator := $7FFFFFFFFFFF;
                if Accumulator < -Int64($800000000000) then
                  Accumulator := (-Int64($800000000000));
              end;
              FState.MACH := (UInt64(Accumulator) shr 32);
              FState.MACL := Cardinal(Accumulator);
              Result := 3;
            end;
        else
          case Op and $FF of
            $02:
              FState.R[N] := FState.SR;
            $12:
              FState.R[N] := FState.GBR;
            $22:
              FState.R[N] := FState.VBR;
            $0A:
              FState.R[N] := FState.MACH;
            $1A:
              FState.R[N] := FState.MACL;
            $2A:
              FState.R[N] := FState.PR;
            $29:
              FState.R[N] := (FState.SR and 1);
            $03:
              begin
                FState.PR := Cardinal(((Cardinal(At) + 4) and $FFFFFFFF));
                Delay(Cardinal(((Cardinal(At) + 4) + A)));
              end;
            $23:
              Delay(Cardinal(((Cardinal(At) + 4) + A)));
          else
            case Op of
              $0008:
                SetT(False);
              $0018:
                SetT(True);
              $0009:
                ;
              $0019:
                FState.SR := (FState.SR and (not Cardinal($301)));
              $0028:
                begin
                  FState.MACH := 0;
                  FState.MACL := 0;
                end;
              $000B:
                Delay(Cardinal(FState.PR));
              $002B:
                begin
                  V := Read(FState.R[15], 4);
                  FState.SR := Cardinal(((Read(Cardinal((Cardinal(FState.R[15]) + 4)), 4) and $3F3) and $FFFFFFFF));
                  FState.R[15] := Cardinal(((Cardinal(FState.R[15]) + 8) and $FFFFFFFF));
                  Delay(V);
                  Result := 4;
                end;
              $001B:
                begin
                  FState.Sleeping := True;
                  Result := 3;
                end;
            else
              Valid := False;
            end;
          end;
        end;
      1:
        Write(Cardinal((Cardinal(A) + (Cardinal(Cardinal((Op and 15))) * 4))), B, 4);
      2:
        case Op and 15 of
          0:
            Write(A, B, 1);
          1:
            Write(A, B, 2);
          2:
            Write(A, B, 4);
          4:
            begin
              FState.R[N] := Cardinal(((Cardinal(FState.R[N]) - 1) and $FFFFFFFF));
              Write(Cardinal(FState.R[N]), B, 1);
            end;
          5:
            begin
              FState.R[N] := Cardinal(((Cardinal(FState.R[N]) - 2) and $FFFFFFFF));
              Write(Cardinal(FState.R[N]), B, 2);
            end;
          6:
            begin
              FState.R[N] := Cardinal(((Cardinal(FState.R[N]) - 4) and $FFFFFFFF));
              Write(Cardinal(FState.R[N]), B, 4);
            end;
          7:
            begin
              FState.SR := (((FState.SR and (not Cardinal($301))) or ((A shr 23) and $100)) or ((B shr 22) and $200));
              SetT((((A xor B) and $80000000) <> 0));
            end;
          8:
            SetT(((A and B) = 0));
          9:
            FState.R[N] := (A and B);
          10:
            FState.R[N] := (A xor B);
          11:
            FState.R[N] := (A or B);
          12:
            begin
              V := (A xor B);
              SetT((V and $FF = 0) or (V and $FF00 = 0) or
                (V and $FF0000 = 0) or (V and $FF000000 = 0));
            end;
          13:
            FState.R[N] := ((A shr 16) or (B shl 16));
          14:
            FState.MACL := Cardinal(((Cardinal(Cardinal(Word(A))) * Word(B)) and $FFFFFFFF));
          15:
            FState.MACL := Cardinal(Integer(SmallInt(A)) * Integer(SmallInt(B)));
        else
          Valid := False;
        end;
      3:
        case Op and 15 of
          0:
            SetT((A = B));
          2:
            SetT((A >= B));
          3:
            SetT((Integer(A) >= Integer(B)));
          4:
            begin
              OldQ := ((OldSR and $100) <> 0);
              MFlag := ((OldSR and $200) <> 0);
              Q := ((A and $80000000) <> 0);
              A := ((A shl 1) or (OldSR and 1));
              V := A;
              if OldQ = MFlag then
              begin
                A := Cardinal(((Cardinal(A) - B) and $FFFFFFFF));
                C := (A > V);
              end
              else
              begin
                A := Cardinal(((Cardinal(A) + B) and $FFFFFFFF));
                C := (A < V);
              end;
              Q := ((Q xor C) xor MFlag);
              FState.R[N] := A;
              FState.SR := ((FState.SR and (not Cardinal($100))) or (Cardinal(Ord(Q)) shl 8));
              SetT((Q = MFlag));
            end;
          5:
            begin
              Product := (UInt64(A) * B);
              FState.MACH := (Product shr 32);
              FState.MACL := Cardinal(Product);
              Result := 2;
            end;
          6:
            SetT((A > B));
          7:
            SetT((Integer(A) > Integer(B)));
          8:
            FState.R[N] := Cardinal(((Cardinal(A) - B) and $FFFFFFFF));
          10:
            begin
              Carry := (OldSR and 1);
              FState.R[N] := Cardinal((((Cardinal(A) - B) - Carry) and $FFFFFFFF));
              SetT((UInt64(A) < (UInt64(B) + Carry)));
            end;
          11:
            begin
              V := Cardinal(((Cardinal(A) - B) and $FFFFFFFF));
              FState.R[N] := V;
              SetT(((((A xor B) and (A xor V)) and $80000000) <> 0));
            end;
          12:
            FState.R[N] := Cardinal(((Cardinal(A) + B) and $FFFFFFFF));
          13:
            begin
              Product := UInt64((Int64(Integer(A)) * Integer(B)));
              FState.MACH := (Product shr 32);
              FState.MACL := Cardinal(Product);
              Result := 2;
            end;
          14:
            begin
              Product := ((UInt64(A) + B) + (OldSR and 1));
              FState.R[N] := Cardinal(Product);
              SetT((Product > $FFFFFFFF));
            end;
          15:
            begin
              V := Cardinal(((Cardinal(A) + B) and $FFFFFFFF));
              FState.R[N] := V;
              SetT(((((not (A xor B)) and (A xor V)) and $80000000) <> 0));
            end;
        else
          Valid := False;
        end;
      4:
        if Op and 15 = 15 then
        begin
          A := SX16(Read(FState.R[M], 2));
          FState.R[M] := Cardinal(((Cardinal(FState.R[M]) + 2) and $FFFFFFFF));
          B := SX16(Read(FState.R[N], 2));
          FState.R[N] := Cardinal(((Cardinal(FState.R[N]) + 2) and $FFFFFFFF));
          Accumulator := (Int64(Integer(A)) * Integer(B));
          if FState.SR and 2 <> 0 then
          begin
            Accumulator := (Accumulator + Integer(FState.MACL));
            if (Accumulator > High(Integer)) or (Accumulator < Low(Integer)) then
              FState.MACH := (FState.MACH or 1);
            if Accumulator > High(Integer) then
              Accumulator := High(Integer);
            if Accumulator < Low(Integer) then
              Accumulator := Low(Integer);
            FState.MACL := Cardinal(Accumulator);
          end
          else
          begin
            Accumulator := Int64(Add64(UInt64(Accumulator), ((UInt64(FState.MACH) shl 32) or FState.MACL)));
            FState.MACH := (UInt64(Accumulator) shr 32);
            FState.MACL := Cardinal(Accumulator);
          end;
          Result := 3;
        end
        else
          case Op and $FF of
            $00, $20:
              begin
                SetT(((A and $80000000) <> 0));
                FState.R[N] := (A shl 1);
              end;
            $01:
              begin
                SetT(Odd(A));
                FState.R[N] := (A shr 1);
              end;
            $21:
              begin
                SetT(Odd(A));
                FState.R[N] := ((A shr 1) or (A and $80000000));
              end;
            $04:
              begin
                SetT(((A and $80000000) <> 0));
                FState.R[N] := ((A shl 1) or (A shr 31));
              end;
            $05:
              begin
                SetT(Odd(A));
                FState.R[N] := ((A shr 1) or (A shl 31));
              end;
            $24:
              begin
                SetT(((A and $80000000) <> 0));
                FState.R[N] := ((A shl 1) or (OldSR and 1));
              end;
            $25:
              begin
                SetT(Odd(A));
                FState.R[N] := ((A shr 1) or ((OldSR and 1) shl 31));
              end;
            $08:
              FState.R[N] := (A shl 2);
            $09:
              FState.R[N] := (A shr 2);
            $18:
              FState.R[N] := (A shl 8);
            $19:
              FState.R[N] := (A shr 8);
            $28:
              FState.R[N] := (A shl 16);
            $29:
              FState.R[N] := (A shr 16);
            $10:
              begin
                FState.R[N] := Cardinal(((Cardinal(A) - 1) and $FFFFFFFF));
                SetT((FState.R[N] = 0));
              end;
            $11:
              SetT((Integer(A) >= 0));
            $15:
              SetT((Integer(A) > 0));
            $1B:
              begin
                V := Read(A, 1);
                SetT((V = 0));
                Write(A, Cardinal((V or $80)), 1);
                Result := 4;
              end;
            $0B:
              begin
                FState.PR := Cardinal(((Cardinal(At) + 4) and $FFFFFFFF));
                Delay(A);
              end;
            $2B:
              Delay(A);
            $02:
              begin
                FState.R[N] := Cardinal(((Cardinal(FState.R[N]) - 4) and $FFFFFFFF));
                Write(Cardinal(FState.R[N]), Cardinal(FState.MACH), 4);
              end;
            $12:
              begin
                FState.R[N] := Cardinal(((Cardinal(FState.R[N]) - 4) and $FFFFFFFF));
                Write(Cardinal(FState.R[N]), Cardinal(FState.MACL), 4);
              end;
            $22:
              begin
                FState.R[N] := Cardinal(((Cardinal(FState.R[N]) - 4) and $FFFFFFFF));
                Write(Cardinal(FState.R[N]), Cardinal(FState.PR), 4);
              end;
            $03:
              begin
                FState.R[N] := Cardinal(((Cardinal(FState.R[N]) - 4) and $FFFFFFFF));
                Write(Cardinal(FState.R[N]), Cardinal(FState.SR), 4);
                Result := 2;
              end;
            $13:
              begin
                FState.R[N] := Cardinal(((Cardinal(FState.R[N]) - 4) and $FFFFFFFF));
                Write(Cardinal(FState.R[N]), Cardinal(FState.GBR), 4);
                Result := 2;
              end;
            $23:
              begin
                FState.R[N] := Cardinal(((Cardinal(FState.R[N]) - 4) and $FFFFFFFF));
                Write(Cardinal(FState.R[N]), Cardinal(FState.VBR), 4);
                Result := 2;
              end;
            $06:
              begin
                FState.MACH := Read(A, 4);
                FState.R[N] := Cardinal(((Cardinal(FState.R[N]) + 4) and $FFFFFFFF));
              end;
            $16:
              begin
                FState.MACL := Read(A, 4);
                FState.R[N] := Cardinal(((Cardinal(FState.R[N]) + 4) and $FFFFFFFF));
              end;
            $26:
              begin
                FState.PR := Read(A, 4);
                FState.R[N] := Cardinal(((Cardinal(FState.R[N]) + 4) and $FFFFFFFF));
              end;
            $07:
              begin
                FState.SR := (Read(A, 4) and $3F3);
                FState.R[N] := Cardinal(((Cardinal(FState.R[N]) + 4) and $FFFFFFFF));
                Result := 3;
              end;
            $17:
              begin
                FState.GBR := Read(A, 4);
                FState.R[N] := Cardinal(((Cardinal(FState.R[N]) + 4) and $FFFFFFFF));
                Result := 3;
              end;
            $27:
              begin
                FState.VBR := Read(A, 4);
                FState.R[N] := Cardinal(((Cardinal(FState.R[N]) + 4) and $FFFFFFFF));
                Result := 3;
              end;
            $0A:
              FState.MACH := A;
            $1A:
              FState.MACL := A;
            $2A:
              FState.PR := A;
            $0E:
              FState.SR := (A and $3F3);
            $1E:
              FState.GBR := A;
            $2E:
              FState.VBR := A;
          else
            Valid := False;
          end;
      5:
        FState.R[N] := Cardinal((Read(Cardinal((Cardinal(B) + (Cardinal(Cardinal((Op and 15))) * 4))), 4) and $FFFFFFFF));
      6:
        case Op and 15 of
          0:
            FState.R[N] := SX8(Read(B, 1));
          1:
            FState.R[N] := SX16(Read(B, 2));
          2:
            FState.R[N] := Read(B, 4);
          3:
            FState.R[N] := B;
          4:
            begin
              FState.R[N] := SX8(Read(B, 1));
              if N <> M then
                FState.R[M] := Cardinal(((Cardinal(FState.R[M]) + 1) and $FFFFFFFF));
            end;
          5:
            begin
              FState.R[N] := SX16(Read(B, 2));
              if N <> M then
                FState.R[M] := Cardinal(((Cardinal(FState.R[M]) + 2) and $FFFFFFFF));
            end;
          6:
            begin
              FState.R[N] := Read(B, 4);
              if N <> M then
                FState.R[M] := Cardinal(((Cardinal(FState.R[M]) + 4) and $FFFFFFFF));
            end;
          7:
            FState.R[N] := (not B);
          8:
            FState.R[N] := (((B and $FFFF0000) or ((B and $FF) shl 8)) or ((B shr 8) and $FF));
          9:
            FState.R[N] := ((B shl 16) or (B shr 16));
          10:
            begin
              FState.R[N] := Cardinal((((Cardinal(0) - B) - (OldSR and 1)) and $FFFFFFFF));
              SetT(((B <> 0) or Odd(OldSR)));
            end;
          11:
            FState.R[N] := Cardinal(((Cardinal(0) - B) and $FFFFFFFF));
          12:
            FState.R[N] := (B and $FF);
          13:
            FState.R[N] := (B and $FFFF);
          14:
            FState.R[N] := SX8(B);
          15:
            FState.R[N] := SX16(B);
        end;
      7:
        FState.R[N] := Cardinal(((Cardinal(A) + SX8(Cardinal(Op))) and $FFFFFFFF));
      8:
        case Op shr 8 of
          $80:
            Write(Cardinal((Cardinal(FState.R[M]) + Cardinal((Op and 15)))), Cardinal(FState.R[0]), 1);
          $81:
            Write(Cardinal((Cardinal(FState.R[M]) + (Cardinal(Cardinal((Op and 15))) * 2))), Cardinal(FState.R[0]), 2);
          $84:
            FState.R[0] := Cardinal((SX8(Read(Cardinal((Cardinal(FState.R[M]) + Cardinal((Op and 15)))), 1)) and $FFFFFFFF));
          $85:
            FState.R[0] := Cardinal((SX16(Read(Cardinal((Cardinal(FState.R[M]) + (Cardinal(Cardinal((Op and 15))) * 2))), 2)) and $FFFFFFFF));
          $88:
            SetT((FState.R[0] = SX8(Op)));
          $89, $8B, $8D, $8F:
            begin
              C := (Odd(OldSR) = ((Op and $200) = 0));
              if WasSlot then
                Valid := False
              else if Op and $400 <> 0 then
              begin
                if C then
                  Delay(Cardinal(((Cardinal(At) + 4) + (Cardinal(SX8(Cardinal(Op))) * 2))));
              end
              else if C then
              begin
                FState.PC := Cardinal((((Cardinal(At) + 4) + (Cardinal(SX8(Cardinal(Op))) * 2)) and $FFFFFFFF));
                Result := 3;
              end;
            end;
        else
          Valid := False;
        end;
      9:
        begin
          V := Cardinal(((Cardinal(At) + 4) and $FFFFFFFF));
          if WasSlot then
            V := Cardinal(((Cardinal(Target) + 2) and $FFFFFFFF));
          FState.R[N] := Cardinal((SX16(Read(Cardinal((Cardinal(V) + (Cardinal(Cardinal((Op and $FF))) * 2))), 2)) and $FFFFFFFF));
        end;
      10, 11:
        begin
          V := (Op and $FFF);
          if V and $800 <> 0 then
            V := (V or $FFFFF000);
          if Op shr 12 = 11 then
            FState.PR := Cardinal(((Cardinal(At) + 4) and $FFFFFFFF));
          Delay(Cardinal(((Cardinal(At) + 4) + (Cardinal(V) * 2))));
        end;
      12:
        begin
          V := (Op and $FF);
          case (Op shr 8) and 15 of
            0:
              Write(Cardinal((Cardinal(FState.GBR) + V)), Cardinal(FState.R[0]), 1);
            1:
              Write(Cardinal((Cardinal(FState.GBR) + (Cardinal(V) * 2))), Cardinal(FState.R[0]), 2);
            2:
              Write(Cardinal((Cardinal(FState.GBR) + (Cardinal(V) * 4))), Cardinal(FState.R[0]), 4);
            3:
              if WasSlot then
                Valid := False
              else
              begin
                ExceptionVector(V, Cardinal((UInt64(At) + 2) and $FFFFFFFF));
                Branch := True;
                Result := 8;
              end;
            4:
              FState.R[0] := Cardinal((SX8(Read(Cardinal((Cardinal(FState.GBR) + V)), 1)) and $FFFFFFFF));
            5:
              FState.R[0] := Cardinal((SX16(Read(Cardinal((Cardinal(FState.GBR) + (Cardinal(V) * 2))), 2)) and $FFFFFFFF));
            6:
              FState.R[0] := Cardinal((Read(Cardinal((Cardinal(FState.GBR) + (Cardinal(V) * 4))), 4) and $FFFFFFFF));
            7:
              begin
                A := Cardinal(((Cardinal(At) + 4) and $FFFFFFFF));
                if WasSlot then
                  A := Cardinal(((Cardinal(Target) + 2) and $FFFFFFFF));
                FState.R[0] := Cardinal(((Cardinal((A and $FFFFFFFC)) + (Cardinal(V) * 4)) and $FFFFFFFF));
              end;
            8:
              SetT(((FState.R[0] and V) = 0));
            9:
              FState.R[0] := (FState.R[0] and V);
            10:
              FState.R[0] := (FState.R[0] xor V);
            11:
              FState.R[0] := (FState.R[0] or V);
            12:
              begin
                SetT(((Read(Cardinal(((UInt64(FState.GBR) + FState.R[0]) and $FFFFFFFF)), 1) and V) = 0));
                Result := 3;
              end;
            13:
              begin
                A := Cardinal(((Cardinal(FState.GBR) + FState.R[0]) and $FFFFFFFF));
                Write(A, Cardinal((Read(A, 1) and V)), 1);
                Result := 3;
              end;
            14:
              begin
                A := Cardinal(((Cardinal(FState.GBR) + FState.R[0]) and $FFFFFFFF));
                Write(A, Cardinal((Read(A, 1) xor V)), 1);
                Result := 3;
              end;
            15:
              begin
                A := Cardinal(((Cardinal(FState.GBR) + FState.R[0]) and $FFFFFFFF));
                Write(A, Cardinal((Read(A, 1) or V)), 1);
                Result := 3;
              end;
          end;
        end;
      13:
        begin
          V := Cardinal(((Cardinal(At) + 4) and $FFFFFFFF));
          if WasSlot then
            V := Cardinal(((Cardinal(Target) + 2) and $FFFFFFFF));
          FState.R[N] := Cardinal((Read(Cardinal((Cardinal((V and $FFFFFFFC)) + (Cardinal(Cardinal((Op and $FF))) * 4))), 4) and $FFFFFFFF));
        end;
      14:
        FState.R[N] := SX8(Op);
    else
      Valid := False;
    end;
  if not Valid then
  begin
    V := At;
    if WasSlot then
      V := Target;
    ExceptionVector(4 + 2 * Ord(WasSlot), V);
    Result := 5;
  end
  else if WasSlot and not Branch then
    FState.PC := Target;
end;

// Cached instructions use live code bytes. Aligned reads use only a native
// cache hit or the on-chip TCSR byte latch; all other memory operations,
// misses and interrupt entry retain the checked executor below.
function TSH2.TryNativeRead(Address: Cardinal; Size: Integer; out Value: Cardinal): Boolean;
begin
  if (Size = 1) and (Address = FByteReadAddress) and (FByteReadValue <> nil) then
  begin
    Value := FByteReadValue^;
    FByteReadLatch^ := Byte(Value);
    Exit(True);
  end;
  var View := FDataView;
  if FDataIndexed then
    Inc(View, (Address shr 4) and 63);
  var Selected: TSH2DataCacheView;
  if (View = nil) or (Address and $FFFFFFF0 <> View.Line) or
    (Address and Cardinal(Size - 1) <> 0) then
  begin
    // The derived view can be absent after a state load or a different data
    // access. Bus availability must depend on hardware tags, not that hint.
    var Bank := FCacheBank;
    if (Bank = nil) or (Address shr 29 <> 0) or (Bank.CCR^ and 1 = 0) or
      (Address and Cardinal(Size - 1) <> 0) then
      Exit(False);
    var Entry := (Address shr 4) and 63;
    var Tag := (Address and $1FFFFC00) or 2;
    var Way := 3;
    while PCardinal(NativeUInt(Bank.Tags) + (Cardinal(Way) * 64 + Entry) * 4)^ <> Tag do
    begin
      Dec(Way);
      if Way < 0 then
        Exit(False);
    end;
    Selected.Data := Pointer(NativeUInt(Bank.RAM) + Cardinal(Way) * 1024 + Entry * 16);
    Selected.LRU := PByte(NativeUInt(Bank.LRU) + Entry);
    case Way of
      0:
        begin
          Selected.Mask := $07;
          Selected.Bits := $00;
        end;
      1:
        begin
          Selected.Mask := $19;
          Selected.Bits := $20;
        end;
      2:
        begin
          Selected.Mask := $2A;
          Selected.Bits := $14;
        end;
      3:
        begin
          Selected.Mask := $34;
          Selected.Bits := $0B;
        end;
    end;
    View := @Selected;
  end;
  // The owner updates this live view on every tag/CCR/purge/restore change.
  // These are cache RAM reads, not direct reads of guest work RAM or MMIO.
  View.LRU^ := (View.LRU^ and View.Mask) or View.Bits;
  var Data := NativeUInt(View.Data) + (Address and 15);
  case Size of
    1:
      Value := PByte(Data)^;
    2:
      Value := Swap(PWord(Data)^);
    4:
      begin
        var Raw := PCardinal(Data)^;
        Value := (Raw shl 24) or ((Raw and $FF00) shl 8) or
          ((Raw shr 8) and $FF00) or (Raw shr 24);
      end;
  else
    Exit(False);
  end;
  Result := True;
end;

function TSH2.SelectInstructionLine(Address: Cardinal): Boolean;
begin
  var Bank := FCacheBank;
  if (Address shr 29 <> 0) or (Bank.CCR^ and 1 = 0) then
    Exit(False);
  var Entry := (Address shr 4) and 63;
  var Tag := (Address and $1FFFFC00) or 2;
  var Way := 3;
  while PCardinal(NativeUInt(Bank.Tags) + (Cardinal(Way) * 64 + Entry) * 4)^ <> Tag do
  begin
    Dec(Way);
    if Way < 0 then
      Exit(False);
  end;
  FCodeLine := Address and $FFFFFFF0;
  FCodeData := Pointer(NativeUInt(Bank.RAM) + Cardinal(Way) * 1024 + Entry * 16);
  FCodeLRU := PByte(NativeUInt(Bank.LRU) + Entry);
  case Way of
    0:
      begin
        FCodeMask := $07;
        FCodeBits := $00;
      end;
    1:
      begin
        FCodeMask := $19;
        FCodeBits := $20;
      end;
    2:
      begin
        FCodeMask := $2A;
        FCodeBits := $14;
      end;
    3:
      begin
        FCodeMask := $34;
        FCodeBits := $0B;
      end;
  end;
  Result := True;
end;

function TSH2.StepCached: Integer;
label
  Slow, Commit;
var
  At, A, B, V, NextPC: Cardinal;
  Op: Word;
  N: Integer;
  WasSlot, delayed: Boolean;
begin
  At := FState.PC;
  WasSlot := FState.DelayPending;
  NextPC := At + 2;
  delayed := False;
  if FState.Sleeping or Odd(At) then
    goto Slow;
  if At and $FFFFFFF0 <> FCodeLine then
  begin
    if FCacheBank = nil then
      goto Slow;
    if not SelectInstructionLine(At) then
      goto Slow;
  end;
  if not WasSlot and (FIRQLevel > 0) and
    ((FIRQLevel = 16) or (FIRQLevel > Integer((FState.SR shr 4) and 15))) then
    goto Slow;
  // Fetch live bytes and retain the hardware LRU touch even on fallback.
  // The second identical touch in StepChecked is idempotent.
  FCodeLRU^ := (FCodeLRU^ and FCodeMask) or FCodeBits;
  Op := Swap(PWord(NativeUInt(FCodeData) + (At and 15))^);
  if Assigned(FOpcodeDecoder) then
    Op := FOpcodeDecoder(FDecodeUser, At, Op);
  Result := 1;
  case Op shr 12 of
    0:
      case Op of
        $0009:
          ;
        $0008:
          SetT(False);
        $0018:
          SetT(True);
        $0019:
          FState.SR := FState.SR and not Cardinal($301);
        $0028:
          begin
            FState.MACH := 0;
            FState.MACL := 0;
          end;
        $001B:
          begin
            FState.Sleeping := True;
            Result := 3;
          end;
        $000B:
          begin
            if WasSlot then
              goto Slow;
            FState.DelayTarget := FState.PR;
            delayed := True;
            Result := 2;
          end;
        $002B:
          begin
            if WasSlot then
              goto Slow;
            if not TryNativeRead(FState.R[15], 4, V) then
              goto Slow;
            if not TryNativeRead(FState.R[15] + 4, 4, A) then
              goto Slow;
            FState.SR := A and $3F3;
            Inc(FState.R[15], 8);
            FState.DelayTarget := V;
            delayed := True;
            Result := 4;
          end;
      else
        if (Op and $F0FF) in [$0003, $0023] then
        begin
          if FSH1 or WasSlot then
            goto Slow;
          if Op and $20 = 0 then
            FState.PR := At + 4;
          FState.DelayTarget := At + 4 + FState.R[(Op shr 8) and 15];
          delayed := True;
          Result := 2;
          goto Commit;
        end;
        if Op and 15 = 7 then
        begin
          if FSH1 then
            goto Slow;
          Result := ExecuteOpcode(Op, At, FState.DelayTarget, WasSlot);
          goto Commit;
        end;
        if (Op and 15) in [12, 13, 14] then
        begin
          var Size := 1 shl (Op and 3);
          A := FState.R[(Op shr 4) and 15] + FState.R[0];
          if not TryNativeRead(A, Size, V) then
            goto Slow;
          N := (Op shr 8) and 15;
          case Size of
            1:
              FState.R[N] := SX8(V);
            2:
              FState.R[N] := SX16(V);
            4:
              FState.R[N] := V;
          end;
          goto Commit;
        end;
        N := (Op shr 8) and 15;
        case Op and $FF of
          $02:
            FState.R[N] := FState.SR;
          $12:
            FState.R[N] := FState.GBR;
          $22:
            FState.R[N] := FState.VBR;
          $0A:
            FState.R[N] := FState.MACH;
          $1A:
            FState.R[N] := FState.MACL;
          $2A:
            FState.R[N] := FState.PR;
          $29:
            FState.R[N] := FState.SR and 1;
        else
          goto Slow;
        end;
      end;
    2:
      begin
        if (Op and 15) in [7, 12, 13, 14, 15] then
        begin
          Result := ExecuteOpcode(Op, At, FState.DelayTarget, WasSlot);
          goto Commit;
        end;
        if not ((Op and 15) in [8, 9, 10, 11]) then
          goto Slow;
        N := (Op shr 8) and 15;
        A := FState.R[N];
        B := FState.R[(Op shr 4) and 15];
        case Op and 15 of
          8:
            SetT(A and B = 0);
          9:
            FState.R[N] := A and B;
          10:
            FState.R[N] := A xor B;
          11:
            FState.R[N] := A or B;
        end;
      end;
    3:
      begin
        if (Op and 15) in [4, 5, 10, 11, 13, 14, 15] then
        begin
          if FSH1 and ((Op and 15) in [5, 13]) then
            goto Slow;
          Result := ExecuteOpcode(Op, At, FState.DelayTarget, WasSlot);
          goto Commit;
        end;
        N := (Op shr 8) and 15;
        A := FState.R[N];
        B := FState.R[(Op shr 4) and 15];
        case Op and 15 of
          0:
            SetT(A = B);
          2:
            SetT(A >= B);
          3:
            SetT(Integer(A) >= Integer(B));
          6:
            SetT(A > B);
          7:
            SetT(Integer(A) > Integer(B));
          8:
            FState.R[N] := A - B;
          12:
            FState.R[N] := A + B;
        else
          goto Slow;
        end;
      end;
    4:
      begin
        N := (Op shr 8) and 15;
        A := FState.R[N];
        case Op and $FF of
          $06, $16, $26, $07, $17, $27:
            begin
              if not TryNativeRead(A, 4, V) then
                goto Slow;
              case Op and $FF of
                $06:
                  FState.MACH := V;
                $16:
                  FState.MACL := V;
                $26:
                  FState.PR := V;
                $07:
                  FState.SR := V and $3F3;
                $17:
                  FState.GBR := V;
                $27:
                  FState.VBR := V;
              end;
              Inc(FState.R[N], 4);
              if Op and 1 <> 0 then
                Result := 3;
            end;
          $0A, $1A, $2A, $0E, $1E, $2E, $24, $25:
            begin
              Result := ExecuteOpcode(Op, At, FState.DelayTarget, WasSlot);
              goto Commit;
            end;
          $00, $20:
            begin
              SetT(A and $80000000 <> 0);
              FState.R[N] := A shl 1;
            end;
          $01:
            begin
              SetT(Odd(A));
              FState.R[N] := A shr 1;
            end;
          $21:
            begin
              SetT(Odd(A));
              FState.R[N] := (A shr 1) or (A and $80000000);
            end;
          $04:
            begin
              SetT(A and $80000000 <> 0);
              FState.R[N] := (A shl 1) or (A shr 31);
            end;
          $05:
            begin
              SetT(Odd(A));
              FState.R[N] := (A shr 1) or (A shl 31);
            end;
          $08:
            FState.R[N] := A shl 2;
          $09:
            FState.R[N] := A shr 2;
          $18:
            FState.R[N] := A shl 8;
          $19:
            FState.R[N] := A shr 8;
          $28:
            FState.R[N] := A shl 16;
          $29:
            FState.R[N] := A shr 16;
          $10:
            begin
              if FSH1 then
                goto Slow;
              FState.R[N] := A - 1;
              SetT(FState.R[N] = 0);
            end;
          $11:
            SetT(Integer(A) >= 0);
          $15:
            SetT(Integer(A) > 0);
          $0B, $2B:
            begin
              if WasSlot then
                goto Slow;
              if Op and $20 = 0 then
                FState.PR := At + 4;
              FState.DelayTarget := A;
              delayed := True;
              Result := 2;
            end;
        else
          goto Slow;
        end;
      end;
    5:
      begin
        A := FState.R[(Op shr 4) and 15] + (Op and 15) * 4;
        if not TryNativeRead(A, 4, V) then
          goto Slow;
        FState.R[(Op shr 8) and 15] := V;
      end;
    6:
      begin
        if (Op and 15) in [0, 1, 2, 4, 5, 6] then
        begin
          var M := (Op shr 4) and 15;
          var Size := 1 shl (Op and 3);
          if not TryNativeRead(FState.R[M], Size, V) then
            goto Slow;
          N := (Op shr 8) and 15;
          case Size of
            1:
              FState.R[N] := SX8(V);
            2:
              FState.R[N] := SX16(V);
            4:
              FState.R[N] := V;
          end;
          if (Op and 4 <> 0) and (N <> M) then
            Inc(FState.R[M], Size);
          goto Commit;
        end;
        N := (Op shr 8) and 15;
        B := FState.R[(Op shr 4) and 15];
        case Op and 15 of
          3:
            FState.R[N] := B;
          7:
            FState.R[N] := not B;
          8:
            FState.R[N] := (B and $FFFF0000) or ((B and $FF) shl 8) or ((B shr 8) and $FF);
          9:
            FState.R[N] := (B shl 16) or (B shr 16);
          10:
            begin
              FState.R[N] := 0 - B - (FState.SR and 1);
              SetT((B <> 0) or Odd(FState.SR));
            end;
          11:
            FState.R[N] := 0 - B;
          12:
            FState.R[N] := B and $FF;
          13:
            FState.R[N] := B and $FFFF;
          14:
            FState.R[N] := SX8(B);
          15:
            FState.R[N] := SX16(B);
        end;
      end;
    7:
      begin
        N := (Op shr 8) and 15;
        FState.R[N] := FState.R[N] + SX8(Op);
      end;
    8:
      case Op shr 8 of
        $84, $85:
          begin
            var Size := 1 shl ((Op shr 8) and 1);
            A := FState.R[(Op shr 4) and 15] + Cardinal((Op and 15) * Size);
            if not TryNativeRead(A, Size, V) then
              goto Slow;
            if Size = 1 then
              FState.R[0] := SX8(V)
            else
              FState.R[0] := SX16(V);
          end;
        $88:
          SetT(FState.R[0] = SX8(Op));
        $8D, $8F:
          begin
            if FSH1 or WasSlot then
              goto Slow;
            if Odd(FState.SR) = (Op and $200 = 0) then
            begin
              FState.DelayTarget := At + 4 + SX8(Op) * 2;
              delayed := True;
              Result := 2;
            end;
          end;
        $89, $8B:
          begin
            if WasSlot then
              goto Slow;
            if Odd(FState.SR) = (Op and $200 = 0) then
            begin
              NextPC := At + 4 + SX8(Op) * 2;
              Result := 3;
            end;
          end;
      else
        goto Slow;
      end;
    9, 13:
      begin
        A := At + 4;
        if WasSlot then
          A := FState.DelayTarget + 2;
        var Size := 2;
        if Op shr 12 = 9 then
          A := A + (Op and $FF) * 2
        else
        begin
          Size := 4;
          A := (A and $FFFFFFFC) + (Op and $FF) * 4;
        end;
        if not TryNativeRead(A, Size, V) then
          goto Slow;
        if Size = 2 then
          V := SX16(V);
        FState.R[(Op shr 8) and 15] := V;
      end;
    10, 11:
      begin
        if WasSlot then
          goto Slow;
        V := Op and $FFF;
        if V and $800 <> 0 then
          V := V or $FFFFF000;
        if Op shr 12 = 11 then
          FState.PR := At + 4;
        FState.DelayTarget := At + 4 + V * 2;
        delayed := True;
        Result := 2;
      end;
    12:
      case (Op shr 8) and 15 of
        4, 5, 6:
          begin
            var Size := 1 shl ((Op shr 8) and 3);
            A := FState.GBR + Cardinal((Op and $FF) * Size);
            if not TryNativeRead(A, Size, V) then
              goto Slow;
            case Size of
              1:
                FState.R[0] := SX8(V);
              2:
                FState.R[0] := SX16(V);
              4:
                FState.R[0] := V;
            end;
          end;
        7:
          begin
            V := At + 4;
            if WasSlot then
              V := FState.DelayTarget + 2;
            FState.R[0] := (V and $FFFFFFFC) + (Op and $FF) * 4;
          end;
        8:
          SetT(FState.R[0] and (Op and $FF) = 0);
        9:
          FState.R[0] := FState.R[0] and (Op and $FF);
        10:
          FState.R[0] := FState.R[0] xor (Op and $FF);
        11:
          FState.R[0] := FState.R[0] or (Op and $FF);
      else
        goto Slow;
      end;
    14:
      FState.R[(Op shr 8) and 15] := SX8(Op);
  else
    goto Slow;
  end;
  goto Commit;
Slow:
  Exit(0);
Commit:
  if WasSlot then
    NextPC := FState.DelayTarget;
  FState.PC := NextPC;
  FState.DelayPending := delayed;
  FInterruptAccepted := False;
  FState.Cycles := Add64(FState.Cycles, UInt64(Result));
end;

function TSH2.Step: Integer;
begin
  Result := StepCached;
  if Result = 0 then
    Result := StepChecked;
end;

function TSH2.StepChecked: Integer;
var
  Op: Word;
  At, Target, A, B: Cardinal;
  N, M: Integer;
  WasSlot, Fast: Boolean;
begin
  Result := 1;
  FInterruptAccepted := False;
  At := FState.PC;
  WasSlot := FState.DelayPending;
  Target := FState.DelayTarget;
  if not WasSlot and (FIRQLevel > 0) and
    ((FIRQLevel = 16) or (FIRQLevel > Integer((FState.SR shr 4) and 15))) then
  begin
    ExceptionVector(FIRQVector, At);
    FState.SR := ((FState.SR and (not Cardinal($F0))) or (Cardinal((FIRQLevel and 15)) shl 4));
    if FIRQLevel = 16 then
      FState.SR := (FState.SR or $F0);
    Result := 5;
    FInterruptAccepted := True;
    FState.Cycles := Add64(FState.Cycles, UInt64(Result));
    Exit;
  end;
  if FState.Sleeping then
  begin
    FState.Cycles := Add64(FState.Cycles, 1);
    Exit;
  end;
  try
    if Odd(At) then
      raise ESH2Address.Create('SH-2 instruction address error');
    if At and $FFFFFFF0 = FCodeLine then
    begin
      FCodeLRU^ := (FCodeLRU^ and FCodeMask) or FCodeBits;
      Op := Swap(PWord(NativeUInt(FCodeData) + (At and 15))^);
    end
    else
      Op := Word((FFetch(FUser, At, 2) and $FFFF));
    if Assigned(FOpcodeDecoder) then
      Op := FOpcodeDecoder(FDecodeUser, At, Op);
    FState.PC := Cardinal(((Cardinal(At) + 2) and $FFFFFFFF));
    FState.DelayPending := False;
    // Common ISA groups use a small executor frame. Branches with delay
    // slots, complex arithmetic, system registers and illegal opcodes retain
    // the full decoder. Every instruction still fetches and consumes cycles.
    Fast := True;
    case Op shr 12 of
      0:
        Fast := Op = $0009;
      1:
        Write(FState.R[(Op shr 8) and 15] + (Op and 15) * 4,
          FState.R[(Op shr 4) and 15], 4);
      2:
        begin
          N := (Op shr 8) and 15;
          A := FState.R[N];
          B := FState.R[(Op shr 4) and 15];
          case Op and 15 of
            0:
              Write(A, B, 1);
            1:
              Write(A, B, 2);
            2:
              Write(A, B, 4);
            8:
              SetT(A and B = 0);
            9:
              FState.R[N] := A and B;
            10:
              FState.R[N] := A xor B;
            11:
              FState.R[N] := A or B;
          else
            Fast := False;
          end;
        end;
      3:
        begin
          N := (Op shr 8) and 15;
          A := FState.R[N];
          B := FState.R[(Op shr 4) and 15];
          case Op and 15 of
            0:
              SetT(A = B);
            2:
              SetT(A >= B);
            3:
              SetT(Integer(A) >= Integer(B));
            6:
              SetT(A > B);
            7:
              SetT(Integer(A) > Integer(B));
            8:
              FState.R[N] := A - B;
            12:
              FState.R[N] := A + B;
          else
            Fast := False;
          end;
        end;
      5:
        FState.R[(Op shr 8) and 15] := Read(FState.R[(Op shr 4) and 15] + (Op and 15) * 4, 4);
      6:
        begin
          N := (Op shr 8) and 15;
          M := (Op shr 4) and 15;
          B := FState.R[M];
          case Op and 15 of
            0, 4:
              begin
                FState.R[N] := SX8(Read(B, 1));
                if (Op and 4 <> 0) and (N <> M) then
                  Inc(FState.R[M]);
              end;
            1, 5:
              begin
                FState.R[N] := SX16(Read(B, 2));
                if (Op and 4 <> 0) and (N <> M) then
                  Inc(FState.R[M], 2);
              end;
            2, 6:
              begin
                FState.R[N] := Read(B, 4);
                if (Op and 4 <> 0) and (N <> M) then
                  Inc(FState.R[M], 4);
              end;
            3:
              FState.R[N] := B;
            7:
              FState.R[N] := not B;
            8:
              FState.R[N] := (B and $FFFF0000) or ((B and $FF) shl 8) or ((B shr 8) and $FF);
            9:
              FState.R[N] := (B shl 16) or (B shr 16);
            10:
              begin
                FState.R[N] := 0 - B - (FState.SR and 1);
                SetT((B <> 0) or Odd(FState.SR));
              end;
            11:
              FState.R[N] := 0 - B;
            12:
              FState.R[N] := B and $FF;
            13:
              FState.R[N] := B and $FFFF;
            14:
              FState.R[N] := SX8(B);
            15:
              FState.R[N] := SX16(B);
          end;
        end;
      7:
        begin
          N := (Op shr 8) and 15;
          FState.R[N] := FState.R[N] + SX8(Op);
        end;
      8:
        case Op shr 8 of
          $88:
            SetT(FState.R[0] = SX8(Op));
          $89, $8B:
            if WasSlot then
              Fast := False
            else if Odd(FState.SR) = (Op and $200 = 0) then
            begin
              FState.PC := At + 4 + SX8(Op) * 2;
              Result := 3;
            end;
        else
          Fast := False;
        end;
      9:
        begin
          A := At + 4;
          if WasSlot then
            A := Target + 2;
          FState.R[(Op shr 8) and 15] := SX16(Read(A + (Op and $FF) * 2, 2));
        end;
      13:
        begin
          A := At + 4;
          if WasSlot then
            A := Target + 2;
          FState.R[(Op shr 8) and 15] := Read((A and $FFFFFFFC) + (Op and $FF) * 4, 4);
        end;
      14:
        FState.R[(Op shr 8) and 15] := SX8(Op);
    else
      Fast := False;
    end;
    if Fast then
    begin
      if WasSlot then
        FState.PC := Target;
    end
    else
      Result := ExecuteOpcode(Op, At, Target, WasSlot);
  except
    on E: ESH2Address do
    begin
      ExceptionVector(9, At);
      Result := 5;
    end;
  end;
  FState.Cycles := Add64(FState.Cycles, UInt64(Result));
end;

{$Q+}{$R+}

procedure TSH2.AddWaitCycles(Count: Integer);
begin
  FState.Cycles := Add64(FState.Cycles, UInt64(Count));
end;

function TSH2.Run(Cycles: Integer): Integer;
begin
  Result := 0;
  while Result < Cycles do
    Inc(Result, Step);
end;

procedure TSH2.SerializeState(Archive: TStateArchive);
begin
  if Archive.Loading then
  begin
    FInterruptAccepted := False;
    InvalidateInstructionLine;
  end;
  Archive.Field(FState, SizeOf(FState));
  Archive.Field(FIRQLevel, SizeOf(FIRQLevel));
  Archive.Field(FIRQVector, SizeOf(FIRQVector));
  if (FIRQLevel < 0) or (FIRQLevel > 16) or (FIRQVector < 0) or (FIRQVector > 255) then
    raise EReadError.Create('Invalid snapshot SH-2 interrupt');
end;

end.

