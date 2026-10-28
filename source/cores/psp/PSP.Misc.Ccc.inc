{ PSP.Misc: sceCcc. "JIS" codes are JIS X 0201 bytes and JIS X 0208 row/cell
  pairs (0x2121..0x7E7E), the index of the program's tables; Shift-JIS is
  computed from them. A conversion stops at the first character it cannot
  decode or that does not fit with the terminator; it returns the characters
  written. }

{$I PSP.Ccc.Table.inc}

var
  CccJisToUcs, CccUcsToJis: TDictionary<Cardinal, Cardinal>;

procedure CccBuildTables;
begin
  if CccJisToUcs <> nil then
    Exit;
  CccJisToUcs := TDictionary<Cardinal, Cardinal>.Create;
  CccUcsToJis := TDictionary<Cardinal, Cardinal>.Create;
  for var V in CccJisTable do
  begin
    CccJisToUcs.AddOrSetValue(V shr 16, V and $FFFF);
    if not CccUcsToJis.ContainsKey(V and $FFFF) then
      CccUcsToJis.Add(V and $FFFF, V shr 16);
  end;
end;

function CccJisToSjis(J: Cardinal): Cardinal;
begin
  if J < $100 then
    Exit(J);
  var J1 := J shr 8;
  var J2 := J and $FF;
  var S1 := (J1 + 1) div 2 + $70;
  if S1 >= $A0 then
    Inc(S1, $40);
  var S2: Cardinal;
  if (J1 and 1) <> 0 then
  begin
    S2 := J2 + $1F;
    if S2 >= $7F then
      Inc(S2);
  end
  else
    S2 := J2 + $7E;
  Result := (S1 shl 8) or S2;
end;

function CccSjisToJis(S: Cardinal): Cardinal;
begin
  if S < $100 then
    Exit(S);
  var S1 := S shr 8;
  var S2 := S and $FF;
  if S1 >= $E0 then
    Dec(S1, $40);
  var J1 := (S1 - $81) * 2 + $21;
  var J2: Cardinal;
  if S2 >= $9F then
  begin
    Inc(J1);
    J2 := S2 - $9F + $21;
  end
  else
  begin
    J2 := S2 - $40 + $21;
    if S2 >= $80 then
      Dec(J2);
  end;
  Result := (J1 shl 8) or J2;
end;

function TPSPMisc.JisToUcs(Jis: Cardinal): Cardinal;
begin
  Result := 0;
  if Jis > $FFFF then
    Exit;
  if FJis2Ucs <> 0 then
    Exit(FMemory.Read16(FJis2Ucs + Jis * 2));
  CccBuildTables;
  CccJisToUcs.TryGetValue(Jis, Result);
end;

function TPSPMisc.UcsToJis(Ucs: Cardinal): Cardinal;
begin
  Result := 0;
  if Ucs > $FFFF then
    Exit;
  if FUcs2Jis <> 0 then
    Exit(FMemory.Read16(FUcs2Jis + Ucs * 2));
  CccBuildTables;
  CccUcsToJis.TryGetValue(Ucs, Result);
end;

// Decoders take the address of the next unit and return 0 at the end and
// $FFFFFFFF on invalid data.
function TPSPMisc.DecodeUtf8(var P: Cardinal): Cardinal;
begin
  var B := FMemory.Read8(P);
  if B < $80 then
  begin
    if B <> 0 then
      Inc(P);
    Exit(B);
  end;
  var N: Integer;
  var C: Cardinal;
  if (B and $E0) = $C0 then begin N := 1; C := B and $1F; end
  else if (B and $F0) = $E0 then begin N := 2; C := B and $0F; end
  else if (B and $F8) = $F0 then begin N := 3; C := B and $07; end
  else Exit($FFFFFFFF);
  for var I := 1 to N do
  begin
    var T := FMemory.Read8(P + Cardinal(I));
    if (T and $C0) <> $80 then
      Exit($FFFFFFFF);
    C := (C shl 6) or (T and $3F);
  end;
  if ((N = 1) and (C < $80)) or ((N = 2) and (C < $800)) or ((N = 3) and (C < $10000)) or (C > $10FFFF) or
    ((C >= $D800) and (C <= $DFFF)) then
    Exit($FFFFFFFF);
  Inc(P, N + 1);
  Result := C;
end;

function TPSPMisc.DecodeUtf16(var P: Cardinal): Cardinal;
begin
  var W := FMemory.Read16(P);
  if W = 0 then
    Exit(0);
  if (W >= $DC00) and (W <= $DFFF) then
    Exit($FFFFFFFF);
  if (W >= $D800) and (W <= $DBFF) then
  begin
    var L := FMemory.Read16(P + 2);
    if (L < $DC00) or (L > $DFFF) then
      Exit($FFFFFFFF);
    Inc(P, 4);
    Exit($10000 + ((W - $D800) shl 10) + (L - $DC00));
  end;
  Inc(P, 2);
  Result := W;
end;

function TPSPMisc.DecodeSjis(var P: Cardinal): Cardinal;
begin
  var B := FMemory.Read8(P);
  if B = 0 then
    Exit(0);
  var Jis: Cardinal;
  var Len := 1;
  if (B < $80) or ((B >= $A1) and (B <= $DF)) then
    Jis := B
  else if ((B >= $81) and (B <= $9F)) or ((B >= $E0) and (B <= $FC)) then
  begin
    var T := FMemory.Read8(P + 1);
    if (T < $40) or (T = $7F) or (T > $FC) then
      Exit($FFFFFFFF);
    Jis := CccSjisToJis((B shl 8) or T);
    Len := 2;
  end
  else
    Exit($FFFFFFFF);
  var U := JisToUcs(Jis);
  if U = 0 then
    Exit($FFFFFFFF);
  Inc(P, Len);
  Result := U;
end;

function CccUtf8Length(C: Cardinal): Integer;
begin
  if C < $80 then Result := 1
  else if C < $800 then Result := 2
  else if C < $10000 then Result := 3
  else Result := 4;
end;

function TPSPMisc.EncodeTo(Kind: Integer; Dst: Cardinal; C: Cardinal; Room: Integer): Integer;
begin
  // Kind 0 UTF-8, 1 UTF-16, 2 Shift-JIS. Returns the bytes written, -1 if it
  // does not fit, -2 if it cannot be encoded.
  case Kind of
    0:
      begin
        var N := CccUtf8Length(C);
        if N > Room then
          Exit(-1);
        if Dst <> 0 then
          case N of
            1: FMemory.Write8(Dst, C);
            2:
              begin
                FMemory.Write8(Dst, $C0 or (C shr 6));
                FMemory.Write8(Dst + 1, $80 or (C and $3F));
              end;
            3:
              begin
                FMemory.Write8(Dst, $E0 or (C shr 12));
                FMemory.Write8(Dst + 1, $80 or ((C shr 6) and $3F));
                FMemory.Write8(Dst + 2, $80 or (C and $3F));
              end;
          else
            FMemory.Write8(Dst, $F0 or (C shr 18));
            FMemory.Write8(Dst + 1, $80 or ((C shr 12) and $3F));
            FMemory.Write8(Dst + 2, $80 or ((C shr 6) and $3F));
            FMemory.Write8(Dst + 3, $80 or (C and $3F));
          end;
        Result := N;
      end;
    1:
      begin
        var N := 2;
        if C >= $10000 then
          N := 4;
        if N > Room then
          Exit(-1);
        if Dst <> 0 then
          if N = 2 then
            FMemory.Write16(Dst, C)
          else
          begin
            FMemory.Write16(Dst, $D800 + ((C - $10000) shr 10));
            FMemory.Write16(Dst + 2, $DC00 + ((C - $10000) and $3FF));
          end;
        Result := N;
      end;
  else
    begin
      var J := UcsToJis(C);
      if (J = 0) and (C <> 0) then
        Exit(-2);
      var S := CccJisToSjis(J);
      var N := 1;
      if S >= $100 then
        N := 2;
      if N > Room then
        Exit(-1);
      if Dst <> 0 then
        if N = 1 then
          FMemory.Write8(Dst, S)
        else
        begin
          FMemory.Write8(Dst, S shr 8);
          FMemory.Write8(Dst + 1, S and $FF);
        end;
      Result := N;
    end;
  end;
end;

function TPSPMisc.Decode(Kind: Integer; var P: Cardinal): Cardinal;
begin
  case Kind of
    0: Result := DecodeUtf8(P);
    1: Result := DecodeUtf16(P);
  else
    Result := DecodeSjis(P);
  end;
end;

procedure TPSPMisc.Convert(FromKind, ToKind: Integer);
begin
  var Dst := FHLE.Arg(0);
  var Size := FHLE.Arg(1);
  var Src := FHLE.Arg(2);
  if Dst = 0 then
    begin FHLE.Result(0); Exit; end;
  var Unit_ := 1;
  if ToKind = 1 then
    Unit_ := 2;
  // Room in bytes, whole units only, one unit kept for the terminator.
  var Room := Integer(Size div Cardinal(Unit_)) * Unit_ - Unit_;
  if Room < 0 then
    begin FHLE.Result(0); Exit; end;
  var Count := 0;
  var Pos: Cardinal := 0;
  while True do
  begin
    var C := Decode(FromKind, Src);
    if (C = 0) or (C = $FFFFFFFF) then
      Break;
    var N := EncodeTo(ToKind, Dst + Pos, C, Room - Integer(Pos));
    if N < 0 then
      Break;
    Inc(Pos, N);
    Inc(Count);
  end;
  if Unit_ = 2 then
    FMemory.Write16(Dst + Pos, 0)
  else
    FMemory.Write8(Dst + Pos, 0);
  FHLE.Result(Cardinal(Count));
end;

procedure TPSPMisc.hCccSetTable;
begin
  FJis2Ucs := FHLE.Arg(0);
  FUcs2Jis := FHLE.Arg(1);
  FHLE.Result(0);
end;

procedure TPSPMisc.hCccUtf8ToUtf16; begin Convert(0, 1); end;
procedure TPSPMisc.hCccUtf8ToSjis; begin Convert(0, 2); end;
procedure TPSPMisc.hCccUtf16ToUtf8; begin Convert(1, 0); end;
procedure TPSPMisc.hCccUtf16ToSjis; begin Convert(1, 2); end;
procedure TPSPMisc.hCccSjisToUtf8; begin Convert(2, 0); end;
procedure TPSPMisc.hCccSjisToUtf16; begin Convert(2, 1); end;

procedure TPSPMisc.Strlen(Kind: Integer);
begin
  var P := FHLE.Arg(0);
  var N := 0;
  while True do
  begin
    var C := Decode(Kind, P);
    if (C = 0) or (C = $FFFFFFFF) then
      Break;
    Inc(N);
  end;
  FHLE.Result(Cardinal(N));
end;

procedure TPSPMisc.hCccStrlenUtf8; begin Strlen(0); end;
procedure TPSPMisc.hCccStrlenUtf16; begin Strlen(1); end;
procedure TPSPMisc.hCccStrlenSjis; begin Strlen(2); end;

procedure TPSPMisc.Encode(Kind: Integer);
begin
  var PP := FHLE.Arg(0);
  var C := FHLE.Arg(1);
  var Dst := FMemory.Read32(PP);
  var N := EncodeTo(Kind, Dst, C, 4);
  if N = -2 then
    N := EncodeTo(Kind, Dst, FErrorChar[Kind], 4);
  if N > 0 then
    FMemory.Write32(PP, Dst + Cardinal(N));
  FHLE.Result(Dst + Cardinal(Max(N, 0)));
end;

procedure TPSPMisc.hCccEncodeUtf8; begin Encode(0); end;
procedure TPSPMisc.hCccEncodeUtf16; begin Encode(1); end;
procedure TPSPMisc.hCccEncodeSjis; begin Encode(2); end;

procedure TPSPMisc.DecodeCall(Kind: Integer);
begin
  var PP := FHLE.Arg(0);
  var P := FMemory.Read32(PP);
  var Start := P;
  var C := Decode(Kind, P);
  if C = $FFFFFFFF then
  begin
    // An undecodable unit is skipped and reads as the error character.
    if Kind = 1 then
      P := Start + 2
    else
      P := Start + 1;
    C := FErrorChar[Kind];
  end;
  FMemory.Write32(PP, P);
  FHLE.Result(C);
end;

procedure TPSPMisc.hCccDecodeUtf8; begin DecodeCall(0); end;
procedure TPSPMisc.hCccDecodeUtf16; begin DecodeCall(1); end;
procedure TPSPMisc.hCccDecodeSjis; begin DecodeCall(2); end;

procedure TPSPMisc.SetErrorChar(Kind: Integer);
begin
  var Old := FErrorChar[Kind];
  FErrorChar[Kind] := FHLE.Arg(0) and $FFFF;
  FHLE.Result(Old);
end;

procedure TPSPMisc.hCccSetErrorCharUtf8; begin SetErrorChar(0); end;
procedure TPSPMisc.hCccSetErrorCharUtf16; begin SetErrorChar(1); end;
procedure TPSPMisc.hCccSetErrorCharSjis; begin SetErrorChar(2); end;

procedure TPSPMisc.hCccIsValidUcs4;
begin
  var C := FHLE.Arg(0);
  FHLE.Result(Ord((C <= $10FFFF) and ((C < $D800) or (C > $DFFF))));
end;

procedure TPSPMisc.hCccIsValidUcs2;
begin
  var C := FHLE.Arg(0);
  FHLE.Result(Ord((C <= $FFFF) and ((C < $D800) or (C > $DFFF))));
end;

procedure TPSPMisc.hCccIsValidUtf16;
begin
  FHLE.Result(Ord(FHLE.Arg(0) <= $FFFF));
end;

procedure TPSPMisc.hCccIsValidUtf8;
begin
  hCccIsValidUcs4;
end;

procedure TPSPMisc.hCccIsValidSjis;
begin
  var C := FHLE.Arg(0);
  var Ok: Boolean;
  if C < $100 then
    Ok := (C < $80) or ((C >= $A1) and (C <= $DF))
  else
  begin
    var B := C shr 8;
    var T := C and $FF;
    Ok := (C <= $FFFF) and (((B >= $81) and (B <= $9F)) or ((B >= $E0) and (B <= $FC))) and (T >= $40) and
      (T <> $7F) and (T <= $FC) and (JisToUcs(CccSjisToJis(C)) <> 0);
  end;
  FHLE.Result(Ord(Ok));
end;

procedure TPSPMisc.hCccIsValidJis;
begin
  var C := FHLE.Arg(0);
  FHLE.Result(Ord((C = 0) or (JisToUcs(C) <> 0)));
end;

procedure TPSPMisc.hCccUcsToJis;
begin
  var J := UcsToJis(FHLE.Arg(0));
  if (J = 0) and (FHLE.Arg(0) <> 0) then
    J := FHLE.Arg(1);
  FHLE.Result(J);
end;

procedure TPSPMisc.hCccJisToUcs;
begin
  var U := JisToUcs(FHLE.Arg(0));
  if (U = 0) and (FHLE.Arg(0) <> 0) then
    U := FHLE.Arg(1);
  FHLE.Result(U);
end;
