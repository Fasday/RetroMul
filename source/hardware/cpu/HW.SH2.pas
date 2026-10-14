unit HW.SH2;

interface

uses System.SysUtils, System.Classes, Core.Snapshots;

type
  TSH2Read = function(User: Pointer; Address: Cardinal; Size: Integer): Cardinal;
  TSH2Write = procedure(User: Pointer; Address, Value: Cardinal; Size: Integer);
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
    FWrite: TSH2Write;
    FUser: Pointer;
    FIRQLevel, FIRQVector: Integer;
    function Read(Address: Cardinal; Size: Integer): Cardinal;
    procedure Write(Address, Value: Cardinal; Size: Integer);
    procedure SetT(Value: Boolean);
    procedure ExceptionVector(Vector: Integer; PC: Cardinal);
  public
    constructor Create(ReadCallback: TSH2Read; WriteCallback: TSH2Write; User: Pointer; FetchCallback: TSH2Read = nil);
    procedure Reset;
    function Step: Integer;
    function Run(Cycles: Integer): Integer;
    procedure Interrupt(Level, Vector: Integer);
    procedure SerializeState(Archive: TStateArchive);
    property State: TSH2State read FState write FState;
  end;

implementation

// Native interpreter for the SH-2 ISA. Reference: Renesas REJ09B0171,
// SH-1/SH-2/SH-DSP Software Manual. Architectural arithmetic wraps at 32 bits.
{$Q-}{$R-}

type ESH2Address = class(Exception);

function SX8(Value: Cardinal): Cardinal; inline;
begin Result := Cardinal(Integer(ShortInt(Value and $FF))); end;
function SX16(Value: Cardinal): Cardinal; inline;
begin Result := Cardinal(Integer(SmallInt(Value and $FFFF))); end;

constructor TSH2.Create(ReadCallback: TSH2Read; WriteCallback: TSH2Write; User: Pointer; FetchCallback: TSH2Read);
begin
  inherited Create;
  if not Assigned(ReadCallback) or not Assigned(WriteCallback) then
    raise EArgumentException.Create('SH-2 requires memory callbacks');
  FRead := ReadCallback; FWrite := WriteCallback; FUser := User;
  FFetch := FetchCallback; if not Assigned(FFetch) then FFetch := FRead;
end;

function TSH2.Read(Address: Cardinal; Size: Integer): Cardinal;
begin
  if Address and Cardinal(Size - 1) <> 0 then raise ESH2Address.Create('SH-2 address error');
  Result := FRead(FUser, Address, Size);
end;
procedure TSH2.Write(Address, Value: Cardinal; Size: Integer);
begin
  if Address and Cardinal(Size - 1) <> 0 then raise ESH2Address.Create('SH-2 address error');
  FWrite(FUser, Address, Value, Size);
end;
procedure TSH2.SetT(Value: Boolean);
begin FState.SR := (FState.SR and not Cardinal(1)) or Cardinal(Ord(Value)); end;

procedure TSH2.Reset;
begin
  FState := Default(TSH2State);
  FState.SR := $F0;
  FState.PC := Read(0, 4);
  FState.R[15] := Read(4, 4);
  FIRQLevel := 0; FIRQVector := 0;
end;

procedure TSH2.Interrupt(Level, Vector: Integer);
begin
  if (Level < 0) or (Level > 16) or (Vector < 0) or (Vector > 255) then
    raise EArgumentOutOfRangeException.Create('Invalid SH-2 interrupt');
  FIRQLevel := Level; FIRQVector := Vector;
end;

procedure TSH2.ExceptionVector(Vector: Integer; PC: Cardinal);
begin
  Dec(FState.R[15], 4); Write(FState.R[15], FState.SR, 4);
  Dec(FState.R[15], 4); Write(FState.R[15], PC, 4);
  FState.PC := Read(FState.VBR + Cardinal(Vector) * 4, 4);
  FState.DelayPending := False; FState.Sleeping := False;
end;

function TSH2.Step: Integer;
var
  Op: Word;
  N, M: Integer;
  At, A, B, V, Target, OldSR, Carry: Cardinal;
  WasSlot, Branch, Valid, OldQ, Q, MFlag, C: Boolean;
  Product: UInt64;
  Accumulator: Int64;
  procedure Delay(Address: Cardinal);
  begin
    if WasSlot then begin Valid := False; Exit; end;
    FState.DelayTarget := Address; FState.DelayPending := True; Branch := True;
    Result := 2;
  end;
begin
  Result := 1;
  At := FState.PC;
  WasSlot := FState.DelayPending;
  Target := FState.DelayTarget;
  if not WasSlot and (FIRQLevel > 0) and
    ((FIRQLevel = 16) or (FIRQLevel > Integer((FState.SR shr 4) and 15))) then
  begin
    ExceptionVector(FIRQVector, At);
    FState.SR := (FState.SR and not Cardinal($F0)) or (Cardinal(FIRQLevel and 15) shl 4);
    if FIRQLevel = 16 then FState.SR := FState.SR or $F0;
    Result := 5; Inc(FState.Cycles, Result); Exit;
  end;
  if FState.Sleeping then begin Inc(FState.Cycles); Exit; end;
  try
    if Odd(At) then raise ESH2Address.Create('SH-2 instruction address error');
    Op := FFetch(FUser, At, 2);
    FState.PC := At + 2;
    FState.DelayPending := False;
    N := (Op shr 8) and 15; M := (Op shr 4) and 15;
    A := FState.R[N]; B := FState.R[M]; OldSR := FState.SR;
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
    if Valid then case Op shr 12 of
      0:
        case Op and $F of
          4: Write(A + FState.R[0], B, 1);
          5: Write(A + FState.R[0], B, 2);
          6: Write(A + FState.R[0], B, 4);
          7: begin FState.MACL := A * B; Result := 2; end;
          12: FState.R[N] := SX8(Read(B + FState.R[0], 1));
          13: FState.R[N] := SX16(Read(B + FState.R[0], 2));
          14: FState.R[N] := Read(B + FState.R[0], 4);
          15:
            begin
              A := Read(FState.R[M], 4); Inc(FState.R[M], 4);
              B := Read(FState.R[N], 4); Inc(FState.R[N], 4);
              Accumulator := Int64(Integer(A)) * Integer(B);
              Accumulator := Accumulator + Int64((UInt64(FState.MACH) shl 32) or FState.MACL);
              if FState.SR and 2 <> 0 then
              begin
                // Saturating MAC.L uses a signed 48-bit accumulator.
                Accumulator := (Int64(SmallInt(FState.MACH)) shl 32) + FState.MACL +
                  Int64(Integer(A)) * Integer(B);
                if Accumulator > Int64($7FFFFFFFFFFF) then Accumulator := $7FFFFFFFFFFF;
                if Accumulator < -Int64($800000000000) then Accumulator := -Int64($800000000000);
              end;
              FState.MACH := UInt64(Accumulator) shr 32; FState.MACL := Cardinal(Accumulator); Result := 3;
            end;
        else
          case Op and $FF of
            $02: FState.R[N] := FState.SR;
            $12: FState.R[N] := FState.GBR;
            $22: FState.R[N] := FState.VBR;
            $0A: FState.R[N] := FState.MACH;
            $1A: FState.R[N] := FState.MACL;
            $2A: FState.R[N] := FState.PR;
            $29: FState.R[N] := FState.SR and 1;
            $03: begin FState.PR := At + 4; Delay(At + 4 + A); end;
            $23: Delay(At + 4 + A);
          else
            case Op of
              $0008: SetT(False);
              $0018: SetT(True);
              $0009: ;
              $0019: FState.SR := FState.SR and not Cardinal($301);
              $0028: begin FState.MACH := 0; FState.MACL := 0; end;
              $000B: Delay(FState.PR);
              $002B:
                begin
                  V := Read(FState.R[15], 4); FState.SR := Read(FState.R[15] + 4, 4) and $3F3;
                  Inc(FState.R[15], 8); Delay(V); Result := 4;
                end;
              $001B: begin FState.Sleeping := True; Result := 3; end;
            else Valid := False;
            end;
          end;
        end;
      1: Write(A + Cardinal(Op and 15) * 4, B, 4);
      2:
        case Op and 15 of
          0: Write(A, B, 1);
          1: Write(A, B, 2);
          2: Write(A, B, 4);
          4: begin Dec(FState.R[N]); Write(FState.R[N], B, 1); end;
          5: begin Dec(FState.R[N], 2); Write(FState.R[N], B, 2); end;
          6: begin Dec(FState.R[N], 4); Write(FState.R[N], B, 4); end;
          7:
            begin
              FState.SR := (FState.SR and not Cardinal($301)) or ((A shr 23) and $100) or ((B shr 22) and $200);
              SetT(((A xor B) and $80000000) <> 0);
            end;
          8: SetT(A and B = 0);
          9: FState.R[N] := A and B;
          10: FState.R[N] := A xor B;
          11: FState.R[N] := A or B;
          12: begin V := A xor B; SetT((V and $FF = 0) or (V and $FF00 = 0) or
            (V and $FF0000 = 0) or (V and $FF000000 = 0)); end;
          13: FState.R[N] := (A shr 16) or (B shl 16);
          14: FState.MACL := Cardinal(Word(A)) * Word(B);
          15: FState.MACL := Cardinal(Integer(SmallInt(A)) * SmallInt(B));
        else Valid := False;
        end;
      3:
        case Op and 15 of
          0: SetT(A = B);
          2: SetT(A >= B);
          3: SetT(Integer(A) >= Integer(B));
          4:
            begin
              OldQ := OldSR and $100 <> 0; MFlag := OldSR and $200 <> 0;
              Q := A and $80000000 <> 0; A := (A shl 1) or (OldSR and 1);
              V := A;
              if OldQ = MFlag then begin A := A - B; C := A > V; end
              else begin A := A + B; C := A < V; end;
              Q := Q xor C xor MFlag;
              FState.R[N] := A;
              FState.SR := (FState.SR and not Cardinal($100)) or (Cardinal(Ord(Q)) shl 8);
              SetT(Q = MFlag);
            end;
          5: begin Product := UInt64(A) * B; FState.MACH := Product shr 32; FState.MACL := Cardinal(Product); Result := 2; end;
          6: SetT(A > B);
          7: SetT(Integer(A) > Integer(B));
          8: FState.R[N] := A - B;
          10: begin Carry := OldSR and 1; FState.R[N] := A - B - Carry; SetT(UInt64(A) < UInt64(B) + Carry); end;
          11: begin V := A - B; FState.R[N] := V; SetT(((A xor B) and (A xor V) and $80000000) <> 0); end;
          12: FState.R[N] := A + B;
          13: begin Product := UInt64(Int64(Integer(A)) * Integer(B)); FState.MACH := Product shr 32; FState.MACL := Cardinal(Product); Result := 2; end;
          14: begin Product := UInt64(A) + B + (OldSR and 1); FState.R[N] := Cardinal(Product); SetT(Product > $FFFFFFFF); end;
          15: begin V := A + B; FState.R[N] := V; SetT(((not (A xor B)) and (A xor V) and $80000000) <> 0); end;
        else Valid := False;
        end;
      4:
        if Op and 15 = 15 then
        begin
          A := SX16(Read(FState.R[M], 2)); Inc(FState.R[M], 2);
          B := SX16(Read(FState.R[N], 2)); Inc(FState.R[N], 2);
          Accumulator := Int64(Integer(A)) * Integer(B);
          if FState.SR and 2 <> 0 then
          begin
            Accumulator := Accumulator + Integer(FState.MACL);
            if (Accumulator > High(Integer)) or (Accumulator < Low(Integer)) then
              FState.MACH := FState.MACH or 1;
            if Accumulator > High(Integer) then Accumulator := High(Integer);
            if Accumulator < Low(Integer) then Accumulator := Low(Integer);
            FState.MACL := Cardinal(Accumulator);
          end
          else
          begin
            Accumulator := Accumulator + Int64((UInt64(FState.MACH) shl 32) or FState.MACL);
            FState.MACH := UInt64(Accumulator) shr 32; FState.MACL := Cardinal(Accumulator);
          end;
          Result := 3;
        end
        else
          case Op and $FF of
            $00, $20: begin SetT(A and $80000000 <> 0); FState.R[N] := A shl 1; end;
            $01: begin SetT(Odd(A)); FState.R[N] := A shr 1; end;
            $21: begin SetT(Odd(A)); FState.R[N] := (A shr 1) or (A and $80000000); end;
            $04: begin SetT(A and $80000000 <> 0); FState.R[N] := (A shl 1) or (A shr 31); end;
            $05: begin SetT(Odd(A)); FState.R[N] := (A shr 1) or (A shl 31); end;
            $24: begin SetT(A and $80000000 <> 0); FState.R[N] := (A shl 1) or (OldSR and 1); end;
            $25: begin SetT(Odd(A)); FState.R[N] := (A shr 1) or ((OldSR and 1) shl 31); end;
            $08: FState.R[N] := A shl 2;
            $09: FState.R[N] := A shr 2;
            $18: FState.R[N] := A shl 8;
            $19: FState.R[N] := A shr 8;
            $28: FState.R[N] := A shl 16;
            $29: FState.R[N] := A shr 16;
            $10: begin FState.R[N] := A - 1; SetT(FState.R[N] = 0); end;
            $11: SetT(Integer(A) >= 0);
            $15: SetT(Integer(A) > 0);
            $1B: begin V := Read(A, 1); SetT(V = 0); Write(A, V or $80, 1); Result := 4; end;
            $0B: begin FState.PR := At + 4; Delay(A); end;
            $2B: Delay(A);
            $02: begin Dec(FState.R[N], 4); Write(FState.R[N], FState.MACH, 4); end;
            $12: begin Dec(FState.R[N], 4); Write(FState.R[N], FState.MACL, 4); end;
            $22: begin Dec(FState.R[N], 4); Write(FState.R[N], FState.PR, 4); end;
            $03: begin Dec(FState.R[N], 4); Write(FState.R[N], FState.SR, 4); Result := 2; end;
            $13: begin Dec(FState.R[N], 4); Write(FState.R[N], FState.GBR, 4); Result := 2; end;
            $23: begin Dec(FState.R[N], 4); Write(FState.R[N], FState.VBR, 4); Result := 2; end;
            $06: begin FState.MACH := Read(A, 4); Inc(FState.R[N], 4); end;
            $16: begin FState.MACL := Read(A, 4); Inc(FState.R[N], 4); end;
            $26: begin FState.PR := Read(A, 4); Inc(FState.R[N], 4); end;
            $07: begin FState.SR := Read(A, 4) and $3F3; Inc(FState.R[N], 4); Result := 3; end;
            $17: begin FState.GBR := Read(A, 4); Inc(FState.R[N], 4); Result := 3; end;
            $27: begin FState.VBR := Read(A, 4); Inc(FState.R[N], 4); Result := 3; end;
            $0A: FState.MACH := A;
            $1A: FState.MACL := A;
            $2A: FState.PR := A;
            $0E: FState.SR := A and $3F3;
            $1E: FState.GBR := A;
            $2E: FState.VBR := A;
          else Valid := False;
          end;
      5: FState.R[N] := Read(B + Cardinal(Op and 15) * 4, 4);
      6:
        case Op and 15 of
          0: FState.R[N] := SX8(Read(B, 1));
          1: FState.R[N] := SX16(Read(B, 2));
          2: FState.R[N] := Read(B, 4);
          3: FState.R[N] := B;
          4: begin FState.R[N] := SX8(Read(B, 1)); if N <> M then Inc(FState.R[M]); end;
          5: begin FState.R[N] := SX16(Read(B, 2)); if N <> M then Inc(FState.R[M], 2); end;
          6: begin FState.R[N] := Read(B, 4); if N <> M then Inc(FState.R[M], 4); end;
          7: FState.R[N] := not B;
          8: FState.R[N] := (B and $FFFF0000) or ((B and $FF) shl 8) or ((B shr 8) and $FF);
          9: FState.R[N] := (B shl 16) or (B shr 16);
          10: begin FState.R[N] := 0 - B - (OldSR and 1); SetT((B <> 0) or Odd(OldSR)); end;
          11: FState.R[N] := 0 - B;
          12: FState.R[N] := B and $FF;
          13: FState.R[N] := B and $FFFF;
          14: FState.R[N] := SX8(B);
          15: FState.R[N] := SX16(B);
        end;
      7: FState.R[N] := A + SX8(Op);
      8:
        case Op shr 8 of
          $80: Write(FState.R[M] + Cardinal(Op and 15), FState.R[0], 1);
          $81: Write(FState.R[M] + Cardinal(Op and 15) * 2, FState.R[0], 2);
          $84: FState.R[0] := SX8(Read(FState.R[M] + Cardinal(Op and 15), 1));
          $85: FState.R[0] := SX16(Read(FState.R[M] + Cardinal(Op and 15) * 2, 2));
          $88: SetT(FState.R[0] = SX8(Op));
          $89, $8B, $8D, $8F:
            begin
              C := Odd(OldSR) = ((Op and $200) = 0);
              if WasSlot then Valid := False
              else if Op and $400 <> 0 then
              begin
                if C then Delay(At + 4 + SX8(Op) * 2);
              end
              else if C then begin FState.PC := At + 4 + SX8(Op) * 2; Result := 3; end;
            end;
        else Valid := False;
        end;
      9:
        begin
          V := At + 4; if WasSlot then V := Target + 2;
          FState.R[N] := SX16(Read(V + Cardinal(Op and $FF) * 2, 2));
        end;
      10, 11:
        begin
          V := Op and $FFF;
          if V and $800 <> 0 then V := V or $FFFFF000;
          if Op shr 12 = 11 then FState.PR := At + 4;
          Delay(At + 4 + V * 2);
        end;
      12:
        begin
          V := Op and $FF;
          case (Op shr 8) and 15 of
            0: Write(FState.GBR + V, FState.R[0], 1);
            1: Write(FState.GBR + V * 2, FState.R[0], 2);
            2: Write(FState.GBR + V * 4, FState.R[0], 4);
            3: if WasSlot then Valid := False else begin ExceptionVector(V, At + 2); Branch := True; Result := 8; end;
            4: FState.R[0] := SX8(Read(FState.GBR + V, 1));
            5: FState.R[0] := SX16(Read(FState.GBR + V * 2, 2));
            6: FState.R[0] := Read(FState.GBR + V * 4, 4);
            7: begin A := At + 4; if WasSlot then A := Target + 2; FState.R[0] := (A and $FFFFFFFC) + V * 4; end;
            8: SetT(FState.R[0] and V = 0);
            9: FState.R[0] := FState.R[0] and V;
            10: FState.R[0] := FState.R[0] xor V;
            11: FState.R[0] := FState.R[0] or V;
            12: begin SetT(Read(FState.GBR + FState.R[0], 1) and V = 0); Result := 3; end;
            13: begin A := FState.GBR + FState.R[0]; Write(A, Read(A, 1) and V, 1); Result := 3; end;
            14: begin A := FState.GBR + FState.R[0]; Write(A, Read(A, 1) xor V, 1); Result := 3; end;
            15: begin A := FState.GBR + FState.R[0]; Write(A, Read(A, 1) or V, 1); Result := 3; end;
          end;
        end;
      13:
        begin
          V := At + 4; if WasSlot then V := Target + 2;
          FState.R[N] := Read((V and $FFFFFFFC) + Cardinal(Op and $FF) * 4, 4);
        end;
      14: FState.R[N] := SX8(Op);
    else Valid := False;
    end;
    if not Valid then
    begin
      V := At; if WasSlot then V := Target;
      ExceptionVector(4 + 2 * Ord(WasSlot), V); Result := 5;
    end
    else if WasSlot and not Branch then FState.PC := Target;
  except
    on E: ESH2Address do begin ExceptionVector(9, At); Result := 5; end;
  end;
  Inc(FState.Cycles, Result);
end;

function TSH2.Run(Cycles: Integer): Integer;
begin
  Result := 0;
  while Result < Cycles do Inc(Result, Step);
end;

procedure TSH2.SerializeState(Archive: TStateArchive);
begin
  Archive.Field(FState, SizeOf(FState));
  Archive.Field(FIRQLevel, SizeOf(FIRQLevel));
  Archive.Field(FIRQVector, SizeOf(FIRQVector));
  if (FIRQLevel < 0) or (FIRQLevel > 16) or (FIRQVector < 0) or (FIRQVector > 255) then
    raise EReadError.Create('Invalid snapshot SH-2 interrupt');
end;

end.
