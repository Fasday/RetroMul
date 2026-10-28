// sceParseUri. sceUriParse splits a URI into scheme, user, password, host,
// path, query and fragment, copied one after the other (each NUL-ended)
// into the caller's work area. The scheme is what comes before the first
// ':' when it is made of scheme characters; "//" after it marks an
// authority, but the part after a scheme is read as user@host:port either
// way, as long as it starts with a host character (letters, digits, '-',
// '.'). With no scheme the whole string is that part. Ports take at most
// five digits and up to 65536, which wraps to 0; none given means the
// scheme's.

const
  SCE_HTTP_ERROR_INVALID_VALUE = Cardinal($80433060);
  SCE_HTTP_ERROR_OUT_OF_SIZE = Cardinal($80433022);
  SCE_HTTP_ERROR_INVALID_ARGS = Cardinal($804331FE);

type
  TParsedUri = record
    NoSlash: Boolean;
    Parts: array[0..6] of RawByteString;
    Port: Cardinal;
  end;

function UriSchemeChar(C: AnsiChar): Boolean;
begin
  Result := CharInSet(C, ['A'..'Z', 'a'..'z', '0'..'9', '+', '-', '.']);
end;

function UriHostChar(C: AnsiChar): Boolean;
begin
  Result := CharInSet(C, ['A'..'Z', 'a'..'z', '0'..'9', '-', '.']);
end;

function UriDefaultPort(const Scheme: RawByteString): Cardinal;
begin
  var S := LowerCase(string(Scheme));
  if S = 'http' then
    Result := 80
  else if S = 'https' then
    Result := 443
  else
    Result := 0;
end;

function ParseUriText(const S: RawByteString; out U: TParsedUri): Boolean;
begin
  Result := False;
  U := Default(TParsedUri);
  var N := Length(S);
  var P := 1;
  var I := 1;
  while (I <= N) and UriSchemeChar(S[I]) do
    Inc(I);
  if (I <= N) and (S[I] = ':') then
  begin
    U.Parts[0] := Copy(S, 1, I - 1);
    P := I + 1;
  end;
  U.NoSlash := True;
  if (U.Parts[0] <> '') and (P + 1 <= N) and (S[P] = '/') and (S[P + 1] = '/') then
  begin
    U.NoSlash := False;
    Inc(P, 2);
  end;
  // User information runs to an '@' before the path.
  var J := P;
  while (J <= N) and not CharInSet(S[J], ['/', '?', '#', '@']) do
    Inc(J);
  if (J <= N) and (S[J] = '@') then
  begin
    var Info := Copy(S, P, J - P);
    var Colon := Pos(AnsiChar(':'), Info);
    if Colon > 0 then
    begin
      U.Parts[1] := Copy(Info, 1, Colon - 1);
      U.Parts[2] := Copy(Info, Colon + 1, MaxInt);
    end
    else
      U.Parts[1] := Info;
    P := J + 1;
  end;
  U.Port := UriDefaultPort(U.Parts[0]);
  if (P <= N) and UriHostChar(S[P]) then
  begin
    var H := P;
    while (P <= N) and UriHostChar(S[P]) do
      Inc(P);
    U.Parts[3] := Copy(S, H, P - H);
    if (P <= N) and (S[P] = ':') then
    begin
      Inc(P);
      var D := P;
      while (P <= N) and CharInSet(S[P], ['0'..'9']) do
        Inc(P);
      var Digits := P - D;
      if Digits = 0 then
      begin
        if (P <= N) and not CharInSet(S[P], ['/', '?', '#']) then
          Exit;
      end
      else
      begin
        if Digits > 5 then
          Exit;
        var V := StrToInt(string(Copy(S, D, Digits)));
        if V > 65536 then
          Exit;
        U.Port := Cardinal(V) and $FFFF;
      end;
    end;
  end;
  var Q := P;
  while (Q <= N) and not CharInSet(S[Q], ['?', '#']) do
    Inc(Q);
  U.Parts[4] := Copy(S, P, Q - P);
  P := Q;
  if (P <= N) and (S[P] = '?') then
  begin
    while (Q <= N) and (S[Q] <> '#') do
      Inc(Q);
    U.Parts[5] := Copy(S, P, Q - P);
    P := Q;
  end;
  if P <= N then
    U.Parts[6] := Copy(S, P, MaxInt);
  Result := True;
end;

procedure TPSPNet.hUriParse;
begin
  var Parsed := FHLE.Arg(0);
  var UriPtr := FHLE.Arg(1);
  var Work := FHLE.Arg(2);
  var SizePtr := FHLE.Arg(3);
  var WorkLen := FHLE.ArgInt(4);
  if UriPtr = 0 then
  begin
    FHLE.Result(SCE_HTTP_ERROR_INVALID_VALUE);
    Exit;
  end;
  var U: TParsedUri;
  if not ParseUriText(FMemory.ReadAnsi(UriPtr, 4096), U) then
  begin
    FHLE.Result(SCE_HTTP_ERROR_INVALID_VALUE);
    Exit;
  end;
  var Need := 0;
  for var K := 0 to 6 do
    Inc(Need, Length(U.Parts[K]) + 1);
  if (Parsed = 0) or (Work = 0) then
  begin
    // The size query.
    if SizePtr = 0 then
      FHLE.Result(SCE_HTTP_ERROR_INVALID_ARGS)
    else
    begin
      FMemory.Write32(SizePtr, Cardinal(Need));
      FHLE.Result(0);
    end;
    Exit;
  end;
  if Need > WorkLen then
  begin
    FHLE.Result(SCE_HTTP_ERROR_OUT_OF_SIZE);
    Exit;
  end;
  FMemory.Fill(Parsed, 0, 44);
  FMemory.Write32(Parsed, Ord(U.NoSlash));
  var At := Work;
  for var K := 0 to 6 do
  begin
    FMemory.WriteString(At, U.Parts[K], Length(U.Parts[K]) + 1);
    FMemory.Write32(Parsed + 4 + Cardinal(K * 4), At);
    Inc(At, Length(U.Parts[K]) + 1);
  end;
  FMemory.Write16(Parsed + 32, U.Port);
  if SizePtr <> 0 then
    FMemory.Write32(SizePtr, Cardinal(Need));
  FHLE.Result(0);
end;

procedure TPSPNet.hUriBuild;
const
  WithScheme = $01;
  WithHost = $02;
  WithPort = $04;
  WithPath = $08;
  WithUser = $10;
  WithPassword = $20;
  WithQuery = $40;
  WithFragment = $80;
begin
  var Out_ := FHLE.Arg(0);
  var SizePtr := FHLE.Arg(1);
  var OutLen := FHLE.ArgInt(2);
  var Parsed := FHLE.Arg(3);
  var Flags := FHLE.Arg(4);
  if Parsed = 0 then
  begin
    FHLE.Result(SCE_HTTP_ERROR_INVALID_ARGS);
    Exit;
  end;
  var Part: array[0..6] of RawByteString;
  for var K := 0 to 6 do
    Part[K] := FMemory.ReadAnsi(FMemory.Read32(Parsed + 4 + Cardinal(K * 4)), 4096);
  var NoSlash := FMemory.Read32(Parsed) <> 0;
  var Port := FMemory.Read16(Parsed + 32);
  var S: RawByteString := '';
  if (Flags and WithScheme) <> 0 then
  begin
    S := Part[0] + ':';
    if not NoSlash then
      S := S + '//';
  end;
  if ((Flags and WithUser) <> 0) and (Part[1] <> '') then
  begin
    S := S + Part[1];
    if ((Flags and WithPassword) <> 0) and (Part[2] <> '') then
      S := S + ':' + Part[2];
    S := S + '@';
  end;
  if (Flags and WithHost) <> 0 then
    S := S + Part[3];
  if ((Flags and WithPort) <> 0) and (Port <> UriDefaultPort(Part[0])) then
    S := S + ':' + RawByteString(IntToStr(Port));
  if (Flags and WithPath) <> 0 then
    S := S + Part[4];
  if (Flags and WithQuery) <> 0 then
    S := S + Part[5];
  if (Flags and WithFragment) <> 0 then
    S := S + Part[6];
  var Need := Length(S) + 1;
  if Out_ <> 0 then
  begin
    if Need > OutLen then
    begin
      FHLE.Result(SCE_HTTP_ERROR_OUT_OF_SIZE);
      Exit;
    end;
    FMemory.WriteString(Out_, S, Need);
  end;
  if SizePtr <> 0 then
    FMemory.Write32(SizePtr, Cardinal(Need));
  FHLE.Result(0);
end;

// Characters left alone: letters, digits and - _ . *; the rest become %XX.
function UriSafe(C: Byte): Boolean;
begin
  Result := CharInSet(AnsiChar(C), ['A'..'Z', 'a'..'z', '0'..'9', '-', '_', '.', '*']);
end;

procedure TPSPNet.hUriEscape;
const
  Hex: array[0..15] of AnsiChar = '0123456789ABCDEF';
begin
  var Out_ := FHLE.Arg(0);
  var LenPtr := FHLE.Arg(1);
  var OutLen := FHLE.ArgInt(2);
  var Src := FMemory.ReadAnsi(FHLE.Arg(3), 65536);
  var S: RawByteString := '';
  for var I := 1 to Length(Src) do
  begin
    var C := Ord(Src[I]);
    if UriSafe(C) then
      S := S + Src[I]
    else
      S := S + '%' + Hex[C shr 4] + Hex[C and 15];
  end;
  if Out_ <> 0 then
  begin
    // Written as far as it fits.
    for var I := 1 to Length(S) do
    begin
      if I > OutLen then
      begin
        FHLE.Result(SCE_HTTP_ERROR_OUT_OF_SIZE);
        Exit;
      end;
      FMemory.Write8(Out_ + Cardinal(I - 1), Ord(S[I]));
    end;
    if Length(S) >= OutLen then
    begin
      FHLE.Result(SCE_HTTP_ERROR_OUT_OF_SIZE);
      Exit;
    end;
    FMemory.Write8(Out_ + Cardinal(Length(S)), 0);
  end;
  FMemory.Write32(LenPtr, Cardinal(Length(S) + 1));
  FHLE.Result(0);
end;

function HexValue(C: AnsiChar): Integer;
begin
  case C of
    '0'..'9': Result := Ord(C) - Ord('0');
    'A'..'F': Result := Ord(C) - Ord('A') + 10;
    'a'..'f': Result := Ord(C) - Ord('a') + 10;
  else
    Result := -1;
  end;
end;

procedure TPSPNet.hUriUnescape;
begin
  // Returns the source length plus two for each escape.
  var Out_ := FHLE.Arg(0);
  var LenPtr := FHLE.Arg(1);
  var OutLen := FHLE.ArgInt(2);
  var Src := FMemory.ReadAnsi(FHLE.Arg(3), 65536);
  var Count := 0;
  var Escapes := 0;
  var I := 1;
  while I <= Length(Src) do
  begin
    var C := Ord(Src[I]);
    if Src[I] = '%' then
    begin
      if (I + 2 > Length(Src)) or (HexValue(Src[I + 1]) < 0) or (HexValue(Src[I + 2]) < 0) then
      begin
        FHLE.Result(SCE_HTTP_ERROR_INVALID_VALUE);
        Exit;
      end;
      C := HexValue(Src[I + 1]) * 16 + HexValue(Src[I + 2]);
      Inc(I, 3);
      Inc(Escapes);
    end
    else
      Inc(I);
    if Out_ <> 0 then
    begin
      if Count >= OutLen then
      begin
        FHLE.Result(SCE_HTTP_ERROR_OUT_OF_SIZE);
        Exit;
      end;
      FMemory.Write8(Out_ + Cardinal(Count), C);
    end;
    Inc(Count);
  end;
  if Out_ <> 0 then
  begin
    if Count >= OutLen then
    begin
      FHLE.Result(SCE_HTTP_ERROR_OUT_OF_SIZE);
      Exit;
    end;
    FMemory.Write8(Out_ + Cardinal(Count), 0);
  end;
  FMemory.Write32(LenPtr, Cardinal(Count + 1));
  FHLE.Result(Cardinal(Length(Src) + 2 * Escapes));
end;
