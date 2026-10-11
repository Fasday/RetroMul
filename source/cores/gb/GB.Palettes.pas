unit GB.Palettes;

interface

uses
  System.UITypes, System.IniFiles;

type
  // Host enhancements are not part of emulated hardware or save states.
  TGBRuntimeOptions = record
    FrameBlending: Boolean;
    Palettes: array[0..2] of Integer; // BG, OBJ0, OBJ1; -1 inherits default.
    ChannelVolumes: array[0..3] of Integer; // percent
    ShowBackground, ShowWindow, ShowSprites, RemoveSpriteLimit: Boolean;
    Overclock: Integer; // CPU percent, 100..400; video/audio retain their clocks.
    class function Defaults: TGBRuntimeOptions; static;
    procedure Normalize;
    procedure Load(Ini: TCustomIniFile);
    procedure Save(Ini: TCustomIniFile);
    function PresentationColor(Pixel, DefaultPalette: Integer; ColorHardware: Boolean): TAlphaColor;
    function MonochromeColor(Pixel, DefaultPalette: Integer): TAlphaColor;
  end;

  TScreenPalette = record
    Name: string;
    Colors: array[0..3] of TAlphaColor;
  end;

const
  SCREEN_PALETTE_COUNT = 8;

const
  // Shades are ordered from lightest to darkest; Original preserves the initial palette.
  // DMG/Pocket/Light and GBC presets use RGB values from Gambatte's palette table:
  // https://github.com/libretro/gambatte-libretro/blob/master/libgambatte/libretro/gbcpalettes.h
  ScreenPalettes: array[0..SCREEN_PALETTE_COUNT - 1] of TScreenPalette = (
    (Name: 'Original'; Colors: ($FFE0F8D0, $FF88C070, $FF346856, $FF081820)),
    (Name: 'Game Boy DMG'; Colors: ($FF578200, $FF317400, $FF005121, $FF00420C)),
    (Name: 'Game Boy Pocket'; Colors: ($FFA7B19A, $FF86927C, $FF535F49, $FF2A3325)),
    (Name: 'Game Boy Light'; Colors: ($FF01CBDF, $FF01B6D5, $FF269BAD, $FF00778D)),
    (Name: 'Grayscale'; Colors: ($FFFFFFFF, $FFA5A5A5, $FF525252, $FF000000)),
    (Name: 'GBC Blue'; Colors: ($FFFFFFFF, $FF63A5FF, $FF0000FF, $FF000000)),
    (Name: 'GBC Brown'; Colors: ($FFFFFFFF, $FFFFAD63, $FF843100, $FF000000)),
    (Name: 'GBC Pastel'; Colors: ($FFFFFFA5, $FFFF9494, $FF9494FF, $FF000000)));

function GBBlendColor(Current, Previous: TAlphaColor): TAlphaColor;

implementation

uses
  System.Math, System.SysUtils;

const
  PaletteKeys: array[0..2] of string = ('BGPalette', 'OBJ0Palette', 'OBJ1Palette');

class function TGBRuntimeOptions.Defaults: TGBRuntimeOptions;
begin
  Result := Default(TGBRuntimeOptions);
  for var i := 0 to 2 do
    Result.Palettes[i] := -1;
  for var i := 0 to 3 do
    Result.ChannelVolumes[i] := 100;
  Result.ShowBackground := True;
  Result.ShowWindow := True;
  Result.ShowSprites := True;
  Result.Overclock := 100;
end;

procedure TGBRuntimeOptions.Normalize;
begin
  for var i := 0 to 2 do
    Palettes[i] := EnsureRange(Palettes[i], -1, SCREEN_PALETTE_COUNT - 1);
  for var i := 0 to 3 do
    ChannelVolumes[i] := EnsureRange(ChannelVolumes[i], 0, 100);
  Overclock := EnsureRange(Overclock, 100, 400);
end;

procedure TGBRuntimeOptions.Load(Ini: TCustomIniFile);
begin
  Self := Defaults;
  FrameBlending := Ini.ReadBool('Video', 'FrameBlending', False);
  for var i := 0 to 2 do
    Palettes[i] := Ini.ReadInteger('Video', PaletteKeys[i], -1);
  for var i := 0 to 3 do
    ChannelVolumes[i] := Ini.ReadInteger('Audio', 'Channel' + IntToStr(i + 1) + 'Volume', 100);
  ShowBackground := Ini.ReadBool('Video', 'ShowBackground', True);
  ShowWindow := Ini.ReadBool('Video', 'ShowWindow', True);
  ShowSprites := Ini.ReadBool('Video', 'ShowSprites', True);
  RemoveSpriteLimit := Ini.ReadBool('Video', 'RemoveSpriteLimit', False);
  Overclock := Ini.ReadInteger('Emulation', 'Overclock', 100);
  Normalize;
end;

procedure TGBRuntimeOptions.Save(Ini: TCustomIniFile);
begin
  Normalize;
  Ini.WriteBool('Video', 'FrameBlending', FrameBlending);
  for var i := 0 to 2 do
    Ini.WriteInteger('Video', PaletteKeys[i], Palettes[i]);
  for var i := 0 to 3 do
    Ini.WriteInteger('Audio', 'Channel' + IntToStr(i + 1) + 'Volume', ChannelVolumes[i]);
  Ini.WriteBool('Video', 'ShowBackground', ShowBackground);
  Ini.WriteBool('Video', 'ShowWindow', ShowWindow);
  Ini.WriteBool('Video', 'ShowSprites', ShowSprites);
  Ini.WriteBool('Video', 'RemoveSpriteLimit', RemoveSpriteLimit);
  Ini.WriteInteger('Emulation', 'Overclock', Overclock);
end;

function TGBRuntimeOptions.MonochromeColor(Pixel, DefaultPalette: Integer): TAlphaColor;
begin
  if (Pixel < 0) or (Pixel > 11) then
    Pixel := 0;
  var Index := Palettes[Pixel shr 2];
  if Index < 0 then
    Index := DefaultPalette;
  Result := ScreenPalettes[EnsureRange(Index, 0, SCREEN_PALETTE_COUNT - 1)].Colors[Pixel and 3];
end;

function TGBRuntimeOptions.PresentationColor(Pixel, DefaultPalette: Integer; ColorHardware: Boolean): TAlphaColor;
begin
  if not ColorHardware then
    Exit(MonochromeColor(Pixel, DefaultPalette));

  Move(Pixel, Result, SizeOf(Result));
  // C0..CB alpha tags retain the boot palette RGB plus monochrome source/shade.
  var Tag := Integer(Result shr 24) - $C0;
  if (Tag >= 0) and (Tag <= 11) then
  begin
    if Palettes[Tag shr 2] >= 0 then
      Result := ScreenPalettes[Palettes[Tag shr 2]].Colors[Tag and 3]
    else
      Result := Result or $FF000000;
  end;
end;

function GBBlendColor(Current, Previous: TAlphaColor): TAlphaColor;
begin
  Result := $FF000000 or
    (((Current and $00FEFEFE) shr 1) + ((Previous and $00FEFEFE) shr 1) +
    (Current and Previous and $00010101));
end;

end.

