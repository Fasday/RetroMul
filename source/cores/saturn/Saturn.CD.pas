unit Saturn.CD;

interface

uses
  System.SysUtils, System.Classes, Core.CD.Disc, Core.Snapshots, Saturn.CDB;

type
  TCDInterrupt = procedure(Active: Boolean) of object;

  TCDFilter = record
    Start, Count: Cardinal;
    Mode, Channel, FileID, SubMask, CodeMask, SubValue, CodeValue, Yes, No: Byte;
  end;

  TCDSector = record
    Used: Boolean;
    Partition: Byte;
    Sequence, FAD: Cardinal;
    Data: array[0..2351] of Byte;
  end;

  TCDFile = record
    FAD, Bytes: Cardinal;
    Flags, UnitSize, Gap, FileNumber: Byte; // FileNumber occupies the legacy reserved byte.
  end;
  // Native command model or original SH-1 firmware backend. Media remains
  // owned by the adapter; the two backends never dispatch the same command.

  TSaturnCD = class
  private
    FDisc: TCDDisc;
    FIRQ: TCDInterrupt;
    FClock: Integer;
    FModelNext: Int64; // derived earliest command/sector/report deadline
    FIRQKnown, FIRQLine, FNativeEnabled: Boolean;
    FTime, FCommandAt, FReportAt, FSectorAt: Int64;
    FCR, FCommand: array[0..3] of Word;
    FHIRQ, FMask: Word;
    FPending, FResponse, FPlaying, FSingleSpeed, FFilePlay, FPowered: Boolean;
    FStatus, FConnection, FLast, FAuthenticated, FRepeat, FRepeatLimit, FCopyError: Byte;
    FFAD, FStart, FEnd, FSequence, FCalculated, FSearchFAD: Cardinal;
    FSearchPosition, FSearchPartition: Word;
    FGetSize, FPutSize: Integer;
    FFilters: array[0..23] of TCDFilter;
    FSectors: array[0..199] of TCDSector;
    FFIFO: TBytes;
    FFIFOAt, FTransferred, FTransferPartition, FTransferStart, FTransferCount, FTransferKind: Integer;
    FFiles: TArray<TCDFile>;
    FFileFirst, FFileCount: Integer;
    FDirectoryFAD, FDirectoryBytes: Cardinal;
    FAudio: array[0..2351] of Byte;
    FAudioAt: Integer;
    FNative: TSaturnCDB;
    FNativePhase, FNativeTime: Int64;
    FProtection: Boolean;
    FSeekAt, FAuthAt, FSectorFraction: Int64;
    FSeekTarget: Cardinal;
    FSeekPlay: Boolean;
    FNetlinkScratch: Byte;
    FNetlinkRegs: array[0..5] of Byte; // IER, DLL, DLM, FCR, LCR, MCR
    FNetlinkRX: array[0..1023] of Byte;
    FNetlinkCommand: array[0..255] of Byte;
    FNetlinkRXAt, FNetlinkRXCount, FNetlinkCommandCount: Integer;
    FNetlinkEcho, FNetlinkVerbose, FNetlinkQuiet, FNetlinkTXIRQ: Boolean;
    FNetlinkIRQ: TCDInterrupt;
    FNetlinkPresent: Boolean;
    procedure SetNetlinkPresent(Value: Boolean);
    procedure UpdateNetlinkIRQ;
    procedure NetlinkReceive(Value: Byte);
    procedure NetlinkTransmit(Value: Byte);
    function NetlinkRead(Address: Cardinal): Byte;
    procedure NetlinkWrite(Address: Cardinal; Value: Byte);
    procedure Seek(Target: Cardinal; Playing: Boolean);
    function GetFAD: Cardinal;
    procedure SetProtection(Value: Boolean);
    procedure UpdateIRQ;
    procedure AdvanceNative(Target: Int64);
    procedure AdvanceModel;
    procedure Report(Periodic: Boolean = False);
    procedure Execute;
    procedure ReadSector;
    procedure ResetSelectors(Flags: Byte; Partition: Integer);
    function FreeCount: Integer;
    function SectorCount(Partition: Integer): Integer;
    function SectorIndex(Partition, Position: Integer): Integer;
    procedure DeleteSectors(Partition, Position, Count: Integer);
    function FilterDestination(const Raw: TBytes; SectorFAD: Cardinal; StartFilter: Integer): Integer;
    procedure BeginTransfer(const Data: TBytes);
    procedure SectorTransfer(Kind, Partition, Position, Count: Integer);
    procedure EndTransfer;
    procedure ReadDirectory(FAD, Bytes: Cardinal);
    procedure RootDirectory;
    function PositionFAD(Value: Cardinal; Ending: Boolean): Cardinal;
  public
    constructor Create(Disc: TCDDisc; IRQ: TCDInterrupt);
    destructor Destroy; override;
    procedure UseSH1(Enabled: Boolean);
    function WaitHost(Address: Cardinal; Size: Integer; Writing: Boolean): Integer;
    procedure Reset(Clock: Integer);
    procedure SetClock(Clock: Integer);
    procedure SetPower(Enabled: Boolean; At: Int64);
    procedure Advance(Target: Int64); inline;
    // Board scheduler only: Target is already known to be monotonic.
    procedure AdvanceForward(Target: Int64); inline;
    function Read(Address: Cardinal; Size: Integer): Cardinal;
    procedure Write(Address, Value: Cardinal; Size: Integer);
    procedure AudioSample(out Left, Right: Integer);
    procedure SerializeState(Archive: TStateArchive; Extended: Boolean = True; Modem: Boolean = True; ModemPresence: Boolean = True);
    property NetlinkPresent: Boolean read FNetlinkPresent write SetNetlinkPresent;
    property NetlinkIRQ: TCDInterrupt read FNetlinkIRQ write FNetlinkIRQ;
    property Disc: TCDDisc read FDisc;
    property FAD: Cardinal read GetFAD;
    property SH1: TSaturnCDB read FNative;
    property Protection: Boolean read FProtection write SetProtection;
    property SeekReadyAt: Int64 read FSeekAt;
  end;

implementation

uses
  System.Math, Saturn.Firmware;

{$Q+}{$R+}

const
  SectorSizes: array[0..3] of Integer = (2048, 2336, 2340, 2352);

function LE32(const B: TBytes; A: Integer): Cardinal;
begin
  Result := Cardinal(B[A]) or (Cardinal(B[A + 1]) shl 8) or (Cardinal(B[A + 2]) shl 16) or (Cardinal(B[A + 3]) shl 24);
end;

procedure BE32(var B: TBytes; A: Integer; V: Cardinal);
begin
  for var i := 0 to 3 do
    B[A + i] := (V shr ((3 - i) * 8)) and $FF;
end;

constructor TSaturnCD.Create(Disc: TCDDisc; IRQ: TCDInterrupt);
begin
  inherited Create;
  FDisc := Disc;
  FIRQ := IRQ;
  Reset(26846587);
end;

destructor TSaturnCD.Destroy;
begin
  FNative.Free;
  inherited;
end;

function TSaturnCD.WaitHost(Address: Cardinal; Size: Integer; Writing: Boolean): Integer;
begin
  Result := 0;
  if (FNative = nil) or not ((Address = $05818000) or (Address = $05898000)) then
    Exit;
  if Writing <> (FNative.Read($0A000002, 2) and 1 <> 0) then
    Exit;

  var Start := FNative.CPU.Time;

  // CPU reads are synchronous. Charge the local bridge advance to the
  // issuing CPU's bus wait; the normal CD clock catches up afterwards.
  while not FNative.HostReady(Size, Writing) and (FNative.CPU.Time - Start < 4096) do
    FNative.Advance(FNative.CPU.Time + 16);
  Result := Integer(((FNative.CPU.Time - Start) * FClock + 19999999) div 20000000);
end;

procedure TSaturnCD.UseSH1(Enabled: Boolean);
begin
  FNativeEnabled := Enabled;
  FModelNext := 0;
  FIRQKnown := False;
  if Enabled = (FNative <> nil) then
    Exit;

  if Enabled then
    FNative := TSaturnCDB.Create(LoadSaturnCDFirmware, FDisc, FIRQ)
  else
    FreeAndNil(FNative);
  if FNative <> nil then
    FNative.Protection := FProtection;
  FNativePhase := 0;
  FNativeTime := 0;
end;

procedure TSaturnCD.SetProtection(Value: Boolean);
begin
  FModelNext := 0;
  FIRQKnown := False;
  if Value = FProtection then
    Exit;

  FProtection := Value;
  FAuthenticated := 0;
  FAuthAt := -1;
  if FNative <> nil then
  begin
    FNative.Protection := Value;
    FNativeTime := 0;
    FNativePhase := 0;
  end;
end;

function TSaturnCD.GetFAD: Cardinal;
begin
  if FNative <> nil then
    Result := FNative.FAD
  else
    Result := FFAD;
end;

procedure TSaturnCD.Seek(Target: Cardinal; Playing: Boolean);
begin
  var Distance := Abs(Int64(Target) - Int64(FFAD));
  FSeekTarget := Target;
  FSeekPlay := Playing;
  if (Distance = 0) and (FSeekAt < 0) then
  begin
    FSeekAt := -1;
    FFAD := Target;
    FPlaying := Playing;
    FStatus := 1;
    if Playing then
      FStatus := 3;
    FSectorAt := FTime + FClock div 150;
    Exit;
  end;

  // Mechanism travel plus rotational settling; seek completion is independent
  // of command acknowledgement and sector I/O. This is a bounded travel model.
  var Span: Int64 := 333000;
  if FDisc <> nil then
    Span := Max(1, FDisc.LeadOut);
  var Micro := Min(500000, 40000 + Round(200000 * Sqrt(Min(1.0, Distance / Span))));
  FSeekAt := FTime + Int64(FClock) * Micro div 1000000;
  FFAD := Target;
  FPlaying := False;
  FStatus := 4;
  FAudioAt := 2352;
end;

procedure TSaturnCD.Reset(Clock: Integer);
begin
  FModelNext := 0;
  FIRQKnown := False;
  FNetlinkScratch := 0;
  FillChar(FNetlinkRegs, SizeOf(FNetlinkRegs), 0);
  FillChar(FNetlinkRX, SizeOf(FNetlinkRX), 0);
  FillChar(FNetlinkCommand, SizeOf(FNetlinkCommand), 0);
  FNetlinkRXAt := 0;
  FNetlinkRXCount := 0;
  FNetlinkCommandCount := 0;
  FNetlinkEcho := True;
  FNetlinkVerbose := True;
  FNetlinkQuiet := False;
  FNetlinkTXIRQ := False;
  UpdateNetlinkIRQ;
  FClock := Clock;
  FTime := 0;
  FCommandAt := Clock div 10;
  FReportAt := FCommandAt;
  FSectorAt := 0;
  FSeekAt := -1;
  FAuthAt := -1;
  FSectorFraction := 0;
  FSeekTarget := 150;
  FSeekPlay := False;
  FNativeTime := 0;
  FNativePhase := 0;
  if FNative <> nil then
    FNative.Reset;
  FCR[0] := $0043;
  FCR[1] := $4442;
  FCR[2] := $4C4F;
  FCR[3] := $434B;
  FillChar(FCommand, SizeOf(FCommand), 0);
  FPending := False;
  FResponse := False;
  FHIRQ := $FFF;
  FMask := $FFFF;
  FStatus := 6;
  if FDisc <> nil then
    FStatus := 1;
  FPlaying := False;
  FSingleSpeed := False;
  FFilePlay := False;
  FPowered := True;
  FAuthenticated := 0;
  FFAD := 150;
  FStart := 150;
  FEnd := 150;
  FSequence := 0;
  FCalculated := 0;
  FSearchFAD := 0;
  FSearchPosition := $FFFF;
  FSearchPartition := $FF;
  FRepeat := 0;
  FRepeatLimit := 0;
  FCopyError := 0;
  FGetSize := 2048;
  FPutSize := 2048;
  FConnection := $FF;
  FLast := $FF;
  FTransferKind := 0;
  FFIFO := nil;
  FFIFOAt := 0;
  FTransferred := 0;
  FTransferPartition := 0;
  FTransferStart := 0;
  FTransferCount := 0;
  FFiles := nil;
  FFileFirst := 2;
  FFileCount := 0;
  FDirectoryFAD := 0;
  FDirectoryBytes := 0;
  FAudioAt := 2352;
  FillChar(FAudio, SizeOf(FAudio), 0);
  ResetSelectors($D4, 0);
  UpdateIRQ;
end;

procedure TSaturnCD.SetClock(Clock: Integer);

  procedure Scale(var Deadline: Int64);
  begin
    if Deadline > FTime then
      Deadline := FTime + (Deadline - FTime) * Clock div FClock;
  end;

begin
  FModelNext := 0;
  FIRQKnown := False;
  Scale(FSeekAt);
  Scale(FAuthAt);
  Scale(FSectorAt);
  Scale(FCommandAt);
  Scale(FReportAt);
  FNativePhase := FNativePhase * Clock div FClock;
  FClock := Clock;
end;

procedure TSaturnCD.SetPower(Enabled: Boolean; At: Int64);
begin
  FModelNext := 0;
  FIRQKnown := False;
  if Enabled = FPowered then
    Exit;

  if Enabled then
  begin
    Reset(FClock);
    FTime := At;
    Inc(FCommandAt, At);
    Inc(FReportAt, At);
  end
  else
  begin
    FPowered := False;
    FPlaying := False;
    FPending := False;
    FAudioAt := 2352;
    FFIFO := nil;
    FFIFOAt := 0;
    FTransferKind := 0;
  end;
  UpdateIRQ;
end;

procedure TSaturnCD.UpdateIRQ;
begin
  var Active := FPowered and (FHIRQ and FMask <> 0);
  if not FIRQKnown or (Active <> FIRQLine) then
  begin
    FIRQKnown := True;
    FIRQLine := Active;
    if Assigned(FIRQ) then
      FIRQ(Active);
  end;
end;

procedure TSaturnCD.Report(Periodic: Boolean);
begin
  var Status := FStatus;
  if Periodic then
    Status := Status or $20;
  if Length(FFIFO) > FFIFOAt then
    Status := Status or $40;
  FCR[0] := Word(Status) shl 8;
  FCR[1] := $FFFF;
  FCR[2] := $FFFF;
  FCR[3] := $FFFF;
  if (FDisc = nil) or (FStatus in [6, 7]) then
    Exit;

  var T := FDisc.TrackAt(Integer(FFAD) - 150) + 1;
  if T < 1 then
    T := FDisc.TrackCount;
  var Track := FDisc.Track(T);
  var Control: Integer := $41;
  if Track.Audio then
    Control := 1
  else if FPlaying then
    FCR[0] := FCR[0] or $80;
  FCR[0] := FCR[0] or FRepeat;
  FCR[1] := (Control shl 8) or T;
  FCR[2] := (Cardinal(Max(0, FDisc.IndexAt(Integer(FFAD) - 150))) shl 8) or ((FFAD shr 16) and $FF);
  FCR[3] := FFAD and $FFFF;
end;

function TSaturnCD.FreeCount: Integer;
begin
  Result := 0;
  for var i := 0 to 199 do
    if not FSectors[i].Used then
      Inc(Result);
end;

function TSaturnCD.SectorCount(Partition: Integer): Integer;
begin
  Result := 0;
  for var i := 0 to 199 do
    if FSectors[i].Used and (Integer(FSectors[i].Partition) = Partition) then
      Inc(Result);
end;

function TSaturnCD.SectorIndex(Partition, Position: Integer): Integer;
begin
  Result := -1;
  var Previous: Int64 := -1;
  for var N := 0 to Position do
  begin
    Result := -1;
    var Best: Int64 := High(Int64);
    for var i := 0 to 199 do
      if FSectors[i].Used and (Integer(FSectors[i].Partition) = Partition) and
        (Int64(FSectors[i].Sequence) > Previous) and (Int64(FSectors[i].Sequence) < Best) then
      begin
        Result := i;
        Best := FSectors[i].Sequence;
      end;

    if Result < 0 then
      Exit;

    Previous := Best;
  end;
end;

procedure TSaturnCD.DeleteSectors(Partition, Position, Count: Integer);
begin
  for var N := 1 to Count do
  begin
    var i := SectorIndex(Partition, Position);
    if i < 0 then
      Break;

    FSectors[i].Used := False;
  end;
  if FreeCount > 0 then
    FHIRQ := FHIRQ and not 8;
end;

procedure TSaturnCD.ResetSelectors(Flags: Byte; Partition: Integer);
begin
  for var i := 0 to 23 do
  begin
    if Flags and $80 <> 0 then
      FFilters[i].No := $FF;
    if Flags and $40 <> 0 then
      FFilters[i].Yes := i;
    if Flags and $10 <> 0 then
    begin
      FFilters[i].Mode := 0;
      FFilters[i].Start := 0;
      FFilters[i].Count := $FFFFFF;
    end;
    if (Flags and 4 <> 0) or ((Flags = 0) and (i = Partition)) then
      DeleteSectors(i, 0, 200);
  end;
end;

function TSaturnCD.FilterDestination(const Raw: TBytes; SectorFAD: Cardinal; StartFilter: Integer): Integer;
begin
  Result := -1;
  var Filter: Integer := StartFilter;
  for var N := 0 to 23 do
  begin
    if Filter >= 24 then
      Exit;

    var F := FFilters[Filter];
    var Match: Boolean := True;
    var FileID, Channel, Submode, Coding: Byte;
    FileID := 0;
    Channel := 0;
    Submode := 0;
    Coding := 0;
    if Raw[15] = 2 then
    begin
      FileID := Raw[16];
      Channel := Raw[17];
      Submode := Raw[18];
      Coding := Raw[19];
    end;
    if F.Mode and $40 <> 0 then
      Match := (SectorFAD >= F.Start) and (Int64(SectorFAD) < Int64(F.Start) + F.Count);
    if F.Mode and 2 <> 0 then
      Match := Match and (Channel = F.Channel);
    if F.Mode and 1 <> 0 then
      Match := Match and (FileID = F.FileID);
    if F.Mode and 4 <> 0 then
      Match := Match and (Submode and F.SubMask = F.SubValue);
    if F.Mode and 8 <> 0 then
      Match := Match and (Coding and F.CodeMask = F.CodeValue);
    if F.Mode and $10 <> 0 then
      Match := not Match;
    if Match then
    begin
      if F.Yes < 24 then
        Result := F.Yes;
      Exit;
    end;

    Filter := F.No;
  end;
end;

procedure TSaturnCD.BeginTransfer(const Data: TBytes);
begin
  FFIFO := Copy(Data);
  FFIFOAt := 0;
  FTransferred := 0;
  FTransferKind := 0;
  FHIRQ := FHIRQ or 2;
end;

procedure TSaturnCD.SectorTransfer(Kind, Partition, Position, Count: Integer);
begin
  var Available := SectorCount(Partition);
  if Position = $FFFF then
    Position := Max(0, Available - 1);
  if Count = $FFFF then
    Count := Available - Position;
  if (Partition >= 24) or (Position < 0) or (Count <= 0) or (Position + Count > Available) then
  begin
    FCR[0] := $FF00;
    FHIRQ := FHIRQ or $80;
    Exit;
  end;

  if Kind = 2 then
  begin
    DeleteSectors(Partition, Position, Count);
    FHIRQ := FHIRQ or $80;
    Exit;
  end;

  SetLength(FFIFO, Count * FGetSize);
  FFIFOAt := 0;
  FTransferred := 0;
  for var N := 0 to Count - 1 do
  begin
    var i := SectorIndex(Partition, Position + N);
    var Offset := 2352 - FGetSize;
    if FGetSize = 2048 then
    begin
      Offset := 16;
      if FSectors[i].Data[15] = 2 then
        Offset := 24;
    end;
    Move(FSectors[i].Data[Offset], FFIFO[N * FGetSize], FGetSize);
  end;
  FTransferKind := Kind;
  FTransferPartition := Partition;
  FTransferStart := Position;
  FTransferCount := Count;
  FHIRQ := FHIRQ or $82;
end;

procedure TSaturnCD.EndTransfer;
begin
  if FTransferKind = 3 then
    DeleteSectors(FTransferPartition, FTransferStart, Min(FTransferCount, FTransferred div FGetSize));
  if FTransferKind = 4 then
    for var N := 0 to Min(FTransferCount, FTransferred div FPutSize) - 1 do
      for var i := 0 to 199 do
        if not FSectors[i].Used then
        begin
          FillChar(FSectors[i], SizeOf(TCDSector), 0);
          FSectors[i].Used := True;
          FSectors[i].Partition := FTransferPartition;
          Inc(FSequence);
          FSectors[i].Sequence := FSequence;
          FSectors[i].Data[15] := 1;
          var Offset := 2352 - FPutSize;
          if FPutSize = 2048 then
            Offset := 16;
          Move(FFIFO[N * FPutSize], FSectors[i].Data[Offset], FPutSize);
          Break;
        end;

  FCR[0] := (Word(FStatus) shl 8) or ((FTransferred div 2) shr 16);
  FCR[1] := (FTransferred div 2) and $FFFF;
  FCR[2] := 0;
  FCR[3] := 0;
  FFIFO := nil;
  FFIFOAt := 0;
  FTransferKind := 0;
  FHIRQ := (FHIRQ and not 2) or $80;
end;

function TSaturnCD.PositionFAD(Value: Cardinal; Ending: Boolean): Cardinal;
begin
  Result := 150;
  if Value and $800000 <> 0 then
  begin
    Result := Value and $7FFFFF;
    if Ending then
      Inc(Result, FStart);
    Exit;
  end;

  if FDisc = nil then
    Exit;

  var T: Integer := (Value shr 8) and $FF;
  if Ending then
  begin
    if (T = 0) or (T > FDisc.TrackCount) then
      Exit(FDisc.LeadOut + 150);

    Exit(FDisc.Track(T).EndLBA + 150);
  end;

  T := EnsureRange(T, 1, FDisc.TrackCount);
  Result := FDisc.Track(T).StartLBA + 150;
end;

procedure TSaturnCD.RootDirectory;
begin
  var B: TBytes;
  FDisc.ReadData(16, B);
  if (Length(B) < 2048) or (TEncoding.ASCII.GetString(B, 1, 5) <> 'CD001') then
    raise EReadError.Create('CD block: missing ISO9660 directory');

  ReadDirectory(LE32(B, 158) + 150, LE32(B, 166));
end;

procedure TSaturnCD.ReadDirectory(FAD, Bytes: Cardinal);
begin
  if (Bytes > 1024 * 1024) or (FAD < 150) or (Int64(FAD) + ((Bytes + 2047) div 2048) > FDisc.LeadOut + 150) then
    raise EReadError.Create('CD block: invalid directory extent');

  var Data: TBytes;
  SetLength(Data, ((Bytes + 2047) div 2048) * 2048);
  for var i := 0 to Length(Data) div 2048 - 1 do
  begin
    var B: TBytes;
    FDisc.ReadData(Integer(FAD) - 150 + i, B);
    Move(B[0], Data[i * 2048], 2048);
  end;
  FFiles := nil;
  var At: Integer := 0;
  while (At < Integer(Bytes)) and (Length(FFiles) < 32768) do
  begin
    var Count: Integer := Data[At];
    if Count = 0 then
    begin
      At := (At div 2048 + 1) * 2048;
      Continue;
    end;

    if (Count < 34) or (At + Count > Integer(Bytes)) then
      raise EReadError.Create('CD block: truncated directory record');

    var F: TCDFile;
    FillChar(F, SizeOf(F), 0); // directory records include padding in legacy raw snapshots
    F.FAD := LE32(Data, At + 2) + 150;
    F.Bytes := LE32(Data, At + 10);
    F.Flags := Data[At + 25] and 2;
    F.UnitSize := Data[At + 26];
    F.Gap := Data[At + 27];

    // CDC_FILE_FN is the XA subheader file number, not the directory index.
    // ISO9660 records without XA system-use information have file number 0.
    var SystemAt := 33 + (Integer(Data[At + 32]) or 1);
    if (SystemAt + 14 <= Count) and (Data[At + SystemAt + 6] = Ord('X')) and (Data[At + SystemAt + 7] = Ord('A')) then
    begin
      F.FileNumber := Data[At + SystemAt + 8];
      F.Flags := F.Flags or (Data[At + SystemAt + 4] and $F8);
    end;
    SetLength(FFiles, Length(FFiles) + 1);
    FFiles[High(FFiles)] := F;
    Inc(At, Count);
  end;
  FDirectoryFAD := FAD;
  FDirectoryBytes := Bytes;
  FFileFirst := 2;
  FFileCount := Min(254, Max(0, Length(FFiles) - 2));
end;

procedure TSaturnCD.Execute;
begin
  var C := FCommand;
  var Cmd: Integer := C[0] shr 8;
  var P: Integer := C[2] shr 8;
  var V: Cardinal := (Cardinal(C[2] and $FF) shl 16) or C[3];
  Report;
  FPending := False;
  FResponse := True;
  if (P >= 24) and (Cmd in [$40..$47, $51, $52, $54, $55, $61..$66, $70, $71, $74]) then
  begin
    FCR[0] := $FF00;
    FHIRQ := FHIRQ or 1;
    UpdateIRQ;
    Exit;
  end;

  if (FProtection and (FAuthenticated <> 4) and (Cmd in [$70..$74])) or ((Cmd in [$E0, $E1]) and (C[0] and $FF <> 0)) then
  begin
    FCR[0] := $FF00;
    FHIRQ := FHIRQ or $201;
    UpdateIRQ;
    Exit;
  end;

  try
    case Cmd of
      $00:
        ;
      $01:
        begin
          FCR[0] := Word(FStatus) shl 8;
          FCR[1] := $0002;
          FCR[2] := 0;
          FCR[3] := $FF00;
          FHIRQ := FHIRQ and not $20;
        end;
      $02:
        begin
          if FDisc = nil then
            FCR[0] := $FF00
          else
          begin
            var B: TBytes;
            SetLength(B, 408);
            FillChar(B[0], 408, $FF);
            for var T := 1 to FDisc.TrackCount do
            begin
              var Track := FDisc.Track(T);
              var Control: Cardinal := $41000000;
              if Track.Audio then
                Control := $01000000;
              BE32(B, (T - 1) * 4, Control or Cardinal(Track.StartLBA + 150));
            end;
            BE32(B, 396, (Cardinal(B[0]) shl 24) or $10000);
            BE32(B, 400, (Cardinal(B[(FDisc.TrackCount - 1) * 4]) shl 24) or (Cardinal(FDisc.TrackCount) shl 16));
            BE32(B, 404, (Cardinal(B[(FDisc.TrackCount - 1) * 4]) shl 24) or Cardinal(FDisc.LeadOut + 150));
            BeginTransfer(B);
            FCR[0] := Word(FStatus) shl 8;
            FCR[1] := 204;
            FCR[2] := 0;
            FCR[3] := 0;
          end;
        end;
      $03:
        begin
          FCR[0] := Word(FStatus) shl 8;
          FCR[1] := 0;
          FCR[2] := $0100;
          FCR[3] := 0;
          if (C[0] and $FF = 0) and (FDisc <> nil) then
          begin
            FCR[2] := $0100 or ((FDisc.LeadOut + 150) shr 16);
            FCR[3] := (FDisc.LeadOut + 150) and $FFFF;
          end;
        end;
      $04:
        begin
          FSeekAt := -1;
          FPlaying := False;
          FFAD := 150;
          FSingleSpeed := C[0] and $10 <> 0;
          if FDisc <> nil then
            FStatus := 1;
          if C[0] and 1 <> 0 then
          begin
            ResetSelectors($D4, 0);
            FFIFO := nil;
            FFIFOAt := 0;
          end;
          Report;
          FHIRQ := FHIRQ or $40;
        end;
      $05:
        begin
          FSeekAt := -1;
          FAuthAt := -1;
          FAuthenticated := 0;
          FPlaying := False;
          FStatus := 6;
          FAudioAt := 2352;
          Report;
          FHIRQ := FHIRQ or $20;
        end;
      $06:
        EndTransfer;
      $10:
        begin
          if FDisc = nil then
            FCR[0] := $FF00
          else
          begin
            var Start: Cardinal := (Cardinal(C[0] and $FF) shl 16) or C[1];
            if Start <> $FFFFFF then
              FStart := PositionFAD(Start, False);
            if V <> $FFFFFF then
              FEnd := PositionFAD(V, True);
            var Target := FFAD;
            if C[2] and $8000 = 0 then
              Target := FStart;
            if (C[2] shr 8) and $7F <> $7F then
              FRepeatLimit := (C[2] shr 8) and $7F;
            FRepeat := 0;
            FFilePlay := False;
            Seek(Target, True);
            Report;
          end;
        end;
      $11:
        begin
          FPlaying := False;
          FAudioAt := 2352;
          if FDisc <> nil then
          begin
            var Position: Cardinal := (Cardinal(C[0] and $FF) shl 16) or C[1];
            if Position = $FFFFFF then
            begin
              FSeekAt := -1;
              FStatus := 1;
            end
            else
              Seek(PositionFAD(Position, False), False);
          end
          else
            FSeekAt := -1;
          Report;
        end;
      $20:
        begin
          var B: TBytes;
          if FDisc <> nil then
            FDisc.ReadSubQ(Integer(FFAD) - 150, B);
          if Length(B) < 10 then
            SetLength(B, 10);
          SetLength(B, 10);
          BeginTransfer(B);
          FCR[0] := Word(FStatus) shl 8;
          FCR[1] := 5;
          FCR[2] := 0;
          FCR[3] := 0;
        end;
      $30:
        begin
          FConnection := P;
          FHIRQ := FHIRQ or $40;
        end;
      $31, $32:
        begin
          FCR[0] := Word(FStatus) shl 8;
          FCR[1] := 0;
          FCR[2] := Word(FConnection) shl 8;
          if Cmd = $32 then
            FCR[2] := Word(FLast) shl 8;
          FCR[3] := 0;
        end;
      $40:
        begin
          FFilters[P].Start := (Cardinal(C[0] and $FF) shl 16) or C[1];
          FFilters[P].Count := V;
          FHIRQ := FHIRQ or $40;
        end;
      $41:
        begin
          FCR[0] := (Word(FStatus) shl 8) or (FFilters[P].Start shr 16);
          FCR[1] := FFilters[P].Start and $FFFF;
          FCR[2] := FFilters[P].Count shr 16;
          FCR[3] := FFilters[P].Count and $FFFF;
        end;
      $42:
        begin
          FFilters[P].Channel := C[0] and $FF;
          FFilters[P].FileID := C[2] and $FF;
          FFilters[P].SubMask := C[1] shr 8;
          FFilters[P].CodeMask := C[1] and $FF;
          FFilters[P].SubValue := C[3] shr 8;
          FFilters[P].CodeValue := C[3] and $FF;
          FHIRQ := FHIRQ or $40;
        end;
      $43:
        begin
          FCR[0] := (Word(FStatus) shl 8) or FFilters[P].Channel;
          FCR[1] := (Word(FFilters[P].SubMask) shl 8) or FFilters[P].CodeMask;
          FCR[2] := FFilters[P].FileID;
          FCR[3] := (Word(FFilters[P].SubValue) shl 8) or FFilters[P].CodeValue;
        end;
      $44:
        begin
          FFilters[P].Mode := C[0] and $7F;
          if C[0] and $80 <> 0 then
          begin
            FFilters[P].Mode := 0;
            FFilters[P].Start := 0;
            FFilters[P].Count := $FFFFFF;
          end;
          FHIRQ := FHIRQ or $40;
        end;
      $45:
        begin
          FCR[0] := (Word(FStatus) shl 8) or FFilters[P].Mode;
          FCR[1] := 0;
          FCR[2] := 0;
          FCR[3] := 0;
        end;
      $46:
        begin
          if C[0] and 1 <> 0 then
            FFilters[P].Yes := C[1] shr 8;
          if C[0] and 2 <> 0 then
            FFilters[P].No := C[1] and $FF;
          FHIRQ := FHIRQ or $40;
        end;
      $47:
        begin
          FCR[0] := Word(FStatus) shl 8;
          FCR[1] := (Word(FFilters[P].Yes) shl 8) or FFilters[P].No;
          FCR[2] := 0;
          FCR[3] := 0;
        end;
      $48:
        begin
          ResetSelectors(C[0] and $FF, P);
          FHIRQ := FHIRQ or $40;
        end;
      $50:
        begin
          FCR[0] := Word(FStatus) shl 8;
          FCR[1] := FreeCount;
          FCR[2] := $1800;
          FCR[3] := 200;
        end;
      $51:
        begin
          FCR[0] := Word(FStatus) shl 8;
          FCR[1] := 0;
          FCR[2] := 0;
          FCR[3] := SectorCount(P);
        end;
      $52:
        begin
          FCalculated := Min(Integer(C[3]), SectorCount(P) - Min(Integer(C[1]), SectorCount(P))) * FGetSize div 2;
          FHIRQ := FHIRQ or $40;
        end;
      $53:
        begin
          FCR[0] := (Word(FStatus) shl 8) or (FCalculated shr 16);
          FCR[1] := FCalculated and $FFFF;
          FCR[2] := 0;
          FCR[3] := 0;
        end;
      $54:
        begin
          var i := SectorIndex(P, C[1]);
          if i < 0 then
            FCR[0] := $FF00
          else
          begin
            FCR[0] := (Word(FStatus) shl 8) or (FSectors[i].FAD shr 16);
            FCR[1] := FSectors[i].FAD and $FFFF;
            FCR[2] := (Word(FSectors[i].Data[16]) shl 8) or FSectors[i].Data[17];
            FCR[3] := (Word(FSectors[i].Data[18]) shl 8) or FSectors[i].Data[19];
          end;
          FHIRQ := FHIRQ or $40;
        end;
      $55:
        begin
          FSearchPosition := $FFFF;
          FSearchPartition := P;
          FSearchFAD := V;
          for var N := C[1] to SectorCount(P) - 1 do
          begin
            var i := SectorIndex(P, N);
            if (i >= 0) and (FSectors[i].FAD >= V) then
            begin
              FSearchPosition := N;
              FSearchFAD := FSectors[i].FAD;
              Break;
            end;
          end;
          FHIRQ := FHIRQ or $40;
        end;
      $56:
        begin
          FCR[0] := Word(FStatus) shl 8;
          FCR[1] := FSearchPosition;
          FCR[2] := (FSearchPartition shl 8) or (FSearchFAD shr 16);
          FCR[3] := FSearchFAD and $FFFF;
        end;
      $60:
        begin
          if C[0] and $FF < 4 then
            FGetSize := SectorSizes[C[0] and 3];
          if C[1] shr 8 < 4 then
            FPutSize := SectorSizes[C[1] shr 8];
          FHIRQ := FHIRQ or $40;
        end;
      $61..$63:
        SectorTransfer(Cmd - $60, P, C[1], C[3]);
      $64:
        begin
          if (C[3] = 0) or (C[3] > FreeCount) then
            FCR[0] := $FF00
          else
          begin
            SetLength(FFIFO, Integer(C[3]) * FPutSize);
            FFIFOAt := 0;
            FTransferred := 0;
            FTransferKind := 4;
            FTransferCount := C[3];
            FTransferPartition := P;
            FHIRQ := FHIRQ or 2;
          end;
        end;
      $65, $66:
        begin
          var Count: Integer := C[3];
          var Position: Integer := C[1];
          var Destination: Integer := C[0] and $FF;
          var Available := SectorCount(P);
          if Position = $FFFF then
            Position := Max(0, Available - 1);
          if Count = $FFFF then
            Count := Available - Position;
          FCopyError := 0;
          if (Destination >= 24) or (Count <= 0) or (Position + Count > Available) then
          begin
            FCR[0] := $FF00;
            FCopyError := 1;
          end
          else if (Cmd = $65) and (Count > FreeCount) then
          begin
            FCR[0] := Word(FStatus or $80) shl 8;
            FCopyError := 2;
          end
          else
          begin
            // Resolve the source list first: copied sectors may join the source
            // partition, and moving must not change subsequent positional IDs.
            var Indices: TArray<Integer>;
            SetLength(Indices, Count);
            for var N := 0 to Count - 1 do
              Indices[N] := SectorIndex(P, Position + N);
            for var i in Indices do
            begin
              var Raw: TBytes;
              SetLength(Raw, 2352);
              Move(FSectors[i].Data, Raw[0], 2352);
              var Dest := FilterDestination(Raw, FSectors[i].FAD, Destination);
              if Cmd = $66 then
              begin
                if Dest < 0 then
                  FSectors[i].Used := False
                else
                begin
                  FSectors[i].Partition := Dest;
                  Inc(FSequence);
                  FSectors[i].Sequence := FSequence;
                end;
              end
              else if Dest >= 0 then
                for var J := 0 to 199 do
                  if not FSectors[J].Used then
                  begin
                    FSectors[J] := FSectors[i];
                    FSectors[J].Partition := Dest;
                    Inc(FSequence);
                    FSectors[J].Sequence := FSequence;
                    Break;
                  end;
            end;
          end;
          FHIRQ := FHIRQ or $100;
        end;
      $67:
        begin
          FCR[0] := (Word(FStatus) shl 8) or FCopyError;
          FCR[1] := 0;
          FCR[2] := 0;
          FCR[3] := 0;
        end;
      $70:
        begin
          if FDisc = nil then
            FCR[0] := $FF00
          else if (V = $FFFFFF) or (Length(FFiles) = 0) then
            RootDirectory
          else if V < Cardinal(Length(FFiles)) then
          begin
            var F := FFiles[V];
            if F.Flags and 2 <> 0 then
              ReadDirectory(F.FAD, F.Bytes)
            else
              FCR[0] := $FF00;
          end
          else
            FCR[0] := $FF00;
          FHIRQ := FHIRQ or $200;
        end;
      $71:
        begin
          if FDisc = nil then
            FCR[0] := $FF00
          else
          begin
            if Length(FFiles) = 0 then
              RootDirectory;
            var First: Integer := V;
            if V = $FFFFFF then
              First := 2;
            if (First < 2) or (First >= Length(FFiles)) then
              FCR[0] := $FF00
            else
            begin
              FFileFirst := First;
              FFileCount := Min(254, Length(FFiles) - First);
            end;
          end;
          FHIRQ := FHIRQ or $200;
        end;
      $72:
        begin
          FCR[0] := Word(FStatus) shl 8;
          FCR[1] := FFileCount;
          FCR[2] := $100 or (FFileFirst shr 16);
          FCR[3] := FFileFirst and $FFFF;
          FHIRQ := FHIRQ or $200;
        end;
      $73:
        begin
          var B: TBytes;
          var First: Integer := V;
          var Count: Integer := 1;
          if V = $FFFFFF then
          begin
            First := FFileFirst;
            Count := 254;
          end;
          if (First < 0) or ((Count = 1) and (First >= Length(FFiles))) then
            FCR[0] := $FF00
          else
          begin
            SetLength(B, Count * 12);
            for var N := 0 to Count - 1 do
              if First + N < Length(FFiles) then
              begin
                var F := FFiles[First + N];
                BE32(B, N * 12, F.FAD);
                BE32(B, N * 12 + 4, F.Bytes);
                B[N * 12 + 8] := F.UnitSize;
                B[N * 12 + 9] := F.Gap;
                B[N * 12 + 10] := F.FileNumber;
                B[N * 12 + 11] := F.Flags;
              end;
            BeginTransfer(B);
            FCR[0] := Word(FStatus) shl 8;
            FCR[1] := Length(B) div 2;
            FCR[2] := 0;
            FCR[3] := 0;
          end;
        end;
      $74:
        begin
          if V >= Cardinal(Length(FFiles)) then
            FCR[0] := $FF00
          else
          begin
            var Offset: Cardinal := (Cardinal(C[0] and $FF) shl 16) or C[1];
            FStart := FFiles[V].FAD + Offset;
            FEnd := FFiles[V].FAD + (FFiles[V].Bytes + 2047) div 2048;
            FConnection := P;
            FFilePlay := True;
            FRepeatLimit := 0;
            Seek(FStart, True);
            Report;
          end;
        end;
      $75:
        begin
          FSeekAt := -1;
          FPlaying := False;
          FAudioAt := 2352;
          if FDisc <> nil then
            FStatus := 1;
          Report;
          FHIRQ := FHIRQ or $200;
        end;
      $E0:
        begin
          FAuthenticated := 0;
          FAuthAt := FTime + FClock div 10;
          FHIRQ := FHIRQ and not $200;
        end;
      $E1:
        begin
          FCR[0] := Word(FStatus) shl 8;
          FCR[1] := FAuthenticated;
          FCR[2] := 0;
          FCR[3] := 0;
        end;
    else
      FCR[0] := $FF00;
    end;
  except
    on E: EReadError do
    begin
      FCR[0] := $FF00;
      FHIRQ := FHIRQ or $200;
    end;
  end;
  FHIRQ := FHIRQ or 1;
  UpdateIRQ;
end;

procedure TSaturnCD.ReadSector;
begin
  if (FDisc = nil) or not FPlaying then
    Exit;

  if (FFAD >= FEnd) or (FFAD >= Cardinal(FDisc.LeadOut + 150)) then
  begin
    if (FRepeatLimit = $7F) or (FRepeat < FRepeatLimit) then
    begin
      FFAD := FStart;
      if FRepeat < 14 then
        Inc(FRepeat);
    end
    else
    begin
      FPlaying := False;
      FStatus := 1;
      FHIRQ := FHIRQ or $10;
      if FFilePlay then
        FHIRQ := FHIRQ or $200;
      Exit;
    end;
  end;

  if FDisc.IsData(Integer(FFAD) - 150) then
  begin
    if FProtection and (FAuthenticated <> 4) and (FFAD >= 166) then
    begin
      FPlaying := False;
      FStatus := 9;
      FHIRQ := FHIRQ or $10;
      Exit;
    end;

    if FreeCount = 0 then
    begin
      FHIRQ := FHIRQ or 8;
      Exit;
    end;

    var B: TBytes;
    FDisc.ReadRawData(Integer(FFAD) - 150, B);
    var P := FilterDestination(B, FFAD, FConnection);
    FLast := Byte(P and $FF);
    if P >= 0 then
      for var i := 0 to 199 do
        if not FSectors[i].Used then
        begin
          FSectors[i].Used := True;
          FSectors[i].Partition := P;
          FSectors[i].FAD := FFAD;
          Inc(FSequence);
          FSectors[i].Sequence := FSequence;
          Move(B[0], FSectors[i].Data, 2352);
          Break;
        end;

    FHIRQ := FHIRQ or 4;
  end
  else
  begin
    var B: TBytes;
    FDisc.ReadAudio(Integer(FFAD) - 150, B);
    Move(B[0], FAudio, 2352);
    FAudioAt := 0;
  end;
  Inc(FFAD);
  FHIRQ := FHIRQ or $400;
end;

procedure TSaturnCD.Advance(Target: Int64);
begin
  if Target < FTime then
    raise EArgumentException.Create('CD time');

  AdvanceForward(Target);
end;

procedure TSaturnCD.AdvanceForward(Target: Int64);
begin
  if FNativeEnabled then
    AdvanceNative(Target)
  else
  begin
    FTime := Target;
    if FPowered and (Target >= FModelNext) then
      AdvanceModel;
  end;
end;

procedure TSaturnCD.AdvanceNative(Target: Int64);
begin
  if FPowered then
  begin
    Inc(FNativePhase, (Target - FTime) * 20000000);
    Inc(FNativeTime, FNativePhase div FClock);
    FNativePhase := FNativePhase mod FClock;
    if FNativeTime > FNative.CPU.Time then
      FNative.Advance(FNativeTime);
  end;
  FTime := Target;
end;

procedure TSaturnCD.AdvanceModel;
begin
  var Target := FTime;
  if FPending and (Target >= FCommandAt) then
    Execute;
  if (FAuthAt >= 0) and (Target >= FAuthAt) then
  begin
    FAuthAt := -1;
    FAuthenticated := 0;
    if FDisc <> nil then
    begin
      FAuthenticated := 2;
      var B: TBytes;
      FDisc.ReadData(0, B);

      // Sector images carry no optical ring capture. Strict mode must not
      // mistake the IP header for proof of physical-disc authentication.
      if not FProtection and (Length(B) >= 16) and (TEncoding.ASCII.GetString(B, 0, 16) = 'SEGA SEGASATURN ') then
        FAuthenticated := 4;
    end;
    FHIRQ := FHIRQ or $204;
  end;
  if (FSeekAt >= 0) and (Target >= FSeekAt) then
  begin
    FFAD := FSeekTarget;
    FPlaying := FSeekPlay;
    FStatus := 1;
    if FPlaying then
      FStatus := 3;
    var Rate: Integer := 150;
    if FSingleSpeed or ((FDisc <> nil) and not FDisc.IsData(Integer(FFAD) - 150)) then
      Rate := 75;
    FSectorAt := FSeekAt + FClock div Rate;
    FSeekAt := -1;
    FSectorFraction := 0;
  end;
  while FPlaying and (Target >= FSectorAt) do
  begin
    ReadSector;
    var Rate := 150;
    if FSingleSpeed or ((FDisc <> nil) and not FDisc.IsData(Integer(FFAD) - 150)) then
      Rate := 75;
    Inc(FSectorFraction, FClock);
    Inc(FSectorAt, FSectorFraction div Rate);
    FSectorFraction := FSectorFraction mod Rate;
  end;
  if (Target >= FReportAt) and not FPending and not FResponse then
  begin
    Report(True);
    FHIRQ := FHIRQ or $400;
    FReportAt := Target + FClock div 60;
  end;
  UpdateIRQ;
  FModelNext := High(Int64);
  if FPending then
    FModelNext := Min(FModelNext, FCommandAt);
  if FAuthAt >= 0 then
    FModelNext := Min(FModelNext, FAuthAt);
  if FSeekAt >= 0 then
    FModelNext := Min(FModelNext, FSeekAt);
  if FPlaying then
    FModelNext := Min(FModelNext, FSectorAt);
  if not FPending and not FResponse then
    FModelNext := Min(FModelNext, FReportAt);
end;

// A bounded, synchronous offline modem stub: UART register readback, loopback,
// basic AT setup and explicit NO CARRIER on dial/answer. No sockets or remote I/O.
procedure TSaturnCD.UpdateNetlinkIRQ;
begin
  if Assigned(FNetlinkIRQ) then
    FNetlinkIRQ(FNetlinkPresent and (((FNetlinkRegs[0] and 1 <> 0) and (FNetlinkRXCount > 0)) or
      ((FNetlinkRegs[0] and 2 <> 0) and FNetlinkTXIRQ)));
end;

procedure TSaturnCD.SetNetlinkPresent(Value: Boolean);
begin
  FNetlinkPresent := Value;
  UpdateNetlinkIRQ;
end;

procedure TSaturnCD.NetlinkReceive(Value: Byte);
begin
  if FNetlinkRXCount >= Length(FNetlinkRX) then
    Exit;

  FNetlinkRX[(FNetlinkRXAt + FNetlinkRXCount) mod Length(FNetlinkRX)] := Value;
  Inc(FNetlinkRXCount);
end;

procedure TSaturnCD.NetlinkTransmit(Value: Byte);
begin
  if FNetlinkRegs[5] and $10 <> 0 then
    NetlinkReceive(Value)
  else if Value = 13 then
  begin
    var Command := '';
    for var i := 0 to FNetlinkCommandCount - 1 do
      Command := Command + Char(FNetlinkCommand[i]);
    Command := UpperCase(Trim(Command));
    var Echo := FNetlinkEcho;
    var Identification := False;
    var Reply := 'ERROR';
    var Numeric := '4';
    if Command.StartsWith('AT') then
    begin
      Reply := 'OK';
      Numeric := '0';
      if Command.StartsWith('ATD') or Command.StartsWith('ATA') then
      begin
        Reply := 'NO CARRIER';
        Numeric := '3';
      end;

      // Setup is accepted without creating a communications channel.
      if (Command = 'ATZ') or (Command = 'AT&F') then
      begin
        FNetlinkEcho := True;
        FNetlinkVerbose := True;
        FNetlinkQuiet := False;
      end;
      if Pos('E0', Command) > 0 then
        FNetlinkEcho := False;
      if Pos('E1', Command) > 0 then
        FNetlinkEcho := True;
      if Pos('V0', Command) > 0 then
        FNetlinkVerbose := False;
      if Pos('V1', Command) > 0 then
        FNetlinkVerbose := True;
      if Pos('Q0', Command) > 0 then
        FNetlinkQuiet := False;
      if Pos('Q1', Command) > 0 then
        FNetlinkQuiet := True;
      Identification := (Command = 'ATI') or (Command = 'ATI0');
    end;
    if Echo then
    begin
      for var i := 0 to FNetlinkCommandCount - 1 do
        NetlinkReceive(FNetlinkCommand[i]);
      NetlinkReceive(13);
    end;
    if Identification then
      for var Ch in #13#10'28800'#13#10 do
        NetlinkReceive(Ord(Ch));
    FNetlinkCommandCount := 0;
    FillChar(FNetlinkCommand, SizeOf(FNetlinkCommand), 0);
    if not FNetlinkQuiet then
    begin
      if FNetlinkVerbose then
        Reply := #13#10 + Reply + #13#10
      else
        Reply := Numeric + #13;
      for var Ch in Reply do
        NetlinkReceive(Ord(Ch));
    end;
  end
  else if Value = 8 then
  begin
    if FNetlinkCommandCount > 0 then
      Dec(FNetlinkCommandCount);
  end
  else if (Value >= 32) and (Value < 127) and (FNetlinkCommandCount < Length(FNetlinkCommand)) then
  begin
    FNetlinkCommand[FNetlinkCommandCount] := Value;
    Inc(FNetlinkCommandCount);
  end;
  FNetlinkTXIRQ := True;
  UpdateNetlinkIRQ;
end;

function TSaturnCD.NetlinkRead(Address: Cardinal): Byte;
begin
  if not FNetlinkPresent then
    Exit($FF);

  Result := 0;
  case Address of
    $95001:
      if FNetlinkRegs[4] and $80 <> 0 then
        Result := FNetlinkRegs[1]
      else if FNetlinkRXCount > 0 then
      begin
        Result := FNetlinkRX[FNetlinkRXAt];
        FNetlinkRX[FNetlinkRXAt] := 0;
        FNetlinkRXAt := (FNetlinkRXAt + 1) mod Length(FNetlinkRX);
        Dec(FNetlinkRXCount);
      end;
    $95005:
      if FNetlinkRegs[4] and $80 <> 0 then
        Result := FNetlinkRegs[2]
      else
        Result := FNetlinkRegs[0];
    $95009:
      begin
        Result := 1;
        if (FNetlinkRegs[0] and 1 <> 0) and (FNetlinkRXCount > 0) then
          Result := 4
        else if (FNetlinkRegs[0] and 2 <> 0) and FNetlinkTXIRQ then
        begin
          Result := 2;
          FNetlinkTXIRQ := False;
        end;
        if FNetlinkRegs[3] and 1 <> 0 then
          Result := Result or $C0;
      end;
    $9500D:
      Result := FNetlinkRegs[4];
    $95011:
      Result := FNetlinkRegs[5];
    $95015:
      Result := $60 or Ord(FNetlinkRXCount > 0);
    $95019:
      if FNetlinkRegs[5] and $10 <> 0 then
        Result := ((FNetlinkRegs[5] and 2) shl 3) or ((FNetlinkRegs[5] and 1) shl 5) or
          ((FNetlinkRegs[5] and 4) shl 4) or ((FNetlinkRegs[5] and 8) shl 4)
      else
        Result := $30;
    $9501D:
      Result := FNetlinkScratch;
  end;
  UpdateNetlinkIRQ;
end;

procedure TSaturnCD.NetlinkWrite(Address: Cardinal; Value: Byte);
begin
  if not FNetlinkPresent then
    Exit;

  case Address of
    $95001:
      if FNetlinkRegs[4] and $80 <> 0 then
        FNetlinkRegs[1] := Value
      else
        NetlinkTransmit(Value);
    $95005:
      if FNetlinkRegs[4] and $80 <> 0 then
        FNetlinkRegs[2] := Value
      else
      begin
        if (Value and 2 <> 0) and (FNetlinkRegs[0] and 2 = 0) then
          FNetlinkTXIRQ := True;
        FNetlinkRegs[0] := Value and $F;
      end;
    $95009:
      begin
        FNetlinkRegs[3] := Value and $C9;
        if Value and 2 <> 0 then
        begin
          FNetlinkRXAt := 0;
          FNetlinkRXCount := 0;
          FillChar(FNetlinkRX, SizeOf(FNetlinkRX), 0);
        end;
      end;
    $9500D:
      FNetlinkRegs[4] := Value;
    $95011:
      FNetlinkRegs[5] := Value and $1F;
    $9501D:
      FNetlinkScratch := Value;
  end;
  UpdateNetlinkIRQ;
end;

function TSaturnCD.Read(Address: Cardinal; Size: Integer): Cardinal;
begin
  FModelNext := 0;
  var A := Address and $FFFFF;
  Result := $FFFFFFFF;
  if Size = 1 then
    Result := $FF
  else if Size = 2 then
    Result := $FFFF;

  // Offline UART/AT compatibility is independent of the selected CD backend.
  if (Size = 1) and (A >= $95001) and (A <= $9501D) and (A and 3 = 1) then
    Exit(NetlinkRead(A));

  if not FPowered then
    Exit;

  if FNative <> nil then
    Exit(FNative.HostRead(Address, Size));

  if (A = $18000) or (A = $98000) then
  begin
    Result := 0;
    for var i := 1 to Size do
    begin
      Result := Result shl 8;
      if FFIFOAt < Length(FFIFO) then
      begin
        Result := Result or FFIFO[FFIFOAt];
        Inc(FFIFOAt);
        Inc(FTransferred);
      end
      else
        Result := Result or $FF;
    end;
    if FFIFOAt >= Length(FFIFO) then
      FHIRQ := FHIRQ and not 2;
    UpdateIRQ;
    Exit;
  end;

  var W: Word := $FFFF;
  case A and $FFFFC of
    $90008:
      W := FHIRQ;
    $9000C:
      W := FMask;
    $90018, $9001C, $90020, $90024:
      begin
        W := FCR[((A and $3C) - $18) div 4];
        if A and $3C = $24 then
          FResponse := False;
      end;
  end;
  case Size of
    1:
      if Odd(A) then
        Result := W and $FF
      else
        Result := W shr 8;
    2:
      Result := W;
    4:
      Result := (Cardinal(W) shl 16) or W;
  end;
end;

procedure TSaturnCD.Write(Address, Value: Cardinal; Size: Integer);
begin
  FModelNext := 0;
  var A := Address and $FFFFF;
  if (Size = 1) and (A >= $95001) and (A <= $9501D) and (A and 3 = 1) then
  begin
    NetlinkWrite(A, Value and $FF);
    Exit;
  end;

  if (Size = 1) and (A = $2503D) then
    Exit;

  if not FPowered then
    Exit;

  if FNative <> nil then
  begin
    FNative.HostWrite(Address, Value, Size);
    Exit;
  end;

  if (A = $18000) or (A = $98000) then
  begin
    if FTransferKind <> 4 then
      Exit;

    for var i := 0 to Size - 1 do
      if FFIFOAt < Length(FFIFO) then
      begin
        FFIFO[FFIFOAt] := (Value shr ((Size - i - 1) * 8)) and $FF;
        Inc(FFIFOAt);
        Inc(FTransferred);
      end;
    Exit;
  end;

  if Size = 4 then
    Value := Value shr 16;
  case A and $FFFFC of
    $90008:
      FHIRQ := FHIRQ and Word(Value);
    $9000C:
      FMask := Value and $3FFF;
    $90018, $9001C, $90020, $90024:
      begin
        var i := ((A and $3C) - $18) div 4;
        FCommand[i] := Value and $FFFF;
        if i = 0 then
          FResponse := True;
        if i = 3 then
        begin
          FPending := True;
          FCommandAt := FTime + 128;
          FHIRQ := FHIRQ and not 1;
        end;
      end;
  end;
  UpdateIRQ;
end;

procedure TSaturnCD.AudioSample(out Left, Right: Integer);
begin
  FModelNext := 0;
  if FNative <> nil then
  begin
    FNative.AudioSample(Left, Right);
    Exit;
  end;

  Left := 0;
  Right := 0;
  if FAudioAt >= 2352 then
    Exit;

  Left := SmallInt(Word(FAudio[FAudioAt]) or (Word(FAudio[FAudioAt + 1]) shl 8));
  Right := SmallInt(Word(FAudio[FAudioAt + 2]) or (Word(FAudio[FAudioAt + 3]) shl 8));
  Inc(FAudioAt, 4);
end;

procedure TSaturnCD.SerializeState(Archive: TStateArchive; Extended, Modem, ModemPresence: Boolean);
begin
  if Archive.Loading then
  begin
    FModelNext := 0;
    FIRQKnown := False;
  end;
  if Extended then
    Archive.Field(FNetlinkScratch, SizeOf(FNetlinkScratch))
  else if Archive.Loading then
    FNetlinkScratch := 0;
  if Modem then
  begin
    Archive.Field(FNetlinkRegs, SizeOf(FNetlinkRegs));
    Archive.Field(FNetlinkRX, SizeOf(FNetlinkRX));
    Archive.Field(FNetlinkCommand, SizeOf(FNetlinkCommand));
    Archive.Field(FNetlinkRXAt, SizeOf(FNetlinkRXAt));
    Archive.Field(FNetlinkRXCount, SizeOf(FNetlinkRXCount));
    Archive.Field(FNetlinkCommandCount, SizeOf(FNetlinkCommandCount));
    Archive.Field(FNetlinkEcho, SizeOf(FNetlinkEcho));
    Archive.Field(FNetlinkVerbose, SizeOf(FNetlinkVerbose));
    Archive.Field(FNetlinkQuiet, SizeOf(FNetlinkQuiet));
    Archive.Field(FNetlinkTXIRQ, SizeOf(FNetlinkTXIRQ));
    if (FNetlinkRXAt < 0) or (FNetlinkRXAt >= Length(FNetlinkRX)) or
      (FNetlinkRXCount < 0) or (FNetlinkRXCount > Length(FNetlinkRX)) or
      (FNetlinkCommandCount < 0) or (FNetlinkCommandCount > Length(FNetlinkCommand)) then
      raise EReadError.Create('Invalid offline NetLink state');
  end
  else if Archive.Loading then
  begin
    FillChar(FNetlinkRegs, SizeOf(FNetlinkRegs), 0);
    FillChar(FNetlinkRX, SizeOf(FNetlinkRX), 0);
    FillChar(FNetlinkCommand, SizeOf(FNetlinkCommand), 0);
    FNetlinkRXAt := 0;
    FNetlinkRXCount := 0;
    FNetlinkCommandCount := 0;
    FNetlinkEcho := True;
    FNetlinkVerbose := True;
    FNetlinkQuiet := False;
    FNetlinkTXIRQ := False;
  end;
  if ModemPresence then
    Archive.Field(FNetlinkPresent, SizeOf(FNetlinkPresent))
  else if Archive.Loading then
    FNetlinkPresent := Modem;
  var Native := FNative <> nil;
  Archive.Field(Native, SizeOf(Native));
  if Native <> (FNative <> nil) then
    raise EReadError.Create('Saturn CD backend mismatch');

  Archive.Field(FNativeTime, SizeOf(FNativeTime));
  Archive.Field(FNativePhase, SizeOf(FNativePhase));
  if FNative <> nil then
    FNative.SerializeState(Archive);
  var Protection := FProtection;
  Archive.Field(Protection, SizeOf(Protection));
  if Protection <> FProtection then
    raise EReadError.Create('Saturn optical protection setting mismatch');

  Archive.Field(FSeekAt, SizeOf(FSeekAt));
  Archive.Field(FAuthAt, SizeOf(FAuthAt));
  Archive.Field(FSectorFraction, SizeOf(FSectorFraction));
  Archive.Field(FSeekTarget, SizeOf(FSeekTarget));
  Archive.Field(FSeekPlay, SizeOf(FSeekPlay));
  Archive.Field(FClock, SizeOf(FClock));
  Archive.Field(FTime, SizeOf(FTime));
  Archive.Field(FCommandAt, SizeOf(FCommandAt));
  Archive.Field(FReportAt, SizeOf(FReportAt));
  Archive.Field(FSectorAt, SizeOf(FSectorAt));
  Archive.Field(FCR, SizeOf(FCR));
  Archive.Field(FCommand, SizeOf(FCommand));
  Archive.Field(FHIRQ, SizeOf(FHIRQ));
  Archive.Field(FMask, SizeOf(FMask));
  Archive.Field(FPending, SizeOf(FPending));
  Archive.Field(FResponse, SizeOf(FResponse));
  Archive.Field(FPlaying, SizeOf(FPlaying));
  Archive.Field(FSingleSpeed, SizeOf(FSingleSpeed));
  Archive.Field(FFilePlay, SizeOf(FFilePlay));
  Archive.Field(FPowered, SizeOf(FPowered));
  Archive.Field(FStatus, SizeOf(FStatus));
  Archive.Field(FConnection, SizeOf(FConnection));
  Archive.Field(FLast, SizeOf(FLast));
  Archive.Field(FAuthenticated, SizeOf(FAuthenticated));
  Archive.Field(FRepeat, SizeOf(FRepeat));
  Archive.Field(FRepeatLimit, SizeOf(FRepeatLimit));
  Archive.Field(FCopyError, SizeOf(FCopyError));
  Archive.Field(FFAD, SizeOf(FFAD));
  Archive.Field(FStart, SizeOf(FStart));
  Archive.Field(FEnd, SizeOf(FEnd));
  Archive.Field(FSequence, SizeOf(FSequence));
  Archive.Field(FCalculated, SizeOf(FCalculated));
  Archive.Field(FSearchFAD, SizeOf(FSearchFAD));
  Archive.Field(FSearchPosition, SizeOf(FSearchPosition));
  Archive.Field(FSearchPartition, SizeOf(FSearchPartition));
  Archive.Field(FGetSize, SizeOf(FGetSize));
  Archive.Field(FPutSize, SizeOf(FPutSize));
  Archive.Field(FFilters, SizeOf(FFilters));
  Archive.Field(FSectors, SizeOf(FSectors));
  var Count := Length(FFIFO);
  Archive.Field(Count, SizeOf(Count));
  if (Count < 0) or (Count > 470400) then
    raise EReadError.Create('CD transfer state size');

  SetLength(FFIFO, Count);
  if Count > 0 then
    Archive.Field(FFIFO[0], Count);
  Archive.Field(FFIFOAt, SizeOf(FFIFOAt));
  Archive.Field(FTransferred, SizeOf(FTransferred));
  Archive.Field(FTransferKind, SizeOf(FTransferKind));
  Archive.Field(FTransferPartition, SizeOf(FTransferPartition));
  Archive.Field(FTransferStart, SizeOf(FTransferStart));
  Archive.Field(FTransferCount, SizeOf(FTransferCount));
  Count := Length(FFiles);
  Archive.Field(Count, SizeOf(Count));
  if (Count < 0) or (Count > 32768) then
    raise EReadError.Create('CD filesystem state size');

  SetLength(FFiles, Count);
  if Count > 0 then
    Archive.Field(FFiles[0], Count * SizeOf(TCDFile));
  if Archive.Loading and not ModemPresence then
    for var i := 0 to Count - 1 do
      FFiles[i].FileNumber := 0;
  Archive.Field(FFileFirst, SizeOf(FFileFirst));
  Archive.Field(FFileCount, SizeOf(FFileCount));
  Archive.Field(FDirectoryFAD, SizeOf(FDirectoryFAD));
  Archive.Field(FDirectoryBytes, SizeOf(FDirectoryBytes));
  Archive.Field(FAudio, SizeOf(FAudio));
  Archive.Field(FAudioAt, SizeOf(FAudioAt));
  if (FFIFOAt < 0) or (FFIFOAt > Length(FFIFO)) or (FTransferred < 0) or (FTransferred > 470400) or (FAudioAt < 0) or (FAudioAt > 2352) or (FTransferPartition < 0) or (FTransferPartition > 23) or (FTime < 0) or (FClock < 20000000) or (FClock > 30000000) or ((FGetSize <> 2048) and (FGetSize <> 2336) and (FGetSize <> 2340) and (FGetSize <> 2352)) or ((FPutSize <> 2048) and (FPutSize <> 2336) and (FPutSize <> 2340) and (FPutSize <> 2352)) or (FTransferKind < 0) or (FTransferKind > 4) or (FTransferCount < 0) or (FTransferCount > 200) or (FTransferStart < 0) or (FTransferStart > 200) or (FStatus > 10) then
    raise EReadError.Create('Invalid CD block state');
end;

end.

