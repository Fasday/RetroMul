{ Software utility UI. Pixels go into the same VRAM buffers as the game's GE
  lists; no host window, font or input polling is involved. }

type
  TSoftwareDialogView = class(TPSPDialogView)
  private
    FSystem: TPSPSystem;
    FFont: TPGFBuiltin;
    FBuffer: PByte;
    FStride, FFormat: Cardinal;
    procedure Pixel(X, Y: Integer; Color: Cardinal; Alpha: Integer = 15);
    procedure Rect(X, Y, W, H: Integer; Color: Cardinal);
    function Glyph(C: Char): TPGFGlyph;
    function TextWidth(const S: string): Integer;
    procedure Text(X, Y: Integer; const S: string; Color: Cardinal);
    procedure Wrapped(X, Y, W, Lines: Integer; const S: string);
    procedure Paint(D: TPSPDialog; Address, Stride, PixelFormat: Cardinal);
  public
    constructor Create(System: TPSPSystem);
    destructor Destroy; override;
    function Update(Dialog: TPSPDialog; Memory: TPSPMemory): Cardinal; override;
  end;

const
  OskKeys = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 -._';
  DialogInk = $FFEFEFEF;
  DialogPanel = $FF382A24;
  DialogAccent = $FFF1BA73;

constructor TSoftwareDialogView.Create(System: TPSPSystem);
begin
  inherited Create;
  FSystem := System;
end;

destructor TSoftwareDialogView.Destroy;
begin
  FFont.Free;
  inherited;
end;

procedure TSoftwareDialogView.Pixel(X, Y: Integer; Color: Cardinal; Alpha: Integer);
begin
  if (X < 0) or (Y < 0) or (X >= 480) or (Y >= 272) or (Alpha = 0) then
    Exit;
  var Bpp := 2;
  if FFormat = 3 then
    Bpp := 4;
  var P := FBuffer + (Cardinal(Y) * FStride + Cardinal(X)) * Cardinal(Bpp);
  var R := Color and $FF;
  var G := (Color shr 8) and $FF;
  var B := (Color shr 16) and $FF;
  if Alpha < 15 then
  begin
    var Old := PWord(P)^;
    var ORed, OGreen, OBlue: Cardinal;
    case FFormat of
      0:
        begin
          ORed := (Old and 31) * 255 div 31;
          OGreen := ((Old shr 5) and 63) * 255 div 63;
          OBlue := ((Old shr 11) and 31) * 255 div 31;
        end;
      1:
        begin
          ORed := (Old and 31) * 255 div 31;
          OGreen := ((Old shr 5) and 31) * 255 div 31;
          OBlue := ((Old shr 10) and 31) * 255 div 31;
        end;
      2:
        begin
          ORed := (Old and 15) * 17;
          OGreen := ((Old shr 4) and 15) * 17;
          OBlue := ((Old shr 8) and 15) * 17;
        end;
    else
      var C := PCardinal(P)^;
      ORed := C and $FF;
      OGreen := (C shr 8) and $FF;
      OBlue := (C shr 16) and $FF;
    end;
    R := (R * Cardinal(Alpha) + ORed * Cardinal(15 - Alpha) + 7) div 15;
    G := (G * Cardinal(Alpha) + OGreen * Cardinal(15 - Alpha) + 7) div 15;
    B := (B * Cardinal(Alpha) + OBlue * Cardinal(15 - Alpha) + 7) div 15;
  end;
  case FFormat of
    0: PWord(P)^ := (R shr 3) or ((G shr 2) shl 5) or ((B shr 3) shl 11);
    1: PWord(P)^ := (R shr 3) or ((G shr 3) shl 5) or ((B shr 3) shl 10) or $8000;
    2: PWord(P)^ := (R shr 4) or ((G shr 4) shl 4) or ((B shr 4) shl 8) or $F000;
    3: PCardinal(P)^ := R or (G shl 8) or (B shl 16) or $FF000000;
  end;
end;

procedure TSoftwareDialogView.Rect(X, Y, W, H: Integer; Color: Cardinal);
begin
  for var J := Max(0, Y) to Min(271, Y + H - 1) do
    for var I := Max(0, X) to Min(479, X + W - 1) do
      Pixel(I, J, Color);
end;

function TSoftwareDialogView.Glyph(C: Char): TPGFGlyph;
begin
  var I := FFont.Lookup(Ord(C));
  if I < 0 then
    I := FFont.Lookup(Ord('?'));
  Result := FFont.Glyph(I);
end;

function TSoftwareDialogView.TextWidth(const S: string): Integer;
begin
  Result := 0;
  for var C in S do
    Inc(Result, (Glyph(C).Advance.X + 32) div 64);
end;

procedure TSoftwareDialogView.Text(X, Y: Integer; const S: string; Color: Cardinal);
begin
  for var C in S do
  begin
    var G := Glyph(C);
    for var J := 0 to G.H - 1 do
      for var I := 0 to G.W - 1 do
        Pixel(X + G.Left + I, Y + 12 - G.Top + J, Color, G.Pixel(I, J));
    Inc(X, (G.Advance.X + 32) div 64);
  end;
end;

procedure TSoftwareDialogView.Wrapped(X, Y, W, Lines: Integer; const S: string);
begin
  var Start := 1;
  for var Row := 0 to Lines - 1 do
  begin
    if Start > Length(S) then
      Exit;
    var LastSpace := 0;
    var N := Start;
    var Width := 0;
    while (N <= Length(S)) and (S[N] <> #10) do
    begin
      var Advance := (Glyph(S[N]).Advance.X + 32) div 64;
      if Width + Advance > W then
        Break;
      Inc(Width, Advance);
      if S[N] = ' ' then
        LastSpace := N;
      Inc(N);
    end;
    if (N <= Length(S)) and (S[N] <> #10) and (LastSpace > Start) then
      N := LastSpace;
    Text(X, Y + Row * 17, Copy(S, Start, N - Start).Replace(#13, ''), DialogInk);
    Start := N;
    if (Start <= Length(S)) and CharInSet(S[Start], [' ', #10]) then
      Inc(Start);
  end;
end;

procedure TSoftwareDialogView.Paint(D: TPSPDialog; Address, Stride, PixelFormat: Cardinal);
begin
  if (Address = 0) or (Stride < 480) or (Stride > 2048) or (PixelFormat > 3) then
    Exit;
  var Bpp: Cardinal := 2;
  if PixelFormat = 3 then
    Bpp := 4;
  FBuffer := FSystem.Memory.Ptr(Address, Stride * 272 * Bpp);
  if FBuffer = nil then
    Exit;
  if FFont = nil then
    FFont := TPGFBuiltin.Create(8, False, False);
  FStride := Stride;
  FFormat := PixelFormat;
  Rect(24, 28, 432, 216, DialogPanel);
  Rect(24, 28, 432, 2, DialogAccent);
  Rect(24, 242, 432, 2, DialogAccent);
  var M := FSystem.Memory;
  var P := D.Params;
  var Title := 'Message';
  var Body := D.Text;
  var Confirm := 'X';
  var Cancel := 'O';
  if PSPSettings.ButtonSwap = 0 then
  begin
    Confirm := 'O';
    Cancel := 'X';
  end;
  var Footer := Confirm + ' Enter    ' + Cancel + ' Back';
  case D.Kind of
    dtMsg:
      begin
        if M.Read32(P + $34) = 0 then
          Body := 'An error has occurred.' + #10 + Format('(%s)', [IntToHex(M.Read32(P + $38), 8)])
        else
          Body := UTF8ToString(M.ReadAnsi(P + $3C, 512));
        var Options: Cardinal := 0;
        if D.Size > $23C then
          Options := M.Read32(P + $23C);
        if (Options and $10) <> 0 then
        begin
          if D.Selection = 0 then
            Text(170, 196, '[ Yes ]       No', DialogAccent)
          else
            Text(170, 196, '  Yes       [ No ]', DialogAccent);
        end;
        if (Options and $80) <> 0 then
          Footer := Confirm + ' Enter';
      end;
    dtSavedata:
      begin
        Title := 'Saved Data';
        if Length(D.Choices) > 1 then
        begin
          var First := Max(0, D.Selection - 2);
          for var I := First to Min(High(D.Choices), First + 3) do
          begin
            var Prefix := '   ';
            var Ink := DialogInk;
            if I = D.Selection then
            begin
              Prefix := '> ';
              Ink := DialogAccent;
            end;
            Text(48, 116 + (I - First) * 19, Prefix + Copy(D.Choices[I], 1, 42), Ink);
          end;
          Footer := 'Up/Down Select    ' + Footer;
        end;
      end;
    dtOsk:
      begin
        Title := 'On-Screen Keyboard';
        Body := D.Text;
        Text(44, 76, Copy(D.Text, Max(1, Length(D.Text) - 47), 48), DialogAccent);
        Body := '';
        for var I := 0 to Length(OskKeys) - 1 do
        begin
          var X := 48 + (I mod 10) * 38;
          var Y := 106 + (I div 10) * 22;
          if I = D.Selection then
            Rect(X - 6, Y - 2, 28, 20, $FF72503D);
          var C := OskKeys[I + 1];
          if C = ' ' then
            C := '_';
          Text(X, Y, C, DialogInk);
        end;
        Footer := Confirm + ' Type  Square Delete  Start Done  ' + Cancel + ' Cancel';
      end;
  end;
  Text(42, 43, Title, DialogAccent);
  Rect(42, 65, 396, 1, $FF79685A);
  var Lines := 7;
  if D.Kind = dtSavedata then
    Lines := 2;
  Wrapped(44, 79, 390, Lines, Body);
  Text(42, 220, Footer, DialogInk);
end;

function TSoftwareDialogView.Update(Dialog: TPSPDialog; Memory: TPSPMemory): Cardinal;
begin
  var Display := FSystem.Display;
  Paint(Dialog, Display.CurrentAddress, Display.Width, Display.Format);
  // The game may have finished drawing its next buffer but not flipped it yet.
  var GE := TPSPGE(FSystem.Find(TPSPGE));
  if GE <> nil then
  begin
    var Addr := PSPVRAMBase + (GE.Engine.Regs.Cmd[GE_FRAMEBUFPTR] and $1FFFF0);
    if (Addr and $1FFFFF) <> (Display.CurrentAddress and $1FFFFF) then
      Paint(Dialog, Addr, GE.Engine.Regs.Cmd[GE_FRAMEBUFWIDTH] and $7FC,
        GE.Engine.Regs.Cmd[GE_FRAMEBUFPIXFORMAT] and 3);
  end;
  Result := Display.SampledButtons;
end;
