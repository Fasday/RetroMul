unit PSP.CPU.JIT;

// Allegrex blocks as generated code (HW.JIT), run in place of the
// interpreter's loop (TPSPCPU.Runner) with its accounting exactly.
//
// A block starts where the interpreter's PC is with NPC = PC + 4 and runs
// up to a branch and its delay slot, an instruction that calls the kernel
// (SYSCALL, BREAK, HALT, a reserved one), its page's end or MaxBlock words.
// It is made from the interpreter's decoded entries once it has been entered
// Hot times (until then the interpreter runs it). Its code takes all its
// cycles from the budget on entry where they fit (else the interpreter runs
// what is left of the budget) and gives back those of a likely branch's
// nullified delay slot. The common integer instructions, branches, jumps and
// aligned-or-not loads and stores through the page table are written out;
// every other instruction calls the interpreter's handler (DecodeOp) with
// PC, NPC and CurPC as the interpreter has them. A store that reaches a code
// page goes through TPSPMemory (which re-decodes); when it rewrote a block
// the block stops after it. After its last instruction a block goes on into
// the next block's code: by direct links (made the first time that way is
// taken) or, after JR/JALR, by a look-up of the block table; else back to
// Run. Blocks are dropped when their words are written (CodeWritten) or the
// decoded code is (Flushed).
//
// PSPJIT=off (the interpreter), model (HW.JIT's model runs the code), stats
// (counts at the end); several with commas.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
// (Guest addresses wrap.)
{$Q-}
{$POINTERMATH ON}

interface

uses
  System.SysUtils, System.Generics.Collections, HW.JIT, PSP.Types, PSP.Memory, PSP.CPU;

const
  PSPJitMaxBlock = 128;

type
  PPSPJitBlock = ^TPSPJitBlock;
  PPSPJitExit = ^TPSPJitExit;

  // A way out of a block's code to a known PC: its jump (Site) goes to its
  // stub (back to Run) or, linked, into the code of the block at Target.
  TPSPJitExit = record
    Block: PPSPJitBlock;
    Target: Cardinal;
    Site, Stub: NativeInt;
    Linked: PPSPJitBlock;
  end;

  TPSPJitState = (bsCold, bsCompiled, bsNone, bsDead);

  TPSPJitBlock = record
    PC: Cardinal;
    Code: Pointer;
    Physical: Cardinal;
    // Instructions (all of them run: its cycles), entries since made.
    Count, Heat: Integer;
    State: TPSPJitState;
    Exits: TArray<PPSPJitExit>;
    Incoming: TList<PPSPJitExit>;
  end;

  PPSPJitPage = ^TPSPJitPage;
  TPSPJitPage = record
    Entries: array[0..(PSPPageSize div 4) - 1] of PPSPJitBlock;
    // Words that compiled blocks cover.
    Covered: array[0..(PSPPageSize div 128) - 1] of Cardinal;
    Blocks: TList<PPSPJitBlock>;
  end;

  TPSPJitOption = (joModel, joStats);
  TPSPJitOptions = set of TPSPJitOption;

  // Where an instruction is, and the PC after it (Dynamic: in the Target
  // register) and the cycles given back when the code leaves after it.
  TPSPJitAt = record
    Addr, Next: Cardinal;
    Dynamic: Boolean;
    Refund: Integer;
  end;

  // An access's way out of line (no page, or a store into code).
  TPSPJitSlow = record
    Slow, Back, Hit: TJitLabel;
    Routine: Pointer;
    Store: Boolean;
    // The register loaded or stored (a GPR or an FPR).
    Reg: TJitOp;
  end;

  TPSPJitHitExit = record
    L: TJitLabel;
    At: TPSPJitAt;
  end;

  TPSPRecompiler = class(TPSPRunner)
  private
    FCPU: TPSPCPU;
    FMemory: TPSPMemory;
    FJ: TJitAsm;
    FOptions: TPSPJitOptions;
    FEnabled: Boolean;
    // Set when a block is dropped (the code running leaves after the store).
    FHit: Byte;
    FInCode, FInRun, FResetPending: Boolean;
    FLastExit: PPSPJitExit;
    FPages: TArray<PPSPJitPage>;
    FAll: TList<PPSPJitBlock>;
    FAllExits: TList<PPSPJitExit>;
    FEnter, FPrologue, FExit, FLookup: NativeInt;
    FCompiled, FInvokes, FInterpreted, FLinks, FKills, FResets: Int64;
    FDead: Integer;
    // While a block is written: what goes out of line.
    FSlow: TList<TPSPJitSlow>;
    FHitExits: TList<TPSPJitHitExit>;
    FStatic: TList<PPSPJitExit>;
    FBlock: PPSPJitBlock;
    function PageOf(PC: Cardinal): PPSPJitPage;
    function Lookup(PC: Cardinal): PPSPJitBlock;
    function Scan(PC: Cardinal): Integer;
    procedure Kill(B: PPSPJitBlock);
    procedure KillAll;
    procedure ResetCode;
    procedure Link(E: PPSPJitExit; B: PPSPJitBlock);
    procedure EmitShared;
    procedure Compile(B: PPSPJitBlock);
    procedure Execute(B: PPSPJitBlock);
    procedure RunBlocks(C: TPSPCPU);
    procedure Interpret(Steps: Integer);
    procedure SetEnabled(Value: Boolean);
    procedure Cover(Page: PPSPJitPage; B: PPSPJitBlock);
    procedure Recover(Page: PPSPJitPage);
    procedure WriteState(const At: TPSPJitAt);
    function HitExit(const At: TPSPJitAt): TJitLabel;
    procedure EmitCall(const At: TPSPJitAt; Op: Cardinal; Handler: Pointer);
    procedure EmitLoad(Op: Cardinal; Kind: Integer; const Reg: TJitOp);
    procedure EmitStore(const At: TPSPJitAt; Op: Cardinal; Kind: Integer; const Reg: TJitOp);
    function EmitInstr(const At: TPSPJitAt; Op: Cardinal; Kind: Integer; Handler: Pointer): Boolean;
    procedure EmitStatic(Target, Last: Cardinal; Refund: Integer);
    procedure EmitDelay(A: Cardinal; Op: Cardinal; Kind: Integer; Handler: Pointer; Dynamic: Boolean; Next: Cardinal);
  public
    constructor Create(CPU: TPSPCPU; Options: TPSPJitOptions);
    destructor Destroy; override;
    procedure Run(C: TPSPCPU); override;
    procedure CodeWritten(Address, Size: Cardinal); override;
    procedure Flushed; override;
    // False: Run interprets (the blocks are kept).
    property Enabled: Boolean read FEnabled write SetEnabled;
    property Compiled: Int64 read FCompiled;
    property Invokes: Int64 read FInvokes;
    property Interpreted: Int64 read FInterpreted;
  end;

var
  // Entries before a block is compiled.
  PSPJitHot: Integer = 8;

// PSPJIT's options; Off when it says off.
function PSPJitOptions(out Off: Boolean): TPSPJitOptions;
// A recompiler for CPU as PSPJIT asks (nil: off, or no code generator here
// and no model asked for). It sets itself as CPU's runner.
function CreatePSPRecompiler(CPU: TPSPCPU): TPSPRecompiler;

implementation

type
  TJitKind = (jkNop, jkHandler, jkPure, jkEnd, jkHBranch,
    jkSLL, jkSRL, jkSRA, jkROTR, jkMOVZ, jkMOVN, jkMFHI, jkMTHI, jkMFLO, jkMTLO,
    jkADDU, jkSUBU, jkAND, jkOR, jkXOR, jkNOR, jkSLT, jkSLTU, jkMAX, jkMIN,
    jkADDIU, jkSLTI, jkSLTIU, jkANDI, jkORI, jkXORI, jkLUI, jkMFC0,
    jkEXT, jkINS, jkWSBH, jkWSBW, jkSEB, jkSEH,
    jkLB, jkLH, jkLW, jkLBU, jkLHU, jkSB, jkSH, jkSW, jkLWC1, jkSWC1, jkMFC1, jkMTC1,
    jkJR, jkJALR, jkJ, jkJAL, jkB, jkBEQ, jkBNE, jkBLEZ, jkBGTZ, jkBLTZ, jkBGEZ, jkBLTZAL, jkBGEZAL,
    jkBEQL, jkBNEL, jkBLEZL, jkBGTZL, jkBLTZL, jkBGEZL, jkBLTZALL, jkBGEZALL);

const
  // An instruction of each kind the code writes out: its handler (DecodeOp)
  // is the kind's.
  KindSample: array[jkSLL..jkBGEZALL] of Cardinal = (
    $00000800, $00000802, $00000803, $00200802, $0000080A, $0000080B, $00000810, $00000011, $00000812, $00000013,
    $00000821, $00000823, $00000824, $00000825, $00000826, $00000827, $0000082A, $0000082B, $0000082C, $0000082D,
    $24010000, $28010000, $2C010000, $30010000, $34010000, $38010000, $3C010000, $40010000,
    $7C010000, $7C010004, $7C0008A0, $7C0008E0, $7C000C20, $7C000E20,
    $80010000, $84010000, $8C010000, $90010000, $94010000, $A0000000, $A4000000, $AC000000,
    $C4000000, $E4000000, $44010000, $44800000,
    $00000008, $00000009, $08000000, $0C000000, $10000000, $10200000, $14000000, $18000000, $1C000000,
    $04000000, $04010000, $04100000, $04110000,
    $50000000, $54000000, $58000000, $5C000000, $04020000, $04030000, $04120000, $04130000);
  // SYSCALL, BREAK, HALT.
  EndSample: array[0..2] of Cardinal = ($0000000C, $0000000D, $70000000);
  // Handlers that read no PC and raise nothing (called without writing PC,
  // NPC and CurPC first): SLLV, SRLV, ROTRV, SRAV, CLZ, CLO, MULT, MULTU,
  // DIV, DIVU, MADD, MADDU, MSUB, MSUBU, BITREV, LWL, LWR, SWL, SWR, LL, SC,
  // MFIC, MTIC.
  PureSample: array[0..22] of Cardinal = ($00000804, $00000806, $00000846, $00000807, $00000816, $00000817,
    $00000018, $00000019, $0000001A, $0000001B, $0000001C, $0000001D, $0000002E, $0000002F, $7C000D20,
    $88010000, $98010000, $A8000000, $B8000000, $C0010000, $E0010000, $70010024, $70000026);

  JitBufferSize = 64 * 1024 * 1024;
  MaxDead = 65536;

  // A host pointer's width (the model runs on 32-bit hosts too).
  {$IFDEF CPU64BITS}
  JPtr = jw64;
  PtrShift = 3;
  {$ELSE}
  JPtr = jw32;
  PtrShift = 2;
  {$ENDIF}

  jrPages = jrS0;
  jrMarks = jrS1;
  jrTarget = jrS2;
  JPages: TJitOp = (Kind: okReg; Reg: jrPages);
  JMarks: TJitOp = (Kind: okReg; Reg: jrMarks);
  JTarget: TJitOp = (Kind: okReg; Reg: jrTarget);

var
  KindHandler: array[jkSLL..jkBGEZALL] of Pointer;
  EndHandler: array[0..2] of Pointer;
  PureHandler: array[0..High(PureSample)] of Pointer;
  KindsReady: Boolean;
  OffGPR, OffFPR, OffHI, OffLO, OffPC, OffNPC, OffCurPC, OffRemaining, OffHit, OffLastExit, OffBlockPC, OffBlockCode: Integer;

function HandlerOf(Op: Cardinal): Pointer;
begin
  var H: TPSPOpHandler := DecodeOp(Op);
  Result := @H;
end;

procedure PrepareKinds;
begin
  if KindsReady then
    Exit;
  for var K := Low(KindSample) to High(KindSample) do
    KindHandler[K] := HandlerOf(KindSample[K]);
  for var I := 0 to High(EndSample) do
    EndHandler[I] := HandlerOf(EndSample[I]);
  for var I := 0 to High(PureSample) do
    PureHandler[I] := HandlerOf(PureSample[I]);
  OffGPR := Integer(NativeUInt(@TPSPCPU(nil).Ctx.GPR[0]));
  OffFPR := Integer(NativeUInt(@TPSPCPU(nil).Ctx.FPR[0]));
  OffHI := Integer(NativeUInt(@TPSPCPU(nil).Ctx.HI));
  OffLO := Integer(NativeUInt(@TPSPCPU(nil).Ctx.LO));
  OffPC := Integer(NativeUInt(@TPSPCPU(nil).Ctx.PC));
  OffNPC := Integer(NativeUInt(@TPSPCPU(nil).Ctx.NPC));
  OffCurPC := Integer(NativeUInt(@TPSPCPU(nil).CurPC));
  OffRemaining := Integer(NativeUInt(@TPSPCPU(nil).FRemaining));
  OffHit := Integer(NativeUInt(@TPSPRecompiler(nil).FHit));
  OffLastExit := Integer(NativeUInt(@TPSPRecompiler(nil).FLastExit));
  OffBlockPC := Integer(NativeUInt(@PPSPJitBlock(nil).PC));
  OffBlockCode := Integer(NativeUInt(@PPSPJitBlock(nil).Code));
  KindsReady := True;
end;

function Classify(Op: Cardinal; out Handler: Pointer): TJitKind;
begin
  Handler := HandlerOf(Op);
  if Handler = @OpNop then
    Exit(jkNop);
  if Handler = @OpReserved then
    Exit(jkEnd);
  for var I := 0 to High(EndHandler) do
    if Handler = EndHandler[I] then
      Exit(jkEnd);
  for var K := Low(KindHandler) to High(KindHandler) do
    if Handler = KindHandler[K] then
      Exit(K);
  // COP1 and VFPU branches (BC1x, BVx): their handlers decide.
  if ((Op shr 26) in [$11, $12]) and (((Op shr 21) and 31) = 8) then
    Exit(jkHBranch);
  for var I := 0 to High(PureHandler) do
    if Handler = PureHandler[I] then
      Exit(jkPure);
  Result := jkHandler;
end;

function IsBranch(K: TJitKind): Boolean; inline;
begin
  Result := (K = jkHBranch) or (K >= jkJR);
end;

function IsLikely(K: TJitKind): Boolean; inline;
begin
  Result := K >= jkBEQL;
end;

// Whether a handler of this instruction may store (the code then checks
// whether a block was rewritten).
function MayStore(Op: Cardinal): Boolean;
begin
  Result := not ((Op shr 26) in [$00, $10, $11, $1C, $1F, $20..$27, $30, $31, $32, $35, $36]);
end;

{ Slow accesses (the page table has no page, or a store reaches code) }

function JitRead8(M: TPSPMemory; A: Cardinal): NativeUInt;
begin
  Result := M.Read8(A);
end;

function JitRead16(M: TPSPMemory; A: Cardinal): NativeUInt;
begin
  Result := M.Read16(A);
end;

function JitRead32(M: TPSPMemory; A: Cardinal): NativeUInt;
begin
  Result := M.Read32(A);
end;

function JitWrite8(R: TPSPRecompiler; A, V: Cardinal): NativeUInt;
begin
  R.FMemory.Write8(A, V);
  Result := R.FHit;
end;

function JitWrite16(R: TPSPRecompiler; A, V: Cardinal): NativeUInt;
begin
  R.FMemory.Write16(A, V);
  Result := R.FHit;
end;

function JitWrite32(R: TPSPRecompiler; A, V: Cardinal): NativeUInt;
begin
  R.FMemory.Write32(A, V);
  Result := R.FHit;
end;

{$I PSP.CPU.JIT.Emit.inc}
{$I PSP.CPU.JIT.Blocks.inc}

end.
