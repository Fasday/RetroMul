unit PSP.JitTest;

// The Allegrex recompiler (PSP.CPU.JIT) against the interpreter. Random
// programs over the integer ISA (branches likely or not, delay slots that
// are branches too, jumps, JR/JALR), loads and stores of every size aligned
// or not (LWL/LWR/SWL/SWR, LL/SC) in RAM, VRAM, the scratchpad and unmapped
// space, stores into the program's own code (by its instructions and by the
// kernel), syscalls (also in JR's delay slot, as kernel stubs are) that add
// cycles, stop the run, rewrite code, switch the context, move the PC or
// drop the decoded code, some COP1, and handlers of the test's own in the
// VFPU's place (they read PC, NPC, CurPC and the budget, stop the run, add
// cycles, store into code, move the PC, branch): each runs from the same
// state on the interpreter, the recompiler's code (this target's backend)
// and the code run by HW.JIT's model, in the same budgets, through both
// segments, with the recompiler now and then switched off. After each Run
// the contexts, CurPC, the cycles it returns, Stopping, the faults and the
// kernel's log (with the registers' hash at each syscall) must match; at the
// end the memories, byte for byte. Also a benchmark (bench): instructions
// per second of hot loops.

interface

uses
  System.Classes;

function RunPSPJitTest(Programs: Integer; Report: TStrings): Boolean;
procedure RunPSPJitBench(Report: TStrings);

implementation

uses
  System.SysUtils, System.Math, System.Diagnostics, System.Generics.Collections, HW.JIT, PSP.Types, PSP.Memory, PSP.CPU, PSP.CPU.JIT, PSP.VFPU;

var
  Rng: Cardinal;
  RealVFPU: Boolean;

function Next(Range: Cardinal): Cardinal;
begin
  Rng := Cardinal((UInt64(Rng) * 1664525 + 1013904223) and $FFFFFFFF);
  Result := Cardinal((UInt64(Rng) * Range) shr 32);
end;

function Rand32: Cardinal;
begin
  Result := (Next($10000) shl 16) or Next($10000);
end;

function Pick(const Values: array of Cardinal): Cardinal;
begin
  Result := Values[Next(Length(Values))];
end;

const
  RegionNames: array[0..2] of string = ('RAM', 'VRAM', 'scratchpad');
  KindNames: array[0..2] of string = ('interpreter', 'recompiler', 'model');
  CodeWords = 4096;
  // Kernel stubs at the end of the code.
  StubCount = 32;
  StubWord = CodeWords - 2 - 2 * StubCount;
  DataBase = $08900000;
  OtherBase = $08A00000;

type
  TMachine = class
  public
    Memory: TPSPMemory;
    CPU: TPSPCPU;
    Jit: TPSPRecompiler;
    Log: TStringBuilder;
    Other: TPSPContext;
    CodeStart: Cardinal;
    Pool: array[0..3] of Cardinal;
    Error: string;
    constructor Create(Kind: Integer);
    destructor Destroy; override;
    procedure Syscall(C: TPSPCPU; Code: Cardinal);
    procedure Break_(C: TPSPCPU; Code: Cardinal);
  end;

constructor TMachine.Create(Kind: Integer);
begin
  inherited Create;
  Memory := TPSPMemory.Create;
  CPU := TPSPCPU.Create(Memory);
  CPU.OnSyscall := Syscall;
  CPU.OnBreak := Break_;
  Log := TStringBuilder.Create;
  case Kind of
    1: Jit := TPSPRecompiler.Create(CPU, []);
    2: Jit := TPSPRecompiler.Create(CPU, [joModel]);
  end;
end;

destructor TMachine.Destroy;
begin
  Jit.Free;
  CPU.Free;
  Memory.Free;
  Log.Free;
  inherited;
end;

procedure TMachine.Syscall(C: TPSPCPU; Code: Cardinal);
begin
  // A kernel of the test's own: what it does depends on the code only. (The
  // log has the registers' hash: a difference shows at the next syscall.)
  var Hash: Cardinal := 2166136261;
  for var R := 0 to 31 do
    Hash := (Hash xor C.Ctx.GPR[R]) * 16777619;
  Hash := (Hash xor C.Ctx.HI xor (C.Ctx.LO shl 1)) * 16777619;
  Log.Append(Format('s%x@%x+%d,%x;', [Code, C.CurPC, C.TakeCycles, Hash]));
  C.Ctx.GPR[2] := Code * 7 + C.Ctx.GPR[4];
  case Code mod 8 of
    1:
      C.AddCycles(Code mod 13 + 1);
    2:
      C.Stop;
    3:
      C.Memory.Write32(CodeStart + (Code * 52) mod (CodeWords * 4 - 8), Pool[Code mod 4]);
    4:
      begin
        var T := C.Ctx;
        C.Ctx := Other;
        Other := T;
      end;
    5:
      begin
        C.AddCycles(3);
        C.Stop;
      end;
    6:
      C.SetPC(CodeStart + (Hash mod (CodeWords - 2)) * 4);
    7:
      if Code mod 3 = 0 then
        C.FlushDecoded;
  end;
end;

procedure TMachine.Break_(C: TPSPCPU; Code: Cardinal);
begin
  Log.Append(Format('b%x@%x+%d;', [Code, C.CurPC, C.TakeCycles]));
  C.Stop;
end;

{ Handlers the recompiler knows nothing of (as the test's VFPU) }

procedure TestReadPC(C: TPSPCPU; Op: Cardinal);
begin
  // What the interpreter has as PC, NPC and CurPC while it runs one.
  var T := (Op shr 16) and 31;
  if T < 24 then
    C.Ctx.GPR[T] := C.Ctx.PC xor (C.Ctx.NPC shl 1) xor (C.CurPC shl 2) xor Op;
end;

procedure TestStop(C: TPSPCPU; Op: Cardinal);
begin
  // Stops the run, adds cycles, or both.
  if (Op and 1) <> 0 then
    C.Stop;
  C.Ctx.V[(Op shr 4) and 127] := Cardinal(C.TakeCycles);
  C.AddCycles((Op shr 1) and 7);
  C.Ctx.V[Op and 127] := C.Ctx.V[Op and 127] + 1;
  // (Now and then on elsewhere, as a kernel call can.)
  if (Op and $3000) = $3000 then
    C.SetPC(C.Ctx.PC + 8);
end;

procedure TestStore(C: TPSPCPU; Op: Cardinal);
begin
  // A store (through its base: into code too).
  C.Memory.Write32(C.Ctx.GPR[(Op shr 21) and 31] + Cardinal(Integer(SmallInt(Word(Op)))), C.Ctx.GPR[(Op shr 16) and 31]);
end;

procedure TestBranch(C: TPSPCPU; Op: Cardinal);
begin
  // A branch on GPR[1]'s low bit (likely where bit 17 is set), as the
  // interpreter's branches (from its own address: CurPC).
  var Taken := ((C.Ctx.GPR[1] and 1) <> 0) = ((Op and $10000) <> 0);
  if Taken then
    C.Ctx.NPC := C.CurPC + 4 + Cardinal(Integer(SmallInt(Word(Op))) * 4)
  else if (Op and $20000) <> 0 then
  begin
    C.Ctx.PC := C.Ctx.NPC;
    C.Ctx.NPC := C.Ctx.NPC + 4;
  end;
end;

function TestDecoder(Op: Cardinal): TPSPOpHandler;
begin
  case Op shr 26 of
    $18: Result := TestReadPC;
    $19: Result := TestStop;
    $3A: Result := TestStore;
    $12:
      if ((Op shr 21) and 31) = 8 then
        Result := TestBranch
      else
        Result := OpReserved;
  else
    Result := OpReserved;
  end;
end;

{ Programs }

function Dest: Cardinal;
begin
  // Registers the program may write: 1..9 mostly, up to 23 ($0 now and
  // then); few, so that values meet and reach memory.
  case Next(32) of
    0, 1: Result := 0;
    2..5: Result := 10 + Next(14);
  else
    Result := 1 + Next(9);
  end;
end;

function Src: Cardinal;
begin
  if Next(8) = 0 then
    Result := Next(32)
  else
    Result := Next(10);
end;

function Imm16: Cardinal;
begin
  case Next(6) of
    0: Result := 0;
    1: Result := $FFFF;
    2: Result := $8000;
    3: Result := $7FFF;
    4: Result := Next(16);
  else
    Result := Next($10000);
  end;
end;

function Edge32: Cardinal;
begin
  case Next(8) of
    0: Result := 0;
    1: Result := 1;
    2: Result := $FFFFFFFF;
    3: Result := $80000000;
    4: Result := $7FFFFFFF;
    5: Result := Next(64);
  else
    Result := Rand32;
  end;
end;

function AluInstruction: Cardinal;
begin
  // An instruction of the integer ALU (or HI/LO, multiply/divide, SPECIAL3).
  case Next(10) of
    0..4:
      begin
        var Fn := Pick([0, 2, 3, 4, 6, 7, $A, $B, $10, $11, $12, $13, $16, $17, $18, $19, $1A, $1B, $1C, $1D,
          $20, $21, $22, $23, $24, $25, $26, $27, $2A, $2B, $2C, $2D, $2E, $2F, $21, $21, $25, $2A, 0, 2]);
        var Rs := Src;
        var Sa := Next(32);
        if Fn = 2 then
          Rs := Next(2);
        if Fn = 6 then
          Sa := Next(2);
        Result := (Rs shl 21) or (Src shl 16) or (Dest shl 11) or (Sa shl 6) or Fn;
      end;
    5..8:
      Result := (Cardinal(Pick([8, 9, 9, 9, $A, $B, $C, $D, $D, $E, $F])) shl 26) or (Src shl 21) or (Dest shl 16) or Imm16;
  else
    case Next(3) of
      0:
        Result := ($1F shl 26) or (Src shl 21) or (Dest shl 16) or (Next(32) shl 11) or (Next(32) shl 6);
      1:
        Result := ($1F shl 26) or (Src shl 21) or (Dest shl 16) or (Next(32) shl 11) or (Next(32) shl 6) or 4;
    else
      Result := ($1F shl 26) or (Src shl 16) or (Dest shl 11) or (Pick([2, 3, $10, $14, $18, $16, $1A]) shl 6) or $20;
    end;
  end;
end;

procedure MakeProgram(var Code: array of Cardinal; Start: Cardinal; var Pool: array of Cardinal);
begin
  for var K := 0 to High(Pool) do
    Pool[K] := AluInstruction;
  var Sparse := Next(4) = 0;
  var I := 0;
  while I < CodeWords - 2 do
  begin
    var Op: Cardinal := 0;
    // Branches forward mostly (backward ones loop for good where their
    // condition holds).
    var Offset := Integer(Next(31));
    if Next(8) = 0 then
      Offset := -Integer(Next(31));
    if I + 1 + Offset < 0 then
      Offset := -I - 1 + Integer(Next(8));
    if I + 1 + Offset > CodeWords - 3 then
      Offset := CodeWords - 3 - I - 1 - Integer(Next(8));
    var Rel := Cardinal(Offset) and $FFFF;
    case Next(100) of
      0..29:
        Op := AluInstruction;
      30..51:
        begin
          // Loads and stores through the data, VRAM, scratchpad and unmapped
          // bases, aligned and not.
          var Base := Pick([28, 28, 28, 28, 29, 30, 26]);
          var Off := (Cardinal(Integer(Next(512)) * 4 - 1024) + Pick([0, 0, 0, 0, 1, 2, 3])) and $FFFF;
          var Code6 := Pick([$20, $21, $22, $23, $24, $25, $26, $28, $29, $2A, $2B, $2E, $23, $2B, $23, $2B, $30, $38,
            $31, $39, $20, $28]);
          if Code6 in [$20..$26, $30] then
            Op := (Code6 shl 26) or (Base shl 21) or (Dest shl 16) or Off
          else
            Op := (Code6 shl 26) or (Base shl 21) or (Src shl 16) or Off;
        end;
      52..55:
        begin
          // A store into the code just ahead (or anywhere).
          var Target := I + 1 + Integer(Next(6));
          if Next(4) = 0 then
            Target := Integer(Next(CodeWords - 2));
          var R := Pick([24, 25]);
          var Kind: Cardinal := $2B;
          if Next(16) = 0 then
            Kind := Pick([$28, $29, $2A, $2E]);
          Op := (Kind shl 26) or (27 shl 21) or (R shl 16) or ((Cardinal(Target) * 4) and $FFFF);
        end;
      56..73:
        begin
          var Rs := Src;
          var Rt := Src;
          case Next(4) of
            0:
              Op := (Cardinal(Pick([4, 5, $14, $15])) shl 26) or (Rs shl 21) or (Rt shl 16) or Rel;
            1:
              Op := (Cardinal(Pick([6, 7, $16, $17])) shl 26) or (Rs shl 21) or Rel;
            2:
              Op := (1 shl 26) or (Rs shl 21) or (Pick([0, 1, 2, 3, $10, $11, $12, $13]) shl 16) or Rel;
          else
            Op := (4 shl 26) or Rel;
          end;
        end;
      74..77:
        begin
          var Target := Cardinal(I) + 2 + Next(200);
          if (Target > CodeWords - 3) or (Next(4) = 0) then
            Target := Next(CodeWords - 2);
          var Kind := Pick([2, 3]);
          if Next(3) = 0 then
          begin
            // A call of a kernel stub (JR $31 with a SYSCALL in its slot).
            Target := StubWord + 2 * Next(StubCount);
            Kind := 3;
          end;
          Op := (Kind shl 26) or (((Start + Target * 4) and $0FFFFFFF) shr 2);
        end;
      78..80:
        if Next(2) = 0 then
          Op := (31 shl 21) or 8
        else
          Op := (31 shl 21) or (31 shl 11) or 9;
      81..83:
        Op := (Next(64) shl 6) or $C;
      84:
        if Next(8) = 0 then
          Op := (Next(16) shl 6) or $D
        else
          Op := 0;
      85..89:
        case Next(6) of
          0: Op := ($11 shl 26) or (4 shl 21) or (Src shl 16) or (Next(32) shl 11);              // MTC1
          1: Op := ($11 shl 26) or (0 shl 21) or (Dest shl 16) or (Next(32) shl 11);             // MFC1
          2: Op := ($11 shl 26) or ($10 shl 21) or (Next(32) shl 16) or (Next(32) shl 11) or (Next(32) shl 6) or
               Pick([0, 1, 2, 5, 6, 7]);
          3: Op := ($11 shl 26) or ($10 shl 21) or (Next(32) shl 16) or (Next(32) shl 11) or Pick([$32, $34, $3C, $3E]);
        else
          Op := ($11 shl 26) or (8 shl 21) or (Next(4) shl 16) or Rel;                           // BC1x
        end;
      90..91:
        case Next(6) of
          0: Op := ($10 shl 26) or (Dest shl 16) or (Next(32) shl 11);                           // MFC0
          1: Op := ($1C shl 26) or (Dest shl 16) or $24;                                         // MFIC
          2: Op := ($1C shl 26) or (Src shl 16) or $26;                                          // MTIC
          3:
            begin
              // MTC0 (not Status, EPC, ErrorEPC), now and then ERET.
              var R := Next(32);
              if R in [12, 14, 30] then
                R := 13;
              if Next(6) = 0 then
                Op := ($10 shl 26) or ($10 shl 21) or $18
              else
                Op := ($10 shl 26) or (4 shl 21) or (Src shl 16) or (R shl 11);
            end;
          4: Op := (Cardinal($D) shl 26) or (31 shl 21) or (31 shl 16) or (1 + Next(3));          // ORI $31 (JR's low bits)
        else
          Op := (Cardinal($30) shl 26) or (28 shl 21) or (Next(2) shl 16) or (Next(64) * 4);               // LL (maybe $0)
        end;
      92..95:
        if RealVFPU then
        begin
          case Next(8) of
            0..3:
              begin
                var Base := Pick([28, 29, 30, 26, 27]);
                var Offset4 := Integer(Next(512)) * 4;
                if Base = 27 then
                  Offset4 := (I + 1 + Integer(Next(8))) * 4;
                Op := (Pick([$32, $36, $3A, $3E]) shl 26) or (Base shl 21) or (Next(32) shl 16) or
                  Cardinal(Offset4) or Next(4);
              end;
            4: Op := ($12 shl 26) or (3 shl 21) or (Dest shl 16) or Next(256); // MFV/MFVC
            5: Op := ($12 shl 26) or (7 shl 21) or (Src shl 16) or Next(256);  // MTV/MTVC
            6: Op := ($12 shl 26) or (8 shl 21) or (Next(32) shl 16) or Rel; // BVC
          else
            Op := Cardinal($DC000000) or Next($100000); // prefix (loads and stores must not consume it)
          end;
        end
        else
        // The test's own "VFPU" (TestDecoder).
        case Next(5) of
          0: Op := (Cardinal($18) shl 26) or (Dest shl 16) or Next($10000);
          1: Op := (Cardinal($19) shl 26) or (Next($2000) * 2) or Cardinal(Ord(Next(4) = 0));
          2: Op := (Cardinal($3A) shl 26) or (28 shl 21) or (Src shl 16) or (Cardinal(Integer(Next(512)) * 4 - 1024) and $FFFF);
          3: Op := (Cardinal($3A) shl 26) or (27 shl 21) or (Pick([24, 25]) shl 16) or ((Cardinal(I) + 1 + Next(6)) * 4);
        else
          Op := (Cardinal($12) shl 26) or (8 shl 21) or (Next(4) shl 16) or Rel;
        end;
      96, 97:
        if I < CodeWords - 3 then
        begin
          // A branch in the delay slot of another to the same label (as
          // compilers emit runs of bvt): taken or not, likely or not; the
          // interpreter runs the pair.
          for var K := 0 to 1 do
          begin
            var R := (Cardinal(Offset - K) and $FFFF);
            var B: Cardinal;
            case Next(6) of
              0: B := (Cardinal(Pick([4, 5, $14, $15])) shl 26) or (Src shl 21) or (Src shl 16) or R;
              1: B := (Cardinal(Pick([6, 7, $16, $17])) shl 26) or (Src shl 21) or R;
              2: B := (1 shl 26) or (Src shl 21) or (Pick([0, 1, 2, 3, $10, $11, $12, $13]) shl 16) or R;
              3: B := (Cardinal($11) shl 26) or (8 shl 21) or (Next(4) shl 16) or R;
            else
              B := (Cardinal($12) shl 26) or (8 shl 21) or (Next(4) shl 16) or R;
            end;
            if K = 0 then
            begin
              Code[I] := B;
              Inc(I);
            end
            else
              Op := B;
          end;
        end
        else
          Op := 0;
    else
      Op := 0;
    end;
    // (Long blocks: few branches.)
    if Sparse and (Op shr 26 in [1..7, $11, $14..$17]) and (Next(16) <> 0) then
      Op := AluInstruction;
    Code[I] := Op;
    Inc(I);
  end;
  for var K := 0 to StubCount - 1 do
  begin
    Code[StubWord + 2 * K] := $03E00008;
    Code[StubWord + 2 * K + 1] := (Next(64) shl 6) or $C;
  end;
  // The end goes back to the start.
  Code[CodeWords - 2] := (2 shl 26) or ((Start and $0FFFFFFF) shr 2);
  Code[CodeWords - 1] := 0;
end;

procedure MakeLoop(var Code: array of Cardinal; Start: Cardinal; var Pool: array of Cardinal);
begin
  // Loops of the written-out instructions on edge values, with stores into
  // their own next words and syscalls; random filler elsewhere.
  MakeProgram(Code, Start, Pool);
  var I := 0;
  while I < StubWord - 40 do
  begin
    var Len := 4 + Integer(Next(12));
    var Head := I;
    Code[I] := (9 shl 26) or (23 shl 16) or (2 + Next(20));                                    // addiu $23, $0, n
    Inc(I);
    for var K := 0 to Len - 1 do
    begin
      case Next(10) of
        0: Code[I] := (Cardinal($2B) shl 26) or (27 shl 21) or (Pick([24, 25]) shl 16) or ((Cardinal(I) + 2 + Next(3)) * 4);
        1: Code[I] := (Next(64) shl 6) or $C;
      else
        Code[I] := AluInstruction;
      end;
      if (Code[I] shr 26 = 0) and ((Code[I] shr 11) and 31 = 23) then
        Code[I] := 0;
      if (Code[I] shr 26 in [8..$F]) and ((Code[I] shr 16) and 31 = 23) then
        Code[I] := 0;
      Inc(I);
    end;
    Code[I] := (9 shl 26) or (23 shl 21) or (23 shl 16) or $FFFF;                               // addiu $23, $23, -1
    Inc(I);
    var Back := Cardinal(Head + 1 - (I + 1)) and $FFFF;
    Code[I] := (Cardinal(Pick([5, $15])) shl 26) or (23 shl 21) or Back;                       // bne(l) $23, $0
    Inc(I);
    Code[I] := AluInstruction;
    Inc(I);
    Inc(I, Integer(Next(16)));
  end;
end;

procedure SetUp(M: TMachine; const Code: array of Cardinal; Start: Cardinal; const Pool: array of Cardinal;
  const Regs: array of Cardinal; const Data: TBytes; OtherPC: Cardinal);
begin
  M.Memory.Reset;
  M.CPU.Reset;
  M.Log.Clear;
  M.CodeStart := Start;
  for var K := 0 to 3 do
    M.Pool[K] := Pool[K];
  M.Memory.WriteBytes(Start, Code[0], CodeWords * 4);
  M.Memory.WriteBytes(DataBase, Data[0], Length(Data));
  M.Memory.WriteBytes(PSPVRAMBase, Data[0], 8192);
  M.Memory.WriteBytes(PSPScratchBase, Data[0], PSPScratchSize);
  for var R := 0 to 31 do
    M.CPU.Ctx.GPR[R] := Regs[R];
  for var R := 0 to 31 do
    M.CPU.Ctx.FPR[R] := Regs[(R * 7) mod 32] xor $3F000000;
  for var R := 0 to 127 do
    M.CPU.Ctx.V[R] := PCardinal(@Data[R * 4])^;
  M.CPU.SetPC(Start);
  // (ERET's targets in the code.)
  M.CPU.COP0[12] := Regs[5] and 6;
  M.CPU.COP0[14] := Start + (Regs[6] and $3FFC);
  M.CPU.COP0[30] := Start + (Regs[7] and $3FFC);
  M.Other := M.CPU.Ctx;
  M.Other.PC := OtherPC;
  M.Other.NPC := OtherPC + 4;
  M.Other.GPR[5] := $12345;
end;

function Unlike(A, B: TMachine): string;
begin
  Result := '';
  var X := A.CPU.Ctx;
  var Y := B.CPU.Ctx;
  for var R := 0 to 31 do
    if X.GPR[R] <> Y.GPR[R] then
      Exit(Format('GPR[%d] %.8x against %.8x', [R, X.GPR[R], Y.GPR[R]]));
  if X.HI <> Y.HI then
    Exit(Format('HI %.8x against %.8x', [X.HI, Y.HI]));
  if X.LO <> Y.LO then
    Exit(Format('LO %.8x against %.8x', [X.LO, Y.LO]));
  if (X.PC <> Y.PC) or (X.NPC <> Y.NPC) then
    Exit(Format('PC %.8x NPC %.8x against %.8x %.8x', [X.PC, X.NPC, Y.PC, Y.NPC]));
  if not CompareMem(@X, @Y, SizeOf(TPSPContext)) then
    Exit('FPR, FCR31, LLBit or VFPU state');
  if A.CPU.CurPC <> B.CPU.CurPC then
    Exit(Format('CurPC %.8x against %.8x', [A.CPU.CurPC, B.CPU.CurPC]));
  if A.CPU.Stopping <> B.CPU.Stopping then
    Exit('Stopping');
  if A.CPU.InterruptsEnabled <> B.CPU.InterruptsEnabled then
    Exit('InterruptsEnabled');
  if not CompareMem(@A.CPU.COP0, @B.CPU.COP0, SizeOf(A.CPU.COP0)) then
    Exit('COP0');
  if (A.CPU.VccWritePC <> B.CPU.VccWritePC) or (A.CPU.VccWriteOld <> B.CPU.VccWriteOld) or
    (A.CPU.VcmpPC <> B.CPU.VcmpPC) or (A.CPU.VcmpOld <> B.CPU.VcmpOld) then
    Exit('VFPU condition hazard');
  if (A.Memory.Faults <> B.Memory.Faults) or (A.Memory.FaultAddress <> B.Memory.FaultAddress) then
    Exit(Format('faults %d at %.8x against %d at %.8x', [A.Memory.Faults, A.Memory.FaultAddress, B.Memory.Faults,
      B.Memory.FaultAddress]));
  if A.Log.ToString <> B.Log.ToString then
    Exit('kernel log ' + A.Log.ToString.Substring(Max(0, A.Log.Length - 80)) + ' against ' +
      B.Log.ToString.Substring(Max(0, B.Log.Length - 80)));
  if A.Error <> B.Error then
    Exit('error "' + A.Error + '" against "' + B.Error + '"');
end;

function UnlikeMemory(A, B: TMachine): string;
begin
  Result := '';
  var Pairs: array[0..2] of TBytes;
  var Others: array[0..2] of TBytes;
  Pairs[0] := A.Memory.RAM;
  Others[0] := B.Memory.RAM;
  Pairs[1] := A.Memory.VRAM;
  Others[1] := B.Memory.VRAM;
  Pairs[2] := A.Memory.Scratch;
  Others[2] := B.Memory.Scratch;
  for var K := 0 to 2 do
    if not CompareMem(@Pairs[K][0], @Others[K][0], Length(Pairs[K])) then
      for var I := 0 to High(Pairs[K]) do
        if Pairs[K][I] <> Others[K][I] then
          Exit(Format('%s %.6x: %.2x against %.2x', [RegionNames[K], I, Pairs[K][I], Others[K][I]]));
end;

function RunVectorCases(const Machines: TArray<TMachine>; Report: TStrings): Boolean;
const
  Start = $08800000;
begin
  Result := True;
  var SavedDecoder: TPSPVFPUDecoder := PSPVFPUDecoder;
  var SavedHot := PSPJitHot;
  PSPVFPUDecoder := PSP.VFPU.DecodeVFPU;
  PSPJitHot := 1;
  try
    var Code: TArray<Cardinal>;
    SetLength(Code, CodeWords);
    var Data: TBytes;
    SetLength(Data, $8000);
    for var I := 0 to High(Data) do
      Data[I] := Byte(I * 37 + I div 11);
    var Regs: array[0..31] of Cardinal;
    FillChar(Regs, SizeOf(Regs), 0);
    Regs[4] := $01234567;
    Regs[27] := Start;
    Regs[28] := DataBase;
    Regs[29] := PSPVRAMBase;
    Regs[30] := PSPScratchBase;
    var Pool: array[0..3] of Cardinal;
    for var I := 0 to 3 do
      Pool[I] := $24210001; // addiu $1, $1, 1
    var Cases := 0;
    for var Test := 0 to 255 do
    begin
      FillChar(Code[0], Length(Code) * 4, 0);
      var Reg := Cardinal(Test and 63);
      var QuadBits := ((Reg and 31) shl 16) or (Reg shr 5);
      if Test < 128 then
      begin
        // Every scalar index and register zero, plus prefixes untouched by
        // moves and loads. Each result is stored where memory comparison
        // observes it.
        for var R := 0 to 127 do
        begin
          Code[R * 4] := $48E40000 or Cardinal(R);      // mtv $4, S...
          Code[R * 4 + 1] := $48650000 or Cardinal(R);  // mfv $5, S...
          Code[R * 4 + 2] := $AC000000 or (28 shl 21) or (5 shl 16) or Cardinal(R * 4);
          Code[R * 4 + 3] := $DC0000E4; // vpfxs (unconsumed by the moves)
        end;
        // Four-word accesses near every page boundary in RAM, VRAM and
        // scratchpad, and unmapped memory (the fallback records faults).
        var Base := Cardinal(28 + (Test mod 3));
        if Test mod 7 = 0 then
          Base := 26;
        var Offset := (4096 - 20 + (Test mod 8) * 4) and $FFFC;
        Code[512] := (Cardinal($36) shl 26) or (Base shl 21) or QuadBits or Cardinal(Offset);
        Code[513] := (Cardinal($3E) shl 26) or (Base shl 21) or QuadBits or Cardinal(Offset + 32);
        Code[514] := $03E00008; // jr $31 (target set below)
        Code[515] := 0;
      end
      else
      begin
        // SV.Q changes its next four instructions. Even when its first
        // store invalidates this block, its other three must finish.
        Code[0] := (Cardinal($36) shl 26) or (30 shl 21) or QuadBits;
        Code[1] := (Cardinal($3E) shl 26) or (27 shl 21) or QuadBits or 8;
        Code[8] := $0000008C; // syscall 2: stop
      end;
      Regs[31] := Start + 516 * 4;
      for var M in Machines do
      begin
        SetUp(M, Code, Start, Pool, Regs, Data, Start);
        M.Memory.WriteBytes(PSPScratchBase, Pool[0], SizeOf(Pool));
      end;
      // A whole block first (so it is generated), then a reset of PC and
      // small budgets ending on every boundary.
      for var Round := 0 to 16 do
      begin
        if Round = 1 then
          for var M in Machines do
            M.CPU.SetPC(Start);
        var Budget := 600;
        if Round > 0 then
          Budget := Round;
        var Used := Machines[0].CPU.Run(Budget);
        for var K := 1 to High(Machines) do
        begin
          var OtherUsed := Machines[K].CPU.Run(Budget);
          var D := Unlike(Machines[0], Machines[K]);
          if (D = '') and (OtherUsed <> Used) then
            D := 'cycles';
          if D <> '' then
          begin
            Report.Add(Format('vector case %d round %d mode %d: %s', [Test, Round, K, D]));
            Exit(False);
          end;
        end;
      end;
      for var K := 1 to High(Machines) do
      begin
        var D := UnlikeMemory(Machines[0], Machines[K]);
        if D <> '' then
        begin
          Report.Add(Format('vector case %d mode %d: %s', [Test, K, D]));
          Exit(False);
        end;
      end;
      Inc(Cases);
    end;
    Report.Add(Format('%d directed VFPU cases: no difference (moves, prefixes, quads across pages, self-writing SV.Q)', [Cases]));
  finally
    PSPVFPUDecoder := SavedDecoder;
    PSPJitHot := SavedHot;
  end;
end;

function RunBranchCases(const Machines: TArray<TMachine>; Report: TStrings): Boolean;
const
  Start = $08800000;
  Forms: array[0..9] of Cardinal = ($10200000, $14200000, $50200000, $54200000, $04200000, $04210000,
    $49000000, $49010000, $49020000, $49030000);
  Values: array[0..3] of Cardinal = (0, 1, $FFFFFFFF, $80000000);
  Budgets: array[0..6] of Integer = (64, 1, 2, 3, 4, 5, 9);
begin
  Result := True;
  var SavedDecoder: TPSPVFPUDecoder := PSPVFPUDecoder;
  var SavedHot := PSPJitHot;
  PSPVFPUDecoder := PSP.VFPU.DecodeVFPU;
  PSPJitHot := 1;
  try
    var Code: TArray<Cardinal>;
    SetLength(Code, CodeWords);
    var Data: TBytes;
    SetLength(Data, $8000);
    var Regs: array[0..31] of Cardinal;
    FillChar(Regs, SizeOf(Regs), 0);
    var Pool: array[0..3] of Cardinal;
    FillChar(Pool, SizeOf(Pool), 0);
    var Cases := 0;
    for var A in Forms do
      for var B in Forms do
        for var Value in Values do
        begin
          FillChar(Code[0], Length(Code) * 4, 0);
          Code[0] := $24420001;
          Code[1] := $24630001;
          Code[2] := A or 9; // both branches target Start + 48, from CurPC + 4
          Code[3] := B or 8;
          for var I := 4 to 11 do
            Code[I] := $24840001;
          Code[12] := $24A50001;
          Code[13] := $0000008C; // syscall 2: stop
          Regs[1] := Value;
          for var M in Machines do
          begin
            SetUp(M, Code, Start, Pool, Regs, Data, Start);
            M.CPU.Ctx.VC[VFPU_CC] := Value and $3F;
            if M.Jit <> nil then
              M.Jit.Enabled := True;
          end;
          for var Budget in Budgets do
          begin
            for var M in Machines do
              M.CPU.SetPC(Start);
            var Used := Machines[0].CPU.Run(Budget);
            for var K := 1 to High(Machines) do
            begin
              var Before := Machines[K].Jit.Interpreted;
              var OtherUsed := Machines[K].CPU.Run(Budget);
              var D := Unlike(Machines[0], Machines[K]);
              if (D = '') and (OtherUsed <> Used) then
                D := 'cycles';
              if (D = '') and (Budget = 64) and (Before = Machines[K].Jit.Interpreted) then
                D := 'the delay-slot branch did not use the interpreter fallback';
              if D <> '' then
              begin
                Report.Add(Format('branch pair %.8x %.8x value %.8x budget %d mode %d: %s',
                  [A, B, Value, Budget, K, D]));
                Exit(False);
              end;
            end;
          end;
          Inc(Cases);
        end;
    Report.Add(Format('%d directed branch pairs: no difference (taken, not taken, likely, BVC, fallback and budgets)', [Cases]));
  finally
    PSPVFPUDecoder := SavedDecoder;
    PSPJitHot := SavedHot;
  end;
end;

function RunPSPJitTest(Programs: Integer; Report: TStrings): Boolean;
const
  Budgets: array[0..15] of Cardinal = (1, 1, 2, 3, 5, 7, 10, 16, 33, 64, 100, 257, 1000, 4000, 20000, 9);
begin
  Result := True;
  var Machines: TArray<TMachine>;
  Machines := [TMachine.Create(0)];
  var Names: TArray<string> := ['interpreter'];
  if JitSupported then
  begin
    Machines := Machines + [TMachine.Create(1)];
    Names := Names + ['code'];
  end;
  Machines := Machines + [TMachine.Create(2)];
  Names := Names + ['model'];
  var Code: TArray<Cardinal>;
  SetLength(Code, CodeWords);
  var Data: TBytes;
  SetLength(Data, $8000);
  var SavedHot := PSPJitHot;
  var SavedDecoder: TPSPVFPUDecoder := PSPVFPUDecoder;
  PSPVFPUDecoder := TestDecoder;
  var Ran: Int64 := 0;
  var Failed := 0;
  var Faulted := 0;
  var Verbose := FindCmdLineSwitch('v');
  try
    for var P := 0 to Programs - 1 do
    begin
      Rng := Cardinal((UInt64(P) * 2654435761 + 12345) and $FFFFFFFF);
      RealVFPU := P mod 3 = 0;
      if RealVFPU then
        PSPVFPUDecoder := PSP.VFPU.DecodeVFPU
      else
        PSPVFPUDecoder := TestDecoder;
      var Start: Cardinal := $08800000;
      case Next(8) of
        0, 1: Start := $88800000;
        2: Start := PSPVRAMBase + $100000;
      end;
      var Pool: array[0..3] of Cardinal;
      if Next(2) = 0 then
        MakeProgram(Code, Start, Pool)
      else
        MakeLoop(Code, Start, Pool);
      for var I := 0 to High(Data) do
        Data[I] := Next(256);
      // Data words that are instructions now and then.
      for var I := 0 to 63 do
        PCardinal(@Data[Next(Length(Data) div 4) * 4])^ := AluInstruction;
      var Regs: array[0..31] of Cardinal;
      for var R := 0 to 31 do
        Regs[R] := Edge32;
      Regs[0] := 0;
      Regs[24] := Pool[0];
      Regs[25] := Pool[1];
      Regs[26] := $02000000 + Next($1000) * 4;
      Regs[27] := Start;
      Regs[28] := DataBase + $2000 + Next(64) * 4;
      Regs[29] := PSPVRAMBase + $1000;
      Regs[30] := PSPScratchBase + $2000;
      Regs[31] := Start + Next(CodeWords - 2) * 4;
      var OtherPC := Start + Next(CodeWords - 2) * 4;
      PSPJitHot := Pick([1, 1, 2, 3, 8]);
      for var M in Machines do
      begin
        SetUp(M, Code, Start, Pool, Regs, Data, OtherPC);
        if M.Jit <> nil then
          M.Jit.Enabled := True;
      end;
      if FindCmdLineSwitch('mix') then
      begin
        var M := Machines[0];
        var Hist: array[0..127] of Integer;
        FillChar(Hist, SizeOf(Hist), 0);
        var Seen := TDictionary<Cardinal, Integer>.Create;
        try
          for var S := 1 to 30000 do
          begin
            var Op := M.Memory.Read32(M.CPU.Ctx.PC);
            Seen.AddOrSetValue(M.CPU.Ctx.PC, 0);
            if Op shr 26 = 0 then
              Inc(Hist[64 + (Op and 63)])
            else
              Inc(Hist[Op shr 26]);
            try
              M.CPU.Run(1);
            except
              Break;
            end;
          end;
          var Line := Format('program %d: %d addresses;', [P, Seen.Count]);
          for var K := 0 to 127 do
            if Hist[K] > 300 then
              Line := Line + Format(' %x:%d', [K, Hist[K]]);
          Report.Add(Line);
        finally
          Seen.Free;
        end;
        Continue;
      end;
      var Runs := 60 + Integer(Next(80));
      var Problem := '';
      for var R := 0 to Runs - 1 do
      begin
        var Budget := Integer(Budgets[Next(Length(Budgets))]);
        // Now and then elsewhere in the code (as a thread switch would; the
        // random branches and jumps make loops that never end).
        if Next(3) = 0 then
        begin
          var NewPC := Start + Next(CodeWords - 2) * 4;
          // (The same code through the other segment: other blocks.)
          if Next(6) = 0 then
            NewPC := NewPC xor $80000000;
          for var M in Machines do
            M.CPU.SetPC(NewPC);
        end;
        // (The recompiler switched off and on: the interpreter meanwhile.)
        var Toggle := Next(12) = 0;
        for var M in Machines do
          if (M.Jit <> nil) and (Toggle or not M.Jit.Enabled) then
            M.Jit.Enabled := not M.Jit.Enabled;
        var Results: TArray<Integer>;
        SetLength(Results, Length(Machines));
        for var K := 0 to High(Machines) do
        begin
          var M := Machines[K];
          try
            Results[K] := M.CPU.Run(Budget);
          except
            on E: Exception do
            begin
              M.Error := E.ClassName + ': ' + E.Message;
              Results[K] := -1;
            end;
          end;
        end;
        Inc(Ran, Results[0]);
        for var K := 1 to High(Machines) do
        begin
          var D := Unlike(Machines[0], Machines[K]);
          if (D = '') and (Results[K] <> Results[0]) then
            D := Format('Run returned %d against %d', [Results[0], Results[K]]);
          if D <> '' then
          begin
            Problem := Format('program %d run %d (budget %d): %s %s', [P, R, Budget, Names[K], D]);
            Break;
          end;
        end;
        if (Problem <> '') or (Machines[0].Error <> '') then
          Break;
      end;
      if Problem = '' then
        for var K := 1 to High(Machines) do
        begin
          var D := UnlikeMemory(Machines[0], Machines[K]);
          if D <> '' then
          begin
            Problem := Format('program %d: %s memory %s', [P, Names[K], D]);
            Break;
          end;
        end;
      if Problem <> '' then
      begin
        Report.Add(Problem);
        Result := False;
        Inc(Failed);
        if Failed >= 10 then
          Break;
      end;
      if Machines[0].Error <> '' then
      begin
        Inc(Faulted);
        if Verbose then
          Report.Add(Format('program %d ended: %s', [P, Machines[0].Error]));
      end;
      for var M in Machines do
        M.Error := '';
    end;
    if Result then
      Result := RunBranchCases(Machines, Report);
    if Result then
      Result := RunVectorCases(Machines, Report);
    Report.Add(Format('%d programs ended by a guest fault', [Faulted]));
    var Line := Format('%d programs, %d instructions on each', [Programs, Ran]);
    for var K := 1 to High(Machines) do
      Line := Line + Format('; %s: %d blocks compiled, %d runs of code, %d instructions interpreted', [Names[K],
        Machines[K].Jit.Compiled, Machines[K].Jit.Invokes, Machines[K].Jit.Interpreted]);
    Report.Add(Line);
    if Result then
      Report.Add('PSP JIT: no difference')
    else
      Report.Add('PSP JIT: DIFFERENCES');
  finally
    PSPJitHot := SavedHot;
    PSPVFPUDecoder := SavedDecoder;
    for var M in Machines do
      M.Free;
  end;
end;

// Instructions for the benchmarks.
function EncR(Fn, Rs, Rt, Rd: Cardinal; Sa: Cardinal = 0): Cardinal;
begin
  Result := (Rs shl 21) or (Rt shl 16) or (Rd shl 11) or (Sa shl 6) or Fn;
end;

function EncI(Op, Rs, Rt: Cardinal; Imm: Integer): Cardinal;
begin
  Result := (Op shl 26) or (Rs shl 21) or (Rt shl 16) or (Cardinal(Imm) and $FFFF);
end;

function EncJ(Op, Target: Cardinal): Cardinal;
begin
  Result := (Op shl 26) or ((Target and $0FFFFFFF) shr 2);
end;

procedure RunPSPJitBench(Report: TStrings);
const
  Start = $08800000;
  Func = Start + $100;
begin
  // Hot loops on the interpreter and on the recompiler's code (and its
  // model): instructions per second. Loop: loads, stores, ALU, a branch.
  // Calls: a call (JAL, JR) of a function with MULT, MFLO, SRA, SLTU, MOVN,
  // halfword loads, a likely branch.
  var Loop: TArray<Cardinal> := [
    EncI($F, 0, 8, $0890),                  // lui $8, 0x0890
    EncI(9, 0, 9, 256),                     // addiu $9, $0, 256
    EncR($21, 0, 0, 10),                    // addu $10, $0, $0
    EncI($23, 8, 11, 0),                    // L: lw $11, 0($8)
    EncR($21, 10, 11, 10),                  // addu $10, $10, $11
    EncR($26, 10, 11, 12),                  // xor $12, $10, $11
    EncR(0, 0, 12, 13, 3),                  // sll $13, $12, 3
    EncI($2B, 8, 13, 1024),                 // sw $13, 1024($8)
    EncI(9, 8, 8, 4),                       // addiu $8, $8, 4
    EncR($2A, 10, 13, 14),                  // slt $14, $10, $13
    EncI(9, 9, 9, -1),                      // addiu $9, $9, -1
    EncI(5, 9, 0, -9),                      // bne $9, $0, L
    EncI($C, 14, 15, 7),                    // andi $15, $14, 7
    EncJ(2, Start),                         // j Start
    0];
  var Calls: TArray<Cardinal> := [
    EncI($F, 0, 8, $0890),                  // lui $8, 0x0890
    EncI(9, 0, 9, 200),                     // addiu $9, $0, 200
    EncI($23, 8, 4, 0),                     // L: lw $4, 0($8)
    EncI($21, 8, 5, 6),                     // lh $5, 6($8)
    EncJ(3, Func),                          // jal Func
    EncI(9, 8, 8, 8),                       // addiu $8, $8, 8
    EncI($29, 8, 2, 2048),                  // sh $2, 2048($8)
    EncI($25, 8, 6, 2050),                  // lhu $6, 2050($8)
    EncR($21, 6, 2, 7),                     // addu $7, $6, $2
    EncI(9, 9, 9, -1),                      // addiu $9, $9, -1
    EncI($15, 9, 0, -9),                    // bnel $9, $0, L
    EncI($2B, 8, 7, 4096),                  // sw $7, 4096($8)
    EncJ(2, Start),                         // j Start
    0];
  var FuncCode: TArray<Cardinal> := [
    EncR($18, 4, 5, 0),                     // mult $4, $5
    EncR($12, 0, 0, 2),                     // mflo $2
    EncR(3, 0, 2, 2, 4),                    // sra $2, $2, 4
    EncR($2B, 2, 4, 3),                     // sltu $3, $2, $4
    EncR($0B, 4, 3, 2),                     // movn $2, $4, $3
    EncR(8, 31, 0, 0),                      // jr $31
    EncI($C, 2, 2, $FFFF)];                 // andi $2, $2, 0xFFFF
  var Vector: TArray<Cardinal> := [
    EncI($F, 0, 8, $0890),
    EncI(9, 0, 9, 256),
    $D9000000,                              // L: lv.q C000, 0($8)
    $486A0000,                              // mfv $10, S000
    $48EA001F,                              // mtv $10, S731
    $F9001000,                              // sv.q C000, 4096($8)
    $C900000E,                              // lv.s S002, 12($8)
    $486B0040,                              // mfv $11, S002
    $E900081F,                              // sv.s S733, 2076($8)
    EncI(9, 8, 8, 16),
    EncI(9, 9, 9, -1),
    EncI(5, 9, 0, -10),
    EncR($26, 10, 11, 12),
    EncJ(2, Start),
    0];
  for var Work := 0 to 2 do
    for var Kind := 0 to 2 do
    begin
      if (Kind = 1) and not JitSupported then
        Continue;
      var M := TMachine.Create(Kind);
      try
        case Work of
          0: M.Memory.WriteBytes(Start, Loop[0], Length(Loop) * 4);
          1:
            begin
              M.Memory.WriteBytes(Start, Calls[0], Length(Calls) * 4);
              M.Memory.WriteBytes(Func, FuncCode[0], Length(FuncCode) * 4);
            end;
          2: M.Memory.WriteBytes(Start, Vector[0], Length(Vector) * 4);
        end;
        M.CPU.SetPC(Start);
        var Total: Int64;
        var Target: Int64 := 100000000;
        case Kind of
          1: Target := 1000000000;
          2: Target := 5000000;
        end;
        // (The best of three: other programs share the host.)
        var S := 1E9;
        for var Round := 1 to 3 do
        begin
          var Done: Int64 := 0;
          var W := TStopwatch.StartNew;
          while Done < Target do
            Inc(Done, M.CPU.Run(1000000));
          S := Min(S, W.Elapsed.TotalSeconds);
          Total := Done;
        end;
        var WorkName := 'loop';
        if Work = 1 then
          WorkName := 'calls'
        else if Work = 2 then
          WorkName := 'vector';
        Report.Add(Format('%-6s %-12s %7.1f M instructions/s (%d in %.2f s)', [WorkName, KindNames[Kind],
          Total / S / 1E6, Total, S]));
      finally
        M.Free;
      end;
    end;
end;

end.