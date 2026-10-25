unit HW.JIT;

// Code generated at run time, for any core (the N64 CPU's blocks first). A
// core writes it in TJitAsm's few operations, over registers by role
// (TJitReg) and simple operands (TJitOp), and knows no host instruction. A
// backend turns them into one host's instructions and calling convention in
// executable memory, with unwind data so exceptions pass through the code:
// x64 instructions (TJitAsmX64) with the Win64 convention (TJitAsmWin64).
// Only Win64 has a backend (JitSupported); other targets compile the unit
// and make no code (CreateJitAsm is nil).

interface

{$Q-}{$R-}

uses
  System.SysUtils;

const
  JitSupported = {$IF DEFINED(MSWINDOWS) AND DEFINED(CPUX64)}True{$ELSE}False{$ENDIF};

type
  // Registers by role. The fixed ones keep their values across calls: Self
  // and Ctx (a function's two arguments, Enter), S0..S3 (the core's own), S4
  // where the backend has one more (Has). The scratch ones T0..T6 do not; a
  // call returns its result in T0.
  TJitReg = (jrSelf, jrCtx, jrS0, jrS1, jrS2, jrS3, jrT0, jrT1, jrT2, jrT3, jrT4, jrT5, jrT6, jrS4);

  // An operation's width: 8 and 32 bits zero-extend into a register.
  TJitWidth = (jw8, jw32, jw64);

  // An operand: a register, a constant, memory at Reg + Disp, or that address
  // as a value. At most one operand of an operation is in memory; constants
  // fit 32 bits (sign-extended to 64) but in Move to a register.
  TJitOpKind = (okReg, okImm, okMem, okAddr);
  TJitOp = record
    Kind: TJitOpKind;
    Reg: TJitReg;
    Disp: Integer;
    Imm: Int64;
  end;

  TJitAlu = (jaAdd, jaSub, jaAnd, jaOr, jaXor);
  TJitShift = (jsShl, jsShr);
  // After Branch's comparison of A with B: signed jcLt..jcGe, unsigned
  // jcBelow..jcAboveEq. After BranchTest of A and B: jcEq none of the bits,
  // jcNe some.
  TJitCond = (jcEq, jcNe, jcLt, jcLe, jcGt, jcGe, jcBelow, jcBelowEq, jcAbove, jcAboveEq);

  TJitLabel = Integer;

  // Code in one buffer of executable memory, written by the operations
  // below; a backend implements the abstract ones. Offsets are from the
  // buffer's start.
  TJitAsm = class abstract
  private
    FBase: PByte;
    FSize, FUsed, FCodeStart, FFlushed: NativeInt;
    // Labels: where each is (-1: not yet), and the jumps to ones not yet
    // bound (their fields). Kept from function to function, so that writing
    // code calls no memory manager once they are long enough.
    FLabelAt: TArray<NativeInt>;
    FFixLabel: TArray<TJitLabel>;
    FFixField: TArray<NativeInt>;
    FLabelCount, FFixCount: Integer;
    procedure Fix(Field: NativeInt; L: TJitLabel);
  protected
    procedure Need(Bytes: NativeInt); inline;
    procedure Emit(const Bytes: array of Byte);
    procedure D(V: Cardinal);
    procedure Q(V: UInt64);
    // The memory: Size bytes, code from CodeStart on.
    function Allocate(Size: NativeInt; out CodeStart: NativeInt): PByte; virtual; abstract;
    procedure Release(Base: PByte); virtual; abstract;
    procedure FlushCode(P: PByte; Len: NativeInt); virtual; abstract;
    // A comparison of A with B, a test of A and B; a jump (conditional on
    // the flags they leave) with a field for its target, which the result
    // is; that field's target, set and read.
    procedure EmitCompare(W: TJitWidth; const A, B: TJitOp); virtual; abstract;
    procedure EmitTest(W: TJitWidth; const A, B: TJitOp); virtual; abstract;
    function EmitJumpIf(Cond: TJitCond): NativeInt; virtual; abstract;
    function EmitJump: NativeInt; virtual; abstract;
    procedure PatchJump(Field, Target: NativeInt); virtual; abstract;
    function JumpTargetOf(Field: NativeInt): NativeInt; virtual; abstract;
    // A jump (conditional on the flags) to code written before.
    procedure EmitJumpIfTo(Cond: TJitCond; Target: NativeInt); virtual;
    // BranchTest's test and jump (its field), where a backend has one
    // instruction for some.
    function EmitTestJump(Cond: TJitCond; W: TJitWidth; const A, B: TJitOp): NativeInt; virtual;
    // Whether the backend has a register for S4.
    function HasS4: Boolean; virtual;
  public
    constructor Create(Size: NativeInt);
    destructor Destroy; override;
    // Drops all code.
    procedure Reset;
    function Room(Bytes: NativeInt): Boolean; inline;
    function Here: PByte; inline;
    function Offset: NativeInt; inline;
    procedure Align(N: Integer);

    // Dst := Src.
    procedure Move(W: TJitWidth; const Dst, Src: TJitOp); virtual; abstract;
    // Dst := Dst op Src.
    procedure Alu(Op: TJitAlu; W: TJitWidth; const Dst, Src: TJitOp); virtual; abstract;
    procedure Shift(Op: TJitShift; W: TJitWidth; Dst: TJitReg; Count: Integer); virtual; abstract;
    // A routine with up to four arguments (pointer-sized; memory ones read as
    // 64 bits); its result in T0, the scratch registers changed.
    procedure Call(Routine: Pointer; const Args: array of TJitOp); virtual; abstract;
    // As Call, the routine's address read from memory operand Routine (its
    // register not one the arguments change).
    procedure CallAt(const Routine: TJitOp; const Args: array of TJitOp); virtual; abstract;
    // A function's start: the fixed registers saved, Self and Ctx from its
    // two arguments. Its end: Value as its result, the fixed registers as
    // they were, back to its caller.
    procedure Enter; virtual; abstract;
    procedure Leave(const Value: TJitOp); virtual; abstract;
    // The start of a function of four arguments shared by many: as Enter,
    // then its fourth argument in T1 and on to the address in its third
    // (code that ends with Leave).
    procedure EnterJump; virtual; abstract;
    // To the address in Target.
    procedure JumpIndirect(const Target: TJitOp); virtual; abstract;
    // Whether role R has a register here.
    function Has(R: TJitReg): Boolean;
    // A hint before any code is written: Self's fields from Disp on are used
    // often (a backend with short displacements keeps a register there).
    procedure AddWindow(Disp: Integer); virtual;

    // Labels within the function being written; ForgetLabels before the next
    // (all of them bound by then).
    function NewLabel: TJitLabel;
    procedure Bind(L: TJitLabel);
    procedure ForgetLabels;
    procedure Branch(Cond: TJitCond; W: TJitWidth; const A, B: TJitOp; L: TJitLabel);
    procedure BranchTest(Cond: TJitCond; W: TJitWidth; const A, B: TJitOp; L: TJitLabel);
    procedure Jump(L: TJitLabel);
    // To code written before (its offset).
    procedure BranchTo(Cond: TJitCond; W: TJitWidth; const A, B: TJitOp; Target: NativeInt);
    procedure JumpTo(Target: NativeInt);
    // A jump to code written before that can be pointed elsewhere later
    // (Redirect): its site.
    function JumpSite(Target: NativeInt): NativeInt;
    function SiteTarget(Site: NativeInt): NativeInt;
    procedure Redirect(Site, Target: NativeInt);
    // The code written since the last Flush made ready to run.
    procedure Flush;
    property Size: NativeInt read FSize;
    property Base: PByte read FBase;
  end;

function JReg(Reg: TJitReg): TJitOp; inline;
function JImm(Value: Int64): TJitOp; inline;
function JMem(Base: TJitReg; Disp: Integer): TJitOp; inline;
function JAddr(Base: TJitReg; Disp: Integer): TJitOp; inline;

const
  JSelf: TJitOp = (Kind: okReg; Reg: jrSelf);
  JCtx: TJitOp = (Kind: okReg; Reg: jrCtx);
  JS0: TJitOp = (Kind: okReg; Reg: jrS0);
  JS1: TJitOp = (Kind: okReg; Reg: jrS1);
  JS2: TJitOp = (Kind: okReg; Reg: jrS2);
  JS3: TJitOp = (Kind: okReg; Reg: jrS3);
  JS4: TJitOp = (Kind: okReg; Reg: jrS4);
  JT0: TJitOp = (Kind: okReg; Reg: jrT0);
  JT1: TJitOp = (Kind: okReg; Reg: jrT1);
  JT2: TJitOp = (Kind: okReg; Reg: jrT2);
  JT3: TJitOp = (Kind: okReg; Reg: jrT3);
  JT4: TJitOp = (Kind: okReg; Reg: jrT4);
  JT5: TJitOp = (Kind: okReg; Reg: jrT5);
  JT6: TJitOp = (Kind: okReg; Reg: jrT6);

// This target's code generator with Size bytes of code (nil: none here).
function CreateJitAsm(Size: NativeInt): TJitAsm;

implementation

{$IF JitSupported}
uses
  {$IFDEF MSWINDOWS}Winapi.Windows{$ELSE}Posix.SysMman{$ENDIF};
{$ENDIF}

function JReg(Reg: TJitReg): TJitOp;
begin
  Result := Default(TJitOp);
  Result.Kind := okReg;
  Result.Reg := Reg;
end;

function JImm(Value: Int64): TJitOp;
begin
  Result := Default(TJitOp);
  Result.Kind := okImm;
  Result.Imm := Value;
end;

function JMem(Base: TJitReg; Disp: Integer): TJitOp;
begin
  Result := Default(TJitOp);
  Result.Kind := okMem;
  Result.Reg := Base;
  Result.Disp := Disp;
end;

function JAddr(Base: TJitReg; Disp: Integer): TJitOp;
begin
  Result := Default(TJitOp);
  Result.Kind := okAddr;
  Result.Reg := Base;
  Result.Disp := Disp;
end;

{ TJitAsm }

constructor TJitAsm.Create(Size: NativeInt);
begin
  inherited Create;
  FSize := Size;
  FBase := Allocate(Size, FCodeStart);
  Reset;
end;

destructor TJitAsm.Destroy;
begin
  if FBase <> nil then
    Release(FBase);
  inherited;
end;

procedure TJitAsm.Reset;
begin
  FUsed := FCodeStart;
  FFlushed := FCodeStart;
  FLabelCount := 0;
  FFixCount := 0;
end;

procedure TJitAsm.EmitJumpIfTo(Cond: TJitCond; Target: NativeInt);
begin
  PatchJump(EmitJumpIf(Cond), Target);
end;

function TJitAsm.EmitTestJump(Cond: TJitCond; W: TJitWidth; const A, B: TJitOp): NativeInt;
begin
  EmitTest(W, A, B);
  Result := EmitJumpIf(Cond);
end;

function TJitAsm.HasS4: Boolean;
begin
  Result := False;
end;

function TJitAsm.Has(R: TJitReg): Boolean;
begin
  Result := (R <> jrS4) or HasS4;
end;

procedure TJitAsm.AddWindow(Disp: Integer);
begin
end;

function TJitAsm.Room(Bytes: NativeInt): Boolean;
begin
  Result := (FBase <> nil) and (FUsed + Bytes <= FSize);
end;

procedure TJitAsm.Need(Bytes: NativeInt);
begin
  if FUsed + Bytes > FSize then
    raise EInvalidOpException.Create('JIT buffer overflow');
end;

function TJitAsm.Here: PByte;
begin
  Result := FBase + FUsed;
end;

function TJitAsm.Offset: NativeInt;
begin
  Result := FUsed;
end;

procedure TJitAsm.Align(N: Integer);
begin
  // (Filled with a breakpoint, never run.)
  while (FUsed and (N - 1)) <> 0 do
    Emit([$CC]);
end;

procedure TJitAsm.Emit(const Bytes: array of Byte);
begin
  Need(Length(Bytes));
  System.Move(Bytes[0], FBase[FUsed], Length(Bytes));
  Inc(FUsed, Length(Bytes));
end;

procedure TJitAsm.D(V: Cardinal);
begin
  Need(4);
  PCardinal(@FBase[FUsed])^ := V;
  Inc(FUsed, 4);
end;

procedure TJitAsm.Q(V: UInt64);
begin
  Need(8);
  PUInt64(@FBase[FUsed])^ := V;
  Inc(FUsed, 8);
end;

function TJitAsm.NewLabel: TJitLabel;
begin
  if FLabelCount = Length(FLabelAt) then
    SetLength(FLabelAt, FLabelCount * 2 + 64);
  FLabelAt[FLabelCount] := -1;
  Result := FLabelCount;
  Inc(FLabelCount);
end;

procedure TJitAsm.Fix(Field: NativeInt; L: TJitLabel);
begin
  if FLabelAt[L] >= 0 then
  begin
    PatchJump(Field, FLabelAt[L]);
    Exit;
  end;
  if FFixCount = Length(FFixField) then
  begin
    SetLength(FFixField, FFixCount * 2 + 64);
    SetLength(FFixLabel, FFixCount * 2 + 64);
  end;
  FFixField[FFixCount] := Field;
  FFixLabel[FFixCount] := L;
  Inc(FFixCount);
end;

procedure TJitAsm.Bind(L: TJitLabel);
begin
  FLabelAt[L] := FUsed;
  var K := 0;
  while K < FFixCount do
    if FFixLabel[K] = L then
    begin
      PatchJump(FFixField[K], FUsed);
      Dec(FFixCount);
      FFixField[K] := FFixField[FFixCount];
      FFixLabel[K] := FFixLabel[FFixCount];
    end
    else
      Inc(K);
end;

procedure TJitAsm.ForgetLabels;
begin
  if FFixCount <> 0 then
    raise EInvalidOpException.Create('JIT: a jump to a label not bound');
  FLabelCount := 0;
end;

procedure TJitAsm.Branch(Cond: TJitCond; W: TJitWidth; const A, B: TJitOp; L: TJitLabel);
begin
  EmitCompare(W, A, B);
  Fix(EmitJumpIf(Cond), L);
end;

procedure TJitAsm.BranchTest(Cond: TJitCond; W: TJitWidth; const A, B: TJitOp; L: TJitLabel);
begin
  Fix(EmitTestJump(Cond, W, A, B), L);
end;

procedure TJitAsm.Jump(L: TJitLabel);
begin
  Fix(EmitJump, L);
end;

procedure TJitAsm.BranchTo(Cond: TJitCond; W: TJitWidth; const A, B: TJitOp; Target: NativeInt);
begin
  EmitCompare(W, A, B);
  EmitJumpIfTo(Cond, Target);
end;

procedure TJitAsm.JumpTo(Target: NativeInt);
begin
  PatchJump(EmitJump, Target);
end;

function TJitAsm.JumpSite(Target: NativeInt): NativeInt;
begin
  Result := EmitJump;
  PatchJump(Result, Target);
end;

function TJitAsm.SiteTarget(Site: NativeInt): NativeInt;
begin
  Result := JumpTargetOf(Site);
end;

procedure TJitAsm.Redirect(Site, Target: NativeInt);
begin
  // (Code that may be running: the field is written at once.)
  PatchJump(Site, Target);
  FlushCode(FBase + Site, 4);
end;

procedure TJitAsm.Flush;
begin
  if FUsed > FFlushed then
    FlushCode(FBase + FFlushed, FUsed - FFlushed);
  FFlushed := FUsed;
end;

{ x64 }

const
  rAX = 0; rCX = 1; rDX = 2; rBX = 3; rSP = 4; rBP = 5; rSI = 6; rDI = 7;
  r8 = 8; r9 = 9; r10 = 10; r11 = 11; r12 = 12; r13 = 13; r14 = 14; r15 = 15;

type
  // An operand with x64 register numbers.
  TX64Op = record
    Kind: TJitOpKind;
    Reg: Integer;
    Disp: Integer;
    Imm: Int64;
  end;

  // TJitAsm's operations as x64 instructions. The calling convention (each
  // role's register and the arguments', a function's frame and its unwind
  // data) and the memory are a subclass's.
  TJitAsmX64 = class abstract(TJitAsm)
  protected
    FPhys: array[TJitReg] of Byte;
    FArgs: array[0..3] of Byte;
    function X(const Op: TJitOp): TX64Op;
    procedure ModRM(W64: Boolean; const Opcode: array of Byte; RegField: Integer; ByteReg: Boolean; const RM: TX64Op;
      ByteRM: Boolean);
    procedure LoadImm(W: TJitWidth; Reg: Integer; Value: Int64);
    procedure MoveX(W: TJitWidth; const Dst, Src: TX64Op);
    procedure MoveArgs(const Args: array of TJitOp);
    procedure EmitCompare(W: TJitWidth; const A, B: TJitOp); override;
    procedure EmitTest(W: TJitWidth; const A, B: TJitOp); override;
    function EmitJumpIf(Cond: TJitCond): NativeInt; override;
    function EmitJump: NativeInt; override;
    procedure PatchJump(Field, Target: NativeInt); override;
    function JumpTargetOf(Field: NativeInt): NativeInt; override;
  public
    procedure Move(W: TJitWidth; const Dst, Src: TJitOp); override;
    procedure Alu(Op: TJitAlu; W: TJitWidth; const Dst, Src: TJitOp); override;
    procedure Shift(Op: TJitShift; W: TJitWidth; Dst: TJitReg; Count: Integer); override;
    procedure Call(Routine: Pointer; const Args: array of TJitOp); override;
    procedure CallAt(const Routine: TJitOp; const Args: array of TJitOp); override;
    procedure JumpIndirect(const Target: TJitOp); override;
    procedure EnterJump; override;
  end;

const
  // TJitAlu: the /digit of op r/m, imm32 (81 /digit), and op r/m, r (op r,
  // r/m is 2 more; the byte forms 1 less).
  AluExt: array[TJitAlu] of Byte = (0, 5, 4, 1, 6);
  AluToRM: array[TJitAlu] of Byte = ($01, $29, $21, $09, $31);
  CondCode: array[TJitCond] of Byte = ($4, $5, $C, $E, $F, $D, $2, $6, $7, $3);

function X64Reg(Reg: Integer): TX64Op;
begin
  Result := Default(TX64Op);
  Result.Kind := okReg;
  Result.Reg := Reg;
end;

function Imm32(Value: Int64; W: TJitWidth): Cardinal;
begin
  // As a 32-bit immediate: sign-extended to 64 bits, or for a 32-bit
  // operation any 32-bit value.
  if (Value >= -Int64($80000000)) and (Value <= $7FFFFFFF) then
    Exit(Cardinal(Integer(Value)));
  if (W <> jw64) and (Value >= 0) and (Value <= $FFFFFFFF) then
    Exit(Cardinal(Value));
  raise EInvalidOpException.Create('JIT: a constant out of range');
end;

function TJitAsmX64.X(const Op: TJitOp): TX64Op;
begin
  if (Op.Kind <> okImm) and (Op.Reg = jrS4) then
    raise EInvalidOpException.Create('JIT: no S4 here');
  Result.Kind := Op.Kind;
  Result.Reg := FPhys[Op.Reg];
  Result.Disp := Op.Disp;
  Result.Imm := Op.Imm;
end;

procedure TJitAsmX64.ModRM(W64: Boolean; const Opcode: array of Byte; RegField: Integer; ByteReg: Boolean;
  const RM: TX64Op; ByteRM: Boolean);
begin
  // REX: W for 64 bits, R and B for registers 8..15, a plain one for the byte
  // registers SPL..DIL (ByteReg, ByteRM: the operand is a byte register).
  // Memory: [base + disp32]; no base needs a SIB byte (RSP, R12).
  var Rex: Byte := $40;
  if W64 then
    Rex := Rex or 8;
  if RegField >= 8 then
    Rex := Rex or 4;
  if RM.Reg >= 8 then
    Rex := Rex or 1;
  var Plain := (ByteReg and (RegField in [4..7])) or (ByteRM and (RM.Kind = okReg) and (RM.Reg in [4..7]));
  if (Rex <> $40) or Plain then
    Emit([Rex]);
  Emit(Opcode);
  if RM.Kind = okReg then
    Emit([$C0 or ((RegField and 7) shl 3) or (RM.Reg and 7)])
  else
  begin
    if (RM.Reg and 7) = rSP then
      raise EInvalidOpException.Create('JIT: no such base register');
    Emit([$80 or ((RegField and 7) shl 3) or (RM.Reg and 7)]);
    D(Cardinal(RM.Disp));
  end;
end;

procedure TJitAsmX64.LoadImm(W: TJitWidth; Reg: Integer; Value: Int64);
begin
  if (W <> jw64) or ((Value >= 0) and (Value <= $FFFFFFFF)) then
  begin
    // mov r32, imm32 (zero-extends)
    if Reg >= 8 then
      Emit([$41]);
    Emit([$B8 + (Reg and 7)]);
    D(Cardinal(Value));
  end
  else if (Value < 0) and (Value >= -Int64($80000000)) then
  begin
    // mov r/m64, imm32 (sign-extends)
    ModRM(True, [$C7], 0, False, X64Reg(Reg), False);
    D(Cardinal(Integer(Value)));
  end
  else
  begin
    var Rex: Byte := $48;
    if Reg >= 8 then
      Rex := Rex or 1;
    Emit([Rex, $B8 + (Reg and 7)]);
    Q(UInt64(Value));
  end;
end;

procedure TJitAsmX64.MoveX(W: TJitWidth; const Dst, Src: TX64Op);
begin
  if Dst.Kind = okReg then
    case Src.Kind of
      okReg:
        if W = jw8 then
          ModRM(False, [$0F, $B6], Dst.Reg, False, Src, True)           // movzx r32, r8
        else if (W = jw32) or (Dst.Reg <> Src.Reg) then
          ModRM(W = jw64, [$89], Src.Reg, False, Dst, False);
      okImm:
        LoadImm(W, Dst.Reg, Src.Imm);
      okMem:
        if W = jw8 then
          ModRM(False, [$0F, $B6], Dst.Reg, False, Src, False)          // movzx r32, byte [m]
        else
          ModRM(W = jw64, [$8B], Dst.Reg, False, Src, False);
      okAddr:
        ModRM(True, [$8D], Dst.Reg, False, Src, False);                // lea
    end
  else if (Dst.Kind = okMem) and (Src.Kind = okReg) then
  begin
    if W = jw8 then
      ModRM(False, [$88], Src.Reg, True, Dst, False)
    else
      ModRM(W = jw64, [$89], Src.Reg, False, Dst, False);
  end
  else if (Dst.Kind = okMem) and (Src.Kind = okImm) then
  begin
    if W = jw8 then
    begin
      ModRM(False, [$C6], 0, False, Dst, False);
      Emit([Byte(Src.Imm)]);
    end
    else
    begin
      ModRM(W = jw64, [$C7], 0, False, Dst, False);
      D(Imm32(Src.Imm, W));
    end;
  end
  else
    raise EInvalidOpException.Create('JIT: no such move');
end;

procedure TJitAsmX64.Move(W: TJitWidth; const Dst, Src: TJitOp);
begin
  MoveX(W, X(Dst), X(Src));
end;

procedure TJitAsmX64.Alu(Op: TJitAlu; W: TJitWidth; const Dst, Src: TJitOp);
begin
  var A := X(Dst);
  var B := X(Src);
  if B.Kind = okImm then
  begin
    if W = jw8 then
    begin
      ModRM(False, [$80], AluExt[Op], False, A, True);
      Emit([Byte(B.Imm)]);
    end
    else
    begin
      ModRM(W = jw64, [$81], AluExt[Op], False, A, False);
      D(Imm32(B.Imm, W));
    end;
  end
  else if (B.Kind = okReg) and (A.Kind in [okReg, okMem]) then
    ModRM(W = jw64, [AluToRM[Op] - Ord(W = jw8)], B.Reg, W = jw8, A, W = jw8)
  else if (A.Kind = okReg) and (B.Kind = okMem) then
    ModRM(W = jw64, [AluToRM[Op] + 2 - Ord(W = jw8)], A.Reg, W = jw8, B, False)
  else
    raise EInvalidOpException.Create('JIT: no such operation');
end;

procedure TJitAsmX64.Shift(Op: TJitShift; W: TJitWidth; Dst: TJitReg; Count: Integer);
begin
  // shl/shr r, imm8 (C1 /4, /5)
  ModRM(W = jw64, [$C1], 4 + Ord(Op = jsShr), False, X64Reg(FPhys[Dst]), False);
  Emit([Byte(Count)]);
end;

procedure TJitAsmX64.EmitCompare(W: TJitWidth; const A, B: TJitOp);
begin
  // cmp (81 /7 or 80 /7 with a constant; 39 cmp r/m, r; 3B cmp r, r/m)
  var P := X(A);
  var R := X(B);
  if R.Kind = okImm then
  begin
    if W = jw8 then
    begin
      ModRM(False, [$80], 7, False, P, True);
      Emit([Byte(R.Imm)]);
    end
    else
    begin
      ModRM(W = jw64, [$81], 7, False, P, False);
      D(Imm32(R.Imm, W));
    end;
  end
  else if (R.Kind = okReg) and (P.Kind in [okReg, okMem]) then
    ModRM(W = jw64, [$39 - Ord(W = jw8)], R.Reg, W = jw8, P, W = jw8)
  else if (P.Kind = okReg) and (R.Kind = okMem) then
    ModRM(W = jw64, [$3B - Ord(W = jw8)], P.Reg, W = jw8, R, False)
  else
    raise EInvalidOpException.Create('JIT: no such comparison');
end;

procedure TJitAsmX64.EmitTest(W: TJitWidth; const A, B: TJitOp);
begin
  // test (A8 test al, imm8; F6 /0, F7 /0 with a constant; 84, 85 test r/m, r)
  var P := X(A);
  var R := X(B);
  if R.Kind = okImm then
  begin
    if W = jw8 then
    begin
      if (P.Kind = okReg) and (P.Reg = rAX) then
        Emit([$A8])
      else
        ModRM(False, [$F6], 0, False, P, True);
      Emit([Byte(R.Imm)]);
    end
    else
    begin
      ModRM(W = jw64, [$F7], 0, False, P, False);
      D(Imm32(R.Imm, W));
    end;
  end
  else if (R.Kind = okReg) and (P.Kind in [okReg, okMem]) then
    ModRM(W = jw64, [$85 - Ord(W = jw8)], R.Reg, W = jw8, P, W = jw8)
  else
    raise EInvalidOpException.Create('JIT: no such test');
end;

function TJitAsmX64.EmitJumpIf(Cond: TJitCond): NativeInt;
begin
  Emit([$0F, $80 or CondCode[Cond]]);                    // jcc rel32
  Result := Offset;
  D(0);
end;

function TJitAsmX64.EmitJump: NativeInt;
begin
  Emit([$E9]);                                           // jmp rel32
  Result := Offset;
  D(0);
end;

procedure TJitAsmX64.PatchJump(Field, Target: NativeInt);
begin
  PInteger(Base + Field)^ := Integer(Target - (Field + 4));
end;

function TJitAsmX64.JumpTargetOf(Field: NativeInt): NativeInt;
begin
  Result := Field + 4 + PInteger(Base + Field)^;
end;

procedure TJitAsmX64.MoveArgs(const Args: array of TJitOp);
var
  Src: array[0..3] of TX64Op;
  Pending: array[0..3] of Boolean;
begin
  // The arguments into their registers, each once no other still to be
  // moved reads its register (arguments that read each other's raise).
  if Length(Args) > Length(FArgs) then
    raise EInvalidOpException.Create('JIT: too many arguments');
  var Left := 0;
  for var K := 0 to High(Args) do
  begin
    Src[K] := X(Args[K]);
    Pending[K] := not ((Src[K].Kind = okReg) and (Src[K].Reg = FArgs[K]));
    if Pending[K] then
      Inc(Left);
  end;
  while Left > 0 do
  begin
    var Moved := False;
    for var K := 0 to High(Args) do
      if Pending[K] then
      begin
        var Blocked := False;
        for var M := 0 to High(Args) do
          if (M <> K) and Pending[M] and (Src[M].Kind <> okImm) and (Src[M].Reg = FArgs[K]) then
            Blocked := True;
        if not Blocked then
        begin
          MoveX(jw64, X64Reg(FArgs[K]), Src[K]);
          Pending[K] := False;
          Dec(Left);
          Moved := True;
        end;
      end;
    if not Moved then
      raise EInvalidOpException.Create('JIT: call arguments read each other');
  end;
end;

procedure TJitAsmX64.Call(Routine: Pointer; const Args: array of TJitOp);
begin
  MoveArgs(Args);
  LoadImm(jw64, rAX, Int64(NativeUInt(Routine)));
  Emit([$FF, $D0]);                                      // call rax
end;

procedure TJitAsmX64.CallAt(const Routine: TJitOp; const Args: array of TJitOp);
begin
  if Routine.Kind <> okMem then
    raise EInvalidOpException.Create('JIT: no such call');
  MoveArgs(Args);
  ModRM(False, [$FF], 2, False, X(Routine), False);      // call r/m64
end;

procedure TJitAsmX64.JumpIndirect(const Target: TJitOp);
begin
  ModRM(False, [$FF], 4, False, X(Target), False);       // jmp r/m64
end;

procedure TJitAsmX64.EnterJump;
begin
  Enter;
  if FArgs[3] <> FPhys[jrT1] then
    MoveX(jw64, X64Reg(FPhys[jrT1]), X64Reg(FArgs[3]));
  ModRM(False, [$FF], 4, False, X64Reg(FArgs[2]), False);
end;

{$IF JitSupported}

{ Win64 }

function RtlAddFunctionTable(FunctionTable: Pointer; EntryCount: DWORD; BaseAddress: UInt64): BOOL; stdcall;
  external kernel32;
function RtlDeleteFunctionTable(FunctionTable: Pointer): BOOL; stdcall; external kernel32;

type
  // The Win64 convention: arguments in RCX, RDX, R8, R9, the result in RAX;
  // RBX, RSI, RDI, R12..R15 kept by a callee (the fixed roles); 32 bytes of
  // shadow space above the return address, RSP 16-aligned at a call. Every
  // function has Enter's frame, so one unwind entry covers the buffer.
  TJitAsmWin64 = class(TJitAsmX64)
  private
    FTable: array[0..0] of record
      BeginAddress, EndAddress, UnwindData: Cardinal;
    end;
    FRegistered: Boolean;
  protected
    function Allocate(Size: NativeInt; out CodeStart: NativeInt): PByte; override;
    procedure Release(Base: PByte); override;
    procedure FlushCode(P: PByte; Len: NativeInt); override;
  public
    constructor Create(Size: NativeInt);
    procedure Enter; override;
    procedure Leave(const Value: TJitOp); override;
  end;

const
  // UNWIND_INFO at the start of the buffer, for Enter: version 1, no flags,
  // 13-byte prologue, 7 codes (padded to 8), no frame register. Codes
  // (offset after the instruction, op | info shl 4), last first: sub rsp,40
  // (ALLOC_SMALL 4), push rdi, r14, r13, r12, rsi, rbx.
  UnwindInfo: array[0..19] of Byte = (
    $01, 13, 7, 0,
    13, $42,          // ALLOC_SMALL (40 - 8) / 8 = 4
    9, $70,           // PUSH_NONVOL RDI
    8, $E0,           // PUSH_NONVOL R14
    6, $D0,           // PUSH_NONVOL R13
    4, $C0,           // PUSH_NONVOL R12
    2, $60,           // PUSH_NONVOL RSI
    1, $30,           // PUSH_NONVOL RBX
    0, 0);
  Win64CodeStart = 64;

constructor TJitAsmWin64.Create(Size: NativeInt);
const
  Phys: array[TJitReg] of Byte = (rBX, rSI, rDI, r12, r13, r14, rAX, rCX, rDX, r8, r9, r10, r11, rAX);
begin
  for var R := Low(TJitReg) to High(TJitReg) do
    FPhys[R] := Phys[R];
  FArgs[0] := rCX;
  FArgs[1] := rDX;
  FArgs[2] := r8;
  FArgs[3] := r9;
  inherited Create(Size);
end;

function TJitAsmWin64.Allocate(Size: NativeInt; out CodeStart: NativeInt): PByte;
begin
  // Read, write and execute: code is written while other code runs.
  Result := VirtualAlloc(nil, Size, MEM_COMMIT or MEM_RESERVE, PAGE_EXECUTE_READWRITE);
  if Result = nil then
    RaiseLastOSError;
  System.Move(UnwindInfo, Result^, SizeOf(UnwindInfo));
  FTable[0].BeginAddress := Win64CodeStart;
  FTable[0].EndAddress := Cardinal(Size);
  FTable[0].UnwindData := 0;
  FRegistered := RtlAddFunctionTable(@FTable, 1, UInt64(Result));
  CodeStart := Win64CodeStart;
end;

procedure TJitAsmWin64.Release(Base: PByte);
begin
  if FRegistered then
    RtlDeleteFunctionTable(@FTable);
  VirtualFree(Base, 0, MEM_RELEASE);
end;

procedure TJitAsmWin64.FlushCode(P: PByte; Len: NativeInt);
begin
  // (x64 keeps the instruction cache coherent; Windows asks for the call for
  // code written at run time.)
  FlushInstructionCache(GetCurrentProcess, P, Len);
end;

procedure TJitAsmWin64.Enter;
begin
  Emit([$53]);                // push rbx
  Emit([$56]);                // push rsi
  Emit([$41, $54]);           // push r12
  Emit([$41, $55]);           // push r13
  Emit([$41, $56]);           // push r14
  Emit([$57]);                // push rdi
  Emit([$48, $83, $EC, 40]);  // sub rsp, 40
  MoveX(jw64, X64Reg(FPhys[jrSelf]), X64Reg(FArgs[0]));
  MoveX(jw64, X64Reg(FPhys[jrCtx]), X64Reg(FArgs[1]));
end;

procedure TJitAsmWin64.Leave(const Value: TJitOp);
begin
  MoveX(jw64, X64Reg(rAX), X(Value));
  Emit([$48, $83, $C4, 40]);  // add rsp, 40
  Emit([$5F]);                // pop rdi
  Emit([$41, $5E]);           // pop r14
  Emit([$41, $5D]);           // pop r13
  Emit([$41, $5C]);           // pop r12
  Emit([$5E]);                // pop rsi
  Emit([$5B]);                // pop rbx
  Emit([$C3]);                // ret
end;

{$ENDIF}

function CreateJitAsm(Size: NativeInt): TJitAsm;
begin
  {$IF JitSupported}
  Result := TJitAsmWin64.Create(Size);
  {$ELSE}
  Result := nil;
  {$ENDIF}
end;

end.
