unit NeoGeoCD.Controller;

interface

uses
  System.SysUtils, System.Classes, Core.Snapshots, NeoGeoCD.Disc;

const
  NGCD_MASTER_CLOCK = 24168000;

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
    LastLeft, LastRight: SmallInt;
  end;

  TNeoGeoCDController = class
  private
    FDisc: TNeoGeoCDDisc;
    FCDZ: Boolean;
    FAudio: TBytes;
    FAudioLBA: Integer;
    procedure Command;
    procedure ResponseTime(LBA: Integer);
    procedure Checksum;
    procedure NextRegister;
    function ReadRegister: Byte;
    procedure WriteRegister(Value: Byte);
  public
    State: TCDControllerState;
    constructor Create(Disc: TNeoGeoCDDisc; CDZ: Boolean = False);
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
  for var I := 0 to 15 do
    Result := (Result shl 1) or ((Value shr I) and 1);
end;

constructor TNeoGeoCDController.Create(Disc: TNeoGeoCDDisc; CDZ: Boolean);
begin
  inherited Create;
  FDisc := Disc;
  FCDZ := CDZ;
  Reset;
end;

procedure TNeoGeoCDController.Reset;
begin
  State := Default(TCDControllerState);
  State.ResponsePointer := 9;
  State.Strobe := 1;
  State.IFStat := $FF;
  State.Registers[8] := $30;
  State.Registers[9] := $09;
  State.NextTick := 373886; // Idle communication: approximately 64.64 Hz.
  State.Header[1] := 2;
  State.Header[3] := 1;
  FAudioLBA := -1;
  Checksum;
end;

procedure TNeoGeoCDController.Checksum;
begin
  var Sum := 5;
  for var I := 0 to 8 do
    Inc(Sum, State.Response[I]);
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
  for var I := 0 to 8 do
    Inc(Sum, State.Command[I]);

  if State.Command[9] <> ((not Sum) and 15) then
  begin
    FillChar(State.Response, SizeOf(State.Response), 0);
    State.Response[0] := State.Status;
    Checksum;
    Exit;
  end;

  var Op := State.Command[0] * 16 + State.Command[1];
  var TrackIndex := FDisc.TrackAt(State.LBA);
  var TrackNumber := Max(1, TrackIndex + 1);
  if State.LBA >= FDisc.LeadOut then
    TrackNumber := FDisc.TrackCount;
  var DataFlag := 0;
  if FDisc.IsData(State.LBA) then
    DataFlag := 4;
  if Op <> 0 then
    FillChar(State.Response, SizeOf(State.Response), 0);

  case Op of
    $00:
      State.Response[0] := State.Status;
    $10:
      begin
        State.Playing := False;
        State.Status := 0;
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
              ResponseTime(Position);
              State.Response[8] := DataFlag;
            end;
          2:
            begin
              State.Response[2] := TrackNumber div 10;
              State.Response[3] := TrackNumber mod 10;
              var Index := Ord(State.LBA >= FDisc.Track(TrackNumber).StartLBA);

              // Pressed discs expose protection indexes in the data track.
              // CDZ BIOS checks one new index every four MSF seconds; plain
              // ISO/CUE/CHD images usually retain only INDEX 01.
              if (TrackNumber = 1) and FDisc.IsData(State.LBA) then
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
            State.Response[3] := 2;
        end;
      end;
    $30, $B0:
      begin
        var Position := 0;
        if Op = $30 then
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
        State.Playing := True;
        State.Status := 1;
        State.Response[1] := 2;
        State.Response[2] := (FDisc.TrackAt(State.LBA) + 1) div 10;
        State.Response[3] := (FDisc.TrackAt(State.LBA) + 1) mod 10;
      end;
    $40:
      begin
        State.Playing := False;
        State.Status := 4;
      end;
    $60:
      begin
        State.Playing := False;
        State.Status := 4;
      end;
    $70:
      begin
        State.Playing := True;
        State.Status := 1;
      end;
    $80, $90:
      begin
        var Delta := 30;
        if Op = $90 then
          Delta := -30;
        State.LBA := EnsureRange(State.LBA + Delta, 0, FDisc.LeadOut - 1);
        State.SampleOffset := 0;
        FAudioLBA := -1;
        State.Playing := True;
        State.Status := 1;
      end;
  end;

  State.Response[0] := State.Status;
  if Op = $40 then
    State.Response[0] := 2;
  if (Op = $80) or (Op = $90) then
    State.Response[0] := 3;
  Checksum;
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
  State.Registers[N] := Value;
  if (N = 6) and ((State.Registers[1] and 2) <> 0) then
    State.IFStat := State.IFStat and $F7;
  if N = 7 then
    State.IFStat := State.IFStat or $40;
  NextRegister;
end;

procedure TNeoGeoCDController.Advance(Time: Int64);
begin
  while State.NextTick <= Time do
  begin
    if State.Playing then
    begin
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
          FDisc.ReadData(State.LBA, Sector);
          Move(Sector[0], State.Sector[0], 2048);
          var WA := (Integer(State.Registers[8]) + Integer(State.Registers[9]) * 256 + 2352) and $FFFF;
          var PT := (Integer(State.Registers[12]) + Integer(State.Registers[13]) * 256 + 2352) and $FFFF;
          State.Registers[8] := WA and $FF;
          State.Registers[9] := WA shr 8;
          State.Registers[12] := PT and $FF;
          State.Registers[13] := PT shr 8;
          State.DecoderStat0 := $80;
          State.IFStat := State.IFStat and $DF;
        end;
        if DecoderPending and ((State.Registers[1] and $20) <> 0) and ((State.IRQMask1 and $500) = $500) then
          State.DecoderIRQ := True;
      end;
      if FDisc.IsData(State.LBA) or (State.LBA >= FDisc.LeadOut) then
        Inc(State.LBA);
    end;
    if State.CommunicationEnabled and ((State.IRQMask1 and $50) = $50) then
      State.CommunicationIRQ := True;
    if State.LBA > 449849 then
    begin
      State.Playing := False;
      State.Status := 12;
    end;
    if State.Playing and FCDZ and FDisc.IsData(State.LBA) then
      Inc(State.NextTick, NGCD_MASTER_CLOCK div 150)
    else if State.Playing then
      Inc(State.NextTick, NGCD_MASTER_CLOCK div 75)
    else
      Inc(State.NextTick, 373886);
  end;
end;

function TNeoGeoCDController.ReadWord(Address: Cardinal; HighByte, LowByte: Boolean): Word;
begin
  Result := 0;
  case Address and $FFFF of
    4:
      Result := State.IRQMask2;
    $102:
      if LowByte then
        Result := ReadRegister;
    $160:
      if LowByte then
        Result := State.Response[State.ResponsePointer] or (State.Strobe shl 4);
    $11C:
      if FCDZ then
        Result := $0500
      else
        Result := $1500; // Europe, closed lid.
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
  if not State.Playing then
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
      (State.SprBank > 3) or (State.PCMBank > 1) or (State.NextTick < 0) or (State.DMALength > $200000) then
      raise EReadError.Create('Invalid Neo Geo CD controller snapshot');

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

