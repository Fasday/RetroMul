unit PSP.GE.Engine;

// The GE's command processor below list control: register writes, matrix
// uploads, vertex processing (decode, morph, skinning, transform, lighting,
// texture coordinate generation), primitive assembly, CLUT loads and block
// transfers. Flow commands (JUMP, CALL, END, ...) are run by the list driver
// in PSP.GE, which owns the program counter. Rasterization is in
// PSP.GE.Raster and works on a snapshot (TGERaster) built here.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$EXCESSPRECISION OFF}

interface

uses
  System.SysUtils, System.Math, PSP.Types, PSP.Memory, PSP.GE.Types, PSP.GE.Texture, PSP.GE.Raster, PSP.GE.Backend;

type
  TGEVec3 = record
    X, Y, Z: Single;
  end;

  // A decoded vertex before transform.
  TGEInVertex = record
    U, V: Single;
    R, G, B, A: Integer;
    HasColor: Boolean;
    N: TGEVec3;
    P: TGEVec3;
    Weights: array[0..7] of Single;
  end;

  TPSPGEEngine = class
  private
    FMemory: TPSPMemory;
    FClut: array[0..1023] of Byte;
    FRaster: TGERaster;
    FVSize: Integer;
    FOffTC, FOffC, FOffN, FOffP: Integer;
    FPrimCost: Int64;
    FAsmType, FAsmCount: Integer;
    FLastU, FLastV: Single;
    FLastN: TGEVec3;
    FAsmBuf: array[0..2] of TGEVertex;
    FAsmClip: array[0..2] of Boolean;
    FCullOn, FCullCW: Boolean;
    procedure SetupVertexFormat(VType: Cardinal);
    procedure DecodeVertex(Addr, VType: Cardinal; out V: TGEInVertex);
    function ReadVertex(Index: Integer; VType: Cardinal; out V: TGEInVertex): Boolean;
    procedure Skin(const V: TGEInVertex; VType: Cardinal; var P, N: TGEVec3);
    procedure Light(const V: TGEInVertex; const WP, WN: TGEVec3; var R, G, B, A, SR, SG, SB: Integer);
    function LightVector(L: Integer; const WP: TGEVec3): TGEVec3;
    procedure TexGen(const V: TGEInVertex; const WP, WN: TGEVec3; out S, T: Single);
    procedure TransformVertex(const V: TGEInVertex; VType: Cardinal; out O: TGEVertex; out Clip: Boolean);
    procedure BuildRaster;
    function ScissoredArea(X1, Y1, X2, Y2: Integer): Int64;
    procedure EmitTriangle(const A, B, C: TGEVertex; Odd: Boolean);
    procedure AddVertex(const V: TGEVertex; Clip: Boolean);
    procedure DrawPrim(Op: Cardinal);
    procedure ImmediateVertex(Op: Cardinal);
    procedure LoadClut(Op: Cardinal);
    procedure BlockTransfer(Op: Cardinal);
  public
    Regs: TPSPGERegs;
    // Set by BBOX: the box is (possibly) visible.
    BoxVisible: Boolean;
    // Draws the primitives instead of PSP.GE.Raster when set (not owned).
    Backend: TGERasterBackend;
    constructor Create(Memory: TPSPMemory);
    // Guest memory holds everything drawn: the GE stops here.
    procedure SyncBackend; inline;
    procedure Reset;
    // Address of a 24-bit pointer parameter with the BASE upper bits and OFFSET.
    function Address(Param: Cardinal): Cardinal; inline;
    // Runs one command; returns its cost in GE nanoseconds.
    function Execute(Op, PC: Cardinal): Integer;
    procedure SaveContext(Address: Cardinal);
    procedure RestoreContext(Address: Cardinal);
    property Memory: TPSPMemory read FMemory;
  end;

const
  // Context words: a header, then the state commands in this order, then the matrices.
  GEContextCmdStart = 17;

var
  GEContextCmds: array of Byte;

implementation

constructor TPSPGEEngine.Create(Memory: TPSPMemory);
begin
  inherited Create;
  FMemory := Memory;
  Reset;
end;

procedure TPSPGEEngine.SyncBackend;
begin
  if Backend <> nil then
    Backend.Sync;
end;

procedure TPSPGEEngine.Reset;
begin
  Regs := Default(TPSPGERegs);
  for var I := 0 to 255 do
    Regs.Cmd[I] := Cardinal(I) shl 24;
  BoxVisible := True;
  FillChar(FClut, SizeOf(FClut), 0);
end;

function TPSPGEEngine.Address(Param: Cardinal): Cardinal;
begin
  Result := (((Regs.Cmd[GE_BASE] and $0F0000) shl 8) or (Param and $FFFFFF)) + Regs.Offset;
end;

function TPSPGEEngine.Execute(Op, PC: Cardinal): Integer;
begin
  Result := 12;
  var Cmd := Op shr 24;
  var P := Op and $FFFFFF;
  case Cmd of
    GE_VADDR:
      Regs.VAddr := Address(P);
    GE_IADDR:
      Regs.IAddr := Address(P);
    GE_PRIM:
      begin
        Regs.Cmd[Cmd] := Op;
        // Primitive setup, per vertex and per pixel.
        FPrimCost := 1000;
        DrawPrim(Op);
        Exit(4 + Integer(Min(FPrimCost, 100000000)));
      end;
    GE_BBOX:
      BoxVisible := (P and $FFFF) <> 0;
    $F7:
      begin
        Regs.Cmd[Cmd] := Op;
        FPrimCost := 0;
        ImmediateVertex(Op);
        Exit(12 + Integer(Min(FPrimCost, 100000000)));
      end;
    GE_OFFSETADDR:
      Regs.Offset := P shl 8;
    GE_ORIGIN:
      Regs.Offset := PC;
    GE_LOADCLUT:
      begin
        Regs.Cmd[Cmd] := Op;
        LoadClut(Op);
        Exit(4 + Integer(P and $3F) * 8);
      end;
    GE_TRANSFERSTART:
      begin
        Regs.Cmd[Cmd] := Op;
        FPrimCost := 0;
        BlockTransfer(Op);
        Exit(4 + Integer(Min(FPrimCost, 100000000)));
      end;
    GE_BONEMATRIXNUMBER:
      Regs.BoneNum := P and $7F;
    GE_BONEMATRIXDATA:
      begin
        if Regs.BoneNum < 96 then
          Regs.Bone[Regs.BoneNum] := P;
        Regs.BoneNum := (Regs.BoneNum + 1) and $7F;
        Exit;
      end;
    GE_WORLDMATRIXNUMBER:
      Regs.WorldNum := P and $F;
    GE_WORLDMATRIXDATA:
      begin
        if Regs.WorldNum < 12 then
          Regs.World[Regs.WorldNum] := P;
        Regs.WorldNum := (Regs.WorldNum + 1) and $F;
        Exit;
      end;
    GE_VIEWMATRIXNUMBER:
      Regs.ViewNum := P and $F;
    GE_VIEWMATRIXDATA:
      begin
        if Regs.ViewNum < 12 then
          Regs.View[Regs.ViewNum] := P;
        Regs.ViewNum := (Regs.ViewNum + 1) and $F;
        Exit;
      end;
    GE_PROJMATRIXNUMBER:
      Regs.ProjNum := P and $F;
    GE_PROJMATRIXDATA:
      begin
        Regs.Proj[Regs.ProjNum and 15] := P;
        Regs.ProjNum := (Regs.ProjNum + 1) and $F;
        Exit;
      end;
    GE_TGENMATRIXNUMBER:
      Regs.TGenNum := P and $F;
    GE_TGENMATRIXDATA:
      begin
        if Regs.TGenNum < 12 then
          Regs.TGen[Regs.TGenNum] := P;
        Regs.TGenNum := (Regs.TGenNum + 1) and $F;
        Exit;
      end;
  end;
  Regs.Cmd[Cmd] := Op;
end;

{ Vertex format }

const
  TCSize: array[0..3] of Integer = (0, 1, 2, 4);
  ColSize: array[0..7] of Integer = (0, 0, 0, 0, 2, 2, 2, 4);
  NrmSize: array[0..3] of Integer = (0, 1, 2, 4);
  WgtSize: array[0..3] of Integer = (0, 1, 2, 4);

procedure TPSPGEEngine.SetupVertexFormat(VType: Cardinal);
begin
  var Tc := VType and 3;
  var Col := (VType shr 2) and 7;
  var Nrm := (VType shr 5) and 3;
  var Pos := (VType shr 7) and 3;
  var Wgt := (VType shr 9) and 3;
  var WCount := Integer((VType shr 14) and 7) + 1;
  var Off := 0;
  var MaxAlign := 1;
  if Wgt <> 0 then
  begin
    Off := WgtSize[Wgt] * WCount;
    MaxAlign := Max(MaxAlign, WgtSize[Wgt]);
  end;
  if Tc <> 0 then
  begin
    Off := (Off + TCSize[Tc] - 1) and not (TCSize[Tc] - 1);
    FOffTC := Off;
    Inc(Off, TCSize[Tc] * 2);
    MaxAlign := Max(MaxAlign, TCSize[Tc]);
  end;
  if Col <> 0 then
  begin
    var S := ColSize[Col];
    if S = 0 then
      S := 1;
    Off := (Off + S - 1) and not (S - 1);
    FOffC := Off;
    Inc(Off, ColSize[Col]);
    MaxAlign := Max(MaxAlign, S);
  end;
  if Nrm <> 0 then
  begin
    Off := (Off + NrmSize[Nrm] - 1) and not (NrmSize[Nrm] - 1);
    FOffN := Off;
    Inc(Off, NrmSize[Nrm] * 3);
    MaxAlign := Max(MaxAlign, NrmSize[Nrm]);
  end;
  if Pos <> 0 then
  begin
    Off := (Off + NrmSize[Pos] - 1) and not (NrmSize[Pos] - 1);
    FOffP := Off;
    Inc(Off, NrmSize[Pos] * 3);
    MaxAlign := Max(MaxAlign, NrmSize[Pos]);
  end;
  FVSize := (Off + MaxAlign - 1) and not (MaxAlign - 1);
end;

procedure TPSPGEEngine.DecodeVertex(Addr, VType: Cardinal; out V: TGEInVertex);
var
  M: TPSPMemory;
  Through: Boolean;
begin
  M := FMemory;
  V := Default(TGEInVertex);
  Through := (VType and (1 shl 23)) <> 0;
  var Tc := VType and 3;
  var Col := (VType shr 2) and 7;
  var Nrm := (VType shr 5) and 3;
  var Pos := (VType shr 7) and 3;
  var Wgt := (VType shr 9) and 3;
  var WCount := Integer((VType shr 14) and 7) + 1;
  if Wgt <> 0 then
    for var I := 0 to WCount - 1 do
      case Wgt of
        1: V.Weights[I] := M.Read8(Addr + Cardinal(I)) / 128;
        2: V.Weights[I] := M.Read16(Addr + Cardinal(I * 2)) / 32768;
        3: V.Weights[I] := M.ReadFloat(Addr + Cardinal(I * 4));
      end;
  case Tc of
    0:
      begin
        // Formats without texture coordinates or normals use the last ones read.
        V.U := FLastU;
        V.V := FLastV;
      end;
    1:
      begin
        // Also in through mode, where they are texels / 128.
        V.U := M.Read8(Addr + Cardinal(FOffTC)) / 128;
        V.V := M.Read8(Addr + Cardinal(FOffTC) + 1) / 128;
      end;
    2:
      begin
        V.U := M.Read16(Addr + Cardinal(FOffTC));
        V.V := M.Read16(Addr + Cardinal(FOffTC) + 2);
        if not Through then
        begin
          V.U := V.U / 32768;
          V.V := V.V / 32768;
        end;
      end;
    3:
      begin
        V.U := M.ReadFloat(Addr + Cardinal(FOffTC));
        V.V := M.ReadFloat(Addr + Cardinal(FOffTC) + 4);
      end;
  end;
  FLastU := V.U;
  FLastV := V.V;
  if Col >= 4 then
  begin
    V.HasColor := True;
    var CA := Addr + Cardinal(FOffC);
    case Col of
      4:
        begin
          var C := M.Read16(CA);
          var R := C and $1F; var G := (C shr 5) and $3F; var B := (C shr 11) and $1F;
          V.R := (R shl 3) or (R shr 2); V.G := (G shl 2) or (G shr 4); V.B := (B shl 3) or (B shr 2); V.A := 255;
        end;
      5:
        begin
          var C := M.Read16(CA);
          var R := C and $1F; var G := (C shr 5) and $1F; var B := (C shr 10) and $1F;
          V.R := (R shl 3) or (R shr 2); V.G := (G shl 3) or (G shr 2); V.B := (B shl 3) or (B shr 2);
          V.A := Ord((C and $8000) <> 0) * 255;
        end;
      6:
        begin
          var C := M.Read16(CA);
          V.R := (C and $F) * 17; V.G := ((C shr 4) and $F) * 17; V.B := ((C shr 8) and $F) * 17; V.A := ((C shr 12) and $F) * 17;
        end;
      7:
        begin
          var C := M.Read32(CA);
          V.R := C and $FF; V.G := (C shr 8) and $FF; V.B := (C shr 16) and $FF; V.A := C shr 24;
        end;
    end;
  end;
  if Nrm <> 0 then
  begin
    var NA := Addr + Cardinal(FOffN);
    case Nrm of
      1:
        begin
          V.N.X := ShortInt(M.Read8(NA)) / 128; V.N.Y := ShortInt(M.Read8(NA + 1)) / 128; V.N.Z := ShortInt(M.Read8(NA + 2)) / 128;
        end;
      2:
        begin
          V.N.X := SmallInt(M.Read16(NA)) / 32768; V.N.Y := SmallInt(M.Read16(NA + 2)) / 32768; V.N.Z := SmallInt(M.Read16(NA + 4)) / 32768;
        end;
      3:
        begin
          V.N.X := M.ReadFloat(NA); V.N.Y := M.ReadFloat(NA + 4); V.N.Z := M.ReadFloat(NA + 8);
        end;
    end;
    FLastN := V.N;
  end
  else
    V.N := FLastN;
  if Pos <> 0 then
  begin
    var PA := Addr + Cardinal(FOffP);
    case Pos of
      1:
        // Through mode has no 8-bit positions: they read as the origin.
        if not Through then
        begin
          V.P.X := ShortInt(M.Read8(PA)) / 128; V.P.Y := ShortInt(M.Read8(PA + 1)) / 128; V.P.Z := ShortInt(M.Read8(PA + 2)) / 128;
        end;
      2:
        if Through then
        begin
          V.P.X := SmallInt(M.Read16(PA)); V.P.Y := SmallInt(M.Read16(PA + 2)); V.P.Z := M.Read16(PA + 4);
        end
        else
        begin
          V.P.X := SmallInt(M.Read16(PA)) / 32768; V.P.Y := SmallInt(M.Read16(PA + 2)) / 32768; V.P.Z := SmallInt(M.Read16(PA + 4)) / 32768;
        end;
      3:
        begin
          V.P.X := M.ReadFloat(PA); V.P.Y := M.ReadFloat(PA + 4); V.P.Z := M.ReadFloat(PA + 8);
        end;
    end;
  end;
end;

function TPSPGEEngine.ReadVertex(Index: Integer; VType: Cardinal; out V: TGEInVertex): Boolean;
begin
  var Morphs := Integer((VType shr 18) and 7) + 1;
  var Base := Regs.VAddr + Cardinal(Index * FVSize * Morphs);
  if Morphs = 1 then
  begin
    DecodeVertex(Base, VType, V);
    Exit(True);
  end;
  V := Default(TGEInVertex);
  var CR, CG, CB, CA: Single;
  CR := 0; CG := 0; CB := 0; CA := 0;
  for var M := 0 to Morphs - 1 do
  begin
    var W := GEFloat(Regs.Cmd[GE_MORPHWEIGHT0 + M]);
    var T: TGEInVertex;
    DecodeVertex(Base + Cardinal(M * FVSize), VType, T);
    V.U := V.U + T.U * W;
    V.V := V.V + T.V * W;
    V.N.X := V.N.X + T.N.X * W; V.N.Y := V.N.Y + T.N.Y * W; V.N.Z := V.N.Z + T.N.Z * W;
    V.P.X := V.P.X + T.P.X * W; V.P.Y := V.P.Y + T.P.Y * W; V.P.Z := V.P.Z + T.P.Z * W;
    CR := CR + T.R * W; CG := CG + T.G * W; CB := CB + T.B * W; CA := CA + T.A * W;
    V.HasColor := T.HasColor;
    for var I := 0 to 7 do
      V.Weights[I] := V.Weights[I] + T.Weights[I] * W;
  end;
  V.R := EnsureRange(Trunc(CR), 0, 255);
  V.G := EnsureRange(Trunc(CG), 0, 255);
  V.B := EnsureRange(Trunc(CB), 0, 255);
  V.A := EnsureRange(Trunc(CA), 0, 255);
  Result := True;
end;

{ Transform and lighting }

function Color24(C: Cardinal; out R, G, B: Integer): Boolean; inline;
begin
  R := C and $FF;
  G := (C shr 8) and $FF;
  B := (C shr 16) and $FF;
  Result := True;
end;

procedure TPSPGEEngine.Skin(const V: TGEInVertex; VType: Cardinal; var P, N: TGEVec3);
var
  KX, KY, KZ, TX, TY, TZ, W: Single;
  I, Bo, WCount: Integer;
begin
  WCount := Integer((VType shr 14) and 7) + 1;
  KX := 0; KY := 0; KZ := 0; TX := 0; TY := 0; TZ := 0;
  for I := 0 to WCount - 1 do
  begin
    W := V.Weights[I];
    Bo := I * 12;
    KX := KX + W * (GEFloat(Regs.Bone[Bo]) * P.X + GEFloat(Regs.Bone[Bo + 3]) * P.Y + GEFloat(Regs.Bone[Bo + 6]) * P.Z + GEFloat(Regs.Bone[Bo + 9]));
    KY := KY + W * (GEFloat(Regs.Bone[Bo + 1]) * P.X + GEFloat(Regs.Bone[Bo + 4]) * P.Y + GEFloat(Regs.Bone[Bo + 7]) * P.Z + GEFloat(Regs.Bone[Bo + 10]));
    KZ := KZ + W * (GEFloat(Regs.Bone[Bo + 2]) * P.X + GEFloat(Regs.Bone[Bo + 5]) * P.Y + GEFloat(Regs.Bone[Bo + 8]) * P.Z + GEFloat(Regs.Bone[Bo + 11]));
    TX := TX + W * (GEFloat(Regs.Bone[Bo]) * N.X + GEFloat(Regs.Bone[Bo + 3]) * N.Y + GEFloat(Regs.Bone[Bo + 6]) * N.Z);
    TY := TY + W * (GEFloat(Regs.Bone[Bo + 1]) * N.X + GEFloat(Regs.Bone[Bo + 4]) * N.Y + GEFloat(Regs.Bone[Bo + 7]) * N.Z);
    TZ := TZ + W * (GEFloat(Regs.Bone[Bo + 2]) * N.X + GEFloat(Regs.Bone[Bo + 5]) * N.Y + GEFloat(Regs.Bone[Bo + 8]) * N.Z);
  end;
  P.X := KX; P.Y := KY; P.Z := KZ;
  N.X := TX; N.Y := TY; N.Z := TZ;
end;

function MulPoint(const M: array of Cardinal; const P: TGEVec3): TGEVec3;
begin
  Result.X := GEFloat(M[0]) * P.X + GEFloat(M[3]) * P.Y + GEFloat(M[6]) * P.Z + GEFloat(M[9]);
  Result.Y := GEFloat(M[1]) * P.X + GEFloat(M[4]) * P.Y + GEFloat(M[7]) * P.Z + GEFloat(M[10]);
  Result.Z := GEFloat(M[2]) * P.X + GEFloat(M[5]) * P.Y + GEFloat(M[8]) * P.Z + GEFloat(M[11]);
end;

function MulDir(const M: array of Cardinal; const P: TGEVec3): TGEVec3;
begin
  Result.X := GEFloat(M[0]) * P.X + GEFloat(M[3]) * P.Y + GEFloat(M[6]) * P.Z;
  Result.Y := GEFloat(M[1]) * P.X + GEFloat(M[4]) * P.Y + GEFloat(M[7]) * P.Z;
  Result.Z := GEFloat(M[2]) * P.X + GEFloat(M[5]) * P.Y + GEFloat(M[8]) * P.Z;
end;

function Normalized(const P: TGEVec3): TGEVec3;
var
  L: Single;
begin
  L := Sqrt(P.X * P.X + P.Y * P.Y + P.Z * P.Z);
  if L > 0 then
  begin
    Result.X := P.X / L; Result.Y := P.Y / L; Result.Z := P.Z / L;
  end
  else
    Result := P;
end;

{ The vertex unit's arithmetic: 24-bit floats (a 16-bit significand),
  truncated after every operation; an add first truncates both terms to the
  precision of the larger one. }

function T24(V: Double): Double;
var
  E: Integer;
  M: Double;
begin
  if (V = 0) or IsNan(V) or IsInfinite(V) then
    Exit(V);
  Frexp(V, M, E);
  // |M| in [0.5, 1): 16 significant bits.
  Result := Ldexp(Int(M * 65536), E - 16);
end;

function Exp24(V: Double): Integer; inline;
var
  M: Double;
begin
  Frexp(V, M, Result);
end;

function Add24(A, B: Double): Double;
begin
  if A = 0 then
    Exit(T24(B));
  if B = 0 then
    Exit(T24(A));
  var E := Max(Exp24(A), Exp24(B));
  var Ulp := Ldexp(1, E - 16);
  Result := T24(Int(A / Ulp) * Ulp + Int(B / Ulp) * Ulp);
end;

// The GE's 1/x: linear between the reciprocals of 1 + k/128.
function Recip24(V: Double): Double;
var
  M: Double;
  E: Integer;
begin
  if V = 0 then
    Exit(Infinity);
  if IsNan(V) or IsInfinite(V) then
    Exit(0);
  Frexp(Abs(V), M, E);
  M := M * 2;
  Dec(E);
  var K := Trunc((M - 1) * 128);
  var T := (M - 1) * 128 - K;
  var R0 := 1 / (1 + K / 128);
  var R1 := 1 / (1 + (K + 1) / 128);
  Result := T24(Ldexp(R0 + (R1 - R0) * T, -E));
  if V < 0 then
    Result := -Result;
end;

// A matrix row times a point: the products summed, then the translation added.
function Row24(M0, M1, M2, T: Cardinal; X, Y, Z: Double): Double; inline;
begin
  Result := Add24(T24(GEFloat(M0) * X + GEFloat(M1) * Y + GEFloat(M2) * Z), GEFloat(T));
end;

function Row24P(M0, M1, M2, M3: Cardinal; X, Y, Z, W: Double): Double; inline;
begin
  Result := Add24(T24(GEFloat(M0) * X + GEFloat(M1) * Y + GEFloat(M2) * Z), T24(GEFloat(M3) * W));
end;

// A value as the GE's 24-bit floats hold it: 16 mantissa bits, truncated.
function F24(V: Single): Single; inline;
begin
  var Bits := PCardinal(@V)^ and $FFFFFF00;
  Result := PSingle(@Bits)^;
end;

function NormalizedF24(const P: TGEVec3): TGEVec3;
var
  L: Single;
begin
  L := F24(P.X * P.X + P.Y * P.Y + P.Z * P.Z);
  if L > 0 then
  begin
    L := 1 / Sqrt(L);
    Result.X := P.X * L; Result.Y := P.Y * L; Result.Z := P.Z * L;
  end
  else
    Result := P;
end;

function Dot(const A, B: TGEVec3): Single; inline;
begin
  Result := A.X * B.X + A.Y * B.Y + A.Z * B.Z;
end;

function Vec3(X, Y, Z: Single): TGEVec3; inline;
begin
  Result.X := X; Result.Y := Y; Result.Z := Z;
end;

function CmdVec(const C: TGECmds; Index: Integer): TGEVec3;
begin
  Result.X := GEFloat(C[Index]);
  Result.Y := GEFloat(C[Index + 1]);
  Result.Z := GEFloat(C[Index + 2]);
end;

// pow as the GE's lighting unit computes it: log2 and exp2 linear between powers of two.
function GEPow(X, E: Single): Single;
begin
  if not (X > 0) then
  begin
    if E = 0 then
      Exit(1);
    Exit(0);
  end;
  var Bits := PCardinal(@X)^;
  var L2: Double := Integer((Bits shr 23) and $FF) - 127 + (Bits and $7FFFFF) / 8388608.0;
  var Y: Double := L2 * E;
  if IsNan(Y) then
    Exit(1);
  if Y > 127 then
    Exit(Infinity);
  if Y < -127 then
    Exit(0);
  var F := Floor(Y);
  Result := Ldexp(1 + (Y - F), F);
end;

function Unit8(C: Cardinal; Shift: Integer): Single; inline;
begin
  Result := ((C shr Shift) and $FF) / 255;
end;

// Lighting works on colours as fractions of 255; the result goes back to
// 8 bits as a fraction of 256, truncated.
function LitChannel(V: Single): Integer; inline;
begin
  if not (V > 0) then
    Exit(0);
  V := V * 256;
  if V >= 255 then
    Result := 255
  else
    Result := Trunc(V);
end;

procedure TPSPGEEngine.Light(const V: TGEInVertex; const WP, WN: TGEVec3; var R, G, B, A, SR, SG, SB: Integer);
var
  C: PGECmds;
  Upd: Cardinal;
  MA, MD, MS, E, AL, LA, LD, LS: array[0..2] of Single;
  Lit, Spec: array[0..2] of Single;
  MAA, ALA, Shine, Att, Spot, Dist, Den, CosA, NdotL, Diff, NdotH, Sp, Cutoff, Expo: Single;
  N, D, SD, H, VW: TGEVec3;
  L, Kind, LType, Ch: Integer;
  LT: Cardinal;
begin
  C := @Regs.Cmd;
  Upd := C[GE_MATERIALUPDATE];
  for Ch := 0 to 2 do
  begin
    MA[Ch] := Unit8(C[GE_MATERIALAMBIENT], Ch * 8);
    MD[Ch] := Unit8(C[GE_MATERIALDIFFUSE], Ch * 8);
    MS[Ch] := Unit8(C[GE_MATERIALSPECULAR], Ch * 8);
    E[Ch] := Unit8(C[GE_MATERIALEMISSIVE], Ch * 8);
    AL[Ch] := Unit8(C[GE_AMBIENTCOLOR], Ch * 8);
  end;
  MAA := Unit8(C[GE_MATERIALALPHA], 0);
  ALA := Unit8(C[GE_AMBIENTALPHA], 0);
  if V.HasColor then
  begin
    if (Upd and 1) <> 0 then
    begin
      MA[0] := V.R / 255; MA[1] := V.G / 255; MA[2] := V.B / 255; MAA := V.A / 255;
    end;
    if (Upd and 2) <> 0 then
    begin
      MD[0] := V.R / 255; MD[1] := V.G / 255; MD[2] := V.B / 255;
    end;
    if (Upd and 4) <> 0 then
    begin
      MS[0] := V.R / 255; MS[1] := V.G / 255; MS[2] := V.B / 255;
    end;
  end;
  for Ch := 0 to 2 do
  begin
    Lit[Ch] := E[Ch] + AL[Ch] * MA[Ch];
    Spec[Ch] := 0;
  end;
  N := Normalized(WN);
  // The exponent keeps the top 4 bits of its mantissa.
  Shine := GEFloat(C[GE_MATERIALSPECULARCOEF] and $FFF800);
  // The viewer is at infinity along view space +z.
  VW := Vec3(GEFloat(Regs.View[2]), GEFloat(Regs.View[5]), GEFloat(Regs.View[8]));
  for L := 0 to 3 do
  begin
    if (C[GE_LIGHTENABLE0 + L] and 1) = 0 then
      Continue;
    LT := C[GE_LIGHTTYPE0 + L];
    Kind := LT and 3;
    LType := (LT shr 8) and 3;
    D := CmdVec(C^, GE_LX0 + L * 3);
    if LType <> 0 then
      D := Vec3(D.X - WP.X, D.Y - WP.Y, D.Z - WP.Z);
    Dist := Sqrt(F24(Dot(D, D)));
    D := NormalizedF24(D);
    Att := 1;
    if LType <> 0 then
    begin
      Den := GEFloat(C[GE_LKA0 + L * 3]) + GEFloat(C[GE_LKA0 + L * 3 + 1]) * Dist + GEFloat(C[GE_LKA0 + L * 3 + 2]) * Dist * Dist;
      if Den <> 0 then
        Att := 1 / Den
      else
        Att := 0;
      if Att > 1 then
        Att := 1;
      if not (Att > 0) then
        Att := 0;
    end;
    Spot := 1;
    if LType = 2 then
    begin
      SD := Normalized(CmdVec(C^, GE_LDX0 + L * 3));
      CosA := Dot(D, SD);
      Cutoff := GEFloat(C[GE_LKO0 + L]);
      Expo := GEFloat(C[GE_LKS0 + L]);
      // An infinite direction lights everything or nothing by its sign.
      if IsNan(CosA) then
        Spot := Ord(GEFloat(C[GE_LDX0 + L * 3]) > 0)
      else if CosA >= Cutoff then
        Spot := Min(GEPow(Max(CosA, 0), Expo), 1E30)
      else
        Spot := 0;
    end;
    for Ch := 0 to 2 do
    begin
      LA[Ch] := Unit8(C[GE_LAC0 + L * 3], Ch * 8);
      LD[Ch] := Unit8(C[GE_LAC0 + L * 3 + 1], Ch * 8);
      LS[Ch] := Unit8(C[GE_LAC0 + L * 3 + 2], Ch * 8);
    end;
    NdotL := Dot(N, D);
    Diff := Max(NdotL, 0);
    if Kind = 2 then
      Diff := Min(GEPow(Diff, Shine), 1);
    for Ch := 0 to 2 do
      Lit[Ch] := Lit[Ch] + Att * Spot * (LA[Ch] * MA[Ch] + LD[Ch] * MD[Ch] * Diff);
    if (Kind = 1) and (NdotL >= 0) then
    begin
      H := Normalized(Vec3(D.X + VW.X, D.Y + VW.Y, D.Z + VW.Z));
      NdotH := Max(Dot(N, H), 0);
      Sp := Att * Spot * Min(GEPow(NdotH, Shine), 1);
      for Ch := 0 to 2 do
        Spec[Ch] := Spec[Ch] + Sp * LS[Ch] * MS[Ch];
    end;
  end;
  if (C[GE_LIGHTMODE] and 1) <> 0 then
  begin
    SR := LitChannel(Spec[0]);
    SG := LitChannel(Spec[1]);
    SB := LitChannel(Spec[2]);
  end
  else
    for Ch := 0 to 2 do
      Lit[Ch] := Lit[Ch] + Spec[Ch];
  R := LitChannel(Lit[0]);
  G := LitChannel(Lit[1]);
  B := LitChannel(Lit[2]);
  A := LitChannel(ALA * MAA);
end;

// The vector to a light as lighting sees it, for shade mapping: the half
// vector for lights with specular.
function TPSPGEEngine.LightVector(L: Integer; const WP: TGEVec3): TGEVec3;
var
  C: PGECmds;
  D, VW: TGEVec3;
begin
  C := @Regs.Cmd;
  D := CmdVec(C^, GE_LX0 + L * 3);
  if ((C[GE_LIGHTTYPE0 + L] shr 8) and 3) <> 0 then
    D := Vec3(D.X - WP.X, D.Y - WP.Y, D.Z - WP.Z);
  D := Normalized(D);
  if (C[GE_LIGHTTYPE0 + L] and 3) = 1 then
  begin
    VW := Vec3(GEFloat(Regs.View[2]), GEFloat(Regs.View[5]), GEFloat(Regs.View[8]));
    D := Normalized(Vec3(D.X + VW.X, D.Y + VW.Y, D.Z + VW.Z));
  end;
  Result := D;
end;

procedure TPSPGEEngine.TexGen(const V: TGEInVertex; const WP, WN: TGEVec3; out S, T: Single);
var
  C: PGECmds;
  Src, N, LU, LV: TGEVec3;
  Q: Single;
begin
  C := @Regs.Cmd;
  case C[GE_TEXMAPMODE] and 3 of
    1:
      begin
        case (C[GE_TEXMAPMODE] shr 8) and 3 of
          0: Src := V.P;
          1: Src := Vec3(V.U, V.V, 0);
          2: Src := Normalized(V.N);
        else
          Src := V.N;
        end;
        S := GEFloat(Regs.TGen[0]) * Src.X + GEFloat(Regs.TGen[3]) * Src.Y + GEFloat(Regs.TGen[6]) * Src.Z + GEFloat(Regs.TGen[9]);
        T := GEFloat(Regs.TGen[1]) * Src.X + GEFloat(Regs.TGen[4]) * Src.Y + GEFloat(Regs.TGen[7]) * Src.Z + GEFloat(Regs.TGen[10]);
        Q := GEFloat(Regs.TGen[2]) * Src.X + GEFloat(Regs.TGen[5]) * Src.Y + GEFloat(Regs.TGen[8]) * Src.Z + GEFloat(Regs.TGen[11]);
        if Q <> 0 then
        begin
          S := S / Q;
          T := T / Q;
        end;
      end;
    2:
      begin
        N := Normalized(WN);
        LU := LightVector(Integer(C[GE_TEXSHADELS] and 3), WP);
        LV := LightVector(Integer((C[GE_TEXSHADELS] shr 8) and 3), WP);
        S := (1 + Dot(N, LU)) / 2;
        T := (1 + Dot(N, LV)) / 2;
      end;
  else
    begin
      S := V.U * GEFloat(C[GE_TEXSCALEU]) + GEFloat(C[GE_TEXOFFSETU]);
      T := V.V * GEFloat(C[GE_TEXSCALEV]) + GEFloat(C[GE_TEXOFFSETV]);
    end;
  end;
end;

procedure TPSPGEEngine.TransformVertex(const V: TGEInVertex; VType: Cardinal; out O: TGEVertex; out Clip: Boolean);
var
  C: PGECmds;
  R, G, B, A, SR, SG, SB: Integer;
  P, N, WP, WN, VP: TGEVec3;
  CX, CY, CZ, CW, IW, SX, SY, SZ: Double;
  S, T: Single;
begin
  O := Default(TGEVertex);
  Clip := False;
  C := @Regs.Cmd;
  if V.HasColor then
  begin
    R := V.R; G := V.G; B := V.B; A := V.A;
  end
  else
  begin
    Color24(C[GE_MATERIALAMBIENT], R, G, B);
    A := C[GE_MATERIALALPHA] and $FF;
  end;
  if (VType and (1 shl 23)) <> 0 then
  begin
    O.X := Round(V.P.X * 16);
    O.Y := Round(V.P.Y * 16);
    O.Z := Trunc(V.P.Z);
    O.W := 1;
    O.R := R; O.G := G; O.B := B; O.A := A;
    O.S := V.U;
    O.T := V.V;
    O.Fog := 1;
    Exit;
  end;
  P := V.P;
  N := V.N;
  if ((VType shr 9) and 3) <> 0 then
    Skin(V, VType, P, N);
  if (C[GE_REVERSENORMAL] and 1) <> 0 then
    N := Vec3(-N.X, -N.Y, -N.Z);
  WP := MulPoint(Regs.World, P);
  WN := MulDir(Regs.World, N);
  VP := MulPoint(Regs.View, WP);
  // Position through the matrices and the viewport in the GE's 24-bit arithmetic.
  begin
    var M: PGEMat12 := @Regs.World;
    var PX := T24(P.X); var PY := T24(P.Y); var PZ := T24(P.Z);
    var AX := Row24(M[0], M[3], M[6], M[9], PX, PY, PZ);
    var AY := Row24(M[1], M[4], M[7], M[10], PX, PY, PZ);
    var AZ := Row24(M[2], M[5], M[8], M[11], PX, PY, PZ);
    M := @Regs.View;
    var BX := Row24(M[0], M[3], M[6], M[9], AX, AY, AZ);
    var BY := Row24(M[1], M[4], M[7], M[10], AX, AY, AZ);
    var BZ := Row24(M[2], M[5], M[8], M[11], AX, AY, AZ);
    var Q: PGEMat16 := @Regs.Proj;
    CX := Row24P(Q[0], Q[4], Q[8], Q[12], BX, BY, BZ, 1);
    CY := Row24P(Q[1], Q[5], Q[9], Q[13], BX, BY, BZ, 1);
    CZ := Row24P(Q[2], Q[6], Q[10], Q[14], BX, BY, BZ, 1);
    CW := Row24P(Q[3], Q[7], Q[11], Q[15], BX, BY, BZ, 1);
    VP := Vec3(BX, BY, BZ);
  end;
  if not (CW > 0) then
  begin
    Clip := True;
    CW := 1E-6;
  end;
  var RW := Recip24(CW);
  IW := RW;
  SX := Add24(T24(T24(CX * RW) * GEFloat(C[GE_VIEWPORTXSCALE])), GEFloat(C[GE_VIEWPORTXCENTER]));
  SY := Add24(T24(T24(CY * RW) * GEFloat(C[GE_VIEWPORTYSCALE])), GEFloat(C[GE_VIEWPORTYCENTER]));
  SZ := Add24(T24(T24(CZ * RW) * GEFloat(C[GE_VIEWPORTZSCALE])), GEFloat(C[GE_VIEWPORTZCENTER]));
  if IsNan(SX) or IsNan(SY) or (Abs(SX) > 1E6) or (Abs(SY) > 1E6) then
  begin
    Clip := True;
    SX := 0; SY := 0;
  end;
  O.X := Floor(SX * 16) - Integer(C[GE_OFFSETX] and $FFFF);
  O.Y := Floor(SY * 16) - Integer(C[GE_OFFSETY] and $FFFF);
  if IsNan(SZ) or (Abs(SZ) > 1E9) then
    SZ := 0;
  O.Z := Floor(SZ);
  O.W := IW;

  SR := 0; SG := 0; SB := 0;
  if (C[GE_LIGHTINGENABLE] and 1) <> 0 then
    Light(V, WP, WN, R, G, B, A, SR, SG, SB);
  O.R := R; O.G := G; O.B := B; O.A := A;
  O.SR := SR; O.SG := SG; O.SB := SB;
  TexGen(V, WP, WN, S, T);
  O.S := S * (1 shl (C[GE_TEXSIZE0] and $F));
  O.T := T * (1 shl ((C[GE_TEXSIZE0] shr 8) and $F));
  O.Fog := (GEFloat(C[GE_FOG1]) + VP.Z) * GEFloat(C[GE_FOG2]);
end;

{ Raster state }

procedure TPSPGEEngine.BuildRaster;
var
  S: ^TGERaster;
begin
  S := @FRaster;
  var C: PGECmds := @Regs.Cmd;
  S.VRAM := @FMemory.VRAM[0];
  S.FBAddr := C[GE_FRAMEBUFPTR] and $1FFFF0;
  S.FBStride := C[GE_FRAMEBUFWIDTH] and $7FC;
  S.FBFormat := C[GE_FRAMEBUFPIXFORMAT] and 3;
  S.ZAddr := C[GE_ZBUFPTR] and $1FFFF0;
  S.ZStride := C[GE_ZBUFWIDTH] and $7FC;
  S.ScissorX1 := C[GE_SCISSOR1] and $3FF;
  S.ScissorY1 := (C[GE_SCISSOR1] shr 10) and $3FF;
  S.ScissorX2 := C[GE_SCISSOR2] and $3FF;
  S.ScissorY2 := (C[GE_SCISSOR2] shr 10) and $3FF;
  S.BandY1 := 0;
  S.BandY2 := 1023;
  S.Through := (C[GE_VTYPE] and (1 shl 23)) <> 0;
  S.ClearMode := (C[GE_CLEARMODE] and 1) <> 0;
  S.ClearColor := (C[GE_CLEARMODE] and $100) <> 0;
  S.ClearStencil := (C[GE_CLEARMODE] and $200) <> 0;
  S.ClearDepth := (C[GE_CLEARMODE] and $400) <> 0;
  S.Gouraud := (C[GE_SHADEMODE] and 1) <> 0;
  S.Flat := not S.Gouraud;
  S.Textured := ((C[GE_TEXENABLE] and 1) <> 0) and not S.ClearMode;
  if S.Textured then
  begin
    var T: ^TGETexture := @S.Tex;
    T.Memory := FMemory;
    T.Format := C[GE_TEXFORMAT] and $F;
    T.Swizzle := (C[GE_TEXMODE] and 1) <> 0;
    T.LevelCount := Integer((C[GE_TEXMODE] shr 16) and 7) + 1;
    for var L := 0 to 7 do
    begin
      T.Levels[L].Addr := ((C[GE_TEXBUFWIDTH0 + L] and $0F0000) shl 8) or (C[GE_TEXADDR0 + L] and $FFFFFF);
      T.Levels[L].BufWidth := C[GE_TEXBUFWIDTH0 + L] and $7FF;
      T.Levels[L].Width := 1 shl Min(C[GE_TEXSIZE0 + L] and $F, 9);
      T.Levels[L].Height := 1 shl Min((C[GE_TEXSIZE0 + L] shr 8) and $F, 9);
    end;
    T.Level := 0;
    T.ClampU := (C[GE_TEXWRAP] and 1) <> 0;
    T.ClampV := (C[GE_TEXWRAP] and $100) <> 0;
    T.Linear := (C[GE_TEXFILTER] and $100) <> 0;
    T.Clut := @FClut[0];
    var CF := C[GE_CLUTFORMAT];
    T.ClutFormat := CF and 3;
    T.ClutShift := (CF shr 2) and $1F;
    T.ClutMask := (CF shr 8) and $FF;
    T.ClutOffset := ((CF shr 16) and $1F) shl 4;
    S.TexFunc := C[GE_TEXFUNC] and 7;
    S.TexAlpha := (C[GE_TEXFUNC] and $100) <> 0;
    S.ColorDouble := (C[GE_TEXFUNC] and $10000) <> 0;
    S.EnvR := C[GE_TEXENVCOLOR] and $FF;
    S.EnvG := (C[GE_TEXENVCOLOR] shr 8) and $FF;
    S.EnvB := (C[GE_TEXENVCOLOR] shr 16) and $FF;
  end;
  S.FogEnabled := ((C[GE_FOGENABLE] and 1) <> 0) and not S.ClearMode;
  S.FogR := C[GE_FOGCOLOR] and $FF;
  S.FogG := (C[GE_FOGCOLOR] shr 8) and $FF;
  S.FogB := (C[GE_FOGCOLOR] shr 16) and $FF;
  S.ColorTest := ((C[GE_COLORTESTENABLE] and 1) <> 0) and not S.ClearMode;
  S.ColorTestFunc := C[GE_COLORTEST] and 3;
  S.ColorRef := C[GE_COLORREF] and $FFFFFF;
  S.ColorMask := C[GE_COLORTESTMASK] and $FFFFFF;
  S.AlphaTest := ((C[GE_ALPHATESTENABLE] and 1) <> 0) and not S.ClearMode;
  S.AlphaFunc := C[GE_ALPHATEST] and 7;
  S.AlphaRef := (C[GE_ALPHATEST] shr 8) and $FF;
  S.AlphaMask := (C[GE_ALPHATEST] shr 16) and $FF;
  S.StencilTest := ((C[GE_STENCILTESTENABLE] and 1) <> 0) and not S.ClearMode;
  S.StencilFunc := C[GE_STENCILTEST] and 7;
  S.StencilRef := (C[GE_STENCILTEST] shr 8) and $FF;
  S.StencilMask := (C[GE_STENCILTEST] shr 16) and $FF;
  S.StencilFail := C[GE_STENCILOP] and 7;
  S.StencilZFail := (C[GE_STENCILOP] shr 8) and 7;
  S.StencilZPass := (C[GE_STENCILOP] shr 16) and 7;
  S.DepthTest := ((C[GE_ZTESTENABLE] and 1) <> 0) and not S.ClearMode;
  S.DepthFunc := C[GE_ZTEST] and 7;
  S.DepthWrite := (C[GE_ZWRITEDISABLE] and 1) = 0;
  S.MinZ := C[GE_MINZ] and $FFFF;
  S.MaxZ := C[GE_MAXZ] and $FFFF;
  S.Blend := ((C[GE_BLENDENABLE] and 1) <> 0) and not S.ClearMode;
  S.BlendSrc := C[GE_BLENDMODE] and $F;
  S.BlendDst := (C[GE_BLENDMODE] shr 4) and $F;
  S.BlendOp := (C[GE_BLENDMODE] shr 8) and $F;
  S.FixA := C[GE_BLENDFIXEDA] and $FFFFFF;
  S.FixB := C[GE_BLENDFIXEDB] and $FFFFFF;
  S.Dither := (C[GE_DITHERENABLE] and 1) <> 0;
  for var Row := 0 to 3 do
    for var Col := 0 to 3 do
    begin
      var D := Integer((C[GE_DITH0 + Row] shr (Col * 4)) and $F);
      if D >= 8 then
        D := D - 16;
      S.DitherMatrix[Row * 4 + Col] := D;
    end;
  S.LogicOp := ((C[GE_LOGICOPENABLE] and 1) <> 0) and not S.ClearMode;
  S.LogicFunc := C[GE_LOGICOP] and $F;
  S.MaskRGB := C[GE_MASKRGB] and $FFFFFF;
  S.MaskA := C[GE_MASKALPHA] and $FF;
end;

{ Primitives }

// Pixels of a 1/16 pixel box inside the scissor, for the drawing cost.
function TPSPGEEngine.ScissoredArea(X1, Y1, X2, Y2: Integer): Int64;
begin
  var W := Min(X2 div 16, FRaster.ScissorX2 + 1) - Max(X1 div 16, FRaster.ScissorX1);
  var H := Min(Y2 div 16, FRaster.ScissorY2 + 1) - Max(Y1 div 16, FRaster.ScissorY1);
  if (W <= 0) or (H <= 0) then
    Exit(0);
  Result := Int64(W) * H;
end;

procedure TPSPGEEngine.EmitTriangle(const A, B, C: TGEVertex; Odd: Boolean);
begin
  if FCullOn then
  begin
    var Cross := Int64(B.X - A.X) * (C.Y - A.Y) - Int64(B.Y - A.Y) * (C.X - A.X);
    if Cross = 0 then
      Exit;
    var CW := Cross > 0;
    if Odd then
      CW := not CW;
    if CW <> FCullCW then
      Exit;
  end;
  if Backend <> nil then Backend.DrawTriangle(FRaster, A, B, C) else GEDrawTriangle(FRaster, A, B, C);
  Inc(FPrimCost, 100 + Min(Abs(Int64(B.X - A.X) * (C.Y - A.Y) - Int64(B.Y - A.Y) * (C.X - A.X)) div 512,
    ScissoredArea(Min(A.X, Min(B.X, C.X)), Min(A.Y, Min(B.Y, C.Y)), Max(A.X, Max(B.X, C.X)), Max(A.Y, Max(B.Y, C.Y)))) * 3);
end;

procedure TPSPGEEngine.AddVertex(const V: TGEVertex; Clip: Boolean);
begin
  var N := FAsmCount;
  Inc(FAsmCount);
  case FAsmType of
    0:
      if not Clip then
        if Backend <> nil then Backend.DrawPoint(FRaster, V) else GEDrawPoint(FRaster, V);
    1:
      begin
        FAsmBuf[N and 1] := V; FAsmClip[N and 1] := Clip;
        if (N and 1) = 1 then
          if not FAsmClip[0] and not FAsmClip[1] then
            if Backend <> nil then Backend.DrawLine(FRaster, FAsmBuf[0], FAsmBuf[1]) else GEDrawLine(FRaster, FAsmBuf[0], FAsmBuf[1]);
      end;
    2:
      begin
        if (N > 0) and not Clip and not FAsmClip[0] then
          if Backend <> nil then Backend.DrawLine(FRaster, FAsmBuf[0], V) else GEDrawLine(FRaster, FAsmBuf[0], V);
        FAsmBuf[0] := V; FAsmClip[0] := Clip;
      end;
    3:
      begin
        var I := N mod 3;
        FAsmBuf[I] := V; FAsmClip[I] := Clip;
        if (I = 2) and not FAsmClip[0] and not FAsmClip[1] and not FAsmClip[2] then
          EmitTriangle(FAsmBuf[0], FAsmBuf[1], FAsmBuf[2], False);
      end;
    4:
      begin
        if N < 2 then
        begin
          FAsmBuf[N] := V; FAsmClip[N] := Clip;
          Exit;
        end;
        FAsmBuf[2] := V; FAsmClip[2] := Clip;
        if not FAsmClip[0] and not FAsmClip[1] and not FAsmClip[2] then
          EmitTriangle(FAsmBuf[0], FAsmBuf[1], FAsmBuf[2], ((N - 2) and 1) <> 0);
        FAsmBuf[0] := FAsmBuf[1]; FAsmClip[0] := FAsmClip[1];
        FAsmBuf[1] := FAsmBuf[2]; FAsmClip[1] := FAsmClip[2];
      end;
    5:
      begin
        if N < 2 then
        begin
          FAsmBuf[N] := V; FAsmClip[N] := Clip;
          Exit;
        end;
        FAsmBuf[2] := V; FAsmClip[2] := Clip;
        if not FAsmClip[0] and not FAsmClip[1] and not FAsmClip[2] then
          EmitTriangle(FAsmBuf[0], FAsmBuf[1], FAsmBuf[2], False);
        FAsmBuf[1] := FAsmBuf[2]; FAsmClip[1] := FAsmClip[2];
      end;
    6:
      begin
        FAsmBuf[N and 1] := V; FAsmClip[N and 1] := Clip;
        if ((N and 1) = 1) and not FAsmClip[0] and not FAsmClip[1] then
        begin
          if Backend <> nil then Backend.DrawSprite(FRaster, FAsmBuf[0], FAsmBuf[1]) else GEDrawSprite(FRaster, FAsmBuf[0], FAsmBuf[1]);
          Inc(FPrimCost, 100 + ScissoredArea(Min(FAsmBuf[0].X, FAsmBuf[1].X), Min(FAsmBuf[0].Y, FAsmBuf[1].Y),
            Max(FAsmBuf[0].X, FAsmBuf[1].X), Max(FAsmBuf[0].Y, FAsmBuf[1].Y)) * 3);
        end;
      end;
  end;
end;

procedure TPSPGEEngine.DrawPrim(Op: Cardinal);
var
  Raw: TGEInVertex;
  V: TGEVertex;
  Clip: Boolean;
begin
  var PrimType := Integer((Op shr 16) and 7);
  var Count := Integer(Op and $FFFF);
  var VType := Regs.Cmd[GE_VTYPE];
  SetupVertexFormat(VType);
  var IdxKind := (VType shr 11) and 3;
  var Through := (VType and (1 shl 23)) <> 0;
  var HasPos := ((VType shr 7) and 3) <> 0;
  var Morphs := Integer((VType shr 18) and 7) + 1;
  if PrimType <> 7 then
  begin
    FAsmType := PrimType;
    FAsmCount := 0;
  end;
  BuildRaster;
  FCullOn := ((Regs.Cmd[GE_CULLENABLE] and 1) <> 0) and not FRaster.ClearMode;
  FCullCW := (Regs.Cmd[GE_CULL] and 1) <> 0;
  if Backend <> nil then
  begin
    if IdxKind <> 0 then
    begin
      Backend.Access(Regs.IAddr, Cardinal(Count) * 4, False);
      Backend.Access(Regs.VAddr, Cardinal($10000 * FVSize * Morphs), False);
    end
    else
      Backend.Access(Regs.VAddr, Cardinal(Count * FVSize * Morphs), False);
  end;
  for var I := 0 to Count - 1 do
  begin
    var Index := I;
    case IdxKind of
      1: Index := FMemory.Read8(Regs.IAddr + Cardinal(I));
      2: Index := FMemory.Read16(Regs.IAddr + Cardinal(I * 2));
      3: Index := Integer(FMemory.Read32(Regs.IAddr + Cardinal(I * 4)) and $FFFF);
    end;
    ReadVertex(Index, VType, Raw);
    TransformVertex(Raw, VType, V, Clip);
    Inc(FPrimCost, 40);
    AddVertex(V, Clip or not HasPos);
  end;
  if IdxKind <> 0 then
  begin
    var ISz: Cardinal := 1;
    if IdxKind = 2 then ISz := 2;
    if IdxKind = 3 then ISz := 4;
    Regs.IAddr := Regs.IAddr + Cardinal(Count) * ISz;
  end
  else
    Regs.VAddr := Regs.VAddr + Cardinal(Count * FVSize * Morphs);
end;

// A vertex given by registers $F0-$F9 (screen x, y in 1/16, z, s, t, q,
// colour, fog, secondary colour); $F7 adds it with the alpha, the primitive
// and, on a primitive's first vertex, enables that replace the usual ones.
procedure TPSPGEEngine.ImmediateVertex(Op: Cardinal);
var
  V: TGEVertex;
begin
  var C: PGECmds := @Regs.Cmd;
  var PrimType := Integer((Op shr 8) and 7);
  var Through := (C[GE_VTYPE] and (1 shl 23)) <> 0;
  if PrimType <> 7 then
  begin
    FAsmType := PrimType;
    FAsmCount := 0;
    BuildRaster;
    FRaster.Through := Through;
    FRaster.Gouraud := (Op and $40000) <> 0;
    FRaster.Flat := not FRaster.Gouraud;
    FRaster.Textured := ((Op and $200000) <> 0) and not FRaster.ClearMode;
    FRaster.FogEnabled := ((Op and $400000) <> 0) and not FRaster.ClearMode;
    FRaster.Dither := ((Op and $800000) <> 0) and not FRaster.ClearMode;
    FCullOn := ((Op and $80000) <> 0) and not FRaster.ClearMode;
    FCullCW := (Op and $100000) <> 0;
  end;
  V := Default(TGEVertex);
  V.X := Integer(C[$F0] and $FFFF);
  V.Y := Integer(C[$F1] and $FFFF);
  Dec(V.X, Integer(C[GE_OFFSETX] and $FFFF));
  Dec(V.Y, Integer(C[GE_OFFSETY] and $FFFF));
  V.Z := C[$F2] and $FFFF;
  V.W := 1;
  V.R := C[$F6] and $FF;
  V.G := (C[$F6] shr 8) and $FF;
  V.B := (C[$F6] shr 16) and $FF;
  V.A := Op and $FF;
  if not Through and ((C[GE_LIGHTMODE] and 1) <> 0) then
  begin
    V.SR := C[$F9] and $FF;
    V.SG := (C[$F9] shr 8) and $FF;
    V.SB := (C[$F9] shr 16) and $FF;
  end;
  var Q := GEFloat(C[$F5]);
  if Q = 0 then
    Q := 1;
  V.S := GEFloat(C[$F3]) / Q * (1 shl (C[GE_TEXSIZE0] and $F));
  V.T := GEFloat(C[$F4]) / Q * (1 shl ((C[GE_TEXSIZE0] shr 8) and $F));
  V.Fog := (C[$F8] and $FF) / 255;
  Inc(FPrimCost, 40);
  AddVertex(V, False);
end;

procedure TPSPGEEngine.LoadClut(Op: Cardinal);
begin
  var Addr := ((Regs.Cmd[GE_CLUTADDRUPPER] and $0F0000) shl 8) or (Regs.Cmd[GE_CLUTADDR] and $FFFFFF);
  var Bytes := Integer(Op and $3F) * 32;
  if Bytes > Length(FClut) then
    Bytes := Length(FClut);
  if Bytes > 0 then
  begin
    if Backend <> nil then
      Backend.Access(Addr, Bytes, False);
    FMemory.ReadBytes(Addr, FClut[0], Bytes);
  end;
end;

procedure TPSPGEEngine.BlockTransfer(Op: Cardinal);
begin
  var C: PGECmds := @Regs.Cmd;
  var Src := ((C[GE_TRANSFERSRCW] and $FF0000) shl 8) or (C[GE_TRANSFERSRC] and $FFFFFF);
  var Dst := ((C[GE_TRANSFERDSTW] and $FF0000) shl 8) or (C[GE_TRANSFERDST] and $FFFFFF);
  var SrcW := Integer(C[GE_TRANSFERSRCW] and $7F8);
  var DstW := Integer(C[GE_TRANSFERDSTW] and $7F8);
  var SX := Integer(C[GE_TRANSFERSRCPOS] and $3FF);
  var SY := Integer((C[GE_TRANSFERSRCPOS] shr 10) and $3FF);
  var DX := Integer(C[GE_TRANSFERDSTPOS] and $3FF);
  var DY := Integer((C[GE_TRANSFERDSTPOS] shr 10) and $3FF);
  var W := Integer(C[GE_TRANSFERSIZE] and $3FF) + 1;
  var H := Integer((C[GE_TRANSFERSIZE] shr 10) and $3FF) + 1;
  var Bpp := 2;
  if (Op and 1) <> 0 then
    Bpp := 4;
  if Backend <> nil then
  begin
    Backend.Access(Src, Cardinal(((SY + H) * SrcW + SX + W) * Bpp), False);
    Backend.Access(Dst, Cardinal(((DY + H) * DstW + DX + W) * Bpp), True);
  end;
  for var Y := 0 to H - 1 do
  begin
    var SA := Src + Cardinal(((SY + Y) * SrcW + SX) * Bpp);
    var DA := Dst + Cardinal(((DY + Y) * DstW + DX) * Bpp);
    FMemory.Copy(DA, SA, Cardinal(W * Bpp));
  end;
  FPrimCost := Int64(W) * H * Bpp * 2;
end;

{ Context }

procedure TPSPGEEngine.SaveContext(Address: Cardinal);
begin
  var W: array[0..511] of Cardinal;
  FillChar(W, SizeOf(W), 0);
  W[0] := $00000001;
  W[5] := Regs.VAddr;
  W[6] := Regs.IAddr;
  W[7] := Regs.Offset;
  W[8] := Regs.BoneNum;
  W[9] := Regs.WorldNum;
  W[10] := Regs.ViewNum;
  W[11] := Regs.ProjNum;
  W[12] := Regs.TGenNum;
  var N := GEContextCmdStart;
  for var C in GEContextCmds do
  begin
    W[N] := Regs.Cmd[C];
    Inc(N);
  end;
  for var I := 0 to 95 do begin W[N] := Regs.Bone[I]; Inc(N); end;
  for var I := 0 to 11 do begin W[N] := Regs.World[I]; Inc(N); end;
  for var I := 0 to 11 do begin W[N] := Regs.View[I]; Inc(N); end;
  for var I := 0 to 15 do begin W[N] := Regs.Proj[I]; Inc(N); end;
  for var I := 0 to 11 do begin W[N] := Regs.TGen[I]; Inc(N); end;
  FMemory.WriteBytes(Address, W[0], N * 4);
end;

procedure TPSPGEEngine.RestoreContext(Address: Cardinal);
begin
  var W: array[0..511] of Cardinal;
  var Total := GEContextCmdStart + Length(GEContextCmds) + 96 + 12 + 12 + 16 + 12;
  FMemory.ReadBytes(Address, W[0], Total * 4);
  Regs.VAddr := W[5];
  Regs.IAddr := W[6];
  Regs.Offset := W[7];
  Regs.BoneNum := W[8] and $7F;
  Regs.WorldNum := W[9] and $F;
  Regs.ViewNum := W[10] and $F;
  Regs.ProjNum := W[11] and $F;
  Regs.TGenNum := W[12] and $F;
  var N := GEContextCmdStart;
  for var C in GEContextCmds do
  begin
    Regs.Cmd[C] := (Cardinal(C) shl 24) or (W[N] and $FFFFFF);
    Inc(N);
  end;
  for var I := 0 to 95 do begin Regs.Bone[I] := W[N] and $FFFFFF; Inc(N); end;
  for var I := 0 to 11 do begin Regs.World[I] := W[N] and $FFFFFF; Inc(N); end;
  for var I := 0 to 11 do begin Regs.View[I] := W[N] and $FFFFFF; Inc(N); end;
  for var I := 0 to 15 do begin Regs.Proj[I] := W[N] and $FFFFFF; Inc(N); end;
  for var I := 0 to 11 do begin Regs.TGen[I] := W[N] and $FFFFFF; Inc(N); end;
end;

procedure InitContextCmds;
const
  Ranges: array[0..15, 0..1] of Byte = (
    ($00, $02), ($10, $10), ($12, $28), ($2C, $33), ($36, $38), ($42, $4D), ($50, $51), ($53, $58),
    ($5B, $B5), ($B8, $C3), ($C5, $D0), ($D2, $E9), ($EB, $EC), ($EE, $EE), ($F0, $F6), ($F8, $F9));
begin
  for var R := 0 to High(Ranges) do
    for var C := Ranges[R, 0] to Ranges[R, 1] do
      GEContextCmds := GEContextCmds + [Byte(C)];
end;

initialization
  InitContextCmds;

end.
