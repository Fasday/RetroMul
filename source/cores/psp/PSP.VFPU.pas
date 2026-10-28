unit PSP.VFPU;

// The VFPU (COP2): 128 single-precision registers in 8 4x4 matrices, prefixes,
// and its load/store instructions. Installs its decoder into PSP.CPU.
// A register field names S<m><c><r>; Ctx.V holds it at m*16 + c*4 + r, so a
// column is four consecutive words.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$EXCESSPRECISION OFF}
{$POINTERMATH ON}

interface

uses
  System.SysUtils, System.Math, PSP.Types, PSP.Memory, PSP.CPU, PSP.VFPU.Math;

function DecodeVFPU(Op: Cardinal): TPSPOpHandler;

implementation

type
  TV4 = array[0..3] of Cardinal;
  TIdx4 = array[0..3] of Byte;
  PIdx4 = ^TIdx4;
  TBinFn = function(A, B: Cardinal): Cardinal;
  TUnFn = function(A: Cardinal): Cardinal;

const
  PFX_NONE = $E4;
  PfxConst: array[0..7] of Cardinal = ($00000000, $3F800000, $40000000, $3F000000,
    $40400000, $3EAAAAAB, $3E800000, $3E2AAAAB);
  PastLanes: array[1..4] of Cardinal = ($E, $C, $8, $0);
  Ones: TV4 = ($3F800000, $3F800000, $3F800000, $3F800000);

var
  VecIdx: array[0..3, 0..127] of TIdx4;
  MatIdx: array[0..3, 0..127, 0..3] of TIdx4;

procedure InitTables;
begin
  for var R := 0 to 127 do
  begin
    var M := (R shr 2) and 7;
    var A := R and 3;
    var Tr := (R shr 5) and 1;
    for var N := 1 to 4 do
    begin
      var B: Integer;
      case N of
        1: B := (R shr 5) and 3;
        3: B := (R shr 6) and 1;
      else
        B := (R shr 5) and 2;
      end;
      for var K := 0 to 3 do
        for var I := 0 to 3 do
        begin
          var Col, Row: Integer;
          if N = 1 then
          begin
            Col := A;
            Row := B;
          end
          else if Tr = 0 then
          begin
            Col := (A + K) and 3;
            Row := (B + I) and 3;
          end
          else
          begin
            Col := (B + I) and 3;
            Row := (A + K) and 3;
          end;
          MatIdx[N - 1, R, K][I] := M * 16 + Col * 4 + Row;
        end;
      VecIdx[N - 1, R] := MatIdx[N - 1, R, 0];
    end;
  end;
end;

{ Fields }

function RegD(Op: Cardinal): Cardinal; inline;
begin
  Result := Op and $7F;
end;

function RegS(Op: Cardinal): Cardinal; inline;
begin
  Result := (Op shr 8) and $7F;
end;

function RegT(Op: Cardinal): Cardinal; inline;
begin
  Result := (Op shr 16) and $7F;
end;

function VSz(Op: Cardinal): Integer; inline;
begin
  Result := 1 + Integer((Op shr 7) and 1) + Integer((Op shr 14) and 2);
end;

function GPRs(C: TPSPCPU; Op: Cardinal): Cardinal; inline;
begin
  Result := C.Ctx.GPR[(Op shr 21) and 31];
end;

function Imm16(Op: Cardinal): Cardinal; inline;
begin
  Result := Cardinal(Integer(SmallInt(Word(Op and $FFFC))));
end;

{ Registers and prefixes }

procedure LoadV(C: TPSPCPU; Reg: Cardinal; N: Integer; var R: TV4); inline;
begin
  var P: PIdx4 := @VecIdx[N - 1, Reg];
  for var I := 0 to 3 do
    if I < N then
      R[I] := C.Ctx.V[P[I]]
    else
      R[I] := 0;
end;

procedure StoreV(C: TPSPCPU; Reg: Cardinal; N: Integer; const R: TV4); inline;
begin
  var P: PIdx4 := @VecIdx[N - 1, Reg];
  for var I := 0 to N - 1 do
    C.Ctx.V[P[I]] := R[I];
end;

// Applies an S/T prefix to the lanes read; returns the lanes whose swizzle
// points past the vector, which come out as zero.
function ApplyPfx(const Src: TV4; N: Integer; Pfx: Cardinal; var Dst: TV4): Cardinal;
begin
  Result := 0;
  for var I := 0 to 3 do
  begin
    var Swz := (Pfx shr (I * 2)) and 3;
    var V: Cardinal;
    if ((Pfx shr (12 + I)) and 1) <> 0 then
      V := PfxConst[Swz or (((Pfx shr (8 + I)) and 1) shl 2)]
    else if Integer(Swz) >= N then
    begin
      Result := Result or (Cardinal(1) shl I);
      V := 0;
    end
    else
    begin
      V := Src[Swz];
      if ((Pfx shr (8 + I)) and 1) <> 0 then
        V := V and $7FFFFFFF;
    end;
    if ((Pfx shr (16 + I)) and 1) <> 0 then
      V := V xor $80000000;
    Dst[I] := V;
  end;
end;

function ReadPfx(C: TPSPCPU; Reg: Cardinal; N: Integer; Pfx: Cardinal; var R: TV4): Cardinal;
begin
  if Pfx = PFX_NONE then
  begin
    LoadV(C, Reg, N, R);
    Result := PastLanes[N];
  end
  else
  begin
    var Raw: TV4;
    LoadV(C, Reg, N, Raw);
    Result := ApplyPfx(Raw, N, Pfx, R);
  end;
end;

procedure Latch(C: TPSPCPU; const R: TV4; Lanes: Cardinal); inline;
begin
  for var I := 0 to 3 do
    if ((Lanes shr I) and 1) <> 0 then
      C.VLatch[I] := R[I];
end;

function ReadS(C: TPSPCPU; Op: Cardinal; N: Integer; var R: TV4): Cardinal; inline;
begin
  Result := ReadPfx(C, RegS(Op), N, C.Ctx.VC[VFPU_PFXS], R);
  if C.Ctx.VC[VFPU_PFXS] <> PFX_NONE then
    Latch(C, R, not Result and $F);
end;

// The S read of the unpack instructions: lanes the swizzle can't reach replay
// the latch instead of reading zero, and unprefixed reads latch too.
procedure ReadSL(C: TPSPCPU; Op: Cardinal; N: Integer; var R: TV4);
begin
  var Pfx := C.Ctx.VC[VFPU_PFXS];
  if Pfx = PFX_NONE then
  begin
    LoadV(C, RegS(Op), N, R);
    Latch(C, R, (Cardinal(1) shl N) - 1);
    Exit;
  end;
  var Raw: TV4;
  LoadV(C, RegS(Op), N, Raw);
  var Z := ApplyPfx(Raw, N, Pfx, R);
  Latch(C, R, not Z and $F);
  for var I := 0 to 3 do
    if ((Z shr I) and 1) <> 0 then
      R[I] := C.VLatch[I];
end;

function ReadT(C: TPSPCPU; Op: Cardinal; N: Integer; var R: TV4): Cardinal; inline;
begin
  Result := ReadPfx(C, RegT(Op), N, C.Ctx.VC[VFPU_PFXT], R);
end;

function SatLane(V, Mode: Cardinal): Cardinal; inline;
begin
  case Mode of
    1: Result := VSat0(V);
    3: Result := VSat1(V);
  else
    Result := V;
  end;
end;

procedure WritePfx(C: TPSPCPU; Reg: Cardinal; N: Integer; const R: TV4; Zero, DPfx: Cardinal);
begin
  var P: PIdx4 := @VecIdx[N - 1, Reg];
  Zero := Zero and ((Cardinal(1) shl N) - 1);
  if (DPfx or Zero) = 0 then
  begin
    for var I := 0 to N - 1 do
      C.Ctx.V[P[I]] := R[I];
    Exit;
  end;
  for var I := 0 to N - 1 do
  begin
    if ((DPfx shr (8 + I)) and 1) <> 0 then
      Continue;
    var V := R[I];
    if ((Zero shr I) and 1) <> 0 then
      V := 0;
    C.Ctx.V[P[I]] := SatLane(V, (DPfx shr (I * 2)) and 3);
  end;
end;

procedure WriteD(C: TPSPCPU; Op: Cardinal; N: Integer; const R: TV4; Zero: Cardinal); inline;
begin
  WritePfx(C, RegD(Op), N, R, Zero, C.Ctx.VC[VFPU_PFXD]);
end;

procedure EatPfx(C: TPSPCPU); inline;
begin
  C.Ctx.VC[VFPU_PFXS] := PFX_NONE;
  C.Ctx.VC[VFPU_PFXT] := PFX_NONE;
  C.Ctx.VC[VFPU_PFXD] := 0;
end;

// The function unit and the dividers work lane by lane; only the last lane
// they produce sees the prefixes, and it sees lane 0 of them, with x naming
// its own value.
function LastIn(Pfx, V: Cardinal; var Zero: Boolean): Cardinal;
begin
  if ((Pfx shr 12) and 1) <> 0 then
    Result := PfxConst[(Pfx and 3) or (((Pfx shr 8) and 1) shl 2)]
  else if (Pfx and 3) <> 0 then
  begin
    Zero := True;
    Result := 0;
  end
  else
  begin
    Result := V;
    if ((Pfx shr 8) and 1) <> 0 then
      Result := Result and $7FFFFFFF;
  end;
  if ((Pfx shr 16) and 1) <> 0 then
    Result := Result xor $80000000;
end;

procedure WriteLast(C: TPSPCPU; Reg: Cardinal; N: Integer; const R: TV4; Zero: Boolean);
begin
  var P: PIdx4 := @VecIdx[N - 1, Reg];
  for var I := 0 to N - 2 do
    C.Ctx.V[P[I]] := R[I];
  var D := C.Ctx.VC[VFPU_PFXD];
  if (D and $100) <> 0 then
    Exit;
  var V := R[N - 1];
  if Zero then
    V := 0;
  C.Ctx.V[P[N - 1]] := SatLane(V, D and 3);
end;

{$I PSP.VFPU.Arith.inc}
{$I PSP.VFPU.Conv.inc}
{$I PSP.VFPU.Matrix.inc}
{$I PSP.VFPU.Decode.inc}

initialization
  InitTables;
  PSPVFPUDecoder := DecodeVFPU;

end.
