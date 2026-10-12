unit N64.CPU;
{$Q+}{$R+}

interface

uses
  System.SysUtils, System.Classes, N64.Types, N64.SoftFloat, Core.Snapshots;

type
  TN64TLBEntry = record
    Mask, Lo0, Lo1: Cardinal;
    EntryHi: UInt64;
  end;

  TN64CPU = class
  private
    FBus: TN64Bus;
    FPC, FNextPC, FInstructionPC: UInt64;
    FCyclesConsumed: Cardinal;
    FOperationCycles: Cardinal;
    FCP0Latch, FCOP2Latch: UInt64;
    FPreviousLoad, FPreviousFP: Integer;
    FPreviousStore, FPreviousCondition, FPreviousException: Boolean;
    FExecutingInstruction, FDataCached: Boolean;
    FDelay, FInDelay, FLL: Boolean;
    FLLAddress: UInt64;
    FCountHalf: Integer;
    procedure SetPCExact(Value: UInt64); inline;
    procedure ApplyInterlocks(Op: Cardinal);
    function CachedAddress(Address: UInt64): Boolean; inline;
    function FPRegister(Index: Integer): Integer; inline;
    function GetIdleInstructionClocks: Cardinal; inline;
    function FPClocks(A, B: UInt64; Format, Fn: Integer): Cardinal;
    function Translate(Address: UInt64; Writing: Boolean): UInt64; inline;
    function Load(Address: UInt64; Size: Integer; Aligned: Boolean = True): UInt64; inline;
    procedure Store(Address: UInt64; Size: Integer; Value: UInt64; Aligned: Boolean = True); inline;
    procedure Fault(Code: Integer; Address: UInt64 = 0; Refill: Boolean = False; Cop: Integer = 0);
    procedure Branch(Taken, Likely: Boolean; Target: UInt64); inline;
    procedure Special(Op: Cardinal); inline;
    procedure Cop0(Op: Cardinal); inline;
    procedure Cop1(Op: Cardinal); inline;
    function FPBits(Index, Format: Integer): UInt64; inline;
    procedure SetFPBits(Index, Format: Integer; Value: UInt64); inline;
    procedure Cop2(Op: Cardinal); inline;
    procedure AdvanceClocks(Clocks: Cardinal); inline;
    procedure FPExceptions(Events: Cardinal; Unimplemented: Boolean = False); inline;
  public
    GPR: array[0..31] of UInt64;
    CP0: array[0..31] of UInt64;
    FPR: array[0..31] of UInt64;
    FCR31: Cardinal;
    HI, LO: UInt64;
    TLB: array[0..31] of TN64TLBEntry;
    constructor Create(Bus: TN64Bus);
    procedure Reset;
    procedure Step;
    function SkipIdle(MaxInstructions: Integer): Integer;
    procedure SerializeState(State: TStateArchive);
    procedure SetPC(Value: UInt64);
    property PC: UInt64 read FPC write SetPC;
    property CyclesConsumed: Cardinal read FCyclesConsumed;
    property IdleInstructionClocks: Cardinal read GetIdleInstructionClocks;
  end;

implementation

type
  EGuestFault = class(Exception);

constructor TN64CPU.Create(Bus: TN64Bus);
begin
  inherited Create;
  FBus := Bus;
  Reset;
end;

procedure TN64CPU.SetPC(Value: UInt64);
begin
  // Public debugger/boot convenience accepts legacy 32-bit kernel addresses.
  // Architectural ERET and branch targets preserve the full virtual address.
  if Value <= $FFFFFFFF then Value := SX(Value, 32);
  SetPCExact(Value);
end;

procedure TN64CPU.SetPCExact(Value: UInt64);
begin
  FPC := Value;
  FNextPC := Add64(Value, 4);
  FDelay := False;
end;

procedure TN64CPU.Reset;
begin
  for var I := 0 to 31 do
  begin
    GPR[I] := 0;
    CP0[I] := 0;
    FPR[I] := 0;
    TLB[I] := Default(TN64TLBEntry);
  end;
  HI := 0;
  LO := 0;
  FCR31 := 0;
  FLL := False;
  FCountHalf := 0;
  FCyclesConsumed := 0;
  FOperationCycles := 1;
  FPreviousLoad := -1;
  FPreviousFP := -1;
  FPreviousStore := False;
  FPreviousCondition := False;
  FPreviousException := False;
  FExecutingInstruction := False;
  FDataCached := False;
  FCP0Latch := 0;
  FCOP2Latch := 0;
  CP0[1] := 31;
  CP0[12] := $34000000;
  CP0[15] := $B22;
  CP0[16] := $7006E463;
  GPR[6] := SX($A4001F0C, 32);
  GPR[7] := SX($A4001F08, 32);
  GPR[8] := $C0;
  GPR[10] := $40;
  GPR[11] := SX($A4000040, 32);
  GPR[20] := 1;
  GPR[22] := $3F;
  GPR[29] := SX($A4001FF0, 32);
  GPR[31] := SX($A4001550, 32);
  SetPC($A4000040);
end;

procedure TN64CPU.Fault(Code: Integer; Address: UInt64; Refill: Boolean; Cop: Integer);
begin
  // NEC VR4300 UM pipeline exception: abort and stall for two PClocks.
  // Aborted instructions do not retain their speculative interlock requests.
  FCyclesConsumed := FOperationCycles + 2;
  if Code = 0 then FCyclesConsumed := 2;
  FPreviousLoad := -1;
  FPreviousFP := -1;
  FPreviousStore := False;
  FPreviousCondition := False;
  FPreviousException := True;
  var KeepCause := CP0[13] and $FF00;
  if (CP0[12] and 2) <> 0 then KeepCause := KeepCause or (CP0[13] and $80000000);
  CP0[13] := KeepCause or Cardinal(Code shl 2) or Cardinal(Cop shl 28);
  if (CP0[12] and 2) = 0 then
  begin
    CP0[14] := FInstructionPC;
    if FInDelay then
    begin
      CP0[14] := Sub64(FInstructionPC, 4);
      CP0[13] := CP0[13] or $80000000;
    end;
  end
  else
    Refill := False;
  if Code in [1, 2, 3, 4, 5] then
    CP0[8] := Address;
  if Code in [1, 2, 3] then
  begin
    CP0[4] := (CP0[4] and $FFFFFFFFFF800000) or ((Address shr 9) and $007FFFF0);
    CP0[20] := (CP0[20] and $FFFFFFFE00000000) or
      ((Address shr 31) and $180000000) or ((Address shr 9) and $7FFFFFF0);
    CP0[10] := (Address and $C00000FFFFFFE000) or (CP0[10] and $FF);
  end;
  CP0[12] := CP0[12] or 2;
  if FBus.TraceEnabled then FBus.Trace(GuestException, FInstructionPC, Address, CP0[13]);
  var Vector: UInt64 := $FFFFFFFF80000180;
  if Refill then
  begin
    Vector := $FFFFFFFF80000000;
    if (Address <> SX(Address, 32)) and (Vector = $FFFFFFFF80000000) then Vector := $FFFFFFFF80000080;
  end;
  if (CP0[12] and $400000) <> 0 then
    if Refill then
    begin
      Vector := $FFFFFFFFBFC00200;
      if Address <> SX(Address, 32) then Vector := $FFFFFFFFBFC00280;
    end
    else
      Vector := $FFFFFFFFBFC00380;
  SetPC(Vector);
  FLL := False;
  raise EGuestFault.Create('');
end;

function TN64CPU.Translate(Address: UInt64; Writing: Boolean): UInt64;
begin
  var Status := CP0[12];
  var Mode := Integer((Status shr 3) and 3);
  if (Status and 6) <> 0 then Mode := 0;
  var Extended := (Status and (UInt64($80) shr Mode)) <> 0;
  var Canonical32 := Address = SX(Address, 32);
  var Low := Cardinal(Address and $FFFFFFFF);
  var InvalidAddress := not Canonical32 and not Extended;
  if Canonical32 then
  begin
    if ((Status and 4) <> 0) and (Low < $80000000) then Exit(Low);
    if (Mode = 2) and (Low >= $80000000) then InvalidAddress := True;
    if (Mode = 1) and (Low >= $80000000) and (Low < $C0000000) then InvalidAddress := True;
    if (Mode = 1) and (Low >= $E0000000) then InvalidAddress := True;
    if not InvalidAddress and (Low >= $80000000) and (Low < $C0000000) then
      Exit(Low and $1FFFFFFF);
  end
  else
  begin
    var Region := Address shr 62;
    if (Mode = 2) and (Region <> 0) then InvalidAddress := True;
    if (Mode = 1) and (Region > 1) then InvalidAddress := True;
    if Region = 2 then
    begin
      if (Mode <> 0) or ((Address and $07FFFFFF00000000) <> 0) then InvalidAddress := True;
      if not InvalidAddress then Exit(Address and $FFFFFFFF);
    end
    else if (Address and $3FFFFF0000000000) <> 0 then InvalidAddress := True;
  end;
  if InvalidAddress then
    if Writing then Fault(5, Address) else Fault(4, Address);
  for var I := 0 to 31 do
  begin
    var Mask := UInt64(TLB[I].Mask or $1FFF);
    var MatchMask: UInt64 := $C00000FFFFFFE000 and not Mask;
    if ((Address and MatchMask) = (TLB[I].EntryHi and MatchMask)) and
      (((TLB[I].Lo0 and TLB[I].Lo1 and 1) <> 0) or
      ((TLB[I].EntryHi and $FF) = (CP0[10] and $FF))) then
    begin
      var HalfMask := (Mask shr 1) + 1;
      var L := TLB[I].Lo0;
      if (Address and HalfMask) <> 0 then L := TLB[I].Lo1;
      if (L and 2) = 0 then
        if Writing then Fault(3, Address) else Fault(2, Address);
      if Writing and ((L and 4) = 0) then Fault(1, Address);
      Exit(((UInt64(L shr 6) shl 12) and not (HalfMask - 1)) or (Address and (HalfMask - 1)));
    end;
  end;
  if Writing then Fault(3, Address, True) else Fault(2, Address, True);
  Result := 0;
end;

function TN64CPU.FPRegister(Index: Integer): Integer;
begin
  if (CP0[12] and $4000000) = 0 then Index := Index and 30;
  Result := Index + 32;
end;

function TN64CPU.GetIdleInstructionClocks: Cardinal;
begin
  Result := 1;
end;

function TN64CPU.CachedAddress(Address: UInt64): Boolean;
begin
  Result := False;
  if Address = SX(Address, 32) then
  begin
    var Low := Cardinal(Address and $FFFFFFFF);
    if ((CP0[12] and 4) <> 0) and (Low < $80000000) then Exit;
    if (Low >= $80000000) and (Low < $A0000000) then Exit(True);
    if (Low >= $A0000000) and (Low < $C0000000) then Exit;
  end
  else if (Address shr 62) = 2 then Exit(((Address shr 59) and 7) <> 2);
  for var I := 0 to 31 do
  begin
    var Mask := UInt64(TLB[I].Mask or $1FFF);
    var MatchMask: UInt64 := $C00000FFFFFFE000 and not Mask;
    if ((Address and MatchMask) = (TLB[I].EntryHi and MatchMask)) and
      (((TLB[I].Lo0 and TLB[I].Lo1 and 1) <> 0) or
      ((TLB[I].EntryHi and $FF) = (CP0[10] and $FF))) then
    begin
      var L := TLB[I].Lo0;
      if (Address and ((Mask shr 1) + 1)) <> 0 then L := TLB[I].Lo1;
      Exit(((L shr 3) and 7) <> 2);
    end;
  end;
end;

procedure TN64CPU.ApplyInterlocks(Op: Cardinal);
begin
  var Code := Op shr 26;
  var S := Integer((Op shr 21) and 31);
  var T := Integer((Op shr 16) and 31);
  var Fn := Integer(Op and 63);
  var RS := -1;
  var RT := -1;
  var FS := -1;
  var FT := -1;
  var Memory := Code in [26, 27, 32..46, 48..63];
  case Code of
    0:
      case Fn of
        0, 2, 3, 56, 58, 59, 60, 62, 63: RT := T;
        8, 9, 17, 19: RS := S;
        4, 6, 7, 20, 22..27, 28..47, 48..54: begin RS := S; RT := T; end;
      end;
    1, 6, 7, 8..14, 22..27: RS := S;
    4, 5, 20, 21: begin RS := S; RT := T; end;
    16, 18: if S in [4..6] then RT := T;
    17:
      begin
        if S in [4..6] then RT := T;
        if S in [0, 1] then FS := FPRegister(Integer((Op shr 11) and 31));
        if S in [16, 17, 20, 21] then
        begin
          FS := FPRegister(Integer((Op shr 11) and 31));
          if (Fn <= 3) or (Fn >= 48) then FT := FPRegister(T);
        end;
      end;
    32..46, 48..63:
      begin
        RS := S;
        if Code in [40..46, 56, 60] then RT := T;
        if Code in [34, 38] then RT := T; // Merge word loads also consume rt.
        if Code in [57, 61] then FS := FPRegister(T);
      end;
  end;
  if Code in [26, 27] then RT := T;
  if ((FPreviousLoad >= 0) and ((FPreviousLoad = RS) or (FPreviousLoad = RT) or
    (FPreviousLoad = FS) or (FPreviousLoad = FT))) then Inc(FCyclesConsumed);
  if (Code = 17) and (S in [16, 17, 20, 21]) and (FPreviousFP >= 0) and
    ((FPreviousFP = FS) or (FPreviousFP = FT)) then Inc(FCyclesConsumed);
  if FPreviousCondition and (Code = 17) and (S = 8) then Inc(FCyclesConsumed);
  if FPreviousException and (Code = 16) and (S in [0, 1]) then Inc(FCyclesConsumed);
  if FPreviousStore and Memory and CachedAddress(Add64(GPR[S], SX(Op and $FFFF, 16))) then
    Inc(FCyclesConsumed);
  FPreviousLoad := -1;
  FPreviousFP := -1;
  FPreviousCondition := False;
  FPreviousException := False;
  FPreviousStore := False;
  if Code in [26, 27, 32..39, 48, 52, 55] then
    if T <> 0 then FPreviousLoad := T;
  if Code in [49, 53] then FPreviousLoad := FPRegister(T);
  if (Code = 17) and (S in [16, 17, 20, 21]) then
    if Fn >= 48 then FPreviousCondition := True
    else FPreviousFP := FPRegister(Integer((Op shr 6) and 31));
  if Code in [40..46, 56, 57, 60, 61, 63] then
    FPreviousStore := CachedAddress(Add64(GPR[S], SX(Op and $FFFF, 16)));
  var Wide := Code in [24..27, 52, 55, 60, 63];
  if Code = 0 then Wide := Fn in [20, 22, 23, 28..31, 44..47, 56, 58..60, 62, 63];
  if Code in [16, 17, 18] then Wide := S in [1, 5];
  if (Code = 17) and (S >= 16) then Wide := (S = 21) or (Fn in [8..11, 37]);
  var Mode := Integer((CP0[12] shr 3) and 3);
  if ((CP0[12] and 6) <> 0) then Mode := 0;
  if Wide and (Mode <> 0) and ((CP0[12] and (UInt64($80) shr Mode)) = 0) then Fault(10);
end;

function TN64CPU.FPClocks(A, B: UInt64; Format, Fn: Integer): Cardinal;
begin
  // NEC U10504EJ7V0UMJ1: tables 7-13/7-14 and section 7.5.6.
  Result := 1;
  case Fn of
    0, 1: Result := 3;
    2: if Format = 16 then Result := 5 else Result := 8;
    3, 4: if Format = 16 then Result := 29 else Result := 58;
    8..15, 36, 37: Result := 5;
    32: if Format = 17 then Result := 2 else Result := 5;
    33: if Format = 16 then Result := 1 else Result := 5;
  end;
  if Result <= 2 then Exit;
  if Format in [20, 21] then
  begin
    if A = 0 then Result := 2;
    Exit;
  end;
  var Exponent: UInt64 := $7FF0000000000000;
  var Fraction: UInt64 := $FFFFFFFFFFFFF;
  var Sign: UInt64 := UInt64(1) shl 63;
  if Format = 16 then begin Exponent := $7F800000; Fraction := $7FFFFF; Sign := $80000000; end;
  var SimpleA := ((A and not Sign) = 0) or ((A and Exponent) = Exponent) or SFIsSubnormal(A, Format);
  var SimpleB := ((B and not Sign) = 0) or ((B and Exponent) = Exponent) or SFIsSubnormal(B, Format);
  if SimpleA or ((Fn <= 3) and SimpleB) then Result := 2;
  if (Fn = 4) and ((A and Sign) <> 0) then Result := 2;
  if (Fn = 2) and (((A and Fraction) = 0) or ((B and Fraction) = 0)) then Result := 2;
end;

function TN64CPU.Load(Address: UInt64; Size: Integer; Aligned: Boolean): UInt64;
begin
  if Aligned and ((Address and Cardinal(Size - 1)) <> 0) then
    Fault(4, Address);
  var Physical := Translate(Address, False);
  if FExecutingInstruction then FDataCached := CachedAddress(Address);
  if Physical > $FFFFFFFF then Exit(0);
  if Size = 4 then
    Result := FBus.Read32(Cardinal(Physical))
  else
  begin
    Result := 0;
    for var I := 0 to Size - 1 do
      Result := (Result shl 8) or FBus.Read8(Add32(Cardinal(Physical), Cardinal(I)));
  end;
  if FBus.TraceEnabled and (Physical >= $03F00000) and (Physical < $04A00000) then
    FBus.Trace(MMIORead, FInstructionPC, Physical, Result);
end;

procedure TN64CPU.Store(Address: UInt64; Size: Integer; Value: UInt64; Aligned: Boolean);
begin
  if Aligned and ((Address and Cardinal(Size - 1)) <> 0) then
    Fault(5, Address);
  var Physical := Translate(Address, True);
  if FExecutingInstruction then FDataCached := CachedAddress(Address);
  FLL := False;
  if Physical > $FFFFFFFF then Exit;
  if FBus.TraceEnabled and (Physical >= $03F00000) and (Physical < $04A00000) then
  begin
    var Written := Value;
    if Size < 8 then Written := Written and ((UInt64(1) shl (Size * 8)) - 1);
    FBus.Trace(MMIOWrite, FInstructionPC, Physical, Written);
  end;
  if Size = 4 then
    FBus.Write32(Cardinal(Physical), Cardinal(Value and $FFFFFFFF))
  else
    for var I := 0 to Size - 1 do
      FBus.Write8(Add32(Cardinal(Physical), Cardinal(I)), Byte((Value shr ((Size - 1 - I) * 8)) and $FF));
end;

procedure TN64CPU.Branch(Taken, Likely: Boolean; Target: UInt64);
begin
  if Taken then
    FNextPC := Target
  else if Likely then
  begin
    FPC := FNextPC;
    FNextPC := Add64(FNextPC, 4);
    Exit;
  end;
  FDelay := True;
end;

procedure TN64CPU.Special(Op: Cardinal);
begin
  var S := (Op shr 21) and 31;
  var T := (Op shr 16) and 31;
  var D := (Op shr 11) and 31;
  var N := (Op shr 6) and 31;
  var A := GPR[S];
  var B := GPR[T];
  var F := Op and 63;
  var V: UInt64 := 0;
  // NEC U10504EJ7 table 3-12. Integer multiply/divide stall the entire pipe.
  case F of
    24, 25: FOperationCycles := 5;
    26, 27: FOperationCycles := 37;
    28, 29: FOperationCycles := 8;
    30, 31: FOperationCycles := 69;
  end;
  Inc(FCyclesConsumed, FOperationCycles - 1);
  case F of
    0:
      V := SX(B shl N, 32);
    2:
      V := SX((B and $FFFFFFFF) shr N, 32);
    3:
      V := SX(SAR(B, N, 32), 32);
    4:
      V := SX(B shl (A and 31), 32);
    6:
      V := SX((B and $FFFFFFFF) shr (A and 31), 32);
    7:
      V := SX(SAR(B, A and 31, 32), 32);
    8, 9:
      begin
        if F = 9 then
          GPR[D] := Add64(FInstructionPC, 8);
        Branch(True, False, A);
        Exit;
      end;
    12:
      Fault(8);
    13:
      Fault(9);
    15:
      Exit; // SYNC: interpreter memory operations are ordered.
      16:
      V := HI;
    17:
      begin
        HI := A;
        Exit
      end;
    18:
      V := LO;
    19:
      begin
        LO := A;
        Exit
      end;
    20:
      V := B shl (A and 63);
    22:
      V := B shr (A and 63);
    23:
      V := SAR(B, A and 63, 64);
    24, 25:
      begin
        if F = 24 then
          V := UInt64(0) // handled through Multiply64 for signed values
        else
          V := (A and $FFFFFFFF) * (B and $FFFFFFFF);
        if F = 24 then
          Multiply64(SX(A, 32), SX(B, 32), True, HI, V);
        LO := SX(V, 32);
        HI := SX(V shr 32, 32);
        Exit;
      end;
    26, 27:
      begin
        if F = 26 then
          Divide64(SX(A, 32), SX(B, 32), True, HI, LO)
        else
          Divide64(A and $FFFFFFFF, B and $FFFFFFFF, False, HI, LO);
        HI := SX(HI, 32);
        LO := SX(LO, 32);
        Exit;
      end;
    28, 29:
      begin
        Multiply64(A, B, F = 28, HI, LO);
        Exit
      end;
    30, 31:
      begin
        Divide64(A, B, F = 30, HI, LO);
        Exit
      end;
    32, 33, 34, 35:
      begin
        if F in [32, 33] then
          V := SX(Add64(A, B), 32)
        else
          V := SX(Sub64(A, B), 32);
        if F = 32 then
          if (((not (A xor B)) and (A xor V)) and $80000000) <> 0 then
            Fault(12);
        if F = 34 then
          if (((A xor B) and (A xor V)) and $80000000) <> 0 then
            Fault(12);
      end;
    36:
      V := A and B;
    37:
      V := A or B;
    38:
      V := A xor B;
    39:
      V := not (A or B);
    42:
      V := Ord(SignedLess(A, B));
    43:
      V := Ord(A < B);
    44, 45, 46, 47:
      begin
        if F in [44, 45] then
          V := Add64(A, B)
        else
          V := Sub64(A, B);
        if F = 44 then
          if ((not (A xor B)) and (A xor V)) shr 63 <> 0 then
            Fault(12);
        if F = 46 then
          if ((A xor B) and (A xor V)) shr 63 <> 0 then
            Fault(12);
      end;
    48:
      begin
        if not SignedLess(A, B) then
          Fault(13);
        Exit
      end;
    49:
      begin
        if A >= B then
          Fault(13);
        Exit
      end;
    50:
      begin
        if SignedLess(A, B) then
          Fault(13);
        Exit
      end;
    51:
      begin
        if A < B then
          Fault(13);
        Exit
      end;
    52:
      begin
        if A = B then
          Fault(13);
        Exit
      end;
    54:
      begin
        if A <> B then
          Fault(13);
        Exit
      end;
    56:
      V := B shl N;
    58:
      V := B shr N;
    59:
      V := SAR(B, N, 64);
    60:
      V := B shl (N + 32);
    62:
      V := B shr (N + 32);
    63:
      V := SAR(B, N + 32, 64);
  else
    Fault(10);
  end;
  GPR[D] := V;
end;

procedure TN64CPU.Cop0(Op: Cardinal);
begin
  var Mode := (CP0[12] shr 3) and 3;
  if ((CP0[12] and 6) = 0) and (Mode <> 0) and ((CP0[12] and $10000000) = 0) then
    Fault(11, 0, False, 0);
  var S := (Op shr 21) and 31;
  var T := (Op shr 16) and 31;
  var D := (Op shr 11) and 31;
  case S of
    0, 1:
      begin
        var V := CP0[D];
        if D in [7, 21..25, 31] then V := FCP0Latch;
        if S = 0 then GPR[T] := SX(V, 32) else GPR[T] := V;
      end;
    4, 5:
      begin
        var V := GPR[T];
        if S = 4 then V := SX(V, 32);
        FCP0Latch := V;
        case D of
          1, 7, 8, 15, 21..25, 27: Exit;
          0: V := V and $8000003F;
          2, 3: V := V and $3FFFFFFF;
          4: V := (V and $FFFFFFFFFF800000) or (CP0[4] and $7FFFF0);
          5: V := V and $01FFE000;
          6: begin V := V and $3F; CP0[1] := 31; end;
          9: V := V and $FFFFFFFF;
          10: V := V and $C00000FFFFFFE0FF;
          11: begin V := V and $FFFFFFFF; CP0[13] := CP0[13] and not UInt64($8000); end;
          12: V := V and $FFF7FFFF;
          13: V := (CP0[13] and not UInt64($300)) or (V and $300);
          16: V := (V and $0F00800F) or (CP0[16] and $F0FF7FF0);
          17: V := V and $FFFFFFFF;
          20: V := (V and $FFFFFFFE00000000) or (CP0[20] and $1FFFFFFFF);
          26: V := V and $FF;
        end;
        CP0[D] := V;
      end;
    16..31:
      case Op and 63 of
        1:
          begin
            var E := TLB[CP0[0] and 31];
            CP0[5] := E.Mask;
            CP0[10] := E.EntryHi and not UInt64(E.Mask);
            CP0[2] := E.Lo0;
            CP0[3] := E.Lo1;
          end;
        2, 6:
          begin
            var I := CP0[0] and 31;
            if (Op and 63) = 6 then I := CP0[1] and 31;
            TLB[I].Mask := Cardinal(CP0[5] and $01554000);
            TLB[I].Mask := TLB[I].Mask or (TLB[I].Mask shr 1);
            TLB[I].EntryHi := CP0[10] and $C00000FFFFFFE0FF;
            TLB[I].Lo0 := Cardinal(CP0[2] and $03FFFFFF);
            TLB[I].Lo1 := Cardinal(CP0[3] and $03FFFFFF);
            if (TLB[I].Lo0 and TLB[I].Lo1 and 1) = 0 then
            begin
              TLB[I].Lo0 := TLB[I].Lo0 and not Cardinal(1);
              TLB[I].Lo1 := TLB[I].Lo1 and not Cardinal(1);
            end;
          end;
        8:
          begin
            CP0[0] := $80000000;
            for var I := 0 to 31 do
            begin
              var M := UInt64(TLB[I].Mask or $1FFF);
              var MatchMask: UInt64 := $C00000FFFFFFE000 and not M;
              if ((TLB[I].EntryHi and MatchMask) = (CP0[10] and MatchMask)) and
                (((TLB[I].Lo0 and TLB[I].Lo1 and 1) <> 0) or
                ((TLB[I].EntryHi and $FF) = (CP0[10] and $FF))) then
              begin CP0[0] := I; Break; end;
            end;
          end;
        24:
          begin
            if (CP0[12] and 4) <> 0 then
            begin SetPCExact(CP0[30]); CP0[12] := CP0[12] and not UInt64(4); end
            else begin SetPCExact(CP0[14]); CP0[12] := CP0[12] and not UInt64(2); end;
            FLL := False;
          end;
      else Fault(10);
      end;
  else Fault(10);
  end;
end;

procedure TN64CPU.Cop2(Op: Cardinal);
begin
  if (CP0[12] and $40000000) = 0 then Fault(11, 0, False, 2);
  var S := (Op shr 21) and 31;
  var T := (Op shr 16) and 31;
  case S of
    0, 2: GPR[T] := SX(FCOP2Latch, 32);
    1: GPR[T] := FCOP2Latch;
    4, 5, 6: FCOP2Latch := GPR[T];
  else Fault(10);
  end;
end;

function TN64CPU.FPBits(Index, Format: Integer): UInt64;
begin
  if (CP0[12] and $4000000) = 0 then
  begin
    Result := FPR[Index and 30];
    if (Format in [16, 20]) and Odd(Index) then
      Result := Result shr 32;
  end
  else
    Result := FPR[Index];
  if Format in [16, 20] then
    Result := Result and $FFFFFFFF;
end;

procedure TN64CPU.SetFPBits(Index, Format: Integer; Value: UInt64);
begin
  if (CP0[12] and $4000000) = 0 then
  begin
    if Format in [16, 20] then
    begin
      if Odd(Index) then
        FPR[Index and 30] := (FPR[Index and 30] and $FFFFFFFF) or ((Value and $FFFFFFFF) shl 32)
      else
        FPR[Index] := (FPR[Index] and $FFFFFFFF00000000) or (Value and $FFFFFFFF);
    end
    else
      FPR[Index and 30] := Value;
  end
  else if Format in [16, 20] then
    FPR[Index] := (FPR[Index] and $FFFFFFFF00000000) or (Value and $FFFFFFFF)
  else
    FPR[Index] := Value;
end;

procedure TN64CPU.FPExceptions(Events: Cardinal; Unimplemented: Boolean);
begin
  FCR31 := FCR31 or ((Events and 31) shl 12);
  FCR31 := FCR31 or (((Events and not (FCR31 shr 7)) and 31) shl 2);
  if Unimplemented then
    FCR31 := FCR31 or $20000;
  if Unimplemented or ((Events and (FCR31 shr 7) and 31) <> 0) then
    Fault(15);
end;

procedure TN64CPU.Cop1(Op: Cardinal);
begin
  if (CP0[12] and $20000000) = 0 then Fault(11, 0, False, 1);
  var F := (Op shr 21) and 31;
  var T := (Op shr 16) and 31;
  var S := (Op shr 11) and 31;
  var D := (Op shr 6) and 31;
  var Fn := Op and 63;
  case F of
    0: GPR[T] := SX(FPBits(S, 16), 32);
    1: GPR[T] := FPBits(S, 17);
    2:
      if S = 31 then GPR[T] := SX(FCR31, 32)
      else if S = 0 then GPR[T] := $A00 else GPR[T] := 0;
    4: SetFPBits(S, 16, GPR[T]);
    5: SetFPBits(S, 17, GPR[T]);
    6:
      if S = 31 then
      begin
        FCR31 := Cardinal(GPR[T] and $0183FFFF);
        if ((FCR31 and $20000) <> 0) or (((FCR31 shr 12) and (FCR31 shr 7) and 31) <> 0) then Fault(15);
      end;
    8:
      begin
        FCR31 := FCR31 and not $3F000;
        Branch(((FCR31 and $800000) <> 0) = ((T and 1) <> 0), (T and 2) <> 0,
          Add64(FPC, SX(Op and $FFFF, 16) shl 2));
      end;
    16, 17, 20, 21:
      begin
        if (F in [20, 21]) and not (Fn in [32, 33]) then Fault(10);
        if Fn = 6 then begin SetFPBits(D, 17, FPBits(S, 17)); Exit; end;
        FCR31 := FCR31 and not $3F000;
        var A := FPBits(S, F);
        var B := FPBits(T, F);
        FOperationCycles := FPClocks(A, B, F, Fn);
        Inc(FCyclesConsumed, FOperationCycles - 1);
        if (F = 21) and (Fn in [32, 33]) and ((A shr 55) <> 0) and ((A shr 55) <> $1FF) then
        begin FOperationCycles := 2; FPExceptions(0, True); end;
        var Binary := Fn in [0..3, 48..63];
        if F in [16, 17] then
        begin
          // VR4300 manual 8.2.7: compare accepts denormal operands.
          if (Fn < 48) and (SFIsSubnormal(A, F) or
            (Binary and SFIsSubnormal(B, F))) then FPExceptions(0, True);
          var NaN1 := SFIsNaN(A, F);
          var NaN2 := Binary and SFIsNaN(B, F);
          var Quiet: UInt64 := $8000000000000;
          if F = 16 then Quiet := $400000;
          if Fn >= 48 then
          begin
            var Unordered, Equal, Less: Boolean;
            SFCompare(A, B, F, Unordered, Equal, Less);
            if Unordered and (((Fn and 8) <> 0) or (NaN1 and ((A and Quiet) <> 0)) or
              (NaN2 and ((B and Quiet) <> 0))) then FPExceptions(sfInvalid);
            var Test := (((Fn and 1) <> 0) and Unordered) or
              (((Fn and 2) <> 0) and Equal) or (((Fn and 4) <> 0) and Less);
            FCR31 := FCR31 and not $800000;
            if Test then FCR31 := FCR31 or $800000;
            Exit;
          end;
          if NaN1 or NaN2 then
          begin
            if (Fn in [8..15, 36, 37]) or (NaN1 and ((A and Quiet) = 0)) or
              (NaN2 and ((B and Quiet) = 0)) then FPExceptions(0, True);
            FPExceptions(sfInvalid);
            var Target := Integer(F);
            if Fn = 32 then Target := 16 else if Fn = 33 then Target := 17;
            var Bits: UInt64 := $7FF7FFFFFFFFFFFF;
            if Target = 16 then Bits := $7FBFFFFF;
            if (Target = 16) and ((CP0[12] and $4000000) <> 0) then FPR[D] := Bits
            else SetFPBits(D, Target, Bits);
            Exit;
          end;
        end;
        var R: TSoftFloatResult;
        var Target := Integer(F);
        case Fn of
          0..5, 7: R := SFCalculate(A, B, F, Fn, FCR31 and 3);
          8..15, 36, 37:
            begin
              Target := 21;
              if Fn in [12..15, 36] then Target := 20;
              var Mode := Fn and 3;
              if Fn in [36, 37] then Mode := FCR31 and 3;
              // VR4300 conversion unit rejects magnitude >= 2^53 (all formats).
              var Magnitude := A and $7FFFFFFFFFFFFFFF;
              var Limit: UInt64 := $4340000000000000;
              if F = 16 then begin Magnitude := A and $7FFFFFFF; Limit := $5A000000; end;
              if Magnitude >= Limit then begin FOperationCycles := 2; FPExceptions(0, True); end;
              R := SFConvert(A, F, Target, Mode);
              if (R.Events and sfInvalid) <> 0 then begin FOperationCycles := 2; FPExceptions(0, True); end;
            end;
          32, 33:
            begin
              Target := 16;
              if Fn = 33 then Target := 17;
              if (Integer(F) = Target) then Fault(10);
              R := SFConvert(A, F, Target, FCR31 and 3);
            end;
        else Fault(10); R := Default(TSoftFloatResult);
        end;
        if Target in [16, 17] then
        begin
          if SFIsSubnormal(R.Bits, Target) or ((R.Events and sfUnderflow) <> 0) then
          begin
            if ((FCR31 and $1000000) = 0) or ((FCR31 and $180) <> 0) then FPExceptions(0, True);
            var Sign: UInt64 := UInt64(1) shl 63;
            var MinNormal: UInt64 := $10000000000000;
            if Target = 16 then begin Sign := $80000000; MinNormal := $800000; end;
            R.Bits := R.Bits and Sign;
            var Mode := FCR31 and 3;
            if ((Mode = 2) and (R.Bits = 0)) or ((Mode = 3) and (R.Bits <> 0)) then
              R.Bits := R.Bits or MinNormal;
            R.Events := R.Events or sfUnderflow or sfInexact;
          end;
        end;
        FPExceptions(R.Events); // Trap before the destination register is written.
        if (Target in [16, 20]) and ((CP0[12] and $4000000) <> 0) then FPR[D] := R.Bits and $FFFFFFFF
        else SetFPBits(D, Target, R.Bits);
      end;
  else Fault(10);
  end;
end;

procedure TN64CPU.Step;
begin
  FCyclesConsumed := 1; // Filled VR4300 pipeline issues one instruction/PClock.
  FOperationCycles := 1;
  FExecutingInstruction := False;
  FDataCached := False;
  FInstructionPC := FPC;
  FInDelay := FDelay;
  FDelay := False;
  try
    if FBus.InterruptPending then
      CP0[13] := CP0[13] or $400
    else
      CP0[13] := CP0[13] and not UInt64($400);
    if ((CP0[12] and 7) = 1) and ((CP0[12] and CP0[13] and $FF00) <> 0) then
      Fault(0);
    var Op := Cardinal(Load(FPC, 4));
    if FBus.TraceEnabled then FBus.Trace(Instruction, FPC, FPC, Op);
    FExecutingInstruction := True;
    ApplyInterlocks(Op);
    FPC := FNextPC;
    FNextPC := Add64(FNextPC, 4);
    var Code := Op shr 26;
    var S := (Op shr 21) and 31;
    var T := (Op shr 16) and 31;
    var A := GPR[S];
    var B := GPR[T];
    var Imm := SX(Op and $FFFF, 16);
    var Address := Add64(A, Imm);
    var Target := Add64(FPC, Imm shl 2);
    var V: UInt64 := 0;
    case Code of
      0:
        Special(Op);
      1:
        begin
          var Taken := SignedLess(A, 0);
          if (T and 1) <> 0 then
            Taken := not Taken;
          if T in [16..19] then
            GPR[31] := Add64(FInstructionPC, 8);
          if T in [0..3, 16..19] then
            Branch(Taken, (T and 2) <> 0, Target)
          else
            case T of
              8:
                if not SignedLess(A, Imm) then
                  Fault(13);
              9:
                if A >= Imm then
                  Fault(13);
              10:
                if SignedLess(A, Imm) then
                  Fault(13);
              11:
                if A < Imm then
                  Fault(13);
              12:
                if A = Imm then
                  Fault(13);
              14:
                if A <> Imm then
                  Fault(13);
            else
              Fault(10);
            end;
        end;
      2, 3:
        begin
          if Code = 3 then
            GPR[31] := Add64(FInstructionPC, 8);
          Branch(True, False, (FPC and $FFFFFFFFF0000000) or ((Op and $3FFFFFF) shl 2));
        end;
      4, 20:
        Branch(A = B, Code = 20, Target);
      5, 21:
        Branch(A <> B, Code = 21, Target);
      6, 22:
        Branch(not SignedLess(0, A), Code = 22, Target);
      7, 23:
        Branch(SignedLess(0, A), Code = 23, Target);
      8, 9, 24, 25:
        begin
          V := Add64(A, Imm);
          if Code in [8, 9] then
            V := SX(V, 32);
          if Code = 8 then
            if (((not (A xor Imm)) and (A xor V)) and $80000000) <> 0 then
              Fault(12);
          if Code = 24 then
            if ((not (A xor Imm)) and (A xor V)) shr 63 <> 0 then
              Fault(12);
          GPR[T] := V;
        end;
      10:
        GPR[T] := Ord(SignedLess(A, Imm));
      11:
        GPR[T] := Ord(A < Imm);
      12:
        GPR[T] := A and (Op and $FFFF);
      13:
        GPR[T] := A or (Op and $FFFF);
      14:
        GPR[T] := A xor (Op and $FFFF);
      15:
        GPR[T] := SX((Op and $FFFF) shl 16, 32);
      16:
        Cop0(Op);
      17:
        Cop1(Op);
      18:
        Cop2(Op);
      32:
        GPR[T] := SX(Load(Address, 1), 8);
      33:
        GPR[T] := SX(Load(Address, 2), 16);
      35:
        GPR[T] := SX(Load(Address, 4), 32);
      36:
        GPR[T] := Load(Address, 1);
      37:
        GPR[T] := Load(Address, 2);
      39:
        GPR[T] := Load(Address, 4);
      55:
        GPR[T] := Load(Address, 8);
      26, 27, 34, 38:
        begin
          var Size := 4;
          if Code in [26, 27] then
            Size := 8;
          var Offset := Integer(Address and Cardinal(Size - 1));
          var Base := Address and not UInt64(Size - 1);
          V := B;
          for var I := 0 to Size - 1 do
          begin
            var Pos := I;
            var J := I;
            if Code in [26, 34] then
              J := I + Offset
            else
              Pos := I + Size - 1 - Offset;
            if (J < Size) and (Pos < Size) then
            begin
              var Shift := (Size - 1 - Pos) * 8;
              var M := UInt64($FF) shl Shift;
              V := (V and not M) or (Load(Add64(Base, Cardinal(J)), 1) shl Shift);
            end;
          end;
          if Size = 4 then
            V := SX(V, 32);
          GPR[T] := V;
        end;
      40:
        Store(Address, 1, B);
      41:
        Store(Address, 2, B);
      43:
        Store(Address, 4, B);
      63:
        Store(Address, 8, B);
      42, 44, 45, 46:
        begin
          var Size := 4;
          if Code in [44, 45] then
            Size := 8;
          var Offset := Integer(Address and Cardinal(Size - 1));
          var Base := Address and not UInt64(Size - 1);
          for var I := 0 to Size - 1 do
          begin
            var Pos := I;
            var J := I;
            if Code in [42, 44] then
              J := I + Offset
            else
              Pos := I + Size - 1 - Offset;
            if (J < Size) and (Pos < Size) then
              Store(Add64(Base, Cardinal(J)), 1, (B shr ((Size - 1 - Pos) * 8)) and $FF);
          end;
        end;
      47:
        ; // CACHE: uncached interpreter, all writes immediately visible.
        48, 52:
        begin
          if Code = 48 then
            GPR[T] := SX(Load(Address, 4), 32)
          else
            GPR[T] := Load(Address, 8);
          FLLAddress := Translate(Address, False);
          CP0[17] := FLLAddress shr 4;
          FLL := True;
        end;
      56, 60:
        begin
          var Size := 4;
          if Code = 60 then
            Size := 8;
          if (Address and Cardinal(Size - 1)) <> 0 then
            Fault(5, Address);
          var P := Translate(Address, True);
          var Success := FLL and (P = FLLAddress);
          if Success then
            Store(Address, Size, B);
          FLL := False;
          GPR[T] := Ord(Success);
        end;
      49, 53, 57, 61:
        begin
          if (CP0[12] and $20000000) = 0 then
            Fault(11, 0, False, 1);
          if Code = 49 then
            SetFPBits(T, 16, Load(Address, 4))
          else if Code = 53 then
            SetFPBits(T, 17, Load(Address, 8))
          else if Code = 57 then
            Store(Address, 4, FPBits(T, 16))
          else
            Store(Address, 8, FPBits(T, 17));
        end;
    else
      Fault(10);
    end;
  except
    on E: EGuestFault do
      ;
  end;
  GPR[0] := 0;
  FExecutingInstruction := False;
  FPreviousStore := FPreviousStore and FDataCached;
  AdvanceClocks(FCyclesConsumed);
  if CP0[1] <= (CP0[6] and 31) then
    CP0[1] := 31
  else
    Dec(CP0[1]);
end;

function TN64CPU.SkipIdle(MaxInstructions: Integer): Integer;
begin
  Result := 0;
  FCyclesConsumed := 0;
  if FBus.TraceEnabled then Exit;
  if (MaxInstructions < 2) or FDelay or not FInDelay or
    (FPC <> Sub64(FInstructionPC, 4)) or (FNextPC <> Add64(FPC, 4)) then Exit;
  if ((CP0[12] and 7) = 1) and
    (((CP0[12] and CP0[13] and $FF00) <> 0) or
    (((CP0[12] and $400) <> 0) and FBus.InterruptPending)) then Exit;
  // Only direct kernel RAM: extended mappings and privilege faults always step.
  if ((CP0[12] and 6) = 0) and ((CP0[12] and $18) <> 0) then Exit;
  if (FPC < $FFFFFFFF80000000) or (FPC >= $FFFFFFFFC0000000) then Exit;
  var P := Cardinal(FPC and $1FFFFFFF);
  if P > $7FFFF8 then Exit;
  var Op := FBus.Read32(P);
  if (Op <> $1000FFFF) and (Op <> ($08000000 or Cardinal((FPC shr 2) and $03FFFFFF))) then Exit;
  if FBus.Read32(P + 4) <> 0 then Exit;
  var Distance := (UInt64(CP0[11] and $FFFFFFFF) + UInt64($100000000) - (CP0[9] and $FFFFFFFF)) and $FFFFFFFF;
  if Distance = 0 then Distance := $100000000;
  var UntilCompare := Distance * 2 - Cardinal(FCountHalf);
  var Skip := MaxInstructions and not 1;
  if UInt64(Skip) >= UntilCompare then Skip := Integer((UntilCompare - 1) and not UInt64(1));
  if Skip = 0 then Exit;
  var Wired := CP0[6] and 31;
  if (CP0[1] < Wired) or (CP0[1] > 31) then Exit;
  if FBus.InterruptPending then CP0[13] := CP0[13] or $400 else CP0[13] := CP0[13] and not UInt64($400);
  FCyclesConsumed := Cardinal(Skip);
  AdvanceClocks(FCyclesConsumed);
  CP0[1] := 31 - ((31 - CP0[1] + Cardinal(Skip)) mod (32 - Wired));
  Result := Skip;
end;

procedure TN64CPU.AdvanceClocks(Clocks: Cardinal);
begin
  var Total := UInt64(Clocks) + Cardinal(FCountHalf);
  var Ticks := Total div 2;
  FCountHalf := Integer(Total and 1);
  var OldCount := CP0[9] and $FFFFFFFF;
  var Distance := (UInt64(CP0[11] and $FFFFFFFF) + UInt64($100000000) - OldCount) and $FFFFFFFF;
  if Distance = 0 then Distance := $100000000;
  if Ticks >= Distance then CP0[13] := CP0[13] or $8000;
  CP0[9] := (OldCount + Ticks) and $FFFFFFFF;
end;

procedure TN64CPU.SerializeState(State: TStateArchive);
  procedure ValidateBoolean(var Value: Boolean);
  begin
    // Do not use Ord(Value): a compiler may normalize a noncanonical Boolean.
    var Raw: Byte;
    Move(Value, Raw, SizeOf(Raw));
    if Raw > 1 then
      raise EReadError.Create('Invalid N64 CPU snapshot Boolean');
  end;
begin
  State.Field(GPR, SizeOf(GPR));
  State.Field(CP0, SizeOf(CP0));
  State.Field(FPR, SizeOf(FPR));
  State.Field(FCR31, SizeOf(FCR31));
  State.Field(HI, SizeOf(HI));
  State.Field(LO, SizeOf(LO));
  State.Field(TLB, SizeOf(TLB));
  State.Field(FPC, SizeOf(FPC));
  State.Field(FNextPC, SizeOf(FNextPC));
  State.Field(FDelay, SizeOf(FDelay));
  State.Field(FLL, SizeOf(FLL));
  State.Field(FLLAddress, SizeOf(FLLAddress));
  State.Field(FCountHalf, SizeOf(FCountHalf));
  State.Field(FCP0Latch, SizeOf(FCP0Latch));
  State.Field(FCOP2Latch, SizeOf(FCOP2Latch));
  State.Field(FPreviousLoad, SizeOf(FPreviousLoad));
  State.Field(FPreviousFP, SizeOf(FPreviousFP));
  State.Field(FPreviousStore, SizeOf(FPreviousStore));
  State.Field(FPreviousCondition, SizeOf(FPreviousCondition));
  State.Field(FPreviousException, SizeOf(FPreviousException));
  if State.Loading then
  begin
    ValidateBoolean(FDelay);
    ValidateBoolean(FLL);
    ValidateBoolean(FPreviousStore);
    ValidateBoolean(FPreviousCondition);
    ValidateBoolean(FPreviousException);
    FInDelay := False; // Idle-loop hint is not architectural snapshot state.
    FInstructionPC := FPC;
    FExecutingInstruction := False;
    FDataCached := False;
    FCyclesConsumed := 0;
    FOperationCycles := 1;
  end;
  if State.Loading and (((FCountHalf < 0) or (FCountHalf > 1)) or
    (FPreviousLoad < -1) or (FPreviousLoad > 63) or
    (FPreviousFP < -1) or (FPreviousFP > 63)) then
    raise EReadError.Create('Invalid N64 CPU snapshot');
end;

end.
