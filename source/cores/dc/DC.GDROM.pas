unit DC.GDROM;

// GD-ROM drive on the G1 ATA interface (005F7000..): status registers and
// the CD-DA playback state shared by the system calls and the AICA mixer
// (44.1 kHz stereo from audio sectors, 588 samples each).
{$IFDEF DC_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, System.Classes, Core.Snapshots, DC.Types, DC.Scheduler, DC.Interrupts, DC.Disc;

type
  TDCCDDAState = record
    Status: Integer;          // 0 none, 1 playing, 2 paused, 3 ended
    StartFAD, EndFAD, FAD: Cardinal;
    Repeats: Integer;         // 0..14, 15 = forever
    Sample: Integer;          // sample index in the current sector
  end;

  TDCGDROMState = record
    Status, Error, Features, SectorCount, SectorNumber, ByteCount, DriveSelect, DeviceControl: Cardinal;
    CDDA: TDCCDDAState;
  end;

  TDCGDROM = class
  private
    FScheduler: TDCScheduler;
    FInterrupts: TDCInterrupts;
    FAudio: array[0..2351] of Byte;
    FAudioFAD: Cardinal;
    FAudioValid: Boolean;
  public
    S: TDCGDROMState;
    // Not owned; nil without a disc.
    Disc: TDCDisc;
    constructor Create(Scheduler: TDCScheduler; Interrupts: TDCInterrupts);
    procedure Reset;
    function Read(Offset: Cardinal; Size: Integer): Cardinal;
    procedure Write(Offset, Value: Cardinal; Size: Integer);
    procedure Event;
    // Copies up to Count bytes of pending DMA data; returns the bytes moved.
    function DMARead(Dest: PByte; Count: Integer): Integer;
    // CD-DA control.
    procedure PlayTracks(First, Last, Repeats: Cardinal);
    procedure PlaySectors(StartFAD, EndFAD, Repeats: Cardinal);
    procedure PauseCDDA;
    procedure ResumeCDDA;
    procedure StopCDDA;
    procedure SeekCDDA(FAD: Cardinal);
    function CDDAPosition: Cardinal;
    // Sub-channel audio status (11h playing, 12h paused, 13h ended, 15h none).
    function AudioStatus: Byte;
    // Drive status code: 1 paused, 2 standby, 3 playing, 7 no disc.
    function DriveStatus: Cardinal;
    // Next CD-DA output sample; silence unless playing.
    procedure NextSample(out Left, Right: SmallInt);
    procedure SerializeState(Archive: TStateArchive);
  end;

implementation

const
  ATAStatusDRDY = $40;
  ATAStatusDSC = $10;

constructor TDCGDROM.Create(Scheduler: TDCScheduler; Interrupts: TDCInterrupts);
begin
  inherited Create;
  FScheduler := Scheduler;
  FInterrupts := Interrupts;
  Reset;
end;

procedure TDCGDROM.Reset;
begin
  S := Default(TDCGDROMState);
  S.Status := ATAStatusDRDY or ATAStatusDSC;
  S.SectorNumber := DriveStatus;
  FAudioValid := False;
end;

function TDCGDROM.DriveStatus: Cardinal;
begin
  if (Disc = nil) or not Disc.HasBootTrack then
    Exit(7);
  case S.CDDA.Status of
    1: Result := 3;
    2: Result := 1;
  else
    Result := 1;
  end;
end;

function TDCGDROM.AudioStatus: Byte;
begin
  case S.CDDA.Status of
    1: Result := $11;
    2: Result := $12;
    3: Result := $13;
  else
    Result := $15;
  end;
end;

function TDCGDROM.CDDAPosition: Cardinal;
begin
  if S.CDDA.Status in [1, 2] then
    Result := S.CDDA.FAD
  else
    Result := 0;
end;

procedure TDCGDROM.PlaySectors(StartFAD, EndFAD, Repeats: Cardinal);
begin
  S.CDDA.StartFAD := StartFAD;
  S.CDDA.EndFAD := EndFAD;
  S.CDDA.FAD := StartFAD;
  S.CDDA.Repeats := Integer(Repeats and 15);
  S.CDDA.Sample := 0;
  S.CDDA.Status := 1;
  FAudioValid := False;
end;

procedure TDCGDROM.PlayTracks(First, Last, Repeats: Cardinal);
begin
  if (Disc = nil) or (First < 1) or (Int64(First) > Disc.Image.TrackCount) then
    Exit;
  if (Last < First) or (Int64(Last) > Disc.Image.TrackCount) then
    Last := First;
  PlaySectors(Cardinal(Disc.Image.Track(First).StartLBA + 150), Cardinal(Disc.Image.Track(Last).EndLBA + 150 - 1), Repeats);
end;

procedure TDCGDROM.PauseCDDA;
begin
  if S.CDDA.Status = 1 then
    S.CDDA.Status := 2;
end;

procedure TDCGDROM.ResumeCDDA;
begin
  if S.CDDA.Status = 2 then
    S.CDDA.Status := 1;
end;

procedure TDCGDROM.StopCDDA;
begin
  S.CDDA.Status := 0;
end;

procedure TDCGDROM.SeekCDDA(FAD: Cardinal);
begin
  S.CDDA.FAD := FAD;
  S.CDDA.StartFAD := FAD;
  S.CDDA.Sample := 0;
  S.CDDA.Status := 2;
end;

procedure TDCGDROM.NextSample(out Left, Right: SmallInt);
begin
  Left := 0;
  Right := 0;
  if (S.CDDA.Status <> 1) or (Disc = nil) then
    Exit;
  if not FAudioValid or (FAudioFAD <> S.CDDA.FAD) then
  begin
    Disc.ReadAudio(Integer(S.CDDA.FAD) - 150, @FAudio[0]);
    FAudioFAD := S.CDDA.FAD;
    FAudioValid := True;
  end;
  Left := PSmallInt(@FAudio[S.CDDA.Sample * 4])^;
  Right := PSmallInt(@FAudio[S.CDDA.Sample * 4 + 2])^;
  Inc(S.CDDA.Sample);
  if S.CDDA.Sample = 588 then
  begin
    S.CDDA.Sample := 0;
    Inc(S.CDDA.FAD);
    if S.CDDA.FAD > S.CDDA.EndFAD then
    begin
      if S.CDDA.Repeats > 0 then
      begin
        if S.CDDA.Repeats < 15 then
          Dec(S.CDDA.Repeats);
        S.CDDA.FAD := S.CDDA.StartFAD;
      end
      else
        S.CDDA.Status := 3;
    end;
  end;
end;

function TDCGDROM.Read(Offset: Cardinal; Size: Integer): Cardinal;
begin
  case Offset and $FF of
    $18: Result := S.Status;
    $84: Result := S.Error;
    $88: Result := S.SectorCount;
    $8C: Result := DriveStatus or (Cardinal(0) shl 4);
    $90: Result := S.ByteCount and $FF;
    $94: Result := (S.ByteCount shr 8) and $FF;
    $98: Result := S.DriveSelect;
    $9C:
      begin
        Result := S.Status;
        FInterrupts.SetExternal(HollyExtGDROM, False);
      end;
  else
    Result := 0;
  end;
end;

procedure TDCGDROM.Write(Offset, Value: Cardinal; Size: Integer);
begin
  case Offset and $FF of
    $18: S.DeviceControl := Value and $FF;
    $84: S.Features := Value and $FF;
    $88: S.SectorCount := Value and $FF;
    $90: S.ByteCount := (S.ByteCount and $FF00) or (Value and $FF);
    $94: S.ByteCount := (S.ByteCount and $FF) or ((Value and $FF) shl 8);
    $98: S.DriveSelect := Value and $FF;
    $9C:
      begin
        // ATA/packet commands are not modelled: abort them.
        S.Error := $04;
        S.Status := ATAStatusDRDY or ATAStatusDSC or 1;
        FInterrupts.SetExternal(HollyExtGDROM, True);
      end;
  end;
end;

procedure TDCGDROM.Event;
begin
end;

function TDCGDROM.DMARead(Dest: PByte; Count: Integer): Integer;
begin
  Result := 0;
end;

procedure TDCGDROM.SerializeState(Archive: TStateArchive);
begin
  Archive.Field(S, SizeOf(S));
  if Archive.Loading then
  begin
    if (S.CDDA.Sample < 0) or (S.CDDA.Sample >= 588) or (S.CDDA.Status < 0) or (S.CDDA.Status > 3) then
      raise EReadError.Create('Dreamcast snapshot GD-ROM state');
    FAudioValid := False;
  end;
end;

end.
