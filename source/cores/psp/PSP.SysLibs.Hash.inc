{ PSP.SysLibs: MD5, SHA-1 and MT19937 with their state in guest memory, as
  UtilsForUser keeps it: h[] at 0, remaining byte count (u16) at 20, total
  length (u64) at 24, the partial block at 32. MD5 runs every byte through the
  block buffer; SHA-1 hashes whole blocks straight from the input. }

const
  Md5Sines: array[0..63] of Cardinal = (
    $D76AA478, $E8C7B756, $242070DB, $C1BDCEEE, $F57C0FAF, $4787C62A, $A8304613, $FD469501,
    $698098D8, $8B44F7AF, $FFFF5BB1, $895CD7BE, $6B901122, $FD987193, $A679438E, $49B40821,
    $F61E2562, $C040B340, $265E5A51, $E9B6C7AA, $D62F105D, $02441453, $D8A1E681, $E7D3FBC8,
    $21E1CDE6, $C33707D6, $F4D50D87, $455A14ED, $A9E3E905, $FCEFA3F8, $676F02D9, $8D2A4C8A,
    $FFFA3942, $8771F681, $6D9D6122, $FDE5380C, $A4BEEA44, $4BDECFA9, $F6BB4B60, $BEBFBC70,
    $289B7EC6, $EAA127FA, $D4EF3085, $04881D05, $D9D4D039, $E6DB99E5, $1FA27CF8, $C4AC5665,
    $F4292244, $432AFF97, $AB9423A7, $FC93A039, $655B59C3, $8F0CCC92, $FFEFF47D, $85845DD1,
    $6FA87E4F, $FE2CE6E0, $A3014314, $4E0811A1, $F7537E82, $BD3AF235, $2AD7D2BB, $EB86D391);
  Md5Shifts: array[0..15] of Byte = (7, 12, 17, 22, 5, 9, 14, 20, 4, 11, 16, 23, 6, 10, 15, 21);
  HashInitState: array[0..4] of Cardinal = ($67452301, $EFCDAB89, $98BADCFE, $10325476, $C3D2E1F0);

function RotL(X: Cardinal; N: Integer): Cardinal; inline;
begin
  Result := (X shl N) or (X shr (32 - N));
end;

type
  THashKind = (hkMd5, hkSha1);

  THashCtx = record
    Kind: THashKind;
    H: array[0..4] of Cardinal;
    Remains: Cardinal;
    Total: UInt64;
    Buf: array[0..63] of Byte;
    procedure Init(AKind: THashKind);
    procedure Block(P: PByte);
    procedure Update(P: PByte; Size: Cardinal);
    function Final: TBytes;
    procedure Load(M: TPSPMemory; Address: Cardinal; AKind: THashKind);
    procedure Store(M: TPSPMemory; Address: Cardinal);
  end;

procedure THashCtx.Init(AKind: THashKind);
begin
  Kind := AKind;
  Move(HashInitState, H, SizeOf(H));
  Remains := 0;
  Total := 0;
  FillChar(Buf, SizeOf(Buf), 0);
end;

procedure THashCtx.Block(P: PByte);
begin
  if Kind = hkMd5 then
  begin
    var X: array[0..15] of Cardinal;
    for var I := 0 to 15 do
      X[I] := P[I * 4] or (Cardinal(P[I * 4 + 1]) shl 8) or (Cardinal(P[I * 4 + 2]) shl 16) or
        (Cardinal(P[I * 4 + 3]) shl 24);
    var A := H[0];
    var B := H[1];
    var C := H[2];
    var D := H[3];
    for var I := 0 to 63 do
    begin
      var F: Cardinal;
      var G: Integer;
      case I shr 4 of
        0: begin F := (B and C) or (not B and D); G := I; end;
        1: begin F := (D and B) or (not D and C); G := (5 * I + 1) and 15; end;
        2: begin F := B xor C xor D; G := (3 * I + 5) and 15; end;
      else
        begin F := C xor (B or not D); G := (7 * I) and 15; end;
      end;
      var T := D;
      D := C;
      C := B;
      B := B + RotL(A + F + Md5Sines[I] + X[G], Md5Shifts[(I shr 4) * 4 + (I and 3)]);
      A := T;
    end;
    Inc(H[0], A);
    Inc(H[1], B);
    Inc(H[2], C);
    Inc(H[3], D);
  end
  else
  begin
    var W: array[0..79] of Cardinal;
    for var I := 0 to 15 do
      W[I] := (Cardinal(P[I * 4]) shl 24) or (Cardinal(P[I * 4 + 1]) shl 16) or (Cardinal(P[I * 4 + 2]) shl 8) or
        P[I * 4 + 3];
    for var I := 16 to 79 do
      W[I] := RotL(W[I - 3] xor W[I - 8] xor W[I - 14] xor W[I - 16], 1);
    var A := H[0];
    var B := H[1];
    var C := H[2];
    var D := H[3];
    var E := H[4];
    for var I := 0 to 79 do
    begin
      var F, K: Cardinal;
      case I div 20 of
        0: begin F := (B and C) or (not B and D); K := $5A827999; end;
        1: begin F := B xor C xor D; K := $6ED9EBA1; end;
        2: begin F := (B and C) or (B and D) or (C and D); K := $8F1BBCDC; end;
      else
        begin F := B xor C xor D; K := $CA62C1D6; end;
      end;
      var T := RotL(A, 5) + F + E + K + W[I];
      E := D;
      D := C;
      C := RotL(B, 30);
      B := A;
      A := T;
    end;
    Inc(H[0], A);
    Inc(H[1], B);
    Inc(H[2], C);
    Inc(H[3], D);
    Inc(H[4], E);
  end;
end;

procedure THashCtx.Update(P: PByte; Size: Cardinal);
begin
  Inc(Total, Size);
  if (Kind = hkSha1) and (Remains = 0) then
    while Size >= 64 do
    begin
      Block(P);
      Inc(P, 64);
      Dec(Size, 64);
    end;
  while Size > 0 do
  begin
    var N := Min(64 - Remains, Size);
    Move(P^, Buf[Remains], N);
    Inc(Remains, N);
    Inc(P, N);
    Dec(Size, N);
    if Remains = 64 then
    begin
      Block(@Buf[0]);
      Remains := 0;
      if Kind = hkSha1 then
        while Size >= 64 do
        begin
          Block(P);
          Inc(P, 64);
          Dec(Size, 64);
        end;
    end;
  end;
end;

function THashCtx.Final: TBytes;
begin
  var Bits := Total * 8;
  var Tail: array[0..127] of Byte;
  FillChar(Tail, SizeOf(Tail), 0);
  Move(Buf[0], Tail[0], Remains);
  Tail[Remains] := $80;
  var Len := 64;
  if Remains >= 56 then
    Len := 128;
  for var I := 0 to 7 do
    if Kind = hkMd5 then
      Tail[Len - 8 + I] := Byte(Bits shr (8 * I))
    else
      Tail[Len - 1 - I] := Byte(Bits shr (8 * I));
  Block(@Tail[0]);
  if Len = 128 then
    Block(@Tail[64]);
  if Kind = hkMd5 then
  begin
    SetLength(Result, 16);
    Move(H[0], Result[0], 16);
  end
  else
  begin
    SetLength(Result, 20);
    for var I := 0 to 4 do
    begin
      Result[I * 4] := Byte(H[I] shr 24);
      Result[I * 4 + 1] := Byte(H[I] shr 16);
      Result[I * 4 + 2] := Byte(H[I] shr 8);
      Result[I * 4 + 3] := Byte(H[I]);
    end;
  end;
end;

procedure THashCtx.Load(M: TPSPMemory; Address: Cardinal; AKind: THashKind);
begin
  Kind := AKind;
  for var I := 0 to 4 do
    H[I] := M.Read32(Address + Cardinal(I) * 4);
  Remains := M.Read16(Address + 20) and 63;
  Total := UInt64(M.Read32(Address + 24)) or (UInt64(M.Read32(Address + 28)) shl 32);
  M.ReadBytes(Address + 32, Buf[0], 64);
end;

procedure THashCtx.Store(M: TPSPMemory; Address: Cardinal);
begin
  var N := 4;
  if Kind = hkSha1 then
    N := 5;
  for var I := 0 to N - 1 do
    M.Write32(Address + Cardinal(I) * 4, H[I]);
  M.Write16(Address + 20, Remains);
  M.Write32(Address + 24, Cardinal(Total));
  M.Write32(Address + 28, Cardinal(Total shr 32));
  // Bytes never stashed are written back unchanged.
  M.WriteBytes(Address + 32, Buf[0], 64);
end;

function GuestBytes(M: TPSPMemory; Address, Size: Cardinal): TBytes;
begin
  SetLength(Result, Size);
  if Size > 0 then
    M.ReadBytes(Address, Result[0], Size);
end;

procedure HashOneShot(S: TPSPSysLibs; Kind: THashKind);
begin
  var H := S.System.HLE;
  var M := S.System.Memory;
  var Data := GuestBytes(M, H.Arg(0), H.Arg(1));
  var C: THashCtx;
  C.Init(Kind);
  if Length(Data) > 0 then
    C.Update(@Data[0], Length(Data));
  var D := C.Final;
  M.WriteBytes(H.Arg(2), D[0], Length(D));
  H.Result(0);
end;

procedure HashBlockInit(S: TPSPSysLibs; Kind: THashKind);
begin
  var H := S.System.HLE;
  var M := S.System.Memory;
  var P := H.Arg(0);
  if P = 0 then
    begin H.Result(SCE_KERNEL_ERROR_ILLEGAL_ADDR); Exit; end;
  var N := 4;
  if Kind = hkSha1 then
    N := 5;
  for var I := 0 to N - 1 do
    M.Write32(P + Cardinal(I) * 4, HashInitState[I]);
  M.Write16(P + 20, 0);
  M.Write16(P + 22, 0);
  M.Write32(P + 24, 0);
  M.Write32(P + 28, 0);
  H.Result(0);
end;

procedure HashBlockUpdate(S: TPSPSysLibs; Kind: THashKind);
begin
  var H := S.System.HLE;
  var M := S.System.Memory;
  var P := H.Arg(0);
  if P = 0 then
    begin H.Result(SCE_KERNEL_ERROR_ILLEGAL_ADDR); Exit; end;
  var C: THashCtx;
  C.Load(M, P, Kind);
  var Data := GuestBytes(M, H.Arg(1), H.Arg(2));
  if Length(Data) > 0 then
    C.Update(@Data[0], Length(Data));
  C.Store(M, P);
  H.Result(0);
end;

procedure HashBlockResult(S: TPSPSysLibs; Kind: THashKind);
begin
  var H := S.System.HLE;
  var M := S.System.Memory;
  var P := H.Arg(0);
  if (P = 0) or (H.Arg(1) = 0) then
    begin H.Result(SCE_KERNEL_ERROR_ILLEGAL_ADDR); Exit; end;
  var C: THashCtx;
  C.Load(M, P, Kind);
  var D := C.Final;
  M.WriteBytes(H.Arg(1), D[0], Length(D));
  H.Result(0);
end;

procedure TPSPSysLibs.hMd5Digest;
begin
  HashOneShot(Self, hkMd5);
end;

procedure TPSPSysLibs.hSha1Digest;
begin
  HashOneShot(Self, hkSha1);
end;

procedure TPSPSysLibs.hMd5BlockInit;
begin
  HashBlockInit(Self, hkMd5);
end;

procedure TPSPSysLibs.hMd5BlockUpdate;
begin
  HashBlockUpdate(Self, hkMd5);
end;

procedure TPSPSysLibs.hMd5BlockResult;
begin
  HashBlockResult(Self, hkMd5);
end;

procedure TPSPSysLibs.hSha1BlockInit;
begin
  HashBlockInit(Self, hkSha1);
end;

procedure TPSPSysLibs.hSha1BlockUpdate;
begin
  HashBlockUpdate(Self, hkSha1);
end;

procedure TPSPSysLibs.hSha1BlockResult;
begin
  HashBlockResult(Self, hkSha1);
end;

{ MT19937: count at 0, then the 624-word state. Init twists the seeded array
  once; each draw returns a word and twists that word in place for the next
  round, which yields the reference sequence. }

procedure TPSPSysLibs.hMt19937Init;
begin
  var Ctx := FHLE.Arg(0);
  var MT: array[0..623] of Cardinal;
  MT[0] := FHLE.Arg(1);
  for var I := 1 to 623 do
    MT[I] := Cardinal(1812433253 * (MT[I - 1] xor (MT[I - 1] shr 30)) + Cardinal(I));
  for var I := 0 to 623 do
  begin
    var Y := (MT[I] and $80000000) or (MT[(I + 1) mod 624] and $7FFFFFFF);
    var V := MT[(I + 397) mod 624] xor (Y shr 1);
    if (Y and 1) <> 0 then
      V := V xor $9908B0DF;
    MT[I] := V;
  end;
  FMemory.Write32(Ctx, 0);
  for var I := 0 to 623 do
    FMemory.Write32(Ctx + 4 + Cardinal(I) * 4, MT[I]);
  FHLE.Result(0);
end;

procedure TPSPSysLibs.hMt19937UInt;
begin
  var Ctx := FHLE.Arg(0);
  var Index := FMemory.Read32(Ctx) mod 624;
  var State := Ctx + 4;
  var Y := FMemory.Read32(State + Index * 4);
  var Z := (Y and $80000000) or (FMemory.Read32(State + ((Index + 1) mod 624) * 4) and $7FFFFFFF);
  var V := FMemory.Read32(State + ((Index + 397) mod 624) * 4) xor (Z shr 1);
  if (Z and 1) <> 0 then
    V := V xor $9908B0DF;
  FMemory.Write32(State + Index * 4, V);
  FMemory.Write32(Ctx, (Index + 1) mod 624);
  Y := Y xor (Y shr 11);
  Y := Y xor ((Y shl 7) and $9D2C5680);
  Y := Y xor ((Y shl 15) and $EFC60000);
  Y := Y xor (Y shr 18);
  FHLE.Result(Y);
end;
