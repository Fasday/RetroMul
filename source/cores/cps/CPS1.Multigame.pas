unit CPS1.Multigame;

interface

uses
  System.SysUtils, CPS1.Boards, CPS.Cartridge, Core.Snapshots;

type
  // Independently banked program, graphics, Z80 and split OKI flash buses.
  // Offsets are decoded flash addresses, not inferred game numbers. The
  // external DIP/GAL game-number truth table has not been recovered.
  TCPSMultigameConsole = class(TCPS1BoardConsole)
  private
    FAllProgram, FAllAudio: TBytes;
    FProgramPage, FGraphicsPage, FAudioPage, FSamplePage, FGraphicsHalf: Integer;
    procedure ApplyBanks;
  public
    constructor Create(Cart: TCPSCartridge);
    procedure SelectBanks(ProgramPage, GraphicsPage, AudioPage, SamplePage: Integer; GraphicsHalf: Integer = 0);
    procedure Reset; override;
    procedure SerializeState(State: TStateArchive); override;
  end;

implementation

uses
  CPS1.Sound, CPS.RomSets, System.Math;

constructor TCPSMultigameConsole.Create(Cart: TCPSCartridge);
begin
  inherited;
  FAllProgram := FProgram;
  FAllAudio := FAudio;
  if (Length(FAllProgram) <> $4000000) or (Length(FAllAudio) <> $100000) or
    (Length(Cart['oki']) <> $400000) then
    raise ECPSRom.Create('Truncated CPS1 multigame flash');

  ApplyBanks;
  Reset;
end;

procedure TCPSMultigameConsole.ApplyBanks;
begin
  if (FProgramPage < 0) or (FProgramPage > 63) or (FGraphicsPage < 0) or (FGraphicsPage > 31) or
    (FGraphicsHalf < 0) or (FGraphicsHalf > 1) or (FAudioPage < 0) or (FAudioPage > 15) or (FSamplePage < 0) or (FSamplePage > 15) then
    raise EArgumentException.Create('Invalid CPS1 multigame flash bank');

  // The CPU sees a 2 MB window; the remaining flash must never shadow I/O.
  // CPU A20 selects decoded flash A23. The two halves are interleaved
  // with seven other game slots; copying adjacent pages boots the wrong tail.
  SetLength(FProgram, $200000);
  Move(FAllProgram[FProgramPage * $100000], FProgram[0], $100000);
  Move(FAllProgram[(FProgramPage xor 8) * $100000], FProgram[$100000], $100000);
  var GraphicsOffset := FGraphicsPage * $400000 + FGraphicsHalf * $200000;
  Video.SelectGraphicsWindow(GraphicsOffset, Min($800000, Length(FCart['gfx']) - GraphicsOffset));

  // Programs were converted to CPS-B-21 register wiring; graphics still use
  // the original game's PAL equations. ROM identification is independent of
  // the currently unknown external selector-to-game-number truth table.
  var Name := 'megaman';
  case FProgramPage and not 8 of
    0:
      Name := 'msword';
    1, 5, 55:
      Name := 'sf2ce';
    2:
      Name := 'punisher';
    3, 6:
      Name := 'dino';
    4, 18:
      Name := 'ffight';
    7:
      Name := 'kod';
    16:
      Name := 'dynwar';
    17:
      Name := 'willow';
    19:
      Name := 'nemo';
    20:
      Name := 'ghouls';
    21:
      Name := 'mercs';
    32:
      Name := 'knights';
    33, 36:
      Name := 'wof';
    34:
      Name := '3wonders';
    35:
      Name := 'captcomm';
    37, 48:
      Name := 'pang3';
    38:
      Name := 'forgottn';
    39:
      Name := 'strider';
    49:
      Name := 'mtwins';
    52:
      Name := 'cawing';
    53:
      Name := 'unsquad';
  end;
  var Profile: TCPSRomSet;
  if not TCPSRomSet.Find(Name, Profile) then
    raise ECPSRom.Create('Missing multigame graphics mapper');

  Video.ConfigureGraphicsMapper(Profile.Board);
  SetLength(FAudio, $18000);
  FillChar(FAudio[0], Length(FAudio), $FF);
  Move(FAllAudio[FAudioPage * $10000], FAudio[0], $8000);
  Move(FAllAudio[FAudioPage * $10000 + $8000], FAudio[$10000], $8000);

  // U18 holds all first 128 KB halves; U19 all second halves.
  // Recombine the selected pair before using the normal OKI address bus.
  var Raw := FCart['oki'];
  var ROM: TBytes;
  SetLength(ROM, $40000);
  Move(Raw[FSamplePage * $20000], ROM[0], $20000);
  Move(Raw[$200000 + FSamplePage * $20000], ROM[$20000], $20000);
  FSound.Free;
  FSound := nil;
  FSound := TCPS1Sound.Create(ROM);
end;

procedure TCPSMultigameConsole.SelectBanks(ProgramPage, GraphicsPage, AudioPage, SamplePage: Integer; GraphicsHalf: Integer);
begin
  if (ProgramPage < 0) or (ProgramPage > 63) or (GraphicsPage < 0) or (GraphicsPage > 31) or
    (GraphicsHalf < 0) or (GraphicsHalf > 1) or (AudioPage < 0) or (AudioPage > 15) or (SamplePage < 0) or (SamplePage > 15) then
    raise EArgumentException.Create('Invalid CPS1 multigame flash bank');

  FGraphicsHalf := GraphicsHalf;
  FProgramPage := ProgramPage;
  FGraphicsPage := GraphicsPage;
  FAudioPage := AudioPage;
  FSamplePage := SamplePage;
  ApplyBanks;
  Reset;
end;

procedure TCPSMultigameConsole.Reset;
begin
  inherited;
end;

procedure TCPSMultigameConsole.SerializeState(State: TStateArchive);
begin
  State.Field(FProgramPage, SizeOf(FProgramPage));
  State.Field(FGraphicsPage, SizeOf(FGraphicsPage));
  State.Field(FAudioPage, SizeOf(FAudioPage));
  State.Field(FSamplePage, SizeOf(FSamplePage));
  State.Field(FGraphicsHalf, SizeOf(FGraphicsHalf));
  if State.Loading then
    ApplyBanks;
  inherited;
end;

end.

