unit NeoGeoCD.Controller;

interface

uses
  System.SysUtils, System.Classes, Core.Snapshots, Core.CD.Disc;

const
  NGCD_MASTER_CLOCK = 24168000;
  // Rounded nominal 64.64 Hz period used by NeoCD's timer.h. The hardware
  // protocol documentation says approximately 64 Hz; no calibrated capture
  // or oscillator tolerance is available. This is not a measured servo delay.
  NGCD_COMMUNICATION_PERIOD = 373886;

type
  TCDControllerState = record
    IRQMask1, IRQMask2: Word;
    DecoderIRQ, CommunicationIRQ, CommunicationEnabled, Z80Enabled: Boolean;
    WatchdogDisabled, SprDisabled, FixDisabled, VideoEnabled: Boolean;
    Area, BusRequest, SprBank, PCMBank: Byte;
    DMAConfig: array[0..8] of Word;
    DMASource, DMADestination, DMALength: Cardinal;
    DMAPattern: Word;
    RegisterPointer, CommandPointer, ResponsePointer, Strobe, Status: Byte;
    Command, Response: array[0..9] of Byte;
    Registers: array[0..15] of Byte;
    IFStat, DecoderStat0: Byte;
    Header: array[0..3] of Byte;
    Sector: array[0..2047] of Byte;
    LBA, SampleOffset: Integer;
    Playing: Boolean;
    NextTick: Int64;
    Clock, NextCommunication, NextSector, PendingDeadline: Int64;
    PendingAction: Byte;
    TrayOpen, DiscPresent: Boolean;
    ScanDirection: ShortInt;
    DMABusy: Boolean;
    NextDMA: Int64;
    LastLeft, LastRight: SmallInt;
  end;

  TNeoGeoCDController = class
  private
    FDisc: TCDDisc;
    FCDZ: Boolean;
    FRecognitionMode: Byte;
    FMediaInitialized: Boolean;
    FRegion: Byte;
    FAudio: TBytes;
    FAudioLBA: Integer;
    procedure Command;
    procedure ResponseTime(LBA: Integer);
    procedure Checksum;
    procedure NextRegister;
    function ReadRegister: Byte;
    procedure WriteRegister(Value: Byte);
    function SectorPeriod: Int64;
    procedure UpdateDeadline;
    procedure DecoderTick;
  public
    State: TCDControllerState;
    constructor Create(Disc: TCDDisc; CDZ: Boolean = False; Region: Byte = 2);
    procedure SetDiscPresent(Present: Boolean);
    procedure SetTrayOpen(Open: Boolean);
    procedure Reset;
    procedure Advance(Time: Int64);
    function ReadWord(Address: Cardinal; HighByte, LowByte: Boolean): Word;
    // Returns True for a DMA start; bus writes are performed by the console.
    function WriteWord(Address: Cardinal; Value: Word; HighByte, LowByte: Boolean): Boolean;
    procedure EndTransfer;
    procedure Mix(var Left, Right: SmallInt);
    function InterruptVector: Integer;
    procedure SerializeState(Archive: TStateArchive);
  end;

implementation

uses
  System.Math;

function BCD(Value: Integer): Byte;
begin
  Result := ((Value div 10) shl 4) or (Value mod 10);
end;

function ReverseBits(Value: Word): Word;
begin
  Result := 0;
  for var i := 0 to 15 do
    Result := (Result shl 1) or ((Value shr i) and 1);
end;

constructor TNeoGeoCDController.Create(Disc: TCDDisc; CDZ: Boolean; Region: Byte);
begin
  inherited Create;
  FDisc := Disc;
  FCDZ := CDZ;
  FRegion := Region and 3;
  FRecognitionMode := 2;
  if FCDZ then
  begin
    // Ordinary images omit the pressed disc's recognition information.
    // CPY.TXT retains the mode that the CDZ BIOS compares to TOC subcommand
    // 7 (BIOS $C0BD66 -> $10F786, comparison at $C0D27A). Export discs use
    // 2; e.g. Ninja Master's and Twinkle Star Sprites require F. Derive it
    // from the disc rather than modifying the BIOS or protection program.
    var Protection := FDisc.ReadISOFile('CPY.TXT');
    for var i := 2 to Length(Protection) - 10 do
      if CompareMem(@Protection[i], PAnsiChar(AnsiString('NEO-GEO'#0)), 8) and
        ((Protection[i + 8] and 1) <> 0) and
        ((Protection[i + 8] and $F8) = 0) then
      begin
        var Mode := Protection[i + 9];
        if (Mode = 2) or (Mode = 5) or (Mode = $E) or (Mode = $F) then
          FRecognitionMode := Mode;
        Break;
      end;
  end;
  Reset;
end;

procedure TNeoGeoCDController.Reset;
begin
  var Present := not FMediaInitialized or State.DiscPresent;
  var Tray := FMediaInitialized and State.TrayOpen;
  FMediaInitialized := True;
  State := Default(TCDControllerState);
  State.ResponsePointer := 9;
  State.Strobe := 1;
  State.IFStat := $FF;
  State.Registers[8] := $30;
  State.Registers[9] := $09;
  State.NextTick := NGCD_COMMUNICATION_PERIOD;
  State.NextCommunication := State.NextTick;
  State.NextSector := State.NextTick;
  State.DiscPresent := Present;
  State.TrayOpen := Tray;
  if not Present then
    State.Status := 11;
  if Tray then
    State.Status := 5;
  State.Header[1] := 2;
  State.Header[3] := 1;
  FAudioLBA := -1;
  Checksum;
end;

procedure TNeoGeoCDController.Checksum;
begin
  var Sum := 5;
  for var i := 0 to 8 do
    Inc(Sum, State.Response[i]);
  State.Response[9] := (not Sum) and 15;
end;

procedure TNeoGeoCDController.ResponseTime(LBA: Integer);
begin
  LBA := Max(0, LBA);
  State.Response[2] := (LBA div 4500) div 10;
  State.Response[3] := (LBA div 4500) mod 10;
  State.Response[4] := ((LBA div 75) mod 60) div 10;
  State.Response[5] := ((LBA div 75) mod 60) mod 10;
  State.Response[6] := (LBA mod 75) div 10;
  State.Response[7] := (LBA mod 75) mod 10;
end;

procedure TNeoGeoCDController.Command;
begin
  var Sum := 5;
  for var i := 0 to 8 do
    Inc(Sum, State.Command[i]);

  if State.Command[9] <> ((not Sum) and 15) then
  begin
    FillChar(State.Response, SizeOf(State.Response), 0);
    State.Response[0] := State.Status;
    Checksum;
    Exit;
  end;

  var Op := State.Command[0] * 16 + State.Command[1];
  if (Op <> 0) and (Op <> $C0) and (Op <> $D0) and (Op <> $10) and
    (State.TrayOpen or not State.DiscPresent) then
  begin
    FillChar(State.Response, SizeOf(State.Response), 0);
    State.Status := 11;
    if State.TrayOpen then
      State.Status := 5;
    State.Response[0] := State.Status;
    Checksum;
    Exit;
  end;

  var TrackIndex := FDisc.TrackAt(State.LBA);
  var TrackNumber := Max(1, TrackIndex + 1);
  var Q: TBytes;
  var StoredQ := FDisc.ReadSubQ(State.LBA, Q);
  if StoredQ then
    TrackNumber := (Q[1] shr 4) * 10 + (Q[1] and 15);
  if (TrackNumber < 1) or (TrackNumber > FDisc.TrackCount) or (State.LBA >= FDisc.LeadOut) then
    TrackNumber := FDisc.TrackCount;
  var DataFlag := 0;
  if FDisc.IsData(State.LBA) then
    DataFlag := 4;
  if StoredQ then
    DataFlag := (Q[0] shr 4) and 4;
  if Op <> 0 then
    FillChar(State.Response, SizeOf(State.Response), 0);

  case Op of
    $00:
      State.Response[0] := State.Status;
    $10:
      begin
        State.Playing := False;
        State.ScanDirection := 0;
        State.PendingAction := 0;
        State.Status := 0;
        if not State.DiscPresent then
          State.Status := 11;
        if State.TrayOpen then
          State.Status := 5;
      end;
    $20:
      begin
        if State.Status = 0 then
          State.Status := 9;
        var Sub := State.Command[3];
        State.Response[1] := Sub;
        case Sub of
          0, 1:
            begin
              var Position := State.LBA + 150;
              if Sub = 1 then
              begin
                var Item := FDisc.Track(TrackNumber);
                Position := State.LBA - Item.StartLBA;
                if Position < 0 then
                  Position := -Position - 1;
              end;
              if StoredQ then
                if Sub = 0 then
                  Position := ((Q[7] shr 4) * 10 + (Q[7] and 15)) * 4500 +
                    ((Q[8] shr 4) * 10 + (Q[8] and 15)) * 75 + (Q[9] shr 4) * 10 + (Q[9] and 15)
                else
                  Position := ((Q[3] shr 4) * 10 + (Q[3] and 15)) * 4500 +
                    ((Q[4] shr 4) * 10 + (Q[4] and 15)) * 75 + (Q[5] shr 4) * 10 + (Q[5] and 15);
              ResponseTime(Position);
              State.Response[8] := DataFlag;
            end;
          2:
            begin
              State.Response[2] := TrackNumber div 10;
              State.Response[3] := TrackNumber mod 10;
              var Index := FDisc.IndexAt(State.LBA);
              if StoredQ then
                Index := (Q[2] shr 4) * 10 + (Q[2] and 15);

              // Pressed discs expose protection indexes in the data track.
              // CDZ BIOS checks one new index every four MSF seconds; plain
              // ISO/CUE/CHD images usually retain only INDEX 01.
              if not StoredQ and not FDisc.HasIndexes(State.LBA) and
                (TrackNumber = 1) and FDisc.IsData(State.LBA) then
              begin
                var MSF := State.LBA + 150;
                Index := Min(99, Max(0, ((MSF div 4500) * 100 + (MSF div 75) mod 60 - 2)) div 4 + 1);
              end;
              State.Response[4] := Index div 10;
              State.Response[5] := Index mod 10;
              State.Response[8] := DataFlag;
            end;
          3:
            ResponseTime(FDisc.LeadOut + 150);
          4:
            begin
              State.Response[3] := 1;
              State.Response[4] := FDisc.TrackCount div 10;
              State.Response[5] := FDisc.TrackCount mod 10;
            end;
          5:
            begin
              var N := State.Command[4] * 10 + State.Command[5];
              if (N >= 1) and (N <= FDisc.TrackCount) then
              begin
                var Item := FDisc.Track(N);
                ResponseTime(Item.StartLBA + 150);
                if not Item.Audio then
                  State.Response[6] := State.Response[6] or 8;
                State.Response[8] := State.Command[5];
              end;
            end;
          6:
            begin
              if State.LBA >= FDisc.LeadOut then
                State.Status := 12;
              State.Response[8] := DataFlag;
            end;
          7:
            State.Response[3] := FRecognitionMode;
        end;
      end;
    $30, $40, $B0:
      begin
        var Position := 0;
        if Op <> $B0 then
          Position := ((State.Command[2] * 10 + State.Command[3]) * 60 +
            State.Command[4] * 10 + State.Command[5]) * 75 +
            State.Command[6] * 10 + State.Command[7] - 150
        else
        begin
          var N := State.Command[2] * 10 + State.Command[3];
          if (N >= 1) and (N <= FDisc.TrackCount) then
            Position := FDisc.Track(N).StartLBA;
        end;
        State.LBA := EnsureRange(Position, 0, 449849);
        State.SampleOffset := 0;
        FAudioLBA := -1;

        // SEEK uses the same absolute MSF as PLAY, but leaves the pickup
        // paused at the new position. RESUME must start there, not at the
        // previous audio sector. The response reports seeking once; the
        // next STATUS observes the completed, paused seek. Completing at the
        // next exchange is an HLE approximation, independent of seek distance;
        // it does not model sled travel, focus, spindle lock or rotation phase.
        // https://wiki.neogeodev.org/index.php/CD_drive_commands
        State.Playing := Op <> $40;
        State.ScanDirection := 0;
        State.PendingAction := 0;
        State.NextSector := State.Clock + SectorPeriod;
        if Op = $40 then
        begin
          State.Status := 2;
          State.PendingAction := 4;
          State.PendingDeadline := State.NextCommunication;
        end
        else
        begin
          State.Status := 1;
          State.Response[1] := 2;
          State.Response[2] := (FDisc.TrackAt(State.LBA) + 1) div 10;
          State.Response[3] := (FDisc.TrackAt(State.LBA) + 1) mod 10;
        end;
      end;
    $60:
      begin
        State.Playing := False;
        State.PendingAction := 0;
        State.ScanDirection := 0;
        State.Status := 4;
      end;
    $70:
      begin
        State.Playing := True;
        State.PendingAction := 0;
        State.ScanDirection := 0;
        State.NextSector := State.Clock + SectorPeriod;
        State.Status := 1;
      end;
    $80, $90:
      begin
        State.ScanDirection := 1;
        if Op = $90 then
          State.ScanDirection := -1;
        State.SampleOffset := 0;
        FAudioLBA := -1;
        State.Playing := True;
        State.Status := 3;
        State.NextSector := State.Clock + NGCD_MASTER_CLOCK div 75;
      end;
    $A0, $C0, $D0:
      begin
        State.Playing := False;
        State.ScanDirection := 0;
        State.SampleOffset := 0;
        FAudioLBA := -1;
        State.PendingAction := Op shr 4;

        // Logical completion only: physical TOC/tray latency is uncalibrated.
        State.PendingDeadline := State.NextCommunication;
        State.Status := 14;
        if Op = $A0 then
          State.Status := 9;
      end;
    $50:
      ; // CDZ acknowledgement; no mechanical operation.
  else
    begin
      State.Response[0] := 7;
      Checksum;
      Exit;
    end;
  end;

  State.Response[0] := State.Status;
  if Op = $40 then
    State.Response[0] := 2;
  if (Op = $80) or (Op = $90) then
    State.Response[0] := 3;
  Checksum;
  UpdateDeadline;
end;

procedure TNeoGeoCDController.NextRegister;
begin
  if State.RegisterPointer <> 0 then
    State.RegisterPointer := (State.RegisterPointer + 1) and 15;
end;

function TNeoGeoCDController.ReadRegister: Byte;
begin
  var N := State.RegisterPointer and 15;
  Result := 0;
  case N of
    1:
      Result := State.IFStat;
    2, 3:
      Result := State.Registers[N];
    4..7:
      if (State.Registers[11] and 1) = 0 then
        Result := State.Header[N - 4];
    8, 9:
      Result := State.Registers[N + 4];
    10, 11:
      Result := State.Registers[N - 2];
    12:
      Result := State.DecoderStat0;
    14:
      if (State.Registers[10] and $10) <> 0 then
        Result := State.Registers[11] and 8
      else
        Result := State.Registers[11] and $0C;
    15:
      State.IFStat := State.IFStat and $DF;
  end;
  NextRegister;
end;

procedure TNeoGeoCDController.WriteRegister(Value: Byte);
begin
  var N := State.RegisterPointer and 15;
  if N = 15 then
  begin
    // Software reset of the sector decoder leaves the external drive and
    // its sector RAM in place, and cancels decoder interrupt/transfer flags.
    FillChar(State.Registers, SizeOf(State.Registers), 0);
    State.Registers[8] := $30;
    State.Registers[9] := $09;
    State.IFStat := $FF;
    State.DecoderStat0 := 0;
    State.DecoderIRQ := False;
    NextRegister;
    Exit;
  end;

  State.Registers[N] := Value;
  if (N = 6) and ((State.Registers[1] and 2) <> 0) then
    State.IFStat := State.IFStat and $F7;
  if N = 7 then
    State.IFStat := State.IFStat or $40;
  NextRegister;
end;

function TNeoGeoCDController.SectorPeriod: Int64;
begin
  Result := NGCD_MASTER_CLOCK div 75;
  if FCDZ and FDisc.IsData(State.LBA) and (State.ScanDirection = 0) then
    Result := Result div 2;
end;

procedure TNeoGeoCDController.UpdateDeadline;
begin
  State.NextTick := State.NextCommunication;
  if State.Playing then
    State.NextTick := Min(State.NextTick, State.NextSector);
  if State.PendingAction <> 0 then
    State.NextTick := Min(State.NextTick, State.PendingDeadline);
end;

procedure TNeoGeoCDController.SetDiscPresent(Present: Boolean);
begin
  State.DiscPresent := Present;
  if not Present then
  begin
    State.Playing := False;
    State.PendingAction := 0;
    State.Status := 11;
    State.SampleOffset := 0;
    FAudioLBA := -1;
  end;
  UpdateDeadline;
end;

procedure TNeoGeoCDController.SetTrayOpen(Open: Boolean);
begin
  State.Playing := False;
  State.ScanDirection := 0;
  State.SampleOffset := 0;
  FAudioLBA := -1;
  State.PendingAction := 12;
  if Open then
    State.PendingAction := 13;
  State.PendingDeadline := State.NextCommunication;
  State.Status := 14;
  UpdateDeadline;
end;

procedure TNeoGeoCDController.DecoderTick;
begin
  if State.ScanDirection <> 0 then
  begin
    State.LBA := EnsureRange(State.LBA + 30 * State.ScanDirection, 0, FDisc.LeadOut);
    if (State.LBA = 0) or (State.LBA = FDisc.LeadOut) then
    begin
      State.Playing := False;
      State.Status := 12;
    end;
    Exit;
  end;

  // The decoder also reports headers while scanning audio / lead-out.
  // CDZ BIOS probes beyond lead-out during disc recognition.
  var DecoderPending := (State.IFStat and $20) = 0;
  if (State.Registers[10] and $80) <> 0 then
  begin
    var Position := State.LBA + 150;
    State.Header[0] := BCD(Position div 4500);
    State.Header[1] := BCD((Position div 75) mod 60);
    State.Header[2] := BCD(Position mod 75);
    if FDisc.IsData(State.LBA) then
    begin
      var Sector: TBytes;
      FDisc.ReadRawData(State.LBA, Sector);
      var ValidSector := CDCorrectMode1(Sector);
      Move(Sector[12], State.Header[0], 4);
      Move(Sector[16], State.Sector[0], 2048);
      var WA := (Integer(State.Registers[8]) + Integer(State.Registers[9]) * 256 + 2352) and $FFFF;
      var PT := (Integer(State.Registers[12]) + Integer(State.Registers[13]) * 256 + 2352) and $FFFF;
      State.Registers[8] := WA and $FF;
      State.Registers[9] := WA shr 8;
      State.Registers[12] := PT and $FF;
      State.Registers[13] := PT shr 8;
      State.DecoderStat0 := 0;
      if ValidSector then
        State.DecoderStat0 := $80;
      State.IFStat := State.IFStat and $DF;
    end;
    if DecoderPending and ((State.Registers[1] and $20) <> 0) and ((State.IRQMask1 and $500) = $500) then
      State.DecoderIRQ := True;
  end;
  if FDisc.IsData(State.LBA) or (State.LBA >= FDisc.LeadOut) then
    Inc(State.LBA);
  if State.LBA > 449849 then
  begin
    State.Playing := False;
    State.Status := 12;
  end;
end;

procedure TNeoGeoCDController.Advance(Time: Int64);
begin
  while State.NextTick <= Time do
  begin
    var EventTime := State.NextTick;
    if (State.PendingAction <> 0) and (State.PendingDeadline <= EventTime) then
    begin
      case State.PendingAction of
        4:
          State.Status := 4;
        10:
          begin
            State.LBA := 0;
            State.Status := 0;
          end;
        12:
          begin
            State.TrayOpen := False;
            State.Status := 0;
            if not State.DiscPresent then
              State.Status := 11;
          end;
        13:
          begin
            State.TrayOpen := True;
            State.Status := 5;
          end;
      end;
      State.PendingAction := 0;
    end;
    if State.Playing and (State.NextSector <= EventTime) then
    begin
      DecoderTick;
      Inc(State.NextSector, SectorPeriod);
    end;
    if State.NextCommunication <= EventTime then
    begin
      if State.CommunicationEnabled and ((State.IRQMask1 and $50) = $50) then
        State.CommunicationIRQ := True;
      Inc(State.NextCommunication, NGCD_COMMUNICATION_PERIOD);
    end;
    UpdateDeadline;
  end;
  State.Clock := Max(State.Clock, Time);
end;

function TNeoGeoCDController.ReadWord(Address: Cardinal; HighByte, LowByte: Boolean): Word;
begin
  Result := 0;
  case Address and $FFFF of
    $60:
      if State.DMABusy then
        Result := $40;
    4:
      Result := State.IRQMask2;
    $102:
      if LowByte then
        Result := ReadRegister;
    $160:
      if LowByte then
        Result := State.Response[State.ResponsePointer] or (State.Strobe shl 4);
    $11C:
      begin
        Result := Word((FRegion xor 7) shl 8);
        if FCDZ = State.TrayOpen then
          Result := Result or $1000;
      end;
    $188:
      Result := ReverseBits(Word(State.LastLeft));
    $18A:
      Result := ReverseBits(Word(State.LastRight));
  end;
end;

function TNeoGeoCDController.WriteWord(Address: Cardinal; Value: Word; HighByte, LowByte: Boolean): Boolean;
begin
  Result := False;
  var Offset := Address and $FFFF;
  if HighByte and LowByte then
    case Offset of
      0:
        begin
          State.Playing := False;
          State.Status := 0;
        end;
      2:
        State.IRQMask1 := Value;
      4:
        State.IRQMask2 := Value;
      $64:
        State.DMADestination := (State.DMADestination and $FFFF) or (Cardinal(Value) shl 16);
      $66:
        State.DMADestination := (State.DMADestination and $FFFF0000) or Value;
      $68:
        State.DMASource := (State.DMASource and $FFFF) or (Cardinal(Value) shl 16);
      $6A:
        State.DMASource := (State.DMASource and $FFFF0000) or Value;
      $6C:
        State.DMAPattern := Value;
      $70:
        State.DMALength := (State.DMALength and $FFFF) or (Cardinal(Value) shl 16);
      $72:
        State.DMALength := (State.DMALength and $FFFF0000) or Value;
      $7E..$8E:
        State.DMAConfig[(Offset - $7E) shr 1] := Value;
    end;

  if not LowByte then
    Exit;

  var B := Byte(Value and $FF);
  case Offset of
    $0E:
      begin
        if (B and $20) <> 0 then
          State.DecoderIRQ := False;
        if (B and $10) <> 0 then
          State.CommunicationIRQ := False;
      end;
    $60:
      begin
        Result := B = $40;
        if B = 0 then
        begin
          State.DMABusy := False;
          FillChar(State.DMAConfig, SizeOf(State.DMAConfig), 0);
          State.DMASource := 0;
          State.DMADestination := 0;
          State.DMALength := 0;
          State.DMAPattern := 0;
        end;
      end;
    $100:
      State.RegisterPointer := B and 15;
    $102:
      WriteRegister(B);
    $104:
      State.Area := B;
    $110:
      State.SprDisabled := B <> 0;
    $114:
      State.FixDisabled := B <> 0;
    $118:
      State.VideoEnabled := B <> 0;
    $120:
      State.BusRequest := State.BusRequest or 1;
    $122:
      State.BusRequest := State.BusRequest or 2;
    $126:
      State.BusRequest := State.BusRequest or 4;
    $128:
      State.BusRequest := State.BusRequest or 8;
    $140:
      State.BusRequest := State.BusRequest and $FE;
    $142:
      State.BusRequest := State.BusRequest and $FD;
    $146:
      State.BusRequest := State.BusRequest and $FB;
    $148:
      State.BusRequest := State.BusRequest and $F7;
    $162:
      State.Command[State.CommandPointer] := B and 15;
    $164:
      case B of
        1:
          begin
            State.CommandPointer := (State.CommandPointer + 1) mod 10;
            if State.CommandPointer = 0 then
              Command;
          end;
        2:
          begin
            State.Strobe := 0;
            State.ResponsePointer := (State.ResponsePointer + 1) mod 10;
          end;
        3:
          State.Strobe := 1;
      end;
    $16E:
      State.WatchdogDisabled := B <> 0;
    $180:
      begin
        State.CommunicationEnabled := B <> 0;
        State.CommandPointer := 0;
        State.ResponsePointer := 9;
        State.Strobe := 1;
      end;
    $182:
      State.Z80Enabled := B <> 0;
    $1A0:
      State.SprBank := B and 3;
    $1A2:
      State.PCMBank := B and 1;
  end;
end;

procedure TNeoGeoCDController.EndTransfer;
begin
  State.IFStat := State.IFStat or 8;
  State.IFStat := State.IFStat and $BF;
  if (State.Registers[1] and $40 <> 0) and (State.IRQMask1 and $500 = $500) then
    State.DecoderIRQ := True;
  var DAC := (Integer(State.Registers[4]) + Integer(State.Registers[5]) * 256 +
    Integer(State.Registers[2]) + Integer(State.Registers[3]) * 256 + 1) and $FFFF;
  State.Registers[4] := DAC and $FF;
  State.Registers[5] := DAC shr 8;
  State.Registers[2] := 0;
  State.Registers[3] := 0;
end;

procedure TNeoGeoCDController.Mix(var Left, Right: SmallInt);
begin
  State.LastLeft := 0;
  State.LastRight := 0;
  if not State.Playing or (State.ScanDirection <> 0) then
    Exit;

  if FAudioLBA <> State.LBA then
  begin
    // The TOC is immutable: validate once per sector, not for all 588 samples.
    // FAudioLBA is invalidated on reset and snapshot restore.
    if FDisc.IsData(State.LBA) or (State.LBA >= FDisc.LeadOut) then
      Exit;

    FDisc.ReadAudio(State.LBA, FAudio);
    FAudioLBA := State.LBA;
  end;

  var Offset := State.SampleOffset * 4;
  State.LastLeft := SmallInt(Word(FAudio[Offset]) or (Word(FAudio[Offset + 1]) shl 8));
  State.LastRight := SmallInt(Word(FAudio[Offset + 2]) or (Word(FAudio[Offset + 3]) shl 8));
  Left := EnsureRange(Integer(Left) + Integer(State.LastLeft), -32768, 32767);
  Right := EnsureRange(Integer(Right) + Integer(State.LastRight), -32768, 32767);
  Inc(State.SampleOffset);
  if State.SampleOffset = 588 then
  begin
    State.SampleOffset := 0;
    Inc(State.LBA);
    if State.LBA >= FDisc.LeadOut then
    begin
      State.Playing := False;
      State.Status := 12;
      UpdateDeadline;
    end;
  end;
end;

function TNeoGeoCDController.InterruptVector: Integer;
begin
  Result := -1;
  if State.DecoderIRQ then
    Result := $54 div 4;
  if State.CommunicationIRQ then
    Result := $58 div 4;
end;

procedure TNeoGeoCDController.SerializeState(Archive: TStateArchive);
begin
  Archive.Field(State, SizeOf(State));
  if Archive.Loading then
  begin
    if (State.LBA < 0) or (State.LBA > 449850) or (State.SampleOffset < 0) or
      (State.SampleOffset >= 588) or (State.CommandPointer > 9) or
      (State.ResponsePointer > 9) or (State.RegisterPointer > 15) or (State.Strobe > 1) or
      (State.Clock < 0) or (State.NextCommunication <= State.Clock) or
      (State.Playing and (State.NextSector <= State.Clock)) or
      not (State.PendingAction in [0, 4, 10, 12, 13]) or
      ((State.PendingAction <> 0) and (State.PendingDeadline <= State.Clock)) or
      (State.Status > 15) or
      (State.Playing and (State.TrayOpen or not State.DiscPresent)) or
      (State.ScanDirection < -1) or (State.ScanDirection > 1) or
      (State.SprBank > 3) or (State.PCMBank > 1) or (State.NextTick < 0) or (State.DMALength > $200000) then
      raise EReadError.Create('Invalid Neo Geo CD controller snapshot');

    var Deadline := State.NextCommunication;
    if State.Playing then
      Deadline := Min(Deadline, State.NextSector);
    if State.PendingAction <> 0 then
      Deadline := Min(Deadline, State.PendingDeadline);
    if State.NextTick <> Deadline then
      raise EReadError.Create('Invalid CD event deadline');

    for var N in State.Command do
      if N > 15 then
        raise EReadError.Create('Invalid Neo Geo CD command snapshot');

    for var N in State.Response do
      if N > 15 then
        raise EReadError.Create('Invalid Neo Geo CD response snapshot');

    FAudioLBA := -1;
  end;
end;

end.

