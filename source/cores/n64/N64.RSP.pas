unit N64.RSP;
// Runs without range and overflow checks (every index is masked and all
// guest arithmetic wraps explicitly); N64_CHECKED builds them in, for the
// tests.
{$IFDEF N64_CHECKED}{$Q+}{$R+}{$ELSE}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, System.SyncObjs, System.Classes, System.Math, N64.Types, Core.Snapshots;

type
  // One vector register's eight lanes.
  TRSPLanes = array[0..7] of Word;
  PRSPLanes = ^TRSPLanes;
  // The eight lanes also as two 64-bit words (all at once: SWAR), 8-byte
  // aligned.
  // The accumulator's lanes.
  TRSPAccLanes = array[0..7] of Int64;
  PRSPAccLanes = ^TRSPAccLanes;
  TRSPQuadLanes = record
    case Integer of
      0: (Lanes: TRSPLanes);
      1: (Quads: array[0..1] of UInt64);
  end;
  PRSPQuadLanes = ^TRSPQuadLanes;

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

  // The value an MFC0 of SP/DP register Index (0..15) reads at clock Clock
  // of a run-ahead window (1 = the first): False if it cannot be known yet.
  TRSPPrediction = function(Index, Clock: Integer; out Value: Cardinal): Boolean of object;
  // Whether an MTC0 of Value to SP/DP register Index at clock Clock of a
  // run-ahead window may be applied later, in its own clock (the console
  // does that).
  TRSPDeferral = function(Index, Clock: Integer; Value: Cardinal): Boolean of object;

  // Why a run-ahead window ended: its clock budget, MTC0, an MFC0 without a
  // prediction, BREAK or another instruction that may raise, a halt.
  // a DMEM access to a fenced line.
  TRSPAheadStop = (Budget, WriteCOP0, ReadCOP0, BreakOrRaise, Halt, Fence);

  // Called by Rewind before it runs clock Stops[Index] + 1 again.
  TRSPReplayStop = procedure(Index: Integer) of object;
  // Whether the console lifts fences for clock Clock of a run-ahead window,
  // which they stop (the DMA they guard expected done by then; checked in
  // that clock's turn). It lifts them only if the clock then runs
  // (TN64RSP.ClockFenced).
  TRSPFenceLift = function(Clock: Integer): Boolean of object;

  // A predicted MFC0, a deferred MTC0 (Write) or lifted fences (Lift) of a
  // run-ahead window.
  TRSPJournalEntry = record
    Clock, Index: Integer;
    Value: Cardinal;
    Write, Lift: Boolean;
  end;
  // The journal as it lies in memory (TN64RSP.Journal).
  TRSPJournal = array[0..16383] of TRSPJournalEntry; // TN64RSP.JournalCapacity
  PRSPJournal = ^TRSPJournal;

  // Everything an RSP clock can change besides DMEM (run-ahead checkpoint).
  TRSPCheckpoint = record
    Reg: array[0..31] of Cardinal;
    Vec: array[0..31, 0..7] of Word;
    Acc: array[0..7] of Int64;
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

  // One clock of a block: the words it issues (Second also unpaired: a
  // stall holds it), the clocks it stalls first and the pipeline after it.
  TRSPBlockStep = record
    Op, Second: Cardinal;
    ScalarLo, ScalarHi, VectorLo, VectorHi: Cardinal;
    Wait, LoadHistory, SingleIssue: Byte;
    Pair: Boolean;
    // How each word issues (TN64RSP.StepKind).
    Kind, SecondKind: Byte;
  end;
  PRSPBlockStep = ^TRSPBlockStep;

  // The clocks RunClocks takes from an IMEM slot and pipeline state (no
  // branch, stall or bubble pending, not single-stepping), worked out once:
  // up to the delay slot of the first branch, or before the first clock
  // with an external instruction. Which words issue, paired or not, and the
  // stalls depend on nothing else. Its Words IMEM words from the slot on
  // (all those the clocks looked at) are compared again once IMEM changed
  // after Checked.
  PRSPBlock = ^TRSPBlock;
  TRSPBlock = record
    ScalarLo, ScalarHi, VectorLo, VectorHi: Cardinal;
    LoadHistory, SingleIssue: Byte;
    Count, First, Words, FirstWord: Integer;
    Checked: UInt64;
    // The next block from the same slot, or -1.
    Next: Integer;
    // The blocks that came next after this one ran to its end, at LinkPC:
    // [0] with no branch taken, [1] after a taken one (and its bubble). The
    // pipeline there follows from this block, the branch and its target
    // alone, so the block found there then fits it again (nil: none yet).
    Link: array[0..1] of PRSPBlock;
    LinkPC: array[0..1] of Cardinal;
  end;

  // After a block's clocks (tests): Clocks run so far in this call.
  TRSPBlockDone = procedure(Clocks: Integer) of object;

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
    // The 48-bit accumulator lanes, sign-extended (also their snapshot
    // form). The slices: bits 32..47 (AccHi), 16..31 (AccMid), 0..15 (AccLo).
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
    // NewRun has started the next run (RunAhead does not again).
    FRunFresh: Boolean;
    FLineRun: array[0..63] of Cardinal;
    FLineBackup: array[0..4095] of Byte;
    // The window's predicted MFC0s and deferred MTC0s, in clock order
    // (FJournalCount used); a rewind replays them from FReplayPos on.
    // FReadPending: the MFC0 of the clock being issued reads FReadValue;
    // FWritePending: its MTC0 is left to the console.
    FPredict: TRSPPrediction;
    FDefer: TRSPDeferral;
    FLift: TRSPFenceLift;
    FJournal: TArray<TRSPJournalEntry>;
    FJournalCount, FReplayPos: Integer;
    FReplaying, FReadPending, FWritePending: Boolean;
    FReadValue: Cardinal;
    // Window clocks before the current RunClocks call (a replay runs in
    // parts).
    FClockBase: Integer;
    // Clocks the window being run has run so far (RunAhead, ContinueAhead).
    FAheadClocks: Integer;
    FAheadStop: TRSPAheadStop;
    // 8-byte groups of DMEM a run-ahead window must not read (bit 0) or
    // write (bit 1): DMA or the RDP uses them meanwhile.
    FFence: array[0..511] of Byte;
    FFenced: Boolean;
    FAheadStopIndex: Integer;
    // The instructions of the clock a fence stops (for ClockFenced).
    FFencedOp, FFencedSecond: Cardinal;
    FFencedPair: Boolean;
    // Blocks (TRSPBlock), chained per IMEM slot from FBlockHead; their steps
    // and words in pools, all dropped when one is full.
    FUseBlocks: Boolean;
    FBlockHead: array[0..1023] of Integer;
    FBlocks: TArray<TRSPBlock>;
    FBlockSteps: TArray<TRSPBlockStep>;
    FBlockWords: TArray<Cardinal>;
    FBlockCount, FStepCount, FWordCount: Integer;
    // Counts ClearBlocks (blocks from before are gone).
    FBlockGen: Cardinal;
    FBlocksBuilt, FBlocksRun, FBlockClocks: Int64;
    FOnBlock: TRSPBlockDone;
    procedure ClearBlocks;
    function BlockValid(B: PRSPBlock; Slot: Integer): Boolean; inline;
    function FindBlock(PC: Cardinal): PRSPBlock;
    function BuildBlock(PC: Cardinal): PRSPBlock;
    function RunBlock(B: PRSPBlock; var PC, Status, Interrupt: Cardinal; Cycles: Integer; Ahead: Boolean;
      var Ran: Integer): Integer;
    function TouchesFence(Op: Cardinal): Boolean;
    procedure SaveCheckpoint(PC: Cardinal);
    procedure SaveLine(Offset: Cardinal);
    function JournalCOP0(Op, Second: Cardinal; Pair: Boolean; Clock: Integer): Boolean;
    function LiftFence(PC, Op, Second: Cardinal; Pair: Boolean; Clock: Integer): Boolean;
    procedure AddJournal(Clock, Index: Integer; Value: Cardinal; Write, Lift: Boolean);
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
    procedure AgePipelineBy(Clocks: Integer); inline;
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
    procedure Issue(Op: Cardinal; var PC, Status, Interrupt: Cardinal); inline;
    function AccHi(I: Integer): Word; inline;
    function AccMid(I: Integer): Word; inline;
    function AccLo(I: Integer): Word; inline;
    procedure SetAcc(I: Integer; Value: Int64); inline;
    procedure SetAccLo(I: Integer; Value: Word); inline;
    procedure SelectVT(T, E: Integer; out VT: TRSPLanes); inline;
    function VTLanes(Op: Cardinal; var Copy: TRSPQuadLanes): PRSPLanes; inline;
    procedure VectorOp(Op: Cardinal);
    procedure VectorMulFrac(Op: Cardinal);
    procedure VectorRound(Op: Cardinal);
    procedure VectorMulQ(Op: Cardinal);
    procedure VectorMul(Op: Cardinal);
    procedure VectorMUDL(Op: Cardinal);
    procedure VectorMUDM(Op: Cardinal);
    procedure VectorMUDN(Op: Cardinal);
    procedure VectorMUDH(Op: Cardinal);
    procedure VectorMADL(Op: Cardinal);
    procedure VectorMADM(Op: Cardinal);
    procedure VectorMADN(Op: Cardinal);
    procedure VectorMADH(Op: Cardinal);
    procedure VectorAddSub(Op: Cardinal);
    procedure VectorAdd(Op: Cardinal);
    procedure VectorSub(Op: Cardinal);
    class function StepKind(Op: Cardinal): Byte; static;
    procedure IssueKind(Kind: Byte; Op: Cardinal; var PC, Status, Interrupt: Cardinal); inline;
    procedure IssueScalar(Kind: Byte; Op: Cardinal);
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
    procedure VectorMemoryDirect(Op: Cardinal; Writing: Boolean);
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
    // touch nothing outside the RSP but DMEM (no MTC0, no BREAK, nothing that
    // raises; an MFC0 only with a value from OnPredict, an MTC0 only if
    // OnDefer leaves it to the console; both go into the journal) and returns
    // how many it ran; Status is not changed (it must not halt or
    // single-step). Rewind returns to the state before them and runs Keep of
    // them again, with the journal's values for their MFC0s (and without
    // their MTC0s). EndAhead keeps them all. Both empty the journal.
    function RunAhead(var PC: Cardinal; Status: Cardinal; Cycles: Integer): Integer;
    // Starts the run of the next window now (RunAhead does it otherwise), so
    // that LineSaved can tell its saved lines while it runs elsewhere.
    procedure NewRun;
    // Whether the window being run has saved the 64-byte DMEM line at Offset
    // (before its first write to it). Safe on another thread: True means the
    // copy is complete.
    function LineSaved(Offset: Cardinal): Boolean;
    // Up to Cycles more clocks of the window RunAhead started (after it ran
    // all its clocks): one window run in parts, exactly as in one.
    function ContinueAhead(var PC: Cardinal; Status: Cardinal; Cycles: Integer): Integer;
    procedure Rewind(var PC: Cardinal; Keep: Integer); overload;
    // The same, calling OnStop(I) after the first Stops[I] clocks (in
    // ascending order, at most Keep): for outside writes to DMEM made while
    // the window ran, at their place among its clocks. OnStop(-1) comes after
    // the saved lines are restored, before the clocks run again.
    procedure Rewind(var PC: Cardinal; Keep: Integer; const Stops: array of Integer; OnStop: TRSPReplayStop); overload;
    procedure EndAhead;
    // Fences the 8-byte groups of Count bytes from Offset (wrapping in DMEM)
    // for the window being run, or the next one: for writes, and with Reads
    // also for reads. EndAhead lifts every fence.
    procedure AddFence(Offset, Count: Cardinal; Reads: Boolean; Source: Byte = 0);
    // Whether the window being run wrote DMEM lines of Count bytes from
    // Offset (wrapping in DMEM).
    function WroteAhead(Offset, Count: Cardinal): Boolean;
    // Whether a fence keeps the window from reading any of Count bytes from
    // Offset (wrapping in DMEM).
    function ReadFenced(Offset, Count: Cardinal): Boolean;
    // Lifts every fence (the window goes on).
    procedure ClearFences;
    // During OnLift: whether the clock is still stopped by a fence.
    function ClockFenced: Boolean;
    // A write to DMEM as one of the window's clocks makes it (a rewind
    // undoes it).
    procedure WriteAhead(Offset: Cardinal; Value: Byte);
    function JournalCount: Integer; inline;
    // The journal's entries, allocated once (JournalCapacity of them).
    function Journal: PRSPJournal;
    function JournalEntry(I: Integer): TRSPJournalEntry; inline;
    property OnPredict: TRSPPrediction read FPredict write FPredict;
    property OnDefer: TRSPDeferral read FDefer write FDefer;
    property OnLift: TRSPFenceLift read FLift write FLift;
    // Whether clocks run from blocks where they can (on by default; the
    // same clocks either way).
    property UseBlocks: Boolean read FUseBlocks write FUseBlocks;
    property OnBlock: TRSPBlockDone read FOnBlock write FOnBlock;
    // Blocks worked out, and run (each time a clock loop took one), with the
    // clocks they took.
    property BlocksBuilt: Int64 read FBlocksBuilt;
    property BlocksRun: Int64 read FBlocksRun;
    property BlockClocks: Int64 read FBlockClocks;
  public const
    // Journal entries one window may hold (the journal never grows, so the
    // console may read published entries while the window runs on).
    JournalCapacity = 16384;
  public
    // Why the last RunAhead ended.
    property AheadStop: TRSPAheadStop read FAheadStop;
    // The SP/DP register (0..15) of the COP0 access that ended it.
    property AheadStopIndex: Integer read FAheadStopIndex;
    procedure SerializeState(State: TStateArchive);
  end;

implementation

constructor TN64RSP.Create(Bus: TN64Bus);
begin
  inherited Create;
  FBus := Bus;
  SetLength(FJournal, JournalCapacity);
  for var I := 0 to High(FDecStamp) do
    FDecStamp[I] := NotDecoded;
  FUseBlocks := True;
  // (Whole 64-bit words of the vector registers are read and written.)
  if (NativeUInt(@FVec[0, 0]) and 7) <> 0 then
    raise EInvalidOpException.Create('RSP vector registers not 8-byte aligned');
  ClearBlocks;
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
    FAcc[I] := 0;
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

// Value clamped to 16 signed bits (compares here: EnsureRange is a call).
function ClampSigned(Value: Integer): Word; overload; inline;
begin
  if Value > 32767 then
    Result := $7FFF
  else if Value < -32768 then
    Result := $8000
  else
    Result := Word(Value and $FFFF);
end;

function ClampSigned(Value: Int64): Word; overload; inline;
begin
  if Value > 32767 then
    Result := $7FFF
  else if Value < -32768 then
    Result := $8000
  else
    Result := Word(Value and $FFFF);
end;

function TN64RSP.AccHi(I: Integer): Word;
begin
  Result := Word((FAcc[I] shr 32) and $FFFF);
end;

function TN64RSP.AccMid(I: Integer): Word;
begin
  Result := Word((FAcc[I] shr 16) and $FFFF);
end;

function TN64RSP.AccLo(I: Integer): Word;
begin
  Result := Word(FAcc[I] and $FFFF);
end;

function Wrap48(Value: Int64): Int64; inline;
begin
  // The low 48 bits (the guest's accumulator wraps there), sign-extended; a
  // sum of a lane and a product rarely leaves them.
  // In range: bits 47..63 all equal (no 64-bit constants in the check).
  Result := Value;
  if (((UInt64(Value) shr 47) + 1) and $1FFFF) > 1 then
    Result := ((Value and $FFFFFFFFFFFF) xor $800000000000) - $800000000000;
end;

procedure TN64RSP.SetAcc(I: Integer; Value: Int64);
begin
  // A sum of a lane and a product needs no other wrapping.
  FAcc[I] := Wrap48(Value);
end;

procedure TN64RSP.SetAccLo(I: Integer; Value: Word);
begin
  // The low slice only (bit 47, the sign, stays).
  FAcc[I] := (FAcc[I] and not Int64($FFFF)) or Value;
end;

function AccClampMid(Acc: Int64): Word; inline;
begin
  // The accumulator's bits 16..47 as a signed value, clamped to 16 bits.
  if UInt64(Acc + $80000000) <= $FFFFFFFF then
    Result := Word((Acc shr 16) and $FFFF)
  else if Acc < 0 then
    Result := $8000
  else
    Result := $7FFF;
end;

function AccClampLow(Acc: Int64): Word; inline;
begin
  // VMADL/VMADN: the low slice when the accumulator fits 32 signed bits,
  // else 0 below and $FFFF above.
  if UInt64(Acc + $80000000) <= $FFFFFFFF then
    Result := Word(Acc and $FFFF)
  else if Acc < 0 then
    Result := 0
  else
    Result := $FFFF;
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

function TN64RSP.VTLanes(Op: Cardinal; var Copy: TRSPQuadLanes): PRSPLanes;
begin
  // Op's VT with its element applied: the register itself when that selects
  // lane I for lane I (an instruction reads lane I of its sources before it
  // writes lane I of VD, so VD may be VT), else Copy, filled four lanes at a
  // time (lane 0 lowest: little-endian hosts only).
  var T := Integer((Op shr 16) and 31);
  var E := Integer((Op shr 21) and 15);
  if E < 2 then
    Exit(@FVec[T]);
  if E >= 8 then
  begin
    // One lane for all.
    var Q := UInt64(FVec[T, E - 8]) * UInt64($0001000100010001);
    Copy.Quads[0] := Q;
    Copy.Quads[1] := Q;
  end
  else if E >= 4 then
  begin
    // Lane E - 4 for the first four, lane E for the others.
    Copy.Quads[0] := UInt64(FVec[T, E - 4]) * UInt64($0001000100010001);
    Copy.Quads[1] := UInt64(FVec[T, E]) * UInt64($0001000100010001);
  end
  else
  begin
    // Lane E - 2 (+ 2, 4, 6) for each pair.
    var A := E - 2;
    Copy.Quads[0] := (UInt64(FVec[T, A]) * $10001) or ((UInt64(FVec[T, A + 2]) * $10001) shl 32);
    Copy.Quads[1] := (UInt64(FVec[T, A + 4]) * $10001) or ((UInt64(FVec[T, A + 6]) * $10001) shl 32);
  end;
  Result := @Copy.Lanes;
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
  var Copy: TRSPQuadLanes;
  var VT := VTLanes(Op, Copy);
  var VS: PRSPLanes := @FVec[(Op shr 11) and 31];
  var VD: PRSPLanes := @FVec[(Op shr 6) and 31];
  var Fn := Op and 63;
  for var I := 0 to 7 do
  begin
    var V := Int64(S16(VS[I]) * S16(VT[I])) * 2;
    var Acc: Int64;
    if Fn < 8 then
      Acc := V + $8000
    else
      Acc := Wrap48(FAcc[I] + V);
    FAcc[I] := Acc;
    if (Fn and 1) = 0 then
      VD[I] := AccClampMid(Acc)
    else if Acc < 0 then
      VD[I] := 0
    else if Acc >= $80000000 then
      VD[I] := $FFFF
    else
      VD[I] := Word((Acc shr 16) and $FFFF);
  end;
end;

procedure TN64RSP.VectorRound(Op: Cardinal);
begin
  // VRNDP (if ACC >= 0), VRNDN (if ACC < 0): ACC += VT, shifted when VS is odd.
  var Copy: TRSPQuadLanes;
  var VT := VTLanes(Op, Copy);
  var S := (Op shr 11) and 31;
  var D := (Op shr 6) and 31;
  var Negative := (Op and 63) = 10;
  for var I := 0 to 7 do
  begin
    var V := Int64(S16(VT[I]));
    if (S and 1) <> 0 then
      V := V * 65536;
    if (FAcc[I] < 0) = Negative then
      SetAcc(I, FAcc[I] + V);
    FVec[D, I] := AccClampMid(FAcc[I]);
  end;
end;

procedure TN64RSP.VectorMulQ(Op: Cardinal);
begin
  // VMULQ (product, biased when negative) and VMACQ (ACC_HI/MD rounded by 32).
  var Copy: TRSPQuadLanes;
  var VT := VTLanes(Op, Copy);
  var S := (Op shr 11) and 31;
  var D := (Op shr 6) and 31;
  var Accumulate := (Op and 63) = 11;
  for var I := 0 to 7 do
  begin
    var V: Int64;
    if Accumulate then
    begin
      // ACC bits 16..47, signed.
      V := Int64(Integer(Cardinal((FAcc[I] shr 16) and $FFFFFFFF)));
      if (V < -32) and ((V and 32) = 0) then
        Inc(V, 32)
      else if (V > 32) and ((V and 32) = 0) then
        Dec(V, 32);
      SetAcc(I, V * 65536 + AccLo(I));
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
  // add it; the products fit 32 bits. Each reads lane I of its sources
  // before it writes lane I of VD (VT from a copy when selected).
  case Op and 63 of
    4:
      VectorMUDL(Op);
    5:
      VectorMUDM(Op);
    6:
      VectorMUDN(Op);
    7:
      VectorMUDH(Op);
    12:
      VectorMADL(Op);
    13:
      VectorMADM(Op);
    14:
      VectorMADN(Op);
  else
    VectorMADH(Op);
  end;
end;

procedure TN64RSP.VectorMUDL(Op: Cardinal);
begin
  var Copy: TRSPQuadLanes;
  var VT := VTLanes(Op, Copy);
  var VS: PRSPLanes := @FVec[(Op shr 11) and 31];
  var VD: PRSPLanes := @FVec[(Op shr 6) and 31];
  var A: PRSPAccLanes := @FAcc;
  for var I := 0 to 7 do
  begin
    var V := Word(((Cardinal(VS[I]) * VT[I]) shr 16) and $FFFF);
    A[I] := V;
    VD[I] := V;
  end;
end;

procedure TN64RSP.VectorMUDM(Op: Cardinal);
begin
  // The products fit the accumulator as they are.
  var Copy: TRSPQuadLanes;
  var VT := VTLanes(Op, Copy);
  var VS: PRSPLanes := @FVec[(Op shr 11) and 31];
  var VD: PRSPLanes := @FVec[(Op shr 6) and 31];
  var A: PRSPAccLanes := @FAcc;
  for var I := 0 to 7 do
  begin
    var Acc := Int64(S16(VS[I]) * Integer(VT[I]));
    A[I] := Acc;
    VD[I] := AccClampMid(Acc);
  end;
end;

procedure TN64RSP.VectorMUDN(Op: Cardinal);
begin
  var Copy: TRSPQuadLanes;
  var VT := VTLanes(Op, Copy);
  var VS: PRSPLanes := @FVec[(Op shr 11) and 31];
  var VD: PRSPLanes := @FVec[(Op shr 6) and 31];
  var A: PRSPAccLanes := @FAcc;
  for var I := 0 to 7 do
  begin
    var Acc := Int64(Integer(VS[I]) * S16(VT[I]));
    A[I] := Acc;
    VD[I] := Word(Acc and $FFFF);
  end;
end;

procedure TN64RSP.VectorMUDH(Op: Cardinal);
begin
  var Copy: TRSPQuadLanes;
  var VT := VTLanes(Op, Copy);
  var VS: PRSPLanes := @FVec[(Op shr 11) and 31];
  var VD: PRSPLanes := @FVec[(Op shr 6) and 31];
  var A: PRSPAccLanes := @FAcc;
  for var I := 0 to 7 do
  begin
    var P := S16(VS[I]) * S16(VT[I]);
    A[I] := Int64(P) * 65536;
    VD[I] := ClampSigned(P);
  end;
end;

procedure TN64RSP.VectorMADL(Op: Cardinal);
begin
  var Copy: TRSPQuadLanes;
  var VT := VTLanes(Op, Copy);
  var VS: PRSPLanes := @FVec[(Op shr 11) and 31];
  var VD: PRSPLanes := @FVec[(Op shr 6) and 31];
  var A: PRSPAccLanes := @FAcc;
  for var I := 0 to 7 do
  begin
    var Acc := Wrap48(A[I] + ((Cardinal(VS[I]) * VT[I]) shr 16));
    A[I] := Acc;
    VD[I] := AccClampLow(Acc);
  end;
end;

procedure TN64RSP.VectorMADM(Op: Cardinal);
begin
  var Copy: TRSPQuadLanes;
  var VT := VTLanes(Op, Copy);
  var VS: PRSPLanes := @FVec[(Op shr 11) and 31];
  var VD: PRSPLanes := @FVec[(Op shr 6) and 31];
  var A: PRSPAccLanes := @FAcc;
  for var I := 0 to 7 do
  begin
    var Acc := Wrap48(A[I] + S16(VS[I]) * Integer(VT[I]));
    A[I] := Acc;
    VD[I] := AccClampMid(Acc);
  end;
end;

procedure TN64RSP.VectorMADN(Op: Cardinal);
begin
  var Copy: TRSPQuadLanes;
  var VT := VTLanes(Op, Copy);
  var VS: PRSPLanes := @FVec[(Op shr 11) and 31];
  var VD: PRSPLanes := @FVec[(Op shr 6) and 31];
  var A: PRSPAccLanes := @FAcc;
  for var I := 0 to 7 do
  begin
    var Acc := Wrap48(A[I] + Integer(VS[I]) * S16(VT[I]));
    A[I] := Acc;
    VD[I] := AccClampLow(Acc);
  end;
end;

procedure TN64RSP.VectorMADH(Op: Cardinal);
begin
  // Bits 16..47 change only (a 32-bit sum, wrapped).
  var Copy: TRSPQuadLanes;
  var VT := VTLanes(Op, Copy);
  var VS: PRSPLanes := @FVec[(Op shr 11) and 31];
  var VD: PRSPLanes := @FVec[(Op shr 6) and 31];
  var A: PRSPAccLanes := @FAcc;
  for var I := 0 to 7 do
  begin
    var Acc := Wrap48(A[I] + Int64(S16(VS[I]) * S16(VT[I])) * 65536);
    A[I] := Acc;
    VD[I] := AccClampMid(Acc);
  end;
end;

procedure TN64RSP.VectorAddSub(Op: Cardinal);
begin
  // VADD, VSUB with the VCO carry; clear VCO.
  if (Op and 63) = 17 then
    VectorSub(Op)
  else
    VectorAdd(Op);
end;

procedure TN64RSP.VectorAdd(Op: Cardinal);
begin
  var Copy: TRSPQuadLanes;
  var VT := VTLanes(Op, Copy);
  var VS: PRSPLanes := @FVec[(Op shr 11) and 31];
  var VD: PRSPLanes := @FVec[(Op shr 6) and 31];
  var A: PRSPAccLanes := @FAcc;
  var Carry := Cardinal(FVCO);
  for var I := 0 to 7 do
  begin
    var V := S16(VS[I]) + S16(VT[I]) + Integer(Carry and 1);
    Carry := Carry shr 1;
    A[I] := (A[I] and not Int64($FFFF)) or (V and $FFFF);
    VD[I] := ClampSigned(V);
  end;
  FVCO := 0;
end;

procedure TN64RSP.VectorSub(Op: Cardinal);
begin
  var Copy: TRSPQuadLanes;
  var VT := VTLanes(Op, Copy);
  var VS: PRSPLanes := @FVec[(Op shr 11) and 31];
  var VD: PRSPLanes := @FVec[(Op shr 6) and 31];
  var A: PRSPAccLanes := @FAcc;
  var Carry := Cardinal(FVCO);
  for var I := 0 to 7 do
  begin
    var V := S16(VS[I]) - S16(VT[I]) - Integer(Carry and 1);
    Carry := Carry shr 1;
    A[I] := (A[I] and not Int64($FFFF)) or (V and $FFFF);
    VD[I] := ClampSigned(V);
  end;
  FVCO := 0;
end;

procedure TN64RSP.VectorAbs(Op: Cardinal);
begin
  // VABS: VT negated, kept or zeroed by the sign of VS.
  var Copy: TRSPQuadLanes;
  var VT := VTLanes(Op, Copy);
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
    SetAccLo(I, Word(V and $FFFF));
    FVec[D, I] := ClampSigned(V);
  end;
end;

procedure TN64RSP.VectorCarry(Op: Cardinal);
begin
  // VADDC (carry out), VSUBC (borrow and not-equal) into VCO.
  var Copy: TRSPQuadLanes;
  var VT := VTLanes(Op, Copy);
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
    SetAccLo(I, Word(V and $FFFF));
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
        FVec[D, I] := AccHi(I);
      9:
        FVec[D, I] := AccMid(I);
      10:
        FVec[D, I] := AccLo(I);
    else
      FVec[D, I] := 0;
    end;
end;

procedure TN64RSP.VectorCompare(Op: Cardinal);
begin
  // VLT, VEQ, VNE, VGE: VCC low byte from the test, VCO cleared.
  var Copy: TRSPQuadLanes;
  var VT := VTLanes(Op, Copy);
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
    SetAccLo(I, R);
    FVec[D, I] := R;
  end;
  FVCO := 0;
  FVCC := Word(Compare);
end;

procedure TN64RSP.VectorClipLow(Op: Cardinal);
begin
  // VCL: the clip compare continuing a VCH/VCR, from VCO, VCC and VCE.
  var Copy: TRSPQuadLanes;
  var VT := VTLanes(Op, Copy);
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
    SetAccLo(I, R);
    FVec[D, I] := R;
  end;
  FVCO := 0;
  FVCC := Word(Compare);
  FVCE := 0;
end;

procedure TN64RSP.VectorClipHigh(Op: Cardinal);
begin
  // VCH (sets VCO and VCE for a following VCL) and VCR.
  var Copy: TRSPQuadLanes;
  var VT := VTLanes(Op, Copy);
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
    SetAccLo(I, R);
    FVec[D, I] := R;
  end;
  FVCO := Word(Carry);
  FVCC := Word(Compare);
  FVCE := Word(Extension);
end;

procedure TN64RSP.VectorMerge(Op: Cardinal);
begin
  // VMRG: VS where VCC is set, else VT; clears VCO.
  var Copy: TRSPQuadLanes;
  var VT := VTLanes(Op, Copy);
  var S := (Op shr 11) and 31;
  var D := (Op shr 6) and 31;
  for var I := 0 to 7 do
  begin
    var R := VT[I];
    if ((FVCC shr I) and 1) <> 0 then
      R := FVec[S, I];
    SetAccLo(I, R);
    FVec[D, I] := R;
  end;
  FVCO := 0;
end;

procedure TN64RSP.VectorLogic(Op: Cardinal);
begin
  // VAND, VNAND, VOR, VNOR, VXOR, VNXOR: all lanes at once, as two 64-bit
  // words (the registers and the copy are 8-byte aligned); the result also
  // into each lane's ACC_LO.
  var Copy: TRSPQuadLanes;
  var VT := PRSPQuadLanes(VTLanes(Op, Copy));
  var VS := PRSPQuadLanes(@FVec[(Op shr 11) and 31]);
  var VD := PRSPQuadLanes(@FVec[(Op shr 6) and 31]);
  var R0, R1: UInt64;
  case Op and 7 of
    0:
      begin
        R0 := VS.Quads[0] and VT.Quads[0];
        R1 := VS.Quads[1] and VT.Quads[1];
      end;
    1:
      begin
        R0 := not (VS.Quads[0] and VT.Quads[0]);
        R1 := not (VS.Quads[1] and VT.Quads[1]);
      end;
    2:
      begin
        R0 := VS.Quads[0] or VT.Quads[0];
        R1 := VS.Quads[1] or VT.Quads[1];
      end;
    3:
      begin
        R0 := not (VS.Quads[0] or VT.Quads[0]);
        R1 := not (VS.Quads[1] or VT.Quads[1]);
      end;
    4:
      begin
        R0 := VS.Quads[0] xor VT.Quads[0];
        R1 := VS.Quads[1] xor VT.Quads[1];
      end;
  else
    R0 := not (VS.Quads[0] xor VT.Quads[0]);
    R1 := not (VS.Quads[1] xor VT.Quads[1]);
  end;
  VD.Quads[0] := R0;
  VD.Quads[1] := R1;
  for var I := 0 to 7 do
    FAcc[I] := (FAcc[I] and not Int64($FFFF)) or VD.Lanes[I];
end;

procedure TN64RSP.VectorReserved(Op: Cardinal);
begin
  // Reserved encodings still execute: VS + VT to ACC_LO, VD zeroed.
  var Copy: TRSPQuadLanes;
  var VT := VTLanes(Op, Copy);
  var S := (Op shr 11) and 31;
  var D := (Op shr 6) and 31;
  for var I := 0 to 7 do
  begin
    SetAccLo(I, Word((S16(FVec[S, I]) + S16(VT[I])) and $FFFF));
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
    SetAccLo(I, VT[I]);
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

procedure TN64RSP.VectorMemoryDirect(Op: Cardinal; Writing: Boolean);
begin
  // VectorMemory's LBV, LSV, LLV, LDV, LQV and their stores with direct SP
  // memory: Size bytes from Address (LQV/SQV: up to the end of its 16-byte
  // line) to or from element E on, wrapping in DMEM. A load stops at element
  // 15, a store wraps around the elements.
  var Kind := Integer((Op shr 11) and 31);
  var E := Integer((Op shr 7) and 15);
  var Offset := Integer(Op and 63) - Integer(Op and 64);
  var Address := ((FReg[(Op shr 21) and 31] and $FFF) + (Cardinal(Offset * (1 shl Kind)) and $FFF)) and $FFF;
  var Size := 1 shl Kind;
  if Kind = 4 then
    Size := 16 - Integer(Address and 15);
  var SP := FBus.DMemBytes;
  var Lanes: PRSPLanes := @FVec[(Op shr 16) and 31];
  var I := 0;
  if Writing then
  begin
    if FAhead then
    begin
      // As DMemWrite before its first byte in a line (the 16 bytes at most
      // lie in the line of the first and of the last).
      var Last := (Address + Cardinal(Size) - 1) and $FFF;
      if FLineRun[Address shr 6] <> FRun then
        SaveLine(Address);
      if FLineRun[Last shr 6] <> FRun then
        SaveLine(Last);
    end;
    if not Odd(E) then
      while I + 1 < Size do
      begin
        var W := Lanes[((E + I) and 15) shr 1];
        SP[(Address + Cardinal(I)) and $FFF] := Byte(W shr 8);
        SP[(Address + Cardinal(I + 1)) and $FFF] := Byte(W and $FF);
        Inc(I, 2);
      end;
    while I < Size do
    begin
      var Index := (E + I) and 15;
      if Odd(Index) then
        SP[(Address + Cardinal(I)) and $FFF] := Byte(Lanes[Index shr 1] and $FF)
      else
        SP[(Address + Cardinal(I)) and $FFF] := Byte(Lanes[Index shr 1] shr 8);
      Inc(I);
    end;
  end
  else
  begin
    Size := Min(Size, 16 - E);
    if not Odd(E) then
      while I + 1 < Size do
      begin
        Lanes[(E + I) shr 1] := (Word(SP[(Address + Cardinal(I)) and $FFF]) shl 8) or
          SP[(Address + Cardinal(I + 1)) and $FFF];
        Inc(I, 2);
      end;
    while I < Size do
    begin
      var Index := E + I;
      var B := SP[(Address + Cardinal(I)) and $FFF];
      if Odd(Index) then
        Lanes[Index shr 1] := (Lanes[Index shr 1] and $FF00) or B
      else
        Lanes[Index shr 1] := (Lanes[Index shr 1] and $FF) or (Word(B) shl 8);
      Inc(I);
    end;
  end;
end;

procedure TN64RSP.VectorMemory(Op: Cardinal; Writing: Boolean);
begin
  if (((Op shr 11) and 31) <= 4) and FBus.DirectMemory then
  begin
    VectorMemoryDirect(Op, Writing);
    Exit;
  end;
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
  else if FBus.DirectMemory then
  begin
    // The same bytes, a whole element at a time where an element's two
    // bytes are both moved. Run ahead, a store first saves the lines it
    // writes, as DMemWrite would before its first byte in each (at most 16
    // bytes: the line of the first and of the last).
    if Writing and FAhead and (Size > 0) then
    begin
      var First := Address and $FFF;
      var Last := (Address + Cardinal(Size) - 1) and $FFF;
      if FLineRun[First shr 6] <> FRun then
        SaveLine(First);
      if FLineRun[Last shr 6] <> FRun then
        SaveLine(Last);
    end;
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

procedure TN64RSP.AgePipelineBy(Clocks: Integer);
begin
  // AgePipeline Clocks (1 or more) times: every counter down by Clocks, to 0
  // at least.
  if Clocks = 1 then
    AgePipeline
  else if Clocks = 2 then
  begin
    // Only a 3 leaves anything (a 1).
    FScalarLo := FScalarHi and FScalarLo;
    FScalarHi := 0;
    FVectorLo := FVectorHi and FVectorLo;
    FVectorHi := 0;
    FLoadHistory := 0;
  end
  else
  begin
    FScalarLo := 0;
    FScalarHi := 0;
    FVectorLo := 0;
    FVectorHi := 0;
    FLoadHistory := 0;
  end;
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
    if FReadPending then
    begin
      // Run ahead: the predicted (or, replayed, journalled) value.
      FReg[T] := FReadValue;
      FReadPending := False;
    end
    else
      FReg[T] := FBus.Read32(IOAddress);
    if FBus.TraceEnabled then
      FBus.Trace(TN64TraceKind.MMIORead, $04001000 + Current, IOAddress, FReg[T]);
  end
  else if (S = 4) and FWritePending then
  begin
    // Run ahead: the console applies it in its own clock (or, replayed,
    // has applied it already).
    FWritePending := False;
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

procedure TN64RSP.Issue(Op: Cardinal; var PC, Status, Interrupt: Cardinal);
begin
  // Vector instructions straight to their unit (nothing of the scalar
  // decode in IssueInstruction concerns them); traced, all go through it.
  if not FBus.TraceEnabled then
    case Op shr 26 of
      18, 50, 58:
        if ((Op shr 26) <> 18) or (((Op shr 21) and 31) >= 16) then
        begin
          if FBranch then
          begin
            PC := FNextPC;
            FBranch := False
          end
          else
            PC := (PC + 4) and $FFC;
          if (Op shr 26) = 18 then
            VectorOp(Op)
          else
            VectorMemory(Op, (Op shr 26) = 58);
          Exit;
        end;
    end;
  IssueInstruction(Op, PC, Status, Interrupt);
end;

function TN64RSP.RunClocks(var PC, Status, Interrupt: Cardinal; Cycles: Integer; Ahead: Boolean): Integer;
begin
  // Ahead: stop before the first clock that is not free (see RunAhead); the
  // checkpoint is taken before the first clock that changes anything.
  Result := 0;
  while Result < Cycles do
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
      // Nothing else happens in a bubble (Status stays): the next clock now.
      if Result >= Cycles then
        Break;
    end;
    // A stalled opcode only counts at its own PC. Both outcomes below set
    // FHasStalledOpcode/FHasStalledSecondOpcode, so a stale one is dropped.
    var Stalled := FHasStalledOpcode and (FStalledPC = PC);
    if FUseBlocks and not Stalled and not FBranch and ((Status and $20) = 0) and (FCheckpointed or not Ahead) and
      FBus.DirectMemory and not FBus.TraceEnabled then
    begin
      // The clocks from here worked out before: run them as they are, and
      // the blocks after them.
      var Block := FindBlock(PC);
      if Block.Count > 0 then
      begin
        var Outcome := RunBlock(Block, PC, Status, Interrupt, Cycles, Ahead, Result);
        if Outcome = 2 then
          Break;
        if Outcome = 0 then
          Continue;
        // A stall longer than the budget left, or a clock no block takes:
        // the clock below (no stall is held after a block's clocks, no
        // bubble is pending).
      end;
    end;
    var Op, Second: Cardinal;
    var Pair: Boolean;
    // The clock's masks, where they are kept (Held: decoded here).
    var Masks: ^TRSPIssueMasks;
    var Held: TRSPIssueMasks;
    var FirstSlot := Integer((PC shr 2) and 1023);
    var SecondSlot := Integer(((PC shr 2) + 1) and 1023);
    if Stalled and FStallKnown and (FStallOp = FStalledOpcode) and (FStallSecond = FStalledSecondOpcode) and
      (FStallPair = FHasStalledSecondOpcode) then
    begin
      // The stall goes on: the same held words.
      Op := FStalledOpcode;
      Second := FStalledSecondOpcode;
      Pair := FHasStalledSecondOpcode;
      Masks := @FStallMasks;
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
          Masks := @FDec[FirstSlot].Single
        else
        begin
          if not FDec[FirstSlot].PairValid or (FDec[FirstSlot].SecondOp <> Second) then
            DecodePair(FirstSlot);
          Masks := @FDec[FirstSlot].Paired;
        end;
      end
      else
      begin
        // IMEM changed under the held words: decode them as held.
        if Pair then
          Combine(InfoEXECUTE(Op), InfoEXECUTE(Second), External(Op), External(Second), Held)
        else
          MasksOf(InfoEXECUTE(Op), External(Op), Held);
        Masks := @Held;
      end;
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
        Masks := @FDec[FirstSlot].Paired
      else
        Masks := @FDec[FirstSlot].Single;
    end;
    var Flags := Masks.Flags;
    var ScalarWrites := Masks.ScalarWrites;
    var VectorWrites := Masks.VectorWrites;
    var Loading := (Flags and 1) <> 0;
    var Storing := (Flags and 2) <> 0;
    if (Storing and ((FLoadHistory and 2) <> 0)) or
      ((Masks.Sources and (FScalarLo or FScalarHi)) <> 0) or ((Masks.Vectors and (FVectorLo or FVectorHi)) <> 0) then
    begin
      // The words wait until every register they read is ready (and a store
      // until the load before it is done), all those clocks at once: they
      // only age the pipeline, and are free ahead.
      if Ahead and not FCheckpointed then
        SaveCheckpoint(PC);
      FStalledOpcode := Op;
      FStalledPC := PC;
      FHasStalledOpcode := True;
      FStalledSecondOpcode := Second;
      FHasStalledSecondOpcode := Pair;
      var Sources := Masks.Sources;
      var Vectors := Masks.Vectors;
      // The longest wait: a counter is Lo + 2 * Hi.
      var Wait := 0;
      if (Sources and FScalarHi) <> 0 then
        Wait := 2 + Ord((Sources and FScalarHi and FScalarLo) <> 0)
      else if (Sources and FScalarLo) <> 0 then
        Wait := 1;
      if (Vectors and FVectorHi) <> 0 then
        Wait := Max(Wait, 2 + Ord((Vectors and FVectorHi and FVectorLo) <> 0))
      else if ((Vectors and FVectorLo) <> 0) and (Wait = 0) then
        Wait := 1;
      // A store also waits while a load two clocks back is in the history:
      // now (bit 1), or one clock on (bit 0), when its registers no longer
      // keep it waiting by then.
      if Wait = 0 then
        Wait := 1;
      if (Wait = 1) and Storing and ((FLoadHistory and 1) <> 0) then
        Wait := 2;
      if Wait >= Cycles - Result then
      begin
        // The stall goes on past this call, or ends with it: the next one
        // starts with the held words, so keep their masks.
        Wait := Cycles - Result;
        FStallMasks := Masks^;
        FStallOp := Op;
        FStallSecond := Second;
        FStallPair := Pair;
        FStallKnown := True;
        AgePipelineBy(Wait);
        Inc(Result, Wait);
        Break;
      end;
      AgePipelineBy(Wait);
      Inc(Result, Wait);
    end;
    if Ahead then
    begin
      // A replay re-runs clocks that already ran, with the fences set later.
      if FFenced and not FReplaying and (TouchesFence(Op) or (Pair and TouchesFence(Second))) and
        not LiftFence(PC, Op, Second, Pair, FClockBase + Result + 1) then
      begin
        FAheadStop := TRSPAheadStop.Fence;
        Break;
      end;
      if Masks.External and not JournalCOP0(Op, Second, Pair, FClockBase + Result + 1) then
      begin
        var Ext := Op;
        if not External(Op) then
          Ext := Second;
        FAheadStopIndex := Integer((Ext shr 11) and 15);
        if ((Ext shr 26) = 16) and (((Ext shr 21) and 31) = 4) then
          FAheadStop := TRSPAheadStop.WriteCOP0
        else if ((Ext shr 26) = 16) and (((Ext shr 21) and 31) = 0) then
          FAheadStop := TRSPAheadStop.ReadCOP0
        else
          FAheadStop := TRSPAheadStop.BreakOrRaise;
        Break;
      end;
      if not FCheckpointed then
        SaveCheckpoint(PC);
    end;
    FHasStalledOpcode := False;
    FHasStalledSecondOpcode := False;
    var DelaySlot := FBranch;
    Issue(Op, PC, Status, Interrupt);
    if Pair and ((Status and 1) = 0) then
      Issue(Second, PC, Status, Interrupt);
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

procedure TN64RSP.ClearBlocks;
begin
  for var I := 0 to High(FBlockHead) do
    FBlockHead[I] := -1;
  FBlockCount := 0;
  FStepCount := 0;
  FWordCount := 0;
  Inc(FBlockGen);
end;

function TN64RSP.BlockValid(B: PRSPBlock; Slot: Integer): Boolean;
begin
  // Whether block B (from Slot) holds for IMEM as it is: one whose IMEM
  // changed after it was checked holds if its words are the same again
  // (code that comes back).
  var Counter := FBus.IMemCounter;
  if B.Checked = Counter then
    Exit(True);
  for var I := 0 to B.Words - 1 do
    if FBus.IMemWord((Slot + I) and 1023) <> FBlockWords[B.FirstWord + I] then
      Exit(False);
  B.Checked := Counter;
  Result := True;
end;

function TN64RSP.FindBlock(PC: Cardinal): PRSPBlock;
begin
  // The block from PC's slot and the pipeline as it is, worked out if new.
  var Slot := Integer((PC shr 2) and 1023);
  var Index := FBlockHead[Slot];
  while Index >= 0 do
  begin
    Result := @FBlocks[Index];
    if (Result.ScalarLo = FScalarLo) and (Result.ScalarHi = FScalarHi) and (Result.VectorLo = FVectorLo) and
      (Result.VectorHi = FVectorHi) and (Result.LoadHistory = FLoadHistory) and (Result.SingleIssue = FSingleIssue) and
      BlockValid(Result, Slot) then
      Exit;
    Index := Result.Next;
  end;
  Result := BuildBlock(PC);
end;

function TN64RSP.BuildBlock(PC: Cardinal): PRSPBlock;
const
  // At most this many steps in a block (the pools keep room for one).
  MaxSteps = 64;
begin
  // The clocks RunClocks takes from PC and the pipeline as it is, without
  // issuing anything: the same decode, pairing, stalls and readiness.
  if FBlocks = nil then
  begin
    SetLength(FBlocks, 2048);
    SetLength(FBlockSteps, 32768);
    SetLength(FBlockWords, 65536);
  end;
  if (FBlockCount >= Length(FBlocks)) or (FStepCount + MaxSteps > Length(FBlockSteps)) or
    (FWordCount + 2 * MaxSteps + 1 > Length(FBlockWords)) then
    ClearBlocks;
  Inc(FBlocksBuilt);
  var Start := Integer((PC shr 2) and 1023);
  Result := @FBlocks[FBlockCount];
  Result.ScalarLo := FScalarLo;
  Result.ScalarHi := FScalarHi;
  Result.VectorLo := FVectorLo;
  Result.VectorHi := FVectorHi;
  Result.LoadHistory := FLoadHistory;
  Result.SingleIssue := FSingleIssue;
  Result.First := FStepCount;
  Result.FirstWord := FWordCount;
  Result.Checked := FBus.IMemCounter;
  Result.Link[0] := nil;
  Result.Link[1] := nil;
  Result.Next := FBlockHead[Start];
  FBlockHead[Start] := FBlockCount;
  Inc(FBlockCount);
  var SLo := FScalarLo;
  var SHi := FScalarHi;
  var VLo := FVectorLo;
  var VHi := FVectorHi;
  var LoadHistory := FLoadHistory;
  var SingleIssue := FSingleIssue;
  var Count := 0;
  // Words looked at from Start on.
  var Words := 0;
  var Branched := False;
  while Count < MaxSteps do
  begin
    var Slot := Integer((PC shr 2) and 1023);
    var NextSlot := (Slot + 1) and 1023;
    DecodedSlot(Slot);
    Words := Max(Words, ((Slot - Start) and 1023) + 1);
    var Op := FDec[Slot].Op;
    var Second: Cardinal := 0;
    var Pair := False;
    var Masks: ^TRSPIssueMasks := @FDec[Slot].Single;
    if (SingleIssue = 0) and ((FDec[Slot].Info.Flags and 4) = 0) then
    begin
      DecodedSlot(NextSlot);
      Words := Max(Words, ((NextSlot - Start) and 1023) + 1);
      if not FDec[Slot].PairValid or (FDec[Slot].SecondOp <> FDec[NextSlot].Op) then
        DecodePair(Slot);
      Pair := FDec[Slot].CanPair;
      Second := FDec[NextSlot].Op;
      if Pair then
        Masks := @FDec[Slot].Paired;
    end;
    // An external instruction is RunClocks' own business (journal, stops).
    if Masks.External then
      Break;
    var Flags := Masks.Flags;
    var Storing := (Flags and 2) <> 0;
    var Wait := 0;
    if (Storing and ((LoadHistory and 2) <> 0)) or ((Masks.Sources and (SLo or SHi)) <> 0) or
      ((Masks.Vectors and (VLo or VHi)) <> 0) then
    begin
      // As RunClocks (a scalar counter never reaches 3, a vector one does).
      var Sources := Masks.Sources;
      var Vectors := Masks.Vectors;
      if (Sources and SHi) <> 0 then
        Wait := 2 + Ord((Sources and SHi and SLo) <> 0)
      else if (Sources and SLo) <> 0 then
        Wait := 1;
      if (Vectors and VHi) <> 0 then
        Wait := Max(Wait, 2 + Ord((Vectors and VHi and VLo) <> 0))
      else if ((Vectors and VLo) <> 0) and (Wait = 0) then
        Wait := 1;
      if Wait = 0 then
        Wait := 1;
      if (Wait = 1) and Storing and ((LoadHistory and 1) <> 0) then
        Wait := 2;
      if Wait = 1 then
      begin
        var Lo := SLo;
        SLo := SHi and not Lo;
        SHi := SHi and Lo;
        Lo := VLo;
        VLo := VHi and not Lo;
        VHi := VHi and Lo;
        LoadHistory := (LoadHistory shl 1) and 3;
      end
      else if Wait = 2 then
      begin
        // As AgePipelineBy (what a 3 leaves, a 1, is gone after the issue
        // clock ages it again).
        SLo := SHi and SLo;
        SHi := 0;
        VLo := VHi and VLo;
        VHi := 0;
        LoadHistory := 0;
      end
      else
      begin
        SLo := 0;
        SHi := 0;
        VLo := 0;
        VHi := 0;
        LoadHistory := 0;
      end;
    end;
    var S: PRSPBlockStep := @FBlockSteps[FStepCount + Count];
    S.Op := Op;
    S.Second := Second;
    S.Pair := Pair;
    S.Wait := Wait;
    S.Kind := StepKind(Op);
    S.SecondKind := StepKind(Second);
    // The issue clock.
    var Lo := SLo;
    SLo := SHi and not Lo;
    SHi := SHi and Lo;
    Lo := VLo;
    VLo := VHi and not Lo;
    VHi := VHi and Lo;
    LoadHistory := (LoadHistory shl 1) and 3;
    var ScalarWrites := Masks.ScalarWrites and not Cardinal(1);
    SHi := SHi or ScalarWrites;
    SLo := SLo and not ScalarWrites;
    VHi := VHi or Masks.VectorWrites;
    VLo := VLo or Masks.VectorWrites;
    if (Flags and 1) <> 0 then
      LoadHistory := LoadHistory or 1;
    SingleIssue := Byte(Ord((Flags and 4) <> 0));
    S.ScalarLo := SLo;
    S.ScalarHi := SHi;
    S.VectorLo := VLo;
    S.VectorHi := VHi;
    S.LoadHistory := LoadHistory;
    S.SingleIssue := SingleIssue;
    Inc(Count);
    // A branch's delay slot is the last clock: where the branch goes is
    // only known as it runs.
    if Branched then
      Break;
    Branched := (Flags and 4) <> 0;
    PC := (PC + 4 + 4 * Cardinal(Ord(Pair))) and $FFC;
  end;
  for var I := 0 to Words - 1 do
    FBlockWords[FWordCount + I] := FDec[(Start + I) and 1023].Op;
  Result.Words := Words;
  Inc(FWordCount, Words);
  Result.Count := Count;
  Inc(FStepCount, Count);
end;

class function TN64RSP.StepKind(Op: Cardinal): Byte;
begin
  // How a block issues Op (IssueKind): the frequent vector instructions by
  // their own routines, other vector ones through VectorOp, vector loads and
  // stores through VectorMemory, the frequent scalar ones (no branches, no
  // COP0/COP2) in place, the rest through IssueInstruction (0).
  Result := 0;
  case Op shr 26 of
    0:
      case Op and 63 of
        0:
          Result := 25;
        2:
          Result := 26;
        3:
          Result := 27;
        32, 33:
          Result := 28;
        34, 35:
          Result := 29;
        36:
          Result := 30;
        37:
          Result := 31;
        38:
          Result := 32;
        39:
          Result := 33;
        42:
          Result := 34;
        43:
          Result := 35;
      end;
    8, 9:
      Result := 20;
    10:
      Result := 36;
    11:
      Result := 37;
    12:
      Result := 21;
    13:
      Result := 22;
    14:
      Result := 23;
    15:
      Result := 24;
    32:
      Result := 40;
    33:
      Result := 41;
    35:
      Result := 42;
    36:
      Result := 43;
    37:
      Result := 44;
    40:
      Result := 45;
    41:
      Result := 46;
    43:
      Result := 47;
    18:
      if ((Op shr 21) and 31) >= 16 then
        case Op and 63 of
          0, 1, 8, 9:
            Result := 14;
          4..7:
            Result := 4 + (Op and 3);
          12..15:
            Result := 8 + (Op and 3);
          16:
            Result := 12;
          17:
            Result := 13;
        else
          Result := 3;
        end;
    50:
      Result := 1;
    58:
      Result := 2;
  end;
end;

procedure TN64RSP.IssueKind(Kind: Byte; Op: Cardinal; var PC, Status, Interrupt: Cardinal);
begin
  // Issue (untraced) for Op of kind Kind (StepKind).
  if Kind = 0 then
    IssueInstruction(Op, PC, Status, Interrupt)
  else
  begin
    if FBranch then
    begin
      PC := FNextPC;
      FBranch := False
    end
    else
      PC := (PC + 4) and $FFC;
    case Kind of
      1:
        VectorMemory(Op, False);
      2:
        VectorMemory(Op, True);
      4:
        VectorMUDL(Op);
      5:
        VectorMUDM(Op);
      6:
        VectorMUDN(Op);
      7:
        VectorMUDH(Op);
      8:
        VectorMADL(Op);
      9:
        VectorMADM(Op);
      10:
        VectorMADN(Op);
      11:
        VectorMADH(Op);
      12:
        VectorAdd(Op);
      13:
        VectorSub(Op);
      14:
        VectorMulFrac(Op);
      20..47:
        begin
          IssueScalar(Kind, Op);
          FReg[0] := 0;
        end;
    else
      VectorOp(Op);
    end;
  end;
end;

procedure TN64RSP.IssueScalar(Kind: Byte; Op: Cardinal);
begin
  // The frequent scalar instructions (StepKind 20..47), as IssueInstruction
  // does them; it zeroes r0 after. Arithmetic wraps without overflow checks.
  var S := (Op shr 21) and 31;
  var T := (Op shr 16) and 31;
  case Kind of
    20:
      FReg[T] := Cardinal((UInt64(FReg[S]) + Cardinal(Integer(SmallInt(Op and $FFFF)))) and $FFFFFFFF);
    21:
      FReg[T] := FReg[S] and (Op and $FFFF);
    22:
      FReg[T] := FReg[S] or (Op and $FFFF);
    23:
      FReg[T] := FReg[S] xor (Op and $FFFF);
    24:
      FReg[T] := (Op and $FFFF) shl 16;
    25:
      FReg[(Op shr 11) and 31] := FReg[T] shl ((Op shr 6) and 31);
    26:
      FReg[(Op shr 11) and 31] := FReg[T] shr ((Op shr 6) and 31);
    27:
      begin
        var B := FReg[T];
        var N := (Op shr 6) and 31;
        if (B and $80000000) <> 0 then
          B := (B shr N) or not (Cardinal($FFFFFFFF) shr N)
        else
          B := B shr N;
        FReg[(Op shr 11) and 31] := B;
      end;
    28:
      FReg[(Op shr 11) and 31] := Cardinal((UInt64(FReg[S]) + FReg[T]) and $FFFFFFFF);
    29:
      FReg[(Op shr 11) and 31] := Cardinal((UInt64(FReg[S]) + UInt64($100000000) - FReg[T]) and $FFFFFFFF);
    30:
      FReg[(Op shr 11) and 31] := FReg[S] and FReg[T];
    31:
      FReg[(Op shr 11) and 31] := FReg[S] or FReg[T];
    32:
      FReg[(Op shr 11) and 31] := FReg[S] xor FReg[T];
    33:
      FReg[(Op shr 11) and 31] := not (FReg[S] or FReg[T]);
    34:
      FReg[(Op shr 11) and 31] := Ord(Integer(FReg[S]) < Integer(FReg[T]));
    35:
      FReg[(Op shr 11) and 31] := Ord(FReg[S] < FReg[T]);
    36:
      FReg[T] := Ord(Integer(FReg[S]) < Integer(SmallInt(Op and $FFFF)));
    37:
      FReg[T] := Ord(FReg[S] < Cardinal(Integer(SmallInt(Op and $FFFF))));
  else
    begin
      // Loads and stores: big-endian bytes, each address wrapped in DMEM.
      var Address := ((FReg[S] and $FFF) + (Op and $FFF)) and $FFF;
      case Kind of
        40:
          FReg[T] := Cardinal(Integer(ShortInt(DMemRead(Address))));
        41:
          FReg[T] := Cardinal(Integer(SmallInt((Word(DMemRead(Address)) shl 8) or DMemRead((Address + 1) and $FFF))));
        42:
          FReg[T] := (Cardinal(DMemRead(Address)) shl 24) or (Cardinal(DMemRead((Address + 1) and $FFF)) shl 16) or
            (Cardinal(DMemRead((Address + 2) and $FFF)) shl 8) or DMemRead((Address + 3) and $FFF);
        43:
          FReg[T] := DMemRead(Address);
        44:
          FReg[T] := (Cardinal(DMemRead(Address)) shl 8) or DMemRead((Address + 1) and $FFF);
        45:
          DMemWrite(Address, Byte(FReg[T] and $FF));
        46:
          begin
            var V := FReg[T];
            DMemWrite(Address, Byte((V shr 8) and $FF));
            DMemWrite((Address + 1) and $FFF, Byte(V and $FF));
          end;
      else
        begin
          var V := FReg[T];
          DMemWrite(Address, Byte(V shr 24));
          DMemWrite((Address + 1) and $FFF, Byte((V shr 16) and $FF));
          DMemWrite((Address + 2) and $FFF, Byte((V shr 8) and $FF));
          DMemWrite((Address + 3) and $FFF, Byte(V and $FF));
        end;
      end;
    end;
  end;
end;

function TN64RSP.RunBlock(B: PRSPBlock; var PC, Status, Interrupt: Cardinal; Cycles: Integer; Ahead: Boolean;
  var Ran: Integer): Integer;
begin
  // Block B's clocks as RunClocks takes them, then those of the blocks after
  // it, up to Cycles in all (Ran so far): 0 when they ran as far as the
  // budget allows, 1 before a stall longer than the budget left, 3 before a
  // clock no block takes (RunClocks takes those), 2 when a fence stopped the
  // window (FAheadStop). The pipeline is set after the last clock run, and
  // before a fence as RunClocks leaves it there.
  while True do
  begin
    Result := 0;
    Inc(FBlocksRun);
    var Before := Ran;
    var S: PRSPBlockStep := @FBlockSteps[B.First];
    var Last: PRSPBlockStep := @FBlockSteps[B.First + B.Count - 1];
    var Done: PRSPBlockStep := nil;
    // A branch is pending only before the last clock (its delay slot).
    var DelaySlot := False;
    while True do
    begin
      if S.Wait > 0 then
      begin
        if S.Wait >= Cycles - Ran then
        begin
          Result := 1;
          Break;
        end;
        FStalledOpcode := S.Op;
        FStalledPC := PC;
        FStalledSecondOpcode := S.Second;
        Inc(Ran, S.Wait);
      end;
      if Ahead and FFenced and not FReplaying and (TouchesFence(S.Op) or (S.Pair and TouchesFence(S.Second))) then
      begin
        // The pipeline after the stall, the words held.
        if Done <> nil then
        begin
          FScalarLo := Done.ScalarLo;
          FScalarHi := Done.ScalarHi;
          FVectorLo := Done.VectorLo;
          FVectorHi := Done.VectorHi;
          FLoadHistory := Done.LoadHistory;
          FSingleIssue := Done.SingleIssue;
          FHasStalledOpcode := False;
          FHasStalledSecondOpcode := False;
        end;
        if S.Wait > 0 then
        begin
          AgePipelineBy(S.Wait);
          FHasStalledOpcode := True;
          FHasStalledSecondOpcode := S.Pair;
        end;
        if not LiftFence(PC, S.Op, S.Second, S.Pair, FClockBase + Ran + 1) then
        begin
          FAheadStop := TRSPAheadStop.Fence;
          Inc(FBlockClocks, Ran - Before);
          Exit(2);
        end;
      end;
      if S = Last then
        DelaySlot := FBranch;
      IssueKind(S.Kind, S.Op, PC, Status, Interrupt);
      if S.Pair then
        IssueKind(S.SecondKind, S.Second, PC, Status, Interrupt);
      Inc(Ran);
      Done := S;
      if (S = Last) or (Ran >= Cycles) then
        Break;
      Inc(S);
    end;
    if Done <> nil then
    begin
      FScalarLo := Done.ScalarLo;
      FScalarHi := Done.ScalarHi;
      FVectorLo := Done.VectorLo;
      FVectorHi := Done.VectorHi;
      FLoadHistory := Done.LoadHistory;
      FSingleIssue := Done.SingleIssue;
      FHasStalledOpcode := False;
      FHasStalledSecondOpcode := False;
      if DelaySlot then
      begin
        FBranchBubble := 1;
        if (PC and 4) <> 0 then
          FSingleIssue := 1;
      end;
    end;
    Inc(FBlockClocks, Ran - Before);
    if Assigned(FOnBlock) then
      FOnBlock(Ran);
    if (Result <> 0) or (Done <> Last) or (Ran >= Cycles) then
      Exit;
    // The block ran to its end: its bubble, as RunClocks takes it (the
    // checkpoint is taken).
    var Taken := 0;
    if FBranchBubble > 0 then
    begin
      Taken := 1;
      Dec(FBranchBubble);
      AgePipeline;
      Inc(Ran);
      if Ran >= Cycles then
        Exit;
    end;
    // A branch still pending (in the delay slot, or its delay slot external,
    // or the block cut at its longest): RunClocks.
    if FBranch then
      Exit(3);
    // The next block: the one that came here before, else found.
    var Slot := Integer((PC shr 2) and 1023);
    var Next := B.Link[Taken];
    if (Next = nil) or (B.LinkPC[Taken] <> PC) or not BlockValid(Next, Slot) then
    begin
      var Gen := FBlockGen;
      Next := FindBlock(PC);
      // (Not if B went with the blocks dropped for room.)
      if FBlockGen = Gen then
      begin
        B.Link[Taken] := Next;
        B.LinkPC[Taken] := PC;
      end;
    end;
    {$IFDEF N64_CHECKED}
    if (Next.ScalarLo <> FScalarLo) or (Next.ScalarHi <> FScalarHi) or (Next.VectorLo <> FVectorLo) or
      (Next.VectorHi <> FVectorHi) or (Next.LoadHistory <> FLoadHistory) or (Next.SingleIssue <> FSingleIssue) then
      raise EInvalidOpException.Create('RSP block linked to another pipeline state');
    {$ENDIF}
    if Next.Count = 0 then
      Exit(3);
    B := Next;
  end;
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
  Move(FAcc, FCheckpoint.Acc, SizeOf(FAcc));
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
  // After the copy (full barrier), for LineSaved on another thread.
  TInterlocked.Exchange(Integer(FLineRun[Offset shr 6]), Integer(FRun));
end;

procedure TN64RSP.NewRun;
begin
  // A new run: no DMEM line saved yet.
  if FRun = High(Cardinal) then
  begin
    for var I := 0 to High(FLineRun) do
      FLineRun[I] := 0;
    FRun := 0;
  end;
  Inc(FRun);
  FRunFresh := True;
end;

function TN64RSP.LineSaved(Offset: Cardinal): Boolean;
begin
  Result := Cardinal(TInterlocked.CompareExchange(Integer(FLineRun[(Offset and $FFF) shr 6]), 0, 0)) = FRun;
end;

function TN64RSP.JournalCOP0(Op, Second: Cardinal; Pair: Boolean; Clock: Integer): Boolean;
begin
  // A clock that issues an external instruction runs ahead only if that is
  // its one external instruction and an MFC0 whose value is known or an
  // MTC0 the console applies later: from the journal in a replay, else as
  // OnPredict or OnDefer allow (then journalled).
  Result := False;
  var Access := Op;
  if not External(Op) then
    Access := Second
  else if Pair and External(Second) then
    Exit;
  var Kind := (Access shr 21) and 31;
  if ((Access shr 26) <> 16) or not (Kind in [0, 4]) then
    Exit;
  var Index := Integer((Access shr 11) and 15);
  var Write := Kind = 4;
  var Value: Cardinal := 0;
  if FReplaying then
  begin
    // Lifted fences are not checked in a replay.
    while (FReplayPos < FJournalCount) and FJournal[FReplayPos].Lift do
      Inc(FReplayPos);
    if (FReplayPos >= FJournalCount) or (FJournal[FReplayPos].Clock <> Clock) or (FJournal[FReplayPos].Index <> Index) or
      (FJournal[FReplayPos].Write <> Write) then
      if FReplayPos >= FJournalCount then
        raise EInvalidOpException.CreateFmt('RSP rewind replay diverged from the journal: clock %d index %d write %s past its %d entries', [Clock, Index, BoolToStr(Write, True), FJournalCount])
      else
        raise EInvalidOpException.CreateFmt('RSP rewind replay diverged from the journal: clock %d index %d write %s, entry %d of %d: clock %d index %d write %s',
          [Clock, Index, BoolToStr(Write, True), FReplayPos, FJournalCount, FJournal[FReplayPos].Clock, FJournal[FReplayPos].Index, BoolToStr(FJournal[FReplayPos].Write, True)]);
    Value := FJournal[FReplayPos].Value;
    Inc(FReplayPos);
  end
  else
  begin
    // A full journal ends the window (room for a lift entry and this one).
    if FJournalCount >= JournalCapacity - 2 then
      Exit;
    if Write then
    begin
      // The MTC0 is its clock's one scalar-unit instruction: its source
      // register holds the value it writes.
      Value := FReg[(Access shr 16) and 31];
      if not Assigned(FDefer) or not FDefer(Index, Clock, Value) then
        Exit;
    end
    else if not Assigned(FPredict) or not FPredict(Index, Clock, Value) then
      Exit;
    AddJournal(Clock, Index, Value, Write, False);
  end;
  if Write then
    FWritePending := True
  else
  begin
    FReadValue := Value;
    FReadPending := True;
  end;
  Result := True;
end;
procedure TN64RSP.AddFence(Offset, Count: Cardinal; Reads: Boolean; Source: Byte);
begin
  if Count = 0 then
    Exit;
  var Flags: Byte := 2 or (Source shl 2);
  if Reads then
    Flags := Flags or 1;
  for var Group := Integer(Offset shr 3) to Integer((Offset + Count - 1) shr 3) do
    FFence[Group and 511] := FFence[Group and 511] or Flags;
  FFenced := True;
end;

function TN64RSP.WroteAhead(Offset, Count: Cardinal): Boolean;
begin
  Result := False;
  if not FAhead or (Count = 0) then
    Exit;
  for var Line := Integer(Offset shr 6) to Integer((Offset + Count - 1) shr 6) do
    if FLineRun[Line and 63] = FRun then
      Exit(True);
end;

function TN64RSP.ReadFenced(Offset, Count: Cardinal): Boolean;
begin
  Result := False;
  if not FFenced or (Count = 0) then
    Exit;
  for var Group := Integer(Offset shr 3) to Integer((Offset + Count - 1) shr 3) do
    if (FFence[Group and 511] and 1) <> 0 then
      Exit(True);
end;

function TN64RSP.TouchesFence(Op: Cardinal): Boolean;
begin
  // Whether a scalar or vector load or store may touch a fenced line: the
  // exact bytes of a scalar access; for a vector one, 32 bytes around its
  // address that hold every byte any form touches. A
  // load/store is the scalar unit's instruction of its clock, so the base
  // register is as before the clock.
  var Code := Op shr 26;
  var Address, Last: Cardinal;
  var Writing: Boolean;
  case Code of
    32, 33, 35..37, 39, 40, 41, 43:
      begin
        Address := ((FReg[(Op shr 21) and 31] and $FFF) + (Op and $FFF)) and $FFF;
        var Size: Cardinal := 1;
        if Code in [33, 37, 41] then
          Size := 2
        else if Code in [35, 39, 43] then
          Size := 4;
        Last := Address + Size - 1;
        Writing := Code >= 40;
      end;
    50, 58:
      begin
        var Kind := (Op shr 11) and 31;
        var Size: Integer := 16;
        if Kind <= 3 then
          Size := 1 shl Kind
        else if Kind in [6, 7] then
          Size := 8;
        var Offset := Integer(SignedValue(SX(Op and 127, 7)));
        // From 16 bytes below (LRV/SRV) to 16 above the 8-byte group.
        Address := Cardinal(Add64(FReg[(Op shr 21) and 31], SX(UInt64((Int64(Offset) * Size) and $FFFFFFFF), 32)) and $FF0);
        Last := Address + 31;
        Writing := Code = 58;
      end;
  else
    Exit(False);
  end;
  var Flags: Byte := 1;
  if Writing then
    Flags := 2;
  for var Group := Integer(Address shr 3) to Integer(Last shr 3) do
    if (FFence[Group and 511] and Flags) <> 0 then
    begin
      FAheadStopIndex := Flags or (FFence[Group and 511] and not Cardinal(3));
      Exit(True);
    end;
  Result := False;
end;

procedure TN64RSP.AddJournal(Clock, Index: Integer; Value: Cardinal; Write, Lift: Boolean);
begin
  if FJournalCount >= JournalCapacity then
    raise EInvalidOpException.Create('RSP journal full');
  FJournal[FJournalCount].Clock := Clock;
  FJournal[FJournalCount].Index := Index;
  FJournal[FJournalCount].Value := Value;
  FJournal[FJournalCount].Write := Write;
  FJournal[FJournalCount].Lift := Lift;
  Inc(FJournalCount);
end;

function TN64RSP.LiftFence(PC, Op, Second: Cardinal; Pair: Boolean; Clock: Integer): Boolean;
begin
  // A clock stopped by a fence: the console may lift the fences of DMA it
  // expects done by then (writing DMEM through WriteAhead, hence the
  // checkpoint first).
  Result := False;
  if not Assigned(FLift) or (FJournalCount >= JournalCapacity - 2) then
    Exit;
  if not FCheckpointed then
    SaveCheckpoint(PC);
  FFencedOp := Op;
  FFencedSecond := Second;
  FFencedPair := Pair;
  if not FLift(Clock) then
    Exit;
  if ClockFenced then
    raise EInvalidOpException.Create('RSP clock still fenced after a lift');
  AddJournal(Clock, -1, 0, False, True);
  Result := True;
end;

function TN64RSP.ClockFenced: Boolean;
begin
  Result := FFenced and (TouchesFence(FFencedOp) or (FFencedPair and TouchesFence(FFencedSecond)));
end;

procedure TN64RSP.WriteAhead(Offset: Cardinal; Value: Byte);
begin
  if not FAhead then
    raise EInvalidOpException.Create('RSP DMEM write ahead outside a window');
  DMemWrite(Offset and $FFF, Value);
end;

procedure TN64RSP.ClearFences;
begin
  if FFenced then
  begin
    FillChar(FFence, SizeOf(FFence), 0);
    FFenced := False;
  end;
end;

function TN64RSP.Journal: PRSPJournal;
begin
  Result := PRSPJournal(@FJournal[0]);
end;

function TN64RSP.JournalCount: Integer;
begin
  Result := FJournalCount;
end;

function TN64RSP.JournalEntry(I: Integer): TRSPJournalEntry;
begin
  Result := FJournal[I];
end;

function TN64RSP.RunAhead(var PC: Cardinal; Status: Cardinal; Cycles: Integer): Integer;
begin
  if (Status and $21) <> 0 then
    raise EInvalidOpException.Create('RSP run-ahead while halted or single-stepping');
  // The fences set for this window stay.
  if not FRunFresh then
    NewRun;
  FRunFresh := False;
  FAhead := False;
  FCheckpointed := False;
  FJournalCount := 0;
  FReadPending := False;
  FWritePending := False;
  var Interrupt: Cardinal := 0;
  FAheadStop := TRSPAheadStop.Budget;
  FClockBase := 0;
  Result := RunClocks(PC, Status, Interrupt, Cycles, True);
  FAheadClocks := Result;
  if (FAheadStop = TRSPAheadStop.Budget) and (Result < Cycles) then
    FAheadStop := TRSPAheadStop.Halt;
  // Without a clock run nothing was saved or changed.
  if Result = 0 then
    EndAhead;
end;

function TN64RSP.ContinueAhead(var PC: Cardinal; Status: Cardinal; Cycles: Integer): Integer;
begin
  if not FAhead or (FAheadStop <> TRSPAheadStop.Budget) then
    raise EInvalidOpException.Create('RSP window continued after it stopped');
  var Interrupt: Cardinal := 0;
  FClockBase := FAheadClocks;
  Result := RunClocks(PC, Status, Interrupt, Cycles, True);
  Inc(FAheadClocks, Result);
  if (FAheadStop = TRSPAheadStop.Budget) and (Result < Cycles) then
    FAheadStop := TRSPAheadStop.Halt;
end;

procedure TN64RSP.Rewind(var PC: Cardinal; Keep: Integer);
begin
  Rewind(PC, Keep, [], nil);
end;

procedure TN64RSP.Rewind(var PC: Cardinal; Keep: Integer; const Stops: array of Integer; OnStop: TRSPReplayStop);
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
  Move(FCheckpoint.Acc, FAcc, SizeOf(FAcc));
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
  if Assigned(OnStop) then
    OnStop(-1);
  // The same free clocks again, up to the current point, with the reads
  // of the journal (all of them verified by then).
  var Status: Cardinal := 0;
  var Interrupt: Cardinal := 0;
  FReplaying := True;
  FReplayPos := 0;
  try
    var Done := 0;
    for var I := 0 to High(Stops) do
    begin
      if (Stops[I] < Done) or (Stops[I] > Keep) then
        raise EInvalidOpException.Create('RSP rewind stops out of order');
      FClockBase := Done;
      if RunClocks(PC, Status, Interrupt, Stops[I] - Done, True) <> Stops[I] - Done then
        raise EInvalidOpException.Create('RSP rewind replay diverged');
      Done := Stops[I];
      OnStop(I);
    end;
    FClockBase := Done;
    if RunClocks(PC, Status, Interrupt, Keep - Done, True) <> Keep - Done then
      raise EInvalidOpException.Create('RSP rewind replay diverged');
  finally
    FReplaying := False;
  end;
  EndAhead;
end;

procedure TN64RSP.EndAhead;
begin
  FAhead := False;
  FCheckpointed := False;
  FJournalCount := 0;
  FReadPending := False;
  FWritePending := False;
  ClearFences;
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
    PlanesToArrays;
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
    ArraysToPlanes;
  end;
end;

end.

