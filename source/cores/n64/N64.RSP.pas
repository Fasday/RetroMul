unit N64.RSP;

interface

uses
  System.SysUtils, System.Classes, System.Math, N64.Types, Core.Snapshots;

type
  // One vector register's eight lanes.
  TRSPLanes = array[0..7] of Word;

  TRSPTimingInfo = record
    Flags, RRead, RWrite, VRead, VWrite, VCRead, VCWrite, VFake: Cardinal;
  end;

  // What one issue clock reads and writes, for the hazard check and the
  // readiness update (an instruction alone, or a pair).
  TRSPIssueMasks = record
    Flags, Sources, Vectors, ScalarWrites, VectorWrites: Cardinal;
    External: Boolean;
  end;

  // A predecoded IMEM word; the pair entries hold for SecondOp at the next
  // slot.
  TRSPDecoded = record
    Op: Cardinal;
    PairValid, CanPair: Boolean;
    SecondOp: Cardinal;
    Info: TRSPTimingInfo;
    Single, Paired: TRSPIssueMasks;
  end;

  // Everything an RSP clock can change besides DMEM (run-ahead checkpoint).
  TRSPCheckpoint = record
    Reg: array[0..31] of Cardinal;
    Vec: array[0..31, 0..7] of Word;
    AccHi, AccMid, AccLo: array[0..7] of Word;
    VCO, VCC, VCE: Word;
    NextPC, PC: Cardinal;
    Branch, DivisionHigh: Boolean;
    DivisionInput, DivisionResult: Word;
    ScalarLo, ScalarHi, VectorLo, VectorHi: Cardinal;
    SingleIssue: Byte;
    StalledSecondOpcode: Cardinal;
    HasStalledSecondOpcode: Boolean;
    LoadHistory, BranchBubble: Byte;
    StalledOpcode, StalledPC: Cardinal;
    HasStalledOpcode: Boolean;
  end;

  TN64RSP = class
  private const
    NotDecoded = High(UInt64);
    // Element selection: lane I of VT[E] is VT lane VectorSelect[E, I].
    VectorSelect: array[0..15, 0..7] of Byte = (
      (0, 1, 2, 3, 4, 5, 6, 7), (0, 1, 2, 3, 4, 5, 6, 7), (0, 0, 2, 2, 4, 4, 6, 6), (1, 1, 3, 3, 5, 5, 7, 7),
      (0, 0, 0, 0, 4, 4, 4, 4), (1, 1, 1, 1, 5, 5, 5, 5), (2, 2, 2, 2, 6, 6, 6, 6), (3, 3, 3, 3, 7, 7, 7, 7),
      (0, 0, 0, 0, 0, 0, 0, 0), (1, 1, 1, 1, 1, 1, 1, 1), (2, 2, 2, 2, 2, 2, 2, 2), (3, 3, 3, 3, 3, 3, 3, 3),
      (4, 4, 4, 4, 4, 4, 4, 4), (5, 5, 5, 5, 5, 5, 5, 5), (6, 6, 6, 6, 6, 6, 6, 6), (7, 7, 7, 7, 7, 7, 7, 7));
  private
    FBus: TN64Bus;
    FReg: array[0..31] of Cardinal;
    FVec: array[0..31, 0..7] of Word;
    // The 48-bit accumulator lanes in three slices (bits 32..47, 16..31,
    // 0..15). FAcc is their snapshot form (sign-extended).
    FAccHi, FAccMid, FAccLo: array[0..7] of Word;
    FAcc: array[0..7] of Int64;
    // Flag registers as lane masks: bit I (and I + 8) for lane I.
    FVCO, FVCC, FVCE: Word;
    FNextPC: Cardinal;
    FBranch: Boolean;
    FDivisionHigh: Boolean;
    FDivisionInput, FDivisionResult: Word;
    // Snapshot form of the readiness counters; the live pipeline uses planes.
    FScalarReady: array[0..31] of Byte;
    FVectorReady: array[0..31] of Byte;
    // Two bit-planes per register file encode readiness 0..3 (Lo + 2 * Hi).
    FScalarLo, FScalarHi, FVectorLo, FVectorHi: Cardinal;
    // IMEM predecoded per word; an entry is redone when the bus's stamp of
    // its word changes (every write to IMEM) or, without direct SP memory,
    // when the word read differs.
    FDec: array[0..1023] of TRSPDecoded;
    // The masks of the held words FStallOp/FStallSecond/FStallPair (a pure
    // function of them), for the clocks a stall repeats.
    FStallMasks: TRSPIssueMasks;
    FStallOp, FStallSecond: Cardinal;
    FStallPair, FStallKnown: Boolean;
    // The bus's IMEM stamp of each word when decoded; NotDecoded at first.
    FDecStamp: array[0..1023] of UInt64;
    FSingleIssue: Byte;
    FStalledSecondOpcode: Cardinal;
    FHasStalledSecondOpcode: Boolean;
    FLoadHistory, FBranchBubble: Byte;
    FStalledOpcode, FStalledPC: Cardinal;
    FHasStalledOpcode: Boolean;
    // Run-ahead: the state before the first clock run ahead, and the 64-byte
    // DMEM lines as they were before their first write in this run (a line
    // is saved when FLineRun differs from FRun).
    FAhead, FCheckpointed: Boolean;
    FCheckpoint: TRSPCheckpoint;
    FRun: Cardinal;
    FLineRun: array[0..63] of Cardinal;
    FLineBackup: array[0..4095] of Byte;
    procedure SaveCheckpoint(PC: Cardinal);
    procedure SaveLine(Offset: Cardinal);
    procedure Decode(Slot: Integer; Op: Cardinal; Stamp: UInt64);
    procedure DecodePair(Slot: Integer);
    function DecodedSlot(Slot: Integer): Integer; inline;
    class procedure Combine(const A, B: TRSPTimingInfo; ExternalA, ExternalB: Boolean; out Masks: TRSPIssueMasks); static;
    class procedure MasksOf(const Info: TRSPTimingInfo; IsExternal: Boolean; out Masks: TRSPIssueMasks); static;
    procedure IssueCOP0(Op, Current: Cardinal);
    procedure IssueMoveCOP2(Op: Cardinal);
    procedure IssueLoadStore(Op, Address: Cardinal);
    class procedure Unsupported(const Kind: string; Op: Cardinal); static;
    function RunClocks(var PC, Status, Interrupt: Cardinal; Cycles: Integer; Ahead: Boolean): Integer;
    class function External(Op: Cardinal): Boolean; static;
    procedure AgePipeline; inline;
    function DMemRead(Offset: Cardinal): Byte; inline;
    procedure DMemWrite(Offset: Cardinal; Value: Byte); inline;
    function IMemRead32(PC: Cardinal): Cardinal; inline;
    procedure PlanesToArrays;
    procedure ArraysToPlanes;
    function InfoEXECUTE(Op: Cardinal): TRSPTimingInfo;
    function InfoSPECIAL(Op: Cardinal): TRSPTimingInfo;
    function InfoREGIMM(Op: Cardinal): TRSPTimingInfo;
    function InfoSCC(Op: Cardinal): TRSPTimingInfo;
    function InfoVU(Op: Cardinal): TRSPTimingInfo;
    function InfoLWC2(Op: Cardinal): TRSPTimingInfo;
    function InfoSWC2(Op: Cardinal): TRSPTimingInfo;
    function CanPair(const A, B: TRSPTimingInfo): Boolean;
    procedure IssueInstruction(Op: Cardinal; var PC, Status, Interrupt: Cardinal);
    function AccOf(I: Integer): Int64; inline;
    function AccBits(I: Integer): Int64; inline;
    procedure SetAcc(I: Integer; Value: Int64); inline;
    procedure SelectVT(T, E: Integer; out VT: TRSPLanes); inline;
    procedure VectorOp(Op: Cardinal);
    procedure VectorMulFrac(Op: Cardinal);
    procedure VectorRound(Op: Cardinal);
    procedure VectorMulQ(Op: Cardinal);
    procedure VectorMul(Op: Cardinal);
    procedure VectorAddSub(Op: Cardinal);
    procedure VectorAbs(Op: Cardinal);
    procedure VectorCarry(Op: Cardinal);
    procedure VectorSar(Op: Cardinal);
    procedure VectorCompare(Op: Cardinal);
    procedure VectorClipLow(Op: Cardinal);
    procedure VectorClipHigh(Op: Cardinal);
    procedure VectorMerge(Op: Cardinal);
    procedure VectorLogic(Op: Cardinal);
    procedure VectorReserved(Op: Cardinal);
    procedure VectorDivide(Op: Cardinal);
    procedure VectorMemory(Op: Cardinal; Writing: Boolean);
    function GetByte(R, Index: Integer): Byte;
    procedure SetByte(R, Index: Integer; Value: Byte);
  public
    constructor Create(Bus: TN64Bus);
    procedure Reset;
    // SP_PC writes discard pending branches and fetched instructions.
    procedure ResetPipeline;
    procedure Execute(var PC, Status, Interrupt: Cardinal);
    // The budget includes SU load interlocks and taken-branch bubbles. Each
    // stalled clock returns to the console before another instruction executes.
    function ExecuteCycles(var PC, Status, Interrupt: Cardinal; Cycles: Integer): Integer;
    // Run-ahead. RunAhead executes up to Cycles clocks for as long as they
    // touch nothing outside the RSP but DMEM (no COP0, no BREAK, nothing that
    // raises) and returns how many it ran; Status is not changed (it must not
    // halt or single-step). Rewind returns to the state before them and runs
    // Keep of them again. EndAhead keeps them all.
    function RunAhead(var PC: Cardinal; Status: Cardinal; Cycles: Integer): Integer;
    procedure Rewind(var PC: Cardinal; Keep: Integer);
    procedure EndAhead;
    procedure SerializeState(State: TStateArchive);
  end;

implementation

constructor TN64RSP.Create(Bus: TN64Bus);
begin
  inherited Create;
  FBus := Bus;
  for var I := 0 to High(FDecStamp) do
    FDecStamp[I] := NotDecoded;
  Reset
end;

procedure TN64RSP.Reset;
begin
  for var I := 0 to 31 do
  begin
    FReg[I] := 0;
    for var J := 0 to 7 do
      FVec[I, J] := 0
  end;
  for var I := 0 to 7 do
  begin
    FAcc[I] := 0;
    FAccHi[I] := 0;
    FAccMid[I] := 0;
    FAccLo[I] := 0;
  end;
  FVCO := 0;
  FVCC := 0;
  FVCE := 0;
  FDivisionHigh := False;
  FDivisionInput := 0;
  FDivisionResult := 0;
  ResetPipeline;
  EndAhead;
end;

procedure TN64RSP.ResetPipeline;
begin
  FNextPC := 0;
  FBranch := False;
  for var I := 0 to 31 do
  begin
    FScalarReady[I] := 0;
    FVectorReady[I] := 0
  end;
  FScalarLo := 0;
  FScalarHi := 0;
  FVectorLo := 0;
  FVectorHi := 0;
  FSingleIssue := 0;
  FStalledSecondOpcode := 0;
  FHasStalledSecondOpcode := False;
  FLoadHistory := 0;
  FBranchBubble := 0;
  FStalledOpcode := 0;
  FStalledPC := 0;
  FHasStalledOpcode := False;
end;

function TN64RSP.DMemRead(Offset: Cardinal): Byte;
begin
  // Offset is already wrapped to DMEM. The bus contract makes SP memory exact.
  if FBus.DirectMemory then
    Result := FBus.ReadSP8(Offset)
  else
    Result := FBus.Read8($04000000 + Offset);
end;

procedure TN64RSP.DMemWrite(Offset: Cardinal; Value: Byte);
begin
  if FAhead and (FLineRun[Offset shr 6] <> FRun) then
    SaveLine(Offset);
  if FBus.DirectMemory then
    FBus.WriteSP8(Offset, Value)
  else
    FBus.Write8($04000000 + Offset, Value);
end;

function TN64RSP.IMemRead32(PC: Cardinal): Cardinal;
begin
  var Offset := $1000 + (PC and $FFC);
  if FBus.DirectMemory then
    Result := FBus.ReadSP32(Offset)
  else
    Result := FBus.Read32($04000000 + Offset);
end;

class procedure TN64RSP.MasksOf(const Info: TRSPTimingInfo; IsExternal: Boolean; out Masks: TRSPIssueMasks);
begin
  Masks.Flags := Info.Flags;
  Masks.Sources := Info.RRead;
  Masks.Vectors := Info.VRead;
  Masks.ScalarWrites := 0;
  if (Info.Flags and 32) = 0 then
    Masks.ScalarWrites := Info.RWrite;
  Masks.VectorWrites := Info.VWrite;
  Masks.External := IsExternal;
end;

class procedure TN64RSP.Combine(const A, B: TRSPTimingInfo; ExternalA, ExternalB: Boolean; out Masks: TRSPIssueMasks);
begin
  var Second: TRSPIssueMasks;
  MasksOf(A, ExternalA, Masks);
  MasksOf(B, ExternalB, Second);
  Masks.Flags := Masks.Flags or Second.Flags;
  Masks.Sources := Masks.Sources or Second.Sources;
  Masks.Vectors := Masks.Vectors or Second.Vectors;
  Masks.ScalarWrites := Masks.ScalarWrites or Second.ScalarWrites;
  Masks.VectorWrites := Masks.VectorWrites or Second.VectorWrites;
  Masks.External := Masks.External or Second.External;
end;

procedure TN64RSP.Decode(Slot: Integer; Op: Cardinal; Stamp: UInt64);
begin
  FDec[Slot].Op := Op;
  FDec[Slot].Info := InfoEXECUTE(Op);
  MasksOf(FDec[Slot].Info, External(Op), FDec[Slot].Single);
  FDec[Slot].PairValid := False;
  FDecStamp[Slot] := Stamp;
end;

procedure TN64RSP.DecodePair(Slot: Integer);
begin
  // Both slots are decoded.
  var Next := (Slot + 1) and 1023;
  FDec[Slot].SecondOp := FDec[Next].Op;
  FDec[Slot].CanPair := CanPair(FDec[Slot].Info, FDec[Next].Info);
  Combine(FDec[Slot].Info, FDec[Next].Info, FDec[Slot].Single.External, FDec[Next].Single.External, FDec[Slot].Paired);
  FDec[Slot].PairValid := True;
end;

function TN64RSP.DecodedSlot(Slot: Integer): Integer;
begin
  if FBus.DirectMemory then
  begin
    if FDecStamp[Slot] <> FBus.IMemStamp(Slot) then
      Decode(Slot, FBus.IMemWord(Slot), FBus.IMemStamp(Slot));
  end
  else
  begin
    // Without the bus's stamps: compare the word itself.
    var Op := IMemRead32(Cardinal(Slot) * 4);
    if (FDecStamp[Slot] = NotDecoded) or (FDec[Slot].Op <> Op) then
      Decode(Slot, Op, 0);
  end;
  Result := Slot;
end;

procedure TN64RSP.PlanesToArrays;
begin
  for var I := 0 to 31 do
  begin
    var Bit := Cardinal(1) shl I;
    FScalarReady[I] := Byte(Ord((FScalarLo and Bit) <> 0) + 2 * Ord((FScalarHi and Bit) <> 0));
    FVectorReady[I] := Byte(Ord((FVectorLo and Bit) <> 0) + 2 * Ord((FVectorHi and Bit) <> 0));
  end;
end;

procedure TN64RSP.ArraysToPlanes;
begin
  FScalarLo := 0;
  FScalarHi := 0;
  FVectorLo := 0;
  FVectorHi := 0;
  for var I := 0 to 31 do
  begin
    var Bit := Cardinal(1) shl I;
    if (FScalarReady[I] and 1) <> 0 then
      FScalarLo := FScalarLo or Bit;
    if (FScalarReady[I] and 2) <> 0 then
      FScalarHi := FScalarHi or Bit;
    if (FVectorReady[I] and 1) <> 0 then
      FVectorLo := FVectorLo or Bit;
    if (FVectorReady[I] and 2) <> 0 then
      FVectorHi := FVectorHi or Bit;
  end;
end;

function TN64RSP.GetByte(R, Index: Integer): Byte;
begin
  Index := Index and 15;
  if Odd(Index) then
    Result := Byte(FVec[R, Index div 2] and $FF)
  else
    Result := Byte(FVec[R, Index div 2] shr 8);
end;

procedure TN64RSP.SetByte(R, Index: Integer; Value: Byte);
begin
  Index := Index and 15;
  if Odd(Index) then
    FVec[R, Index div 2] := (FVec[R, Index div 2] and $FF00) or Value
  else
    FVec[R, Index div 2] := (FVec[R, Index div 2] and $FF) or (Word(Value) shl 8);
end;

function S16(Value: Word): Integer; inline;
begin
  Result := Integer(Value xor $8000) - $8000;
end;

function W16(Value: Int64): Word; inline;
begin
  Result := Word(Value and $FFFF)
end;

function ClampSigned(Value: Int64): Word; inline;
begin
  Result := W16(EnsureRange(Value, Int64(-32768), Int64(32767)))
end;

function ClampMid(Hi, Mid: Word): Word; inline;
begin
  // The accumulator's bits 16..47 as a signed value, clamped to 16 bits.
  if Hi = 0 then
  begin
    if Mid < $8000 then
      Result := Mid
    else
      Result := $7FFF;
  end
  else if Hi = $FFFF then
  begin
    if Mid >= $8000 then
      Result := Mid
    else
      Result := $8000;
  end
  else if Hi < $8000 then
    Result := $7FFF
  else
    Result := $8000;
end;

function ClampLow(Hi, Mid, Lo: Word): Word; inline;
begin
  // VMADL/VMADN: the low half when the accumulator fits 32 signed bits,
  // else 0 below and $FFFF above.
  if ((Hi = 0) and (Mid < $8000)) or ((Hi = $FFFF) and (Mid >= $8000)) then
    Result := Lo
  else if Hi < $8000 then
    Result := $FFFF
  else
    Result := 0;
end;

function TN64RSP.AccOf(I: Integer): Int64;
begin
  // The 48-bit accumulator lane, sign-extended.
  Result := Int64((UInt64(FAccHi[I]) shl 32) or (UInt64(FAccMid[I]) shl 16) or FAccLo[I]);
  if FAccHi[I] >= $8000 then
    Dec(Result, Int64($1000000000000));
end;

function TN64RSP.AccBits(I: Integer): Int64;
begin
  // The lane's 48 bits as they are (not sign-extended): enough for a sum
  // that SetAcc wraps at 48 bits again.
  Result := Int64((UInt64(FAccHi[I]) shl 32) or (UInt64(FAccMid[I]) shl 16) or FAccLo[I]);
end;

procedure TN64RSP.SetAcc(I: Integer; Value: Int64);
begin
  // Keeps the low 48 bits (the guest's accumulator wraps there).
  FAccLo[I] := Word(Value and $FFFF);
  FAccMid[I] := Word((Value shr 16) and $FFFF);
  FAccHi[I] := Word((Value shr 32) and $FFFF);
end;

procedure TN64RSP.SelectVT(T, E: Integer; out VT: TRSPLanes);
begin
  if E < 2 then
    for var I := 0 to 7 do
      VT[I] := FVec[T, I]
  else
    for var I := 0 to 7 do
      VT[I] := FVec[T, VectorSelect[E, I]];
end;

procedure TN64RSP.VectorOp(Op: Cardinal);
begin
  // Each family reads VS lane by lane before writing that VD lane, and VT
  // from a copy, so VD may be VS or VT.
  case Op and 63 of
    0, 1, 8, 9:
      VectorMulFrac(Op);
    2, 10:
      VectorRound(Op);
    3, 11:
      VectorMulQ(Op);
    4..7, 12..15:
      VectorMul(Op);
    16, 17:
      VectorAddSub(Op);
    19:
      VectorAbs(Op);
    20, 21:
      VectorCarry(Op);
    29:
      VectorSar(Op);
    32..35:
      VectorCompare(Op);
    36:
      VectorClipLow(Op);
    37, 38:
      VectorClipHigh(Op);
    39:
      VectorMerge(Op);
    40..45:
      VectorLogic(Op);
    48..54:
      VectorDivide(Op);
    55, 63:
      ; // VNULL encodings: no effect.
  else
    VectorReserved(Op);
  end;
end;

procedure TN64RSP.VectorMulFrac(Op: Cardinal);
begin
  // VMULF, VMULU (product * 2 + rounding), VMACF, VMACU (accumulate).
  var VT: TRSPLanes;
  SelectVT((Op shr 16) and 31, (Op shr 21) and 15, VT);
  var S := (Op shr 11) and 31;
  var D := (Op shr 6) and 31;
  var Fn := Op and 63;
  for var I := 0 to 7 do
  begin
    var V := Int64(S16(FVec[S, I])) * S16(VT[I]) * 2;
    if Fn < 8 then
      SetAcc(I, V + $8000)
    else
      SetAcc(I, AccBits(I) + V);
    if (Fn and 1) = 0 then
      FVec[D, I] := ClampMid(FAccHi[I], FAccMid[I])
    else if FAccHi[I] >= $8000 then
      FVec[D, I] := 0
    else if (FAccHi[I] <> 0) or (FAccMid[I] >= $8000) then
      FVec[D, I] := $FFFF
    else
      FVec[D, I] := FAccMid[I];
  end;
end;

procedure TN64RSP.VectorRound(Op: Cardinal);
begin
  // VRNDP (if ACC >= 0), VRNDN (if ACC < 0): ACC += VT, shifted when VS is odd.
  var VT: TRSPLanes;
  SelectVT((Op shr 16) and 31, (Op shr 21) and 15, VT);
  var S := (Op shr 11) and 31;
  var D := (Op shr 6) and 31;
  var Negative := (Op and 63) = 10;
  for var I := 0 to 7 do
  begin
    var V := Int64(S16(VT[I]));
    if (S and 1) <> 0 then
      V := V * 65536;
    if (FAccHi[I] >= $8000) = Negative then
      SetAcc(I, AccBits(I) + V);
    FVec[D, I] := ClampMid(FAccHi[I], FAccMid[I]);
  end;
end;

procedure TN64RSP.VectorMulQ(Op: Cardinal);
begin
  // VMULQ (product, biased when negative) and VMACQ (ACC_HI/MD rounded by 32).
  var VT: TRSPLanes;
  SelectVT((Op shr 16) and 31, (Op shr 21) and 15, VT);
  var S := (Op shr 11) and 31;
  var D := (Op shr 6) and 31;
  var Accumulate := (Op and 63) = 11;
  for var I := 0 to 7 do
  begin
    var V: Int64;
    if Accumulate then
    begin
      // ACC bits 16..47, signed.
      V := Int64(Integer((Cardinal(FAccHi[I]) shl 16) or FAccMid[I]));
      if (V < -32) and ((V and 32) = 0) then
        Inc(V, 32)
      else if (V > 32) and ((V and 32) = 0) then
        Dec(V, 32);
      SetAcc(I, V * 65536 + FAccLo[I]);
    end
    else
    begin
      V := Int64(S16(FVec[S, I])) * S16(VT[I]);
      if V < 0 then
        Inc(V, 31);
      SetAcc(I, V * 65536);
    end;
    var Half := V div 2;
    if (V < 0) and Odd(V) then
      Dec(Half);
    FVec[D, I] := ClampSigned(Half) and $FFF0;
  end;
end;

procedure TN64RSP.VectorMul(Op: Cardinal);
begin
  // VMUDL/VMUDM/VMUDN/VMUDH set ACC to the product, VMADL/VMADM/VMADN/VMADH
  // add it. One loop per instruction.
  var VT: TRSPLanes;
  SelectVT((Op shr 16) and 31, (Op shr 21) and 15, VT);
  var S := (Op shr 11) and 31;
  var D := (Op shr 6) and 31;
  case Op and 63 of
    4:
      for var I := 0 to 7 do
      begin
        var V := Word(((Cardinal(FVec[S, I]) * VT[I]) shr 16) and $FFFF);
        FAccLo[I] := V;
        FAccMid[I] := 0;
        FAccHi[I] := 0;
        FVec[D, I] := V;
      end;
    5:
      for var I := 0 to 7 do
      begin
        SetAcc(I, Int64(S16(FVec[S, I])) * VT[I]);
        FVec[D, I] := ClampMid(FAccHi[I], FAccMid[I]);
      end;
    6:
      for var I := 0 to 7 do
      begin
        SetAcc(I, Int64(FVec[S, I]) * S16(VT[I]));
        FVec[D, I] := FAccLo[I];
      end;
    7:
      for var I := 0 to 7 do
      begin
        var P := S16(FVec[S, I]) * S16(VT[I]);
        FAccLo[I] := 0;
        FAccMid[I] := Word(P and $FFFF);
        FAccHi[I] := Word((Int64(P) shr 16) and $FFFF);
        FVec[D, I] := ClampSigned(P);
      end;
    12:
      for var I := 0 to 7 do
      begin
        SetAcc(I, AccBits(I) + ((Cardinal(FVec[S, I]) * VT[I]) shr 16));
        FVec[D, I] := ClampLow(FAccHi[I], FAccMid[I], FAccLo[I]);
      end;
    13:
      for var I := 0 to 7 do
      begin
        SetAcc(I, AccBits(I) + Int64(S16(FVec[S, I])) * VT[I]);
        FVec[D, I] := ClampMid(FAccHi[I], FAccMid[I]);
      end;
    14:
      for var I := 0 to 7 do
      begin
        SetAcc(I, AccBits(I) + Int64(FVec[S, I]) * S16(VT[I]));
        FVec[D, I] := ClampLow(FAccHi[I], FAccMid[I], FAccLo[I]);
      end;
  else
    for var I := 0 to 7 do
    begin
      // VMADH changes bits 16..47 only: a 32-bit sum, wrapped.
      var Sum := ((Int64(FAccHi[I]) shl 16) or FAccMid[I]) + S16(FVec[S, I]) * S16(VT[I]);
      FAccMid[I] := Word(Sum and $FFFF);
      FAccHi[I] := Word((Sum shr 16) and $FFFF);
      FVec[D, I] := ClampMid(FAccHi[I], FAccMid[I]);
    end;
  end;
end;

procedure TN64RSP.VectorAddSub(Op: Cardinal);
begin
  // VADD, VSUB with the VCO carry; clears VCO.
  var VT: TRSPLanes;
  SelectVT((Op shr 16) and 31, (Op shr 21) and 15, VT);
  var S := (Op shr 11) and 31;
  var D := (Op shr 6) and 31;
  var Subtract := (Op and 63) = 17;
  for var I := 0 to 7 do
  begin
    var V: Integer;
    if Subtract then
      V := S16(FVec[S, I]) - S16(VT[I]) - Integer((FVCO shr I) and 1)
    else
      V := S16(FVec[S, I]) + S16(VT[I]) + Integer((FVCO shr I) and 1);
    FAccLo[I] := Word(V and $FFFF);
    FVec[D, I] := ClampSigned(V);
  end;
  FVCO := 0;
end;

procedure TN64RSP.VectorAbs(Op: Cardinal);
begin
  // VABS: VT negated, kept or zeroed by the sign of VS.
  var VT: TRSPLanes;
  SelectVT((Op shr 16) and 31, (Op shr 21) and 15, VT);
  var S := (Op shr 11) and 31;
  var D := (Op shr 6) and 31;
  for var I := 0 to 7 do
  begin
    var A := S16(FVec[S, I]);
    var V := 0;
    if A < 0 then
      V := -S16(VT[I])
    else if A > 0 then
      V := S16(VT[I]);
    FAccLo[I] := Word(V and $FFFF);
    FVec[D, I] := ClampSigned(V);
  end;
end;

procedure TN64RSP.VectorCarry(Op: Cardinal);
begin
  // VADDC (carry out), VSUBC (borrow and not-equal) into VCO.
  var VT: TRSPLanes;
  SelectVT((Op shr 16) and 31, (Op shr 21) and 15, VT);
  var S := (Op shr 11) and 31;
  var D := (Op shr 6) and 31;
  var Carry: Cardinal := 0;
  for var I := 0 to 7 do
  begin
    var V: Integer;
    if (Op and 63) = 20 then
    begin
      V := Integer(FVec[S, I]) + VT[I];
      if V > $FFFF then
        Carry := Carry or (Cardinal(1) shl I);
    end
    else
    begin
      V := Integer(FVec[S, I]) - VT[I];
      if V < 0 then
        Carry := Carry or (Cardinal(1) shl I);
      if V <> 0 then
        Carry := Carry or (Cardinal(1) shl (I + 8));
    end;
    FAccLo[I] := Word(V and $FFFF);
    FVec[D, I] := Word(V and $FFFF);
  end;
  FVCO := Word(Carry);
end;

procedure TN64RSP.VectorSar(Op: Cardinal);
begin
  // VSAR: read one accumulator slice (E = 8, 9, 10), zero otherwise.
  var D := (Op shr 6) and 31;
  for var I := 0 to 7 do
    case (Op shr 21) and 15 of
      8:
        FVec[D, I] := FAccHi[I];
      9:
        FVec[D, I] := FAccMid[I];
      10:
        FVec[D, I] := FAccLo[I];
    else
      FVec[D, I] := 0;
    end;
end;

procedure TN64RSP.VectorCompare(Op: Cardinal);
begin
  // VLT, VEQ, VNE, VGE: VCC low byte from the test, VCO cleared.
  var VT: TRSPLanes;
  SelectVT((Op shr 16) and 31, (Op shr 21) and 15, VT);
  var S := (Op shr 11) and 31;
  var D := (Op shr 6) and 31;
  var Fn := Op and 63;
  var Compare: Cardinal := 0;
  for var I := 0 to 7 do
  begin
    var A := S16(FVec[S, I]);
    var B := S16(VT[I]);
    var Carry := ((FVCO shr I) and 1) <> 0;
    var NotEqual := ((FVCO shr (I + 8)) and 1) <> 0;
    var Test: Boolean;
    case Fn of
      32:
        Test := (A < B) or ((A = B) and Carry and NotEqual);
      33:
        Test := (A = B) and not NotEqual;
      34:
        Test := (A <> B) or NotEqual;
    else
      Test := (A > B) or ((A = B) and not (Carry and NotEqual));
    end;
    var R: Word;
    if Test then
    begin
      Compare := Compare or (Cardinal(1) shl I);
      R := FVec[S, I];
    end
    else
      R := VT[I];
    FAccLo[I] := R;
    FVec[D, I] := R;
  end;
  FVCO := 0;
  FVCC := Word(Compare);
end;

procedure TN64RSP.VectorClipLow(Op: Cardinal);
begin
  // VCL: the clip compare continuing a VCH/VCR, from VCO, VCC and VCE.
  var VT: TRSPLanes;
  SelectVT((Op shr 16) and 31, (Op shr 21) and 15, VT);
  var S := (Op shr 11) and 31;
  var D := (Op shr 6) and 31;
  var Compare := Cardinal(FVCC);
  for var I := 0 to 7 do
  begin
    var UA := Integer(FVec[S, I]);
    var UB := Integer(VT[I]);
    var LowFlag := ((FVCC shr I) and 1) <> 0;
    var HighFlag := ((FVCC shr (I + 8)) and 1) <> 0;
    var R := Word(UA);
    if ((FVCO shr I) and 1) <> 0 then
    begin
      if ((FVCO shr (I + 8)) and 1) = 0 then
        if ((FVCE shr I) and 1) <> 0 then
          LowFlag := UA + UB <= 65536
        else
          LowFlag := UA + UB = 0;
      if LowFlag then
        R := Word((-S16(VT[I])) and $FFFF);
    end
    else
    begin
      if ((FVCO shr (I + 8)) and 1) = 0 then
        HighFlag := UA >= UB;
      if HighFlag then
        R := Word(UB);
    end;
    Compare := Compare and not ((Cardinal(1) shl I) or (Cardinal(1) shl (I + 8)));
    if LowFlag then
      Compare := Compare or (Cardinal(1) shl I);
    if HighFlag then
      Compare := Compare or (Cardinal(1) shl (I + 8));
    FAccLo[I] := R;
    FVec[D, I] := R;
  end;
  FVCO := 0;
  FVCC := Word(Compare);
  FVCE := 0;
end;

procedure TN64RSP.VectorClipHigh(Op: Cardinal);
begin
  // VCH (sets VCO and VCE for a following VCL) and VCR.
  var VT: TRSPLanes;
  SelectVT((Op shr 16) and 31, (Op shr 21) and 15, VT);
  var S := (Op shr 11) and 31;
  var D := (Op shr 6) and 31;
  var High := (Op and 63) = 37;
  var Carry: Cardinal := 0;
  var Compare: Cardinal := 0;
  var Extension: Cardinal := 0;
  for var I := 0 to 7 do
  begin
    var A := S16(FVec[S, I]);
    var B := S16(VT[I]);
    var UB := Integer(VT[I]);
    var LowFlag, HighFlag: Boolean;
    var R := FVec[S, I];
    if (A < 0) <> (B < 0) then
    begin
      var Sum := A + B;
      if High then
      begin
        Sum := S16(Word(Sum and $FFFF));
        LowFlag := Sum <= 0;
      end
      else
        LowFlag := Sum + 1 <= 0;
      HighFlag := B < 0;
      if LowFlag then
        if High then
          R := Word((-B) and $FFFF)
        else
          R := Word(UB xor $FFFF);
      if High then
      begin
        Carry := Carry or (Cardinal(1) shl I);
        if (Sum <> 0) and (A <> S16(Word(UB xor $FFFF))) then
          Carry := Carry or (Cardinal(1) shl (I + 8));
        if Sum = -1 then
          Extension := Extension or (Cardinal(1) shl I);
      end;
    end
    else
    begin
      var Difference := A - B;
      if High then
        Difference := S16(Word(Difference and $FFFF));
      LowFlag := B < 0;
      HighFlag := Difference >= 0;
      if HighFlag then
        R := Word(UB);
      if High and (Difference <> 0) and (A <> S16(Word(UB xor $FFFF))) then
        Carry := Carry or (Cardinal(1) shl (I + 8));
    end;
    if LowFlag then
      Compare := Compare or (Cardinal(1) shl I);
    if HighFlag then
      Compare := Compare or (Cardinal(1) shl (I + 8));
    FAccLo[I] := R;
    FVec[D, I] := R;
  end;
  FVCO := Word(Carry);
  FVCC := Word(Compare);
  FVCE := Word(Extension);
end;

procedure TN64RSP.VectorMerge(Op: Cardinal);
begin
  // VMRG: VS where VCC is set, else VT; clears VCO.
  var VT: TRSPLanes;
  SelectVT((Op shr 16) and 31, (Op shr 21) and 15, VT);
  var S := (Op shr 11) and 31;
  var D := (Op shr 6) and 31;
  for var I := 0 to 7 do
  begin
    var R := VT[I];
    if ((FVCC shr I) and 1) <> 0 then
      R := FVec[S, I];
    FAccLo[I] := R;
    FVec[D, I] := R;
  end;
  FVCO := 0;
end;

procedure TN64RSP.VectorLogic(Op: Cardinal);
begin
  // VAND, VNAND, VOR, VNOR, VXOR, VNXOR.
  var VT: TRSPLanes;
  SelectVT((Op shr 16) and 31, (Op shr 21) and 15, VT);
  var S := (Op shr 11) and 31;
  var D := (Op shr 6) and 31;
  var Fn := Op and 63;
  for var I := 0 to 7 do
  begin
    var R: Word;
    case Fn of
      40:
        R := FVec[S, I] and VT[I];
      41:
        R := (FVec[S, I] and VT[I]) xor $FFFF;
      42:
        R := FVec[S, I] or VT[I];
      43:
        R := (FVec[S, I] or VT[I]) xor $FFFF;
      44:
        R := FVec[S, I] xor VT[I];
    else
      R := (FVec[S, I] xor VT[I]) xor $FFFF;
    end;
    FAccLo[I] := R;
    FVec[D, I] := R;
  end;
end;

procedure TN64RSP.VectorReserved(Op: Cardinal);
begin
  // Reserved encodings still execute: VS + VT to ACC_LO, VD zeroed.
  var VT: TRSPLanes;
  SelectVT((Op shr 16) and 31, (Op shr 21) and 15, VT);
  var S := (Op shr 11) and 31;
  var D := (Op shr 6) and 31;
  for var I := 0 to 7 do
  begin
    FAccLo[I] := Word((S16(FVec[S, I]) + S16(VT[I])) and $FFFF);
    FVec[D, I] := 0;
  end;
end;

procedure TN64RSP.VectorDivide(Op: Cardinal);
begin
  // VRCP, VRCPL, VRCPH, VMOV, VRSQ, VRSQL, VRSQH: one lane of VD; every
  // ACC_LO lane gets the selected VT.
  var E := (Op shr 21) and 15;
  var T := (Op shr 16) and 31;
  var D := (Op shr 6) and 31;
  var Fn := Op and 63;
  var DE := ((Op shr 11) and 31) and 7;
  var VT: TRSPLanes;
  SelectVT(T, E, VT);
  // The scalar divider always takes the raw E&7 lane of VT.
  var Source := FVec[T, E and 7];
  for var I := 0 to 7 do
    FAccLo[I] := VT[I];
  if Fn = 51 then
    FVec[D, DE] := VT[DE]
  else if Fn in [50, 54] then
  begin
    FVec[D, DE] := FDivisionResult;
    FDivisionInput := Source;
    FDivisionHigh := True;
  end
  else
  begin
    var Input := Integer(SignedValue(SX(Source, 16)));
    if FDivisionHigh and (Fn in [49, 53]) then
      Input := Integer(SignedValue(SX((Cardinal(FDivisionInput) shl 16) or Source, 32)));
    var Data: Cardinal;
    var SignMask: Cardinal := 0;
    if Input < 0 then
      SignMask := $FFFFFFFF;
    Data := Cardinal(Int64(Input) and $FFFFFFFF) xor SignMask;
    if (Input < 0) and (Input > -32768) then
      Inc(Data);
    var Value: Cardinal := $7FFFFFFF;
    if Input = -32768 then
      Value := $FFFF0000
    else if Data <> 0 then
    begin
      var Shift := 0;
      while (Data and $80000000) = 0 do
      begin
        Data := Data shl 1;
        Inc(Shift)
      end;
      var Index := (Data shr 22) and 511;
      var TableValue: Cardinal;
      if Fn in [52, 53] then
      begin
        var Denominator := UInt64(512 + (Index and 510));
        if (Shift and 1) = 0 then
          Denominator := Denominator * 2;
        var LowBound: UInt64 := 65536;
        var HighBound: UInt64 := 131071;
        while LowBound < HighBound do
        begin
          var Mid := (LowBound + HighBound + 1) div 2;
          if Mid * Mid * Denominator <= (UInt64(1) shl 43) then
            LowBound := Mid
          else
            HighBound := Mid - 1;
        end;
        TableValue := Cardinal(LowBound - 65536);
        Value := ((($10000 or TableValue) shl 14) shr ((31 - Shift) div 2)) xor SignMask;
      end
      else
      begin
        TableValue := Cardinal(Min(UInt64($FFFF), ((((UInt64(1) shl 34) div (Index + 512)) + 1) shr 8) - $10000));
        Value := ((($10000 or TableValue) shl 14) shr (31 - Shift)) xor SignMask;
      end;
    end;
    FVec[D, DE] := Word(Value and $FFFF);
    FDivisionResult := Word(Value shr 16);
    FDivisionHigh := False;
  end;
end;

procedure TN64RSP.VectorMemory(Op: Cardinal; Writing: Boolean);
begin
  var Base := (Op shr 21) and 31;
  var V := (Op shr 16) and 31;
  var Kind := (Op shr 11) and 31;
  var E := Integer((Op shr 7) and 15);
  var Offset := Integer(SignedValue(SX(Op and 127, 7)));
  var Size: Integer;
  case Kind of
    0..3:
      Size := 1 shl Kind;
    4, 5, 8..11:
      Size := 16;
    6, 7:
      Size := 8;
  else
    raise EN64Unsupported.CreateFmt('RSP vector memory opcode %d is not implemented', [Kind]);
  end;
  var Address := Cardinal(Add64(FReg[Base], SX(UInt64((Int64(Offset) * Size) and $FFFFFFFF), 32)) and $FFF);
  if Kind = 11 then
  begin
    var Start := Address and $FF8;
    var Position := (E + Integer(Address and 8)) and 15;
    if Writing then
      Position := (Integer(Address and 7) - (E and 14)) and 15;
    for var I := 0 to 7 do
      for var J := 0 to 1 do
      begin
        var R := Integer(V and 24) + ((E div 2 + I) and 7);
        var Element := I * 2 + J;
        if Writing then
        begin
          R := Integer(V and 24) + I;
          Element := (16 - (E and 14) + I * 2 + J) and 15
        end;
        var A := (Start + Cardinal(Position)) and $FFF;
        if Writing then
          DMemWrite(A, GetByte(R, Element))
        else
          SetByte(R, Element, DMemRead(A));
        Position := (Position + 1) and 15;
      end;
    Exit;
  end;
  if Kind = 10 then
  begin
    if not Writing then
      Exit; // LWV is a hardware no-op.
    var Start := Address and $FF8;
    var Position := Integer(Address and 7);
    for var I := 0 to 15 do
      DMemWrite(((Start + Cardinal((Position + I) and 15)) and $FFF), GetByte(V, E + I));
    Exit;
  end;
  if Kind in [8, 9] then
  begin
    var Start := Address and $FF8;
    var Position := Integer(Address and 7) - E;
    if Kind = 8 then
    begin
      for var I := 0 to 7 do
        if Writing then
        begin
          var Value := ((Cardinal(GetByte(V, E + I * 2)) shl 1) or (GetByte(V, E + I * 2 + 1) shr 7)) and $FF;
          DMemWrite(((Start + Cardinal((Integer(Address and 7) + I * 2) and 15)) and $FFF), Byte(Value));
        end
        else
          FVec[V, I] := Word(DMemRead(((Start + Cardinal((Position + I * 2) and 15)) and $FFF))) shl 7;
    end
    else if Writing then
    begin
      for var I := 0 to 3 do
      begin
        var Lane := -1;
        case E of
          0, 15:
            Lane := I;
          1:
            Lane := 4 + ((2 + I) and 3);
          4:
            Lane := (1 + I) and 3;
          5:
            Lane := 4 + ((3 + I) and 3);
          8:
            Lane := 4 + I;
          11:
            Lane := (3 + I) and 3;
          12:
            Lane := 4 + ((1 + I) and 3);
        end;
        var Value: Byte := 0;
        if Lane >= 0 then
          Value := Byte((FVec[V, Lane and 7] shr 7) and $FF);
        DMemWrite(((Start + Cardinal((Integer(Address and 7) + I * 4) and 15)) and $FFF), Value);
      end;
    end
    else
    begin
      var Temp: array[0..7] of Word;
      for var I := 0 to 3 do
      begin
        Temp[I] := Word(DMemRead(((Start + Cardinal((Position + I * 4) and 15)) and $FFF))) shl 7;
        Temp[I + 4] := Word(DMemRead(((Start + Cardinal((Position + I * 4 + 8) and 15)) and $FFF))) shl 7;
      end;
      for var I := E to Min(15, E + 7) do
        if (I and 1) = 0 then
          SetByte(V, I, Byte(Temp[I div 2] shr 8))
        else
          SetByte(V, I, Byte(Temp[I div 2] and $FF));
    end;
    Exit;
  end;
  if Kind = 4 then
    if Writing then
      Size := 16 - Integer(Address and 15)
    else
      Size := Min(16 - Integer(Address and 15), 16 - E);
  if Kind = 5 then
  begin
    Size := Integer(Address and 15);
    E := 16 - Size + E;
    Address := Address and $FF0;
    if not Writing then
      Size := Min(Size, 16 - E);
  end;
  if Kind in [6, 7] then
  begin
    for var I := 0 to 7 do
      if Writing then
      begin
        var Shift := 8;
        if (((E + I) and 15) >= 8) xor (Kind = 7) then
          Shift := 7;
        DMemWrite(((Address + Cardinal(I)) and $FFF), Byte((FVec[V, (E + I) and 7] shr Shift) and $FF));
      end
      else
      begin
        var Position := (Integer(Address and 7) - E + I) and 15;
        FVec[V, I] := Word(DMemRead((((Address and $FF8) + Cardinal(Position)) and $FFF))) shl (8 - Ord(Kind = 7));
      end;
  end
  else if FBus.DirectMemory and not FAhead then
  begin
    // The same bytes, a whole element at a time where an element's two
    // bytes are both moved.
    var I := 0;
    while I < Size do
    begin
      var Index := E + I;
      if Writing then
      begin
        if not Odd(Index) and (Index < 15) and (I + 1 < Size) then
        begin
          var Lane := FVec[V, Index div 2];
          FBus.WriteSP8((Address + Cardinal(I)) and $FFF, Byte(Lane shr 8));
          FBus.WriteSP8((Address + Cardinal(I + 1)) and $FFF, Byte(Lane and $FF));
          Inc(I, 2);
          Continue;
        end;
        FBus.WriteSP8((Address + Cardinal(I)) and $FFF, GetByte(V, Index));
      end
      else if Index < 16 then
      begin
        if not Odd(Index) and (Index < 15) and (I + 1 < Size) then
        begin
          FVec[V, Index div 2] := (Word(FBus.ReadSP8((Address + Cardinal(I)) and $FFF)) shl 8) or
            FBus.ReadSP8((Address + Cardinal(I + 1)) and $FFF);
          Inc(I, 2);
          Continue;
        end;
        SetByte(V, Index, FBus.ReadSP8((Address + Cardinal(I)) and $FFF));
      end;
      Inc(I);
    end;
  end
  else
    for var I := 0 to Size - 1 do
      if Writing then
        DMemWrite(((Address + Cardinal(I)) and $FFF), GetByte(V, E + I))
      else if E + I < 16 then
        SetByte(V, E + I, DMemRead(((Address + Cardinal(I)) and $FFF)));
end;

procedure TN64RSP.Execute(var PC, Status, Interrupt: Cardinal);
begin
  ExecuteCycles(PC, Status, Interrupt, 32);
end;

procedure TN64RSP.AgePipeline;
begin
  // Saturating decrement of every two-bit counter: 3->2, 2->1, 1->0, 0->0.
  var Lo := FScalarLo;
  FScalarLo := FScalarHi and not Lo;
  FScalarHi := FScalarHi and Lo;
  Lo := FVectorLo;
  FVectorLo := FVectorHi and not Lo;
  FVectorHi := FVectorHi and Lo;
  FLoadHistory := (FLoadHistory shl 1) and 3;
end;

function TN64RSP.InfoEXECUTE(Op: Cardinal): TRSPTimingInfo;
begin
  var S := Integer((Op shr 21) and 31);
  var T := Integer((Op shr 16) and 31);
  Result := Default(TRSPTimingInfo);
  case Op shr 26 of
    $00:
      begin
        Exit(InfoSPECIAL(Op));
      end;
    $01:
      begin
        Exit(InfoREGIMM(Op));
      end;
    $02:
      begin
        Result.Flags := Result.Flags or 4;
        Exit;
      end;
    $03:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl 31);
        Result.Flags := Result.Flags or 32;
        Result.Flags := Result.Flags or 4;
        Exit;
      end;
    $04:
      begin
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.RRead := Result.RRead or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 4;
        Exit;
      end;
    $05:
      begin
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.RRead := Result.RRead or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 4;
        Exit;
      end;
    $06:
      begin
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 4;
        Exit;
      end;
    $07:
      begin
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 4;
        Exit;
      end;
    $08:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 32;
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Exit;
      end;
    $09:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 32;
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Exit;
      end;
    $0a:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 32;
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Exit;
      end;
    $0b:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 32;
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Exit;
      end;
    $0c:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 32;
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Exit;
      end;
    $0d:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 32;
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Exit;
      end;
    $0e:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 32;
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Exit;
      end;
    $0f:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 32;
        Exit;
      end;
    $10:
      begin
        Exit(InfoSCC(Op));
      end;
    $11:
      begin
        Exit;
      end;
    $12:
      begin
        Exit(InfoVU(Op));
      end;
    $13:
      begin
        Exit;
      end;
    $14:
      begin
        Exit;
      end;
    $15:
      begin
        Exit;
      end;
    $16:
      begin
        Exit;
      end;
    $17:
      begin
        Exit;
      end;
    $18:
      begin
        Exit;
      end;
    $19:
      begin
        Exit;
      end;
    $1a:
      begin
        Exit;
      end;
    $1b:
      begin
        Exit;
      end;
    $1c:
      begin
        Exit;
      end;
    $1d:
      begin
        Exit;
      end;
    $1e:
      begin
        Exit;
      end;
    $1f:
      begin
        Exit;
      end;
    $20:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl T);
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 1;
        Result.Flags := Result.Flags or 64;
        Exit;
      end;
    $21:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl T);
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 1;
        Result.Flags := Result.Flags or 64;
        Exit;
      end;
    $22:
      begin
        Exit;
      end;
    $23:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl T);
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 1;
        Result.Flags := Result.Flags or 64;
        Exit;
      end;
    $24:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl T);
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 1;
        Result.Flags := Result.Flags or 64;
        Exit;
      end;
    $25:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl T);
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 1;
        Result.Flags := Result.Flags or 64;
        Exit;
      end;
    $26:
      begin
        Exit;
      end;
    $27:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl T);
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 1;
        Result.Flags := Result.Flags or 64;
        Exit;
      end;
    $28:
      begin
        Result.RRead := Result.RRead or (Cardinal(1) shl T);
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 2;
        Result.Flags := Result.Flags or 64;
        Exit;
      end;
    $29:
      begin
        Result.RRead := Result.RRead or (Cardinal(1) shl T);
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 2;
        Result.Flags := Result.Flags or 64;
        Exit;
      end;
    $2a:
      begin
        Exit;
      end;
    $2b:
      begin
        Result.RRead := Result.RRead or (Cardinal(1) shl T);
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 2;
        Result.Flags := Result.Flags or 64;
        Exit;
      end;
    $2c:
      begin
        Exit;
      end;
    $2d:
      begin
        Exit;
      end;
    $2e:
      begin
        Exit;
      end;
    $2f:
      begin
        Exit;
      end;
    $30:
      begin
        Exit;
      end;
    $31:
      begin
        Exit;
      end;
    $32:
      begin
        Exit(InfoLWC2(Op));
      end;
    $33:
      begin
        Exit;
      end;
    $34:
      begin
        Exit;
      end;
    $35:
      begin
        Exit;
      end;
    $36:
      begin
        Exit;
      end;
    $37:
      begin
        Exit;
      end;
    $38:
      begin
        Exit;
      end;
    $39:
      begin
        Exit;
      end;
    $3a:
      begin
        Exit(InfoSWC2(Op));
      end;
    $3b:
      begin
        Exit;
      end;
    $3c:
      begin
        Exit;
      end;
    $3d:
      begin
        Exit;
      end;
    $3e:
      begin
        Exit;
      end;
    $3f:
      begin
        Exit;
      end;
  end;
end;

function TN64RSP.InfoSPECIAL(Op: Cardinal): TRSPTimingInfo;
begin
  var S := Integer((Op shr 21) and 31);
  var T := Integer((Op shr 16) and 31);
  var D := Integer((Op shr 11) and 31);
  Result := Default(TRSPTimingInfo);
  case Op and $3f of
    $00:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl D);
        Result.Flags := Result.Flags or 32;
        Result.RRead := Result.RRead or (Cardinal(1) shl T);
        Exit;
      end;
    $01:
      begin
        Exit;
      end;
    $02:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl D);
        Result.Flags := Result.Flags or 32;
        Result.RRead := Result.RRead or (Cardinal(1) shl T);
        Exit;
      end;
    $03:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl D);
        Result.Flags := Result.Flags or 32;
        Result.RRead := Result.RRead or (Cardinal(1) shl T);
        Exit;
      end;
    $04:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl D);
        Result.Flags := Result.Flags or 32;
        Result.RRead := Result.RRead or (Cardinal(1) shl T);
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Exit;
      end;
    $05:
      begin
        Exit;
      end;
    $06:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl D);
        Result.Flags := Result.Flags or 32;
        Result.RRead := Result.RRead or (Cardinal(1) shl T);
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Exit;
      end;
    $07:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl D);
        Result.Flags := Result.Flags or 32;
        Result.RRead := Result.RRead or (Cardinal(1) shl T);
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Exit;
      end;
    $08:
      begin
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 4;
        Exit;
      end;
    $09:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl D);
        Result.Flags := Result.Flags or 32;
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 4;
        Exit;
      end;
    $0a:
      begin
        Exit;
      end;
    $0b:
      begin
        Exit;
      end;
    $0c:
      begin
        Exit;
      end;
    $0d:
      begin
        Result.Flags := Result.Flags or 4;
        Result.Flags := Result.Flags or 128;
        Exit;
      end;
    $0e:
      begin
        Exit;
      end;
    $0f:
      begin
        Exit;
      end;
    $10:
      begin
        Exit;
      end;
    $11:
      begin
        Exit;
      end;
    $12:
      begin
        Exit;
      end;
    $13:
      begin
        Exit;
      end;
    $14:
      begin
        Exit;
      end;
    $15:
      begin
        Exit;
      end;
    $16:
      begin
        Exit;
      end;
    $17:
      begin
        Exit;
      end;
    $18:
      begin
        Exit;
      end;
    $19:
      begin
        Exit;
      end;
    $1a:
      begin
        Exit;
      end;
    $1b:
      begin
        Exit;
      end;
    $1c:
      begin
        Exit;
      end;
    $1d:
      begin
        Exit;
      end;
    $1e:
      begin
        Exit;
      end;
    $1f:
      begin
        Exit;
      end;
    $20:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl D);
        Result.Flags := Result.Flags or 32;
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.RRead := Result.RRead or (Cardinal(1) shl T);
        Exit;
      end;
    $21:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl D);
        Result.Flags := Result.Flags or 32;
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.RRead := Result.RRead or (Cardinal(1) shl T);
        Exit;
      end;
    $22:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl D);
        Result.Flags := Result.Flags or 32;
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.RRead := Result.RRead or (Cardinal(1) shl T);
        Exit;
      end;
    $23:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl D);
        Result.Flags := Result.Flags or 32;
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.RRead := Result.RRead or (Cardinal(1) shl T);
        Exit;
      end;
    $24:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl D);
        Result.Flags := Result.Flags or 32;
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.RRead := Result.RRead or (Cardinal(1) shl T);
        Exit;
      end;
    $25:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl D);
        Result.Flags := Result.Flags or 32;
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.RRead := Result.RRead or (Cardinal(1) shl T);
        Exit;
      end;
    $26:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl D);
        Result.Flags := Result.Flags or 32;
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.RRead := Result.RRead or (Cardinal(1) shl T);
        Exit;
      end;
    $27:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl D);
        Result.Flags := Result.Flags or 32;
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.RRead := Result.RRead or (Cardinal(1) shl T);
        Exit;
      end;
    $28:
      begin
        Exit;
      end;
    $29:
      begin
        Exit;
      end;
    $2a:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl D);
        Result.Flags := Result.Flags or 32;
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.RRead := Result.RRead or (Cardinal(1) shl T);
        Exit;
      end;
    $2b:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl D);
        Result.Flags := Result.Flags or 32;
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.RRead := Result.RRead or (Cardinal(1) shl T);
        Exit;
      end;
    $2c:
      begin
        Exit;
      end;
    $2d:
      begin
        Exit;
      end;
    $2e:
      begin
        Exit;
      end;
    $2f:
      begin
        Exit;
      end;
    $30:
      begin
        Exit;
      end;
    $31:
      begin
        Exit;
      end;
    $32:
      begin
        Exit;
      end;
    $33:
      begin
        Exit;
      end;
    $34:
      begin
        Exit;
      end;
    $35:
      begin
        Exit;
      end;
    $36:
      begin
        Exit;
      end;
    $37:
      begin
        Exit;
      end;
    $38:
      begin
        Exit;
      end;
    $39:
      begin
        Exit;
      end;
    $3a:
      begin
        Exit;
      end;
    $3b:
      begin
        Exit;
      end;
    $3c:
      begin
        Exit;
      end;
    $3d:
      begin
        Exit;
      end;
    $3e:
      begin
        Exit;
      end;
    $3f:
      begin
        Exit;
      end;
  end;
end;

function TN64RSP.InfoREGIMM(Op: Cardinal): TRSPTimingInfo;
begin
  var S := Integer((Op shr 21) and 31);
  Result := Default(TRSPTimingInfo);
  case Op shr 16 and $1f of
    $00:
      begin
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 4;
        Exit;
      end;
    $01:
      begin
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 4;
        Exit;
      end;
    $02:
      begin
        Exit;
      end;
    $03:
      begin
        Exit;
      end;
    $04:
      begin
        Exit;
      end;
    $05:
      begin
        Exit;
      end;
    $06:
      begin
        Exit;
      end;
    $07:
      begin
        Exit;
      end;
    $08:
      begin
        Exit;
      end;
    $09:
      begin
        Exit;
      end;
    $0a:
      begin
        Exit;
      end;
    $0b:
      begin
        Exit;
      end;
    $0c:
      begin
        Exit;
      end;
    $0d:
      begin
        Exit;
      end;
    $0e:
      begin
        Exit;
      end;
    $0f:
      begin
        Exit;
      end;
    $10:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl 31);
        Result.Flags := Result.Flags or 32;
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 4;
        Exit;
      end;
    $11:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl 31);
        Result.Flags := Result.Flags or 32;
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 4;
        Exit;
      end;
    $12:
      begin
        Exit;
      end;
    $13:
      begin
        Exit;
      end;
    $14:
      begin
        Exit;
      end;
    $15:
      begin
        Exit;
      end;
    $16:
      begin
        Exit;
      end;
    $17:
      begin
        Exit;
      end;
    $18:
      begin
        Exit;
      end;
    $19:
      begin
        Exit;
      end;
    $1a:
      begin
        Exit;
      end;
    $1b:
      begin
        Exit;
      end;
    $1c:
      begin
        Exit;
      end;
    $1d:
      begin
        Exit;
      end;
    $1e:
      begin
        Exit;
      end;
    $1f:
      begin
        Exit;
      end;
  end;
end;

function TN64RSP.InfoSCC(Op: Cardinal): TRSPTimingInfo;
begin
  var T := Integer((Op shr 16) and 31);
  var D := Integer((Op shr 11) and 31);
  var XT := Integer((Op shr 15) and 31);
  var XD := Integer((Op shr 20) and 31);
  Result := Default(TRSPTimingInfo);
  case Op shr 21 and $1f of
    $00:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 1;
        Result.Flags := Result.Flags or 2;
        Exit;
      end;
    $01:
      begin
        Exit;
      end;
    $02:
      begin
        Exit;
      end;
    $03:
      begin
        Exit;
      end;
    $04:
      begin
        Result.RRead := Result.RRead or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 1;
        Result.Flags := Result.Flags or 2;
        if ((D and 8) = 0) and ((D and 7) = 4) then
          Result.Flags := Result.Flags or 128;
        Exit;
      end;
    $05:
      begin
        Exit;
      end;
    $06:
      begin
        Exit;
      end;
    $07:
      begin
        Exit;
      end;
    $08:
      begin
        Exit;
      end;
    $09:
      begin
        Exit;
      end;
    $0a:
      begin
        Exit;
      end;
    $0b:
      begin
        Exit;
      end;
    $0c:
      begin
        Exit;
      end;
    $0d:
      begin
        Exit;
      end;
    $0e:
      begin
        Exit;
      end;
    $0f:
      begin
        Exit;
      end;
  end;
  case Op and $3f of
    $20:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl XD);
        Result.Flags := Result.Flags or 32;
        Exit;
      end;
    $23:
      begin
        Result.Flags := Result.Flags or 256;
        Exit;
      end;
    $24:
      begin
        Result.Flags := Result.Flags or 256;
        Exit;
      end;
    $25:
      begin
        Result.RRead := Result.RRead or (Cardinal(1) shl XD);
        Result.RRead := Result.RRead or (Cardinal(1) shl XT);
        Exit;
      end;
    $26:
      begin
        Result.RRead := Result.RRead or (Cardinal(1) shl XD);
        Exit;
      end;
    $27:
      begin
        Result.RRead := Result.RRead or (Cardinal(1) shl XD);
        Result.RRead := Result.RRead or (Cardinal(1) shl XT);
        Exit;
      end;
    $28:
      begin
        Result.RRead := Result.RRead or (Cardinal(1) shl XD);
        Exit;
      end;
    $29:
      begin
        Result.RRead := Result.RRead or (Cardinal(1) shl XD);
        Result.RRead := Result.RRead or (Cardinal(1) shl XT);
        Result.RWrite := Result.RWrite or (Cardinal(1) shl XT);
        Result.Flags := Result.Flags or 32;
        Exit;
      end;
    $2a:
      begin
        Result.RRead := Result.RRead or (Cardinal(1) shl XT);
        Exit;
      end;
    $2c:
      begin
        Exit;
      end;
  end;
end;

function TN64RSP.InfoVU(Op: Cardinal): TRSPTimingInfo;
begin
  var T := Integer((Op shr 16) and 31);
  var D := Integer((Op shr 11) and 31);
  var V := Integer((Op shr 6) and 31);
  Result := Default(TRSPTimingInfo);
  case Op shr 21 and $1f of
    $00:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl T);
        Result.VRead := Result.VRead or (Cardinal(1) shl D);
        Result.Flags := Result.Flags or 1;
        Result.Flags := Result.Flags or 2;
        Exit;
      end;
    $01:
      begin
        Exit;
      end;
    $02:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl T);
        Result.VCRead := Result.VCRead or (Cardinal(1) shl D);
        Result.Flags := Result.Flags or 1;
        Result.Flags := Result.Flags or 2;
        Exit;
      end;
    $03:
      begin
        Exit;
      end;
    $04:
      begin
        Result.RRead := Result.RRead or (Cardinal(1) shl T);
        Result.VWrite := Result.VWrite or (Cardinal(1) shl D);
        Result.Flags := Result.Flags or 1;
        Result.Flags := Result.Flags or 2;
        Result.Flags := Result.Flags or 16;
        Exit;
      end;
    $05:
      begin
        Exit;
      end;
    $06:
      begin
        Result.RRead := Result.RRead or (Cardinal(1) shl T);
        Result.VCWrite := Result.VCWrite or (Cardinal(1) shl D);
        Result.Flags := Result.Flags or 1;
        Result.Flags := Result.Flags or 2;
        Exit;
      end;
    $07:
      begin
        Exit;
      end;
    $08:
      begin
        Exit;
      end;
    $09:
      begin
        Exit;
      end;
    $0a:
      begin
        Exit;
      end;
    $0b:
      begin
        Exit;
      end;
    $0c:
      begin
        Exit;
      end;
    $0d:
      begin
        Exit;
      end;
    $0e:
      begin
        Exit;
      end;
    $0f:
      begin
        Exit;
      end;
  end;
  case Op and $3f of
    $00:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $01:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $02:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $03:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $04:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $05:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $06:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $07:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $08:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $09:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $0a:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $0b:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $0c:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $0d:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $0e:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $0f:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $10:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.VCRead := Result.VCRead or (Cardinal(1) shl 0);
        Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 0);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $11:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.VCRead := Result.VCRead or (Cardinal(1) shl 0);
        Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 0);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $12:
      begin
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $13:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.VCRead := Result.VCRead or (Cardinal(1) shl 0);
        Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 0);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $14:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.VCRead := Result.VCRead or (Cardinal(1) shl 0);
        Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 0);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $15:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.VCRead := Result.VCRead or (Cardinal(1) shl 0);
        Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 0);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $16:
      begin
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $17:
      begin
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $18:
      begin
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $19:
      begin
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $1a:
      begin
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $1b:
      begin
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $1c:
      begin
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $1d:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $1e:
      begin
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $1f:
      begin
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $20:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.VCRead := Result.VCRead or (Cardinal(1) shl 0);
        Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 0);
        Result.VCRead := Result.VCRead or (Cardinal(1) shl 1);
        Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 1);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $21:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.VCRead := Result.VCRead or (Cardinal(1) shl 0);
        Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 0);
        Result.VCRead := Result.VCRead or (Cardinal(1) shl 1);
        Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 1);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $22:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.VCRead := Result.VCRead or (Cardinal(1) shl 0);
        Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 0);
        Result.VCRead := Result.VCRead or (Cardinal(1) shl 1);
        Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 1);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $23:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.VCRead := Result.VCRead or (Cardinal(1) shl 0);
        Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 0);
        Result.VCRead := Result.VCRead or (Cardinal(1) shl 1);
        Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 1);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $24:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.VCRead := Result.VCRead or (Cardinal(1) shl 0);
        Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 0);
        Result.VCRead := Result.VCRead or (Cardinal(1) shl 1);
        Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 1);
        Result.VCRead := Result.VCRead or (Cardinal(1) shl 2);
        Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 2);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $25:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.VCRead := Result.VCRead or (Cardinal(1) shl 0);
        Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 0);
        Result.VCRead := Result.VCRead or (Cardinal(1) shl 1);
        Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 1);
        Result.VCRead := Result.VCRead or (Cardinal(1) shl 2);
        Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 2);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $26:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.VCRead := Result.VCRead or (Cardinal(1) shl 0);
        Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 0);
        Result.VCRead := Result.VCRead or (Cardinal(1) shl 1);
        Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 1);
        Result.VCRead := Result.VCRead or (Cardinal(1) shl 2);
        Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 2);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $27:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.VCRead := Result.VCRead or (Cardinal(1) shl 0);
        Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 0);
        Result.VCRead := Result.VCRead or (Cardinal(1) shl 1);
        Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 1);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $28:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $29:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $2a:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $2b:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $2c:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $2d:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $2e:
      begin
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $2f:
      begin
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $30:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VFake := Result.VFake or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $31:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VFake := Result.VFake or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $32:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VFake := Result.VFake or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $33:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VFake := Result.VFake or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $34:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VFake := Result.VFake or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $35:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VFake := Result.VFake or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $36:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VFake := Result.VFake or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $37:
      begin
        Result.VFake := Result.VFake or (Cardinal(1) shl V);
        Result.Flags := Result.Flags or 8;
        Result.Flags := Result.Flags or 16;
        Exit;
      end;
    $38:
      begin
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $39:
      begin
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $3a:
      begin
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $3b:
      begin
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $3c:
      begin
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $3d:
      begin
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $3e:
      begin
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $3f:
      begin
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
  end;
end;

function TN64RSP.InfoLWC2(Op: Cardinal): TRSPTimingInfo;
begin
  var S := Integer((Op shr 21) and 31);
  var T := Integer((Op shr 16) and 31);
  Result := Default(TRSPTimingInfo);
  case Op shr 11 and $1f of
    $00:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl T);
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 1;
        Result.Flags := Result.Flags or 64;
        Exit;
      end;
    $01:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl T);
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 1;
        Result.Flags := Result.Flags or 64;
        Exit;
      end;
    $02:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl T);
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 1;
        Result.Flags := Result.Flags or 64;
        Exit;
      end;
    $03:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl T);
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 1;
        Result.Flags := Result.Flags or 64;
        Exit;
      end;
    $04:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl T);
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 1;
        Result.Flags := Result.Flags or 64;
        Exit;
      end;
    $05:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl T);
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 1;
        Result.Flags := Result.Flags or 64;
        Exit;
      end;
    $06:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl T);
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 1;
        Result.Flags := Result.Flags or 64;
        Exit;
      end;
    $07:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl T);
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 1;
        Result.Flags := Result.Flags or 64;
        Exit;
      end;
    $08:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl T);
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 1;
        Result.Flags := Result.Flags or 64;
        Exit;
      end;
    $09:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl T);
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 1;
        Result.Flags := Result.Flags or 64;
        Exit;
      end;
    $0b:
      begin
        Result.VWrite := Result.VWrite or (Cardinal($FF) shl (T and not 7));
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 1;
        Result.Flags := Result.Flags or 16;
        Result.Flags := Result.Flags or 64;
        Exit;
      end;
  end;
end;

function TN64RSP.InfoSWC2(Op: Cardinal): TRSPTimingInfo;
begin
  var S := Integer((Op shr 21) and 31);
  var T := Integer((Op shr 16) and 31);
  Result := Default(TRSPTimingInfo);
  case Op shr 11 and $1f of
    $00:
      begin
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 2;
        Result.Flags := Result.Flags or 64;
        Exit;
      end;
    $01:
      begin
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 2;
        Result.Flags := Result.Flags or 64;
        Exit;
      end;
    $02:
      begin
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 2;
        Result.Flags := Result.Flags or 64;
        Exit;
      end;
    $03:
      begin
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 2;
        Result.Flags := Result.Flags or 64;
        Exit;
      end;
    $04:
      begin
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 2;
        Result.Flags := Result.Flags or 64;
        Exit;
      end;
    $05:
      begin
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 2;
        Result.Flags := Result.Flags or 64;
        Exit;
      end;
    $06:
      begin
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 2;
        Result.Flags := Result.Flags or 64;
        Exit;
      end;
    $07:
      begin
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 2;
        Result.Flags := Result.Flags or 64;
        Exit;
      end;
    $08:
      begin
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 2;
        Result.Flags := Result.Flags or 64;
        Exit;
      end;
    $09:
      begin
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 2;
        Result.Flags := Result.Flags or 64;
        Exit;
      end;
    $0a:
      begin
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 2;
        Result.Flags := Result.Flags or 64;
        Exit;
      end;
    $0b:
      begin
        Result.VRead := Result.VRead or (Cardinal($FF) shl (T and not 7));
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 2;
        Result.Flags := Result.Flags or 64;
        Exit;
      end;
  end;
end;

function TN64RSP.CanPair(const A, B: TRSPTimingInfo): Boolean;
begin
  Result := (((A.Flags xor B.Flags) and 8) <> 0) and
    ((A.VWrite and (B.VRead or B.VWrite)) = 0) and
    ((A.VCWrite and (B.VCRead or B.VCWrite)) = 0) and
    not ((((A.Flags or not B.Flags) and 16) <> 0) and ((A.VWrite and B.VFake) <> 0));
end;

class procedure TN64RSP.Unsupported(const Kind: string; Op: Cardinal);
begin
  raise EN64Unsupported.CreateFmt('RSP %s %8.8x', [Kind, Op]);
end;

procedure TN64RSP.IssueCOP0(Op, Current: Cardinal);
begin
  // MFC0/MTC0: the SP registers, then the DP registers.
  var S := (Op shr 21) and 31;
  var T := (Op shr 16) and 31;
  var IOIndex := (Op shr 11) and 15;
  var IOAddress := $04040000 + IOIndex * 4;
  if IOIndex >= 8 then
    IOAddress := $04100000 + (IOIndex - 8) * 4;
  if S = 0 then
  begin
    FReg[T] := FBus.Read32(IOAddress);
    if FBus.TraceEnabled then
      FBus.Trace(TN64TraceKind.MMIORead, $04001000 + Current, IOAddress, FReg[T]);
  end
  else if S = 4 then
  begin
    var B := FReg[T];
    if FBus.TraceEnabled then
      FBus.Trace(TN64TraceKind.MMIOWrite, $04001000 + Current, IOAddress, B);
    FBus.Write32(IOAddress, B);
  end
  else
    Unsupported('COP0 opcode', Op);
end;

procedure TN64RSP.IssueMoveCOP2(Op: Cardinal);
begin
  // MFC2, CFC2, MTC2, CTC2.
  var S := (Op shr 21) and 31;
  var T := (Op shr 16) and 31;
  var D := Integer((Op shr 11) and 31);
  var E := Integer((Op shr 7) and 15);
  var B := FReg[T];
  case S of
    0:
      FReg[T] := Cardinal(SX((Word(GetByte(D, E)) shl 8) or GetByte(D, E + 1), 16) and $FFFFFFFF);
    2:
      case D and 3 of
        0:
          FReg[T] := Cardinal(SX(FVCO, 16) and $FFFFFFFF);
        1:
          FReg[T] := Cardinal(SX(FVCC, 16) and $FFFFFFFF);
      else
        FReg[T] := FVCE
      end;
    4:
      begin
        SetByte(D, E, Byte((B shr 8) and $FF));
        if E < 15 then
          SetByte(D, E + 1, Byte(B and $FF))
      end;
    6:
      case D and 3 of
        0:
          FVCO := Word(B and $FFFF);
        1:
          FVCC := Word(B and $FFFF);
      else
        FVCE := Word(B and $FF)
      end;
  else
    Unsupported('COP2 opcode', Op);
  end;
end;

procedure TN64RSP.IssueLoadStore(Op, Address: Cardinal);
begin
  // Scalar DMEM loads and stores; Address is already wrapped to DMEM.
  var Code := Op shr 26;
  var T := (Op shr 16) and 31;
  var Size := 1;
  if Code in [33, 37, 41] then
    Size := 2
  else if Code in [35, 39, 43] then
    Size := 4;
  if Code < 40 then
  begin
    var V: Cardinal := 0;
    for var I := 0 to Size - 1 do
      V := (V shl 8) or DMemRead(((Address + Cardinal(I)) and $FFF));
    if Code in [32, 33] then
      V := Cardinal(SX(V, Size * 8) and $FFFFFFFF);
    FReg[T] := V;
  end
  else
  begin
    var B := FReg[T];
    for var I := 0 to Size - 1 do
      DMemWrite(((Address + Cardinal(I)) and $FFF), Byte((B shr ((Size - 1 - I) * 8)) and $FF));
  end;
end;
procedure TN64RSP.IssueInstruction(Op: Cardinal; var PC, Status, Interrupt: Cardinal);
begin
  if FBus.TraceEnabled then
    FBus.Trace(TN64TraceKind.Instruction, $04001000 + (PC and $FFC),
      $04001000 + (PC and $FFC), Op);
  var Current := PC;
  if FBranch then
  begin
    PC := FNextPC;
    FBranch := False
  end
  else
    PC := (PC + 4) and $FFC;
  var Code := Op shr 26;
  var S := (Op shr 21) and 31;
  var T := (Op shr 16) and 31;
  var D := (Op shr 11) and 31;
  var N := (Op shr 6) and 31;
  var A := FReg[S];
  var B := FReg[T];
  var Imm := SX16(Op);
  // Only the low 12 address bits survive, so the immediate's low bits suffice.
  var Address := ((A and $FFF) + (Op and $FFF)) and $FFF;
  var Target := ((Current + 4) + ((Op and $3FF) shl 2)) and $FFC;
  var Taken := False;
  case Code of
    0:
      case Op and 63 of
        0:
          FReg[D] := B shl N;
        2:
          FReg[D] := B shr N;
        3:
          FReg[D] := Cardinal(SAR(B, N, 32) and $FFFFFFFF);
        4:
          FReg[D] := B shl (A and 31);
        6:
          FReg[D] := B shr (A and 31);
        7:
          FReg[D] := Cardinal(SAR(B, A and 31, 32) and $FFFFFFFF);
        8, 9:
          begin
            if (Op and 63) = 9 then
              FReg[D] := (Current + 8) and $FFF;
            FNextPC := A and $FFC;
            FBranch := True
          end;
        13:
          begin
            Status := Status or 3;
            if (Status and $40) <> 0 then
              Interrupt := Interrupt or 1
          end;
        32, 33:
          FReg[D] := Add32(A, B);
        34, 35:
          FReg[D] := Cardinal(Sub64(A, B) and $FFFFFFFF);
        36:
          FReg[D] := A and B;
        37:
          FReg[D] := A or B;
        38:
          FReg[D] := A xor B;
        39:
          FReg[D] := not (A or B);
        42:
          FReg[D] := Ord(SignedLess(SX(A, 32), SX(B, 32)));
        43:
          FReg[D] := Ord(A < B);
      else
        Unsupported('scalar opcode', Op);
      end;
    1, 4..7:
      begin
        case Code of
          1:
            begin
              if not (T in [0, 1, 16, 17]) then
                Unsupported('REGIMM opcode', Op);
              Taken := SignedLess(SX(A, 32), 0);
              if (T and 1) <> 0 then
                Taken := not Taken;
              if (T and 16) <> 0 then
                FReg[31] := (Current + 8) and $FFF
            end;
          4:
            Taken := A = B;
          5:
            Taken := A <> B;
          6:
            Taken := not SignedLess(0, SX(A, 32));
          7:
            Taken := SignedLess(0, SX(A, 32));
        end;
        if Taken then
        begin
          FNextPC := Target;
          FBranch := True
        end;
      end;
    2, 3:
      begin
        if Code = 3 then
          FReg[31] := (Current + 8) and $FFF;
        FNextPC := (Op shl 2) and $FFC;
        FBranch := True
      end;
    8, 9:
      FReg[T] := Cardinal(Add64(A, Imm) and $FFFFFFFF);
    10:
      FReg[T] := Ord(SignedLess(SX(A, 32), Imm));
    11:
      FReg[T] := Ord(UInt64(A) < (Imm and $FFFFFFFF));
    12:
      FReg[T] := A and (Op and $FFFF);
    13:
      FReg[T] := A or (Op and $FFFF);
    14:
      FReg[T] := A xor (Op and $FFFF);
    15:
      FReg[T] := (Op and $FFFF) shl 16;
    16:
      IssueCOP0(Op, Current);
    18:
      if S >= 16 then
        VectorOp(Op)
      else
        IssueMoveCOP2(Op);
    32, 33, 35..37, 39, 40, 41, 43:
      IssueLoadStore(Op, Address);
    50:
      VectorMemory(Op, False);
    58:
      VectorMemory(Op, True);
  else
    Unsupported('opcode', Op);
  end;
  FReg[0] := 0;
end;

function TN64RSP.RunClocks(var PC, Status, Interrupt: Cardinal; Cycles: Integer; Ahead: Boolean): Integer;
begin
  // Ahead: stop before the first clock that is not free (see RunAhead); the
  // checkpoint is taken before the first clock that changes anything.
  Result := 0;
  for var Iteration := 1 to Cycles do
  begin
    if (Status and 1) <> 0 then
      Break;
    if FBranchBubble > 0 then
    begin
      if Ahead and not FCheckpointed then
        SaveCheckpoint(PC);
      Dec(FBranchBubble);
      AgePipeline;
      Inc(Result);
      Continue
    end;
    // A stalled opcode only counts at its own PC. Both outcomes below set
    // FHasStalledOpcode/FHasStalledSecondOpcode, so a stale one is dropped.
    var Stalled := FHasStalledOpcode and (FStalledPC = PC);
    var Op, Second: Cardinal;
    var Pair: Boolean;
    var Masks: TRSPIssueMasks;
    var FirstSlot := Integer((PC shr 2) and 1023);
    var SecondSlot := Integer(((PC shr 2) + 1) and 1023);
    if Stalled and FStallKnown and (FStallOp = FStalledOpcode) and (FStallSecond = FStalledSecondOpcode) and
      (FStallPair = FHasStalledSecondOpcode) then
    begin
      // The stall goes on: the same held words.
      Op := FStalledOpcode;
      Second := FStalledSecondOpcode;
      Pair := FHasStalledSecondOpcode;
      Masks := FStallMasks;
    end
    else if Stalled then
    begin
      Op := FStalledOpcode;
      Second := FStalledSecondOpcode;
      Pair := FHasStalledSecondOpcode;
      DecodedSlot(FirstSlot);
      if Pair then
        DecodedSlot(SecondSlot);
      if (FDec[FirstSlot].Op = Op) and (not Pair or (FDec[SecondSlot].Op = Second)) then
      begin
        if not Pair then
          Masks := FDec[FirstSlot].Single
        else
        begin
          if not FDec[FirstSlot].PairValid or (FDec[FirstSlot].SecondOp <> Second) then
            DecodePair(FirstSlot);
          Masks := FDec[FirstSlot].Paired;
        end;
      end
      else if Pair then
        // IMEM changed under the held words: decode them as held.
        Combine(InfoEXECUTE(Op), InfoEXECUTE(Second), External(Op), External(Second), Masks)
      else
        MasksOf(InfoEXECUTE(Op), External(Op), Masks);
    end
    else
    begin
      DecodedSlot(FirstSlot);
      Op := FDec[FirstSlot].Op;
      Second := 0;
      Pair := False;
      if (FSingleIssue = 0) and ((Status and $20) = 0) and ((FDec[FirstSlot].Info.Flags and 4) = 0) then
      begin
        DecodedSlot(SecondSlot);
        if not FDec[FirstSlot].PairValid or (FDec[FirstSlot].SecondOp <> FDec[SecondSlot].Op) then
          DecodePair(FirstSlot);
        Pair := FDec[FirstSlot].CanPair;
        // Kept even without a pair: a stall holds it (FStalledSecondOpcode).
        Second := FDec[SecondSlot].Op;
      end;
      if Pair then
        Masks := FDec[FirstSlot].Paired
      else
        Masks := FDec[FirstSlot].Single;
    end;
    var Flags := Masks.Flags;
    var ScalarWrites := Masks.ScalarWrites;
    var VectorWrites := Masks.VectorWrites;
    var Loading := (Flags and 1) <> 0;
    var Storing := (Flags and 2) <> 0;
    var Hazard := (Storing and ((FLoadHistory and 2) <> 0)) or
      ((Masks.Sources and (FScalarLo or FScalarHi)) <> 0) or ((Masks.Vectors and (FVectorLo or FVectorHi)) <> 0);
    if Ahead then
    begin
      if not Hazard and Masks.External then
        Break;
      if not FCheckpointed then
        SaveCheckpoint(PC);
    end;
    if Hazard then
    begin
      FStalledOpcode := Op;
      FStalledPC := PC;
      FHasStalledOpcode := True;
      FStalledSecondOpcode := Second;
      FHasStalledSecondOpcode := Pair;
      FStallMasks := Masks;
      FStallOp := Op;
      FStallSecond := Second;
      FStallPair := Pair;
      FStallKnown := True;
      AgePipeline;
      Inc(Result);
      Continue;
    end;
    FHasStalledOpcode := False;
    FHasStalledSecondOpcode := False;
    var DelaySlot := FBranch;
    IssueInstruction(Op, PC, Status, Interrupt);
    if Pair and ((Status and 1) = 0) then
      IssueInstruction(Second, PC, Status, Interrupt);
    AgePipeline;
    // Scalar results become ready after two clocks, vector results after three.
    ScalarWrites := ScalarWrites and not Cardinal(1);
    FScalarHi := FScalarHi or ScalarWrites;
    FScalarLo := FScalarLo and not ScalarWrites;
    FVectorHi := FVectorHi or VectorWrites;
    FVectorLo := FVectorLo or VectorWrites;
    if Loading then
      FLoadHistory := FLoadHistory or 1;
    FSingleIssue := Byte(Ord((Flags and 4) <> 0));
    if DelaySlot then
    begin
      FBranchBubble := 1;
      if (PC and 4) <> 0 then
        FSingleIssue := 1;
    end;
    Inc(Result);
    if (Status and $20) <> 0 then
      Status := Status or 1;
  end;
end;

function TN64RSP.ExecuteCycles(var PC, Status, Interrupt: Cardinal; Cycles: Integer): Integer;
begin
  Result := RunClocks(PC, Status, Interrupt, Cycles, False);
end;

class function TN64RSP.External(Op: Cardinal): Boolean;
begin
  // Instructions that may touch state outside the RSP and DMEM, or raise.
  Result := True;
  case Op shr 26 of
    0:
      Result := not ((Op and 63) in [0, 2, 3, 4, 6, 7, 8, 9, 32..39, 42, 43]);
    1:
      Result := not (((Op shr 16) and 31) in [0, 1, 16, 17]);
    2..15, 32, 33, 35..37, 39..41, 43:
      Result := False;
    18:
      Result := not ((((Op shr 21) and 31) >= 16) or (((Op shr 21) and 31) in [0, 2, 4, 6]));
    50, 58:
      Result := ((Op shr 11) and 31) > 11;
  end;
end;

procedure TN64RSP.SaveCheckpoint(PC: Cardinal);
begin
  // Same element types and bounds: plain copies.
  Move(FReg, FCheckpoint.Reg, SizeOf(FReg));
  Move(FVec, FCheckpoint.Vec, SizeOf(FVec));
  Move(FAccHi, FCheckpoint.AccHi, SizeOf(FAccHi));
  Move(FAccMid, FCheckpoint.AccMid, SizeOf(FAccMid));
  Move(FAccLo, FCheckpoint.AccLo, SizeOf(FAccLo));
  FCheckpoint.VCO := FVCO;
  FCheckpoint.VCC := FVCC;
  FCheckpoint.VCE := FVCE;
  FCheckpoint.NextPC := FNextPC;
  FCheckpoint.PC := PC;
  FCheckpoint.Branch := FBranch;
  FCheckpoint.DivisionHigh := FDivisionHigh;
  FCheckpoint.DivisionInput := FDivisionInput;
  FCheckpoint.DivisionResult := FDivisionResult;
  FCheckpoint.ScalarLo := FScalarLo;
  FCheckpoint.ScalarHi := FScalarHi;
  FCheckpoint.VectorLo := FVectorLo;
  FCheckpoint.VectorHi := FVectorHi;
  FCheckpoint.SingleIssue := FSingleIssue;
  FCheckpoint.StalledSecondOpcode := FStalledSecondOpcode;
  FCheckpoint.HasStalledSecondOpcode := FHasStalledSecondOpcode;
  FCheckpoint.LoadHistory := FLoadHistory;
  FCheckpoint.BranchBubble := FBranchBubble;
  FCheckpoint.StalledOpcode := FStalledOpcode;
  FCheckpoint.StalledPC := FStalledPC;
  FCheckpoint.HasStalledOpcode := FHasStalledOpcode;
  FCheckpointed := True;
  // A new run: no DMEM line saved yet.
  if FRun = High(Cardinal) then
  begin
    for var I := 0 to High(FLineRun) do
      FLineRun[I] := 0;
    FRun := 0;
  end;
  Inc(FRun);
  FAhead := True;
end;

procedure TN64RSP.SaveLine(Offset: Cardinal);
begin
  // The first write to this line in the run: keep the line as it was.
  var Line := Offset and $FC0;
  if FBus.DirectMemory then
    FBus.CopyFromSP(Line, FLineBackup, Integer(Line), 64)
  else
    for var I := 0 to 63 do
      FLineBackup[Line + Cardinal(I)] := DMemRead(Line + Cardinal(I));
  FLineRun[Offset shr 6] := FRun;
end;

function TN64RSP.RunAhead(var PC: Cardinal; Status: Cardinal; Cycles: Integer): Integer;
begin
  if (Status and $21) <> 0 then
    raise EInvalidOpException.Create('RSP run-ahead while halted or single-stepping');
  EndAhead;
  var Interrupt: Cardinal := 0;
  Result := RunClocks(PC, Status, Interrupt, Cycles, True);
  // Without a clock run nothing was saved or changed.
  if Result = 0 then
    EndAhead;
end;

procedure TN64RSP.Rewind(var PC: Cardinal; Keep: Integer);
begin
  if not FCheckpointed then
    raise EInvalidOpException.Create('RSP rewind without a checkpoint');
  FAhead := False;
  for var Line := 0 to 63 do
    if FLineRun[Line] = FRun then
      if FBus.DirectMemory then
        FBus.CopyToSP(Cardinal(Line) * 64, FLineBackup, Line * 64, 64)
      else
        for var I := Line * 64 to Line * 64 + 63 do
          DMemWrite(Cardinal(I), FLineBackup[I]);
  Move(FCheckpoint.Reg, FReg, SizeOf(FReg));
  Move(FCheckpoint.Vec, FVec, SizeOf(FVec));
  Move(FCheckpoint.AccHi, FAccHi, SizeOf(FAccHi));
  Move(FCheckpoint.AccMid, FAccMid, SizeOf(FAccMid));
  Move(FCheckpoint.AccLo, FAccLo, SizeOf(FAccLo));
  FVCO := FCheckpoint.VCO;
  FVCC := FCheckpoint.VCC;
  FVCE := FCheckpoint.VCE;
  FNextPC := FCheckpoint.NextPC;
  PC := FCheckpoint.PC;
  FBranch := FCheckpoint.Branch;
  FDivisionHigh := FCheckpoint.DivisionHigh;
  FDivisionInput := FCheckpoint.DivisionInput;
  FDivisionResult := FCheckpoint.DivisionResult;
  FScalarLo := FCheckpoint.ScalarLo;
  FScalarHi := FCheckpoint.ScalarHi;
  FVectorLo := FCheckpoint.VectorLo;
  FVectorHi := FCheckpoint.VectorHi;
  FSingleIssue := FCheckpoint.SingleIssue;
  FStalledSecondOpcode := FCheckpoint.StalledSecondOpcode;
  FHasStalledSecondOpcode := FCheckpoint.HasStalledSecondOpcode;
  FLoadHistory := FCheckpoint.LoadHistory;
  FBranchBubble := FCheckpoint.BranchBubble;
  FStalledOpcode := FCheckpoint.StalledOpcode;
  FStalledPC := FCheckpoint.StalledPC;
  FHasStalledOpcode := FCheckpoint.HasStalledOpcode;
  FCheckpointed := False;
  // The same free clocks again, up to the current point.
  var Status: Cardinal := 0;
  var Interrupt: Cardinal := 0;
  if RunClocks(PC, Status, Interrupt, Keep, True) <> Keep then
    raise EInvalidOpException.Create('RSP rewind replay diverged');
  EndAhead;
end;

procedure TN64RSP.EndAhead;
begin
  FAhead := False;
  FCheckpointed := False;
end;
procedure TN64RSP.SerializeState(State: TStateArchive);

  function CanonicalBoolean(const Value: Boolean): Boolean;
  begin
    // Delphi may eliminate Ord(Boolean)>1 as impossible: inspect storage.
    var Stored: Byte := 0;
    Move(Value, Stored, SizeOf(Stored));
    Result := Stored <= 1;
  end;

begin
  if not State.Loading then
  begin
    PlanesToArrays;
    for var I := 0 to 7 do
      FAcc[I] := AccOf(I);
  end;
  State.Field(FReg, SizeOf(FReg));
  State.Field(FVec, SizeOf(FVec));
  State.Field(FAcc, SizeOf(FAcc));
  State.Field(FVCO, SizeOf(FVCO));
  State.Field(FVCC, SizeOf(FVCC));
  State.Field(FVCE, SizeOf(FVCE));
  State.Field(FNextPC, SizeOf(FNextPC));
  State.Field(FBranch, SizeOf(FBranch));
  State.Field(FDivisionHigh, SizeOf(FDivisionHigh));
  State.Field(FDivisionInput, SizeOf(FDivisionInput));
  State.Field(FDivisionResult, SizeOf(FDivisionResult));
  State.Field(FScalarReady, SizeOf(FScalarReady));
  State.Field(FLoadHistory, SizeOf(FLoadHistory));
  State.Field(FBranchBubble, SizeOf(FBranchBubble));
  State.Field(FStalledOpcode, SizeOf(FStalledOpcode));
  State.Field(FStalledPC, SizeOf(FStalledPC));
  State.Field(FHasStalledOpcode, SizeOf(FHasStalledOpcode));
  State.Field(FVectorReady, SizeOf(FVectorReady));
  State.Field(FSingleIssue, SizeOf(FSingleIssue));
  State.Field(FStalledSecondOpcode, SizeOf(FStalledSecondOpcode));
  State.Field(FHasStalledSecondOpcode, SizeOf(FHasStalledSecondOpcode));
  if State.Loading then
  begin
    if (FNextPC > $FFC) or ((FNextPC and 3) <> 0) then
      raise EReadError.Create('Invalid RSP PC');
    if (FLoadHistory > 3) or (FBranchBubble > 1) or
      (FStalledPC > $FFC) or ((FStalledPC and 3) <> 0) or
      not CanonicalBoolean(FHasStalledOpcode) or not CanonicalBoolean(FBranch) or
      not CanonicalBoolean(FDivisionHigh) or (FScalarReady[0] <> 0) then
      raise EReadError.Create('Invalid RSP pipeline snapshot');
    for var I := 1 to 31 do
      if FScalarReady[I] > 2 then
        raise EReadError.Create('Invalid RSP scalar readiness');
    if (FSingleIssue > 1) or not CanonicalBoolean(FHasStalledSecondOpcode) or
      (FHasStalledSecondOpcode and not FHasStalledOpcode) then
      raise EReadError.Create('Invalid RSP pairing snapshot');
    for var I := 0 to 31 do
      if FVectorReady[I] > 3 then
        raise EReadError.Create('Invalid RSP vector readiness');
    for var I := 0 to 7 do
      if (FAcc[I] < -140737488355328) or (FAcc[I] > 140737488355327) then
        raise EReadError.Create('Invalid RSP accumulator');
    for var I := 0 to 7 do
      SetAcc(I, FAcc[I]);
    ArraysToPlanes;
  end;
end;

end.

