unit N64.Console;
{$Q+}{$R+}

interface

uses
  System.SysUtils, System.Math, System.Classes, System.UITypes, N64.Types,
  N64.CPU, N64.RSP, N64.RDP, N64.VI, N64.Timing, Core.Snapshots, Core.Emulation;

type
  TN64SaveType = (Auto, EEPROM4K, EEPROM16K, SRAM, FlashRAM, None);

  TN64Pad = record
    Buttons: Word;
    StickX, StickY: ShortInt;
    Connected: Boolean;
  end;

  TN64Pads = array[0..3] of TN64Pad;

  TN64SPTransfer = record
    Active, Writing: Boolean;
    Local, RAM, Size, Blocks, Skip, Position, Control: Cardinal;
  end;
  TN64PITransfer = record
    Active, Writing, Flash, FirstBlock: Boolean;
    RAM, Cart, Length, Position: Cardinal;
    FlashMode: Integer;
    FlashStatus: UInt64;
    BlockRAM, BlockLength, BlockRead, BlockWriteSize, BlockWritten: Cardinal;
    MaxBlockSize, Stage, Latency, PulseWidth, PageSize, ReleaseDuration, ClockPhase: Cardinal;
    Buffer: array[0..127] of Byte;
  end;
  TN64SITransfer = record
    Active, Writing: Boolean;
    RAM, Position: Cardinal;
    Data: array[0..63] of Byte;
  end;

  TN64Console = class(TN64Bus)
  private
    FData, FRAM, FSP, FPIF, FSave, FHiddenRAM: TBytes;
    FReg: array[0..7, 0..15] of Cardinal;
    FCPU: TN64CPU;
    FRSP: TN64RSP;
    FRDP: TN64RDP;
    FVI: TN64VI;
    FTimeline: TN64Timeline;
    FSPTransfer, FSPQueued: TN64SPTransfer;
    FPITransfer: TN64PITransfer;
    FSITransfer: TN64SITransfer;
    FPendingSPAddress, FPendingRAMAddress: Cardinal;
    FVIPhase, FAIDACPhase: UInt64;
    FAIAnchorTick: UInt64;
    FRSPPhase: Integer;
    FLastLeft, FLastRight: SmallInt;
    FCurrentFrame: TEmulatorFrame;
    FVideoOutputEnabled: Boolean;
    FFrame: UInt64;
    FTick, FLine, FField: Integer;
    FSPPC: Cardinal;
    FInputs: TN64Pads;
    FSample: TArray<SmallInt>;
    FAIAddress, FAILength, FAIProgress, FAIPhase: Cardinal;
    FAINextAddress, FAINextLength: Cardinal;
    FAudioClock: Integer;
    FAIDACRemainder: Cardinal;
    FSaveDirty: Boolean;
    FSaveType: TN64SaveType;
    FDetectedSaveType: TN64SaveType;
    FFlashData: array[0..$1FFFF] of Byte;
    FFlashBuffer: array[0..127] of Byte;
    FFlashUsed, FFlashReady: Boolean;
    FFlashMode: Integer;
    FFlashOffset: Cardinal;
    FFlashStatus: UInt64;
    FDebugOutput: string;
    FDebugBuffer: array[0..511] of Byte;
    procedure SetInterrupts(Value: Cardinal);
    procedure SPDMA(Writing: Boolean; Value: Cardinal);
    procedure PIDMA(Writing: Boolean; Value: Cardinal);
    procedure SIDMA(Writing: Boolean);
    procedure PIFCommand;
    procedure ReadPIFControllers;
    procedure CICChallenge;
    procedure FormatControllerPaks;
    procedure AudioTick;
    procedure ProcessRDP;
    procedure RunRSP;
    procedure FlashCommand(Value: Cardinal);
    function EEPROMSize: Integer;
    function HasFlash: Boolean;
    function VideoClock: Cardinal;
    procedure AdvanceTime(Cycles: Cardinal);
    procedure HandleEvent(Kind: TN64EventKind);
    procedure ScheduleVI;
    procedure ScheduleOutput;
    procedure ScheduleAI;
    procedure ScheduleRSP;
    procedure SPTransferBeat;
    procedure PITransferBeat;
    procedure SITransferBeat;
    function PIBeatCycles: Cardinal;
    procedure PreparePIBlock;
    procedure FinishPIBlock;
    procedure CompletePI;
    procedure ConsumeAI;
    procedure RenderFrame(ScanoutField: Integer);
    procedure ValidateState;
  public
    constructor Create(const Data: TBytes);
    destructor Destroy; override;
    procedure Reset;
    function Read8(Address: Cardinal): Byte; override;
    procedure Write8(Address: Cardinal; Value: Byte); override;
    function Read32(Address: Cardinal): Cardinal; override;
    procedure Write32(Address, Value: Cardinal); override;
    function ReadHidden(Address: Cardinal): Byte; override;
    procedure WriteHidden(Address: Cardinal; Value: Byte); override;
    function GuestTick: UInt64; override;
    function InterruptPending: Boolean; override;
    procedure RunInstructions(Count: Integer);
    procedure RunCycles(Cycles: Cardinal);
    procedure RunFrame;
    function GetFrame: TEmulatorFrame;
    procedure SetInputs(const Inputs: TN64Pads);
    function TakeSamples: TArray<SmallInt>;
    function SaveBattery: TBytes;
    procedure LoadBattery(const Data: TBytes);
    procedure ConfigureSaveType(Value: TN64SaveType);
    procedure SerializeState(State: TStateArchive);
    property CPU: TN64CPU read FCPU;
    // Optional command capture is configured by diagnostics, outside guest state.
    property Renderer: TN64RDP read FRDP;
    property FrameNumber: UInt64 read FFrame;
    property DebugOutput: string read FDebugOutput;
    property SaveDirty: Boolean read FSaveDirty;
    // Raw hardware diagnostics can omit host display conversion. DMA, RDP,
    // guest VI registers/IRQs and audio clocks still execute normally.
    property VideoOutputEnabled: Boolean read FVideoOutputEnabled write FVideoOutputEnabled;
    function FramesPerSecond: Double;
    function RendererDescription: string;
  end;

implementation

constructor TN64Console.Create(const Data: TBytes);
begin
  inherited Create;
  if (Length(Data) < $1000) or (Length(Data) > 64 * 1024 * 1024) or
    ((Length(Data) and 3) <> 0) then
    raise EReadError.Create('Invalid N64 ROM size');

  FData := Copy(Data);
  case Data[0] of
    $37:
      for var I := 0 to Length(Data) div 2 - 1 do
      begin
        FData[I * 2] := Data[I * 2 + 1];
        FData[I * 2 + 1] := Data[I * 2]
      end;
    $40:
      for var I := 0 to Length(Data) div 4 - 1 do
        for var J := 0 to 3 do
          FData[I * 4 + J] := Data[I * 4 + 3 - J];
  end;
  if (FData[0] <> $80) or (FData[1] <> $37) or (FData[2] <> $12) or (FData[3] <> $40) then
    raise EReadError.Create('Invalid N64 ROM signature');

  FDetectedSaveType := TN64SaveType.EEPROM4K;
  // Cartridge save hardware, by the region-independent product code.
  // Reference: ares mia/medium/nintendo-64.cpp (EEPROM/SRAM/Flash database).
  // Unknown/homebrew IDs keep the legacy EEPROM4K and Flash command probe.
  // Explicit frontend settings always override this detection.
  var ID := '|' + Char(FData[$3B]) + Char(FData[$3C]) + Char(FData[$3D]) + '|';
  if Pos(ID, '|NB7|NGT|NFU|NCW|NCZ|ND6|NDO|ND2|N3D|NMX|NGC|NIM|NNB|NMV|NM8|NEV|NPP|NUB|NPD|NRZ|NR7|NEP|NYS|') > 0 then
    FDetectedSaveType := TN64SaveType.EEPROM16K
  else if Pos(ID, '|NTE|NVB|NB5|NFZ|NSI|NG6|NGP|NYW|NHY|NIB|NPS|NPA|NP4|NJ5|NP6|NPE|NJG|NZL|NKG|NMF|NRI|NUT|NUM|NOB|NPM|NRE|NAL|NT3|NS4|NA2|NVP|NWL|NW2|NWX|CZL|CFZ|CPS|') > 0 then
    FDetectedSaveType := TN64SaveType.SRAM
  else if Pos(ID, '|NCC|NCV|NDA|NAF|NJF|NKJ|NZS|NM6|NCK|NMQ|NPN|NPF|NPO|CP2|NP3|NRH|NSQ|NT9|NW4|NDP|') > 0 then
    FDetectedSaveType := TN64SaveType.FlashRAM;
  SetLength(FRAM, $800000);
  SetLength(FHiddenRAM, $400000);
  SetLength(FSP, $2000);
  SetLength(FPIF, 64);
  // EEPROM 16K, SRAM 32K, and four controller paks. Backends are indexed.
  SetLength(FSave, 2048 + 32768 + 4 * 32768);
  for var I := 0 to 2047 do
    FSave[I] := $FF;
  FormatControllerPaks;
  for var I := 0 to High(FFlashData) do
    FFlashData[I] := $FF;
  FCPU := TN64CPU.Create(Self);
  FRSP := TN64RSP.Create(Self);
  FRDP := TN64RDP.Create(Self);
  FVI := TN64VI.Create(Self);
  FTimeline := TN64Timeline.Create;
  FVideoOutputEnabled := True;
  Reset;
end;

destructor TN64Console.Destroy;
begin
  FCPU.Free;
  FRSP.Free;
  FRDP.Free;
  FVI.Free;
  FTimeline.Free;
  inherited;
end;

procedure TN64Console.Reset;
begin
  for var I := 0 to High(FRAM) do
    FRAM[I] := 0;
  for var I := 0 to High(FHiddenRAM) do FHiddenRAM[I] := 0;
  FTimeline.Reset;
  FSPTransfer := Default(TN64SPTransfer); FSPQueued := Default(TN64SPTransfer);
  FPITransfer := Default(TN64PITransfer); FSITransfer := Default(TN64SITransfer);
  FPendingSPAddress := 0; FPendingRAMAddress := 0;
  FVIPhase := 0; FAIDACPhase := 0; FAIAnchorTick := 0; FRSPPhase := 0;
  FLastLeft := 0; FLastRight := 0;
  FCurrentFrame := Default(TEmulatorFrame);
  for var I := 0 to High(FSP) do
    FSP[I] := 0;
  for var I := 0 to 63 do
    FPIF[I] := 0;
  for var I := 0 to 7 do
    for var J := 0 to 15 do
      FReg[I, J] := 0;
  for var I := $40 to $FFF do
    FSP[I] := FData[I];
  FReg[0, 4] := 1;
  FReg[5, 2] := $7F; FReg[5, 3] := $7F;
  FReg[2, 1] := $02020102;
  FReg[1, 3] := $80;
  FReg[3, 6] := 525;
  FReg[6, 0] := $E;
  FReg[6, 1] := $40;
  FReg[6, 3] := $14;
  FReg[6, 4] := $00063634;
  FFrame := 0;
  FTick := 0;
  FLine := 0;
  FField := 0;
  FSPPC := 0;
  FSample := nil;
  FAIAddress := 0;
  FAILength := 0;
  FAIProgress := 0;
  FAIPhase := 0;
  FAINextAddress := 0;
  FAINextLength := 0;
  FAudioClock := 0;
  FAIDACRemainder := 0;
  FDebugOutput := '';
  for var I := 0 to High(FDebugBuffer) do
    FDebugBuffer[I] := 0;
  FFlashMode := 0;
  FFlashOffset := 0;
  FFlashStatus := 0;
  FFlashReady := False;
  FCPU.Reset;
  FRSP.Reset;
  FRDP.Reset;
  FVI.Reset;
  FReg[3, 7] := 3093;
  if FramesPerSecond = 50 then begin FReg[3, 6] := 625; FReg[3, 7] := 3177 end;
  FReg[5, 5] := FData[3]; FReg[5, 6] := FData[2];
  FReg[5, 7] := FData[1] and 15; FReg[5, 8] := (FData[1] shr 4) and 3;
  ScheduleVI; ScheduleOutput;
  // Post-PIF register seeds selected by the IPL3 word checksum used by Project64.
  var Sum: UInt64 := 0;
  for var I := $40 div 4 to $FFC div 4 do
    Sum := Sum + ((Cardinal(FData[I * 4]) shl 24) or (Cardinal(FData[I * 4 + 1]) shl 16) or
      (Cardinal(FData[I * 4 + 2]) shl 8) or FData[I * 4 + 3]);
  var CIC := 6102;
  if Sum = $D6497E414B then
    CIC := 6103
  else if Sum = $11A49F60E96 then
    CIC := 6105
  else if Sum = $D6D5BE5580 then
    CIC := 6106;
  FCPU.GPR[1] := 1;
  FCPU.GPR[2] := $0EBDA536;
  FCPU.GPR[3] := $0EBDA536;
  FCPU.GPR[4] := $A536;
  FCPU.GPR[5] := SX($C95973D5, 32);
  FCPU.GPR[12] := SX($ED10D0B3, 32);
  FCPU.GPR[13] := $1402A4CC;
  FCPU.GPR[14] := $2449A366;
  FCPU.GPR[15] := $3103E121;
  FCPU.GPR[24] := 3;
  FCPU.GPR[25] := SX($9DEBB54F, 32);
  if CIC = 6103 then
  begin
    FCPU.GPR[2] := $49A5EE96;
    FCPU.GPR[3] := $49A5EE96;
    FCPU.GPR[4] := $EE96;
    FCPU.GPR[5] := SX($95315A28, 32);
    FCPU.GPR[12] := SX($CE9DFBF7, 32);
    FCPU.GPR[13] := SX($CE9DFBF7, 32);
    FCPU.GPR[14] := $5BACA1DF;
    FCPU.GPR[15] := $18B63D28;
    FCPU.GPR[22] := $78;
    FCPU.GPR[25] := SX($825B21C9, 32);
  end
  else if CIC = 6105 then
  begin
    FCPU.GPR[1] := 0;
    FCPU.GPR[2] := SX($F58B0FBF, 32);
    FCPU.GPR[3] := SX($F58B0FBF, 32);
    FCPU.GPR[4] := $FBF;
    FCPU.GPR[5] := $5493FB9A;
    FCPU.GPR[12] := SX($9651F81E, 32);
    FCPU.GPR[13] := $2D42AAC5;
    FCPU.GPR[14] := SX($C2C20384, 32);
    FCPU.GPR[15] := $56584D60;
    FCPU.GPR[22] := $91;
    FCPU.GPR[25] := SX($CDCE565F, 32);
    Write32($04001000, $3C0DBFC0);
    Write32($04001004, $8DA807FC);
    Write32($04001008, $25AD07C0);
    Write32($0400100C, $31080080);
    Write32($04001010, $5500FFFC);
    Write32($04001014, $3C0DBFC0);
    Write32($04001018, $8DA80024);
    Write32($0400101C, $3C0BB000);
  end
  else if CIC = 6106 then
  begin
    FCPU.GPR[1] := 0;
    FCPU.GPR[2] := SX($A95930A4, 32);
    FCPU.GPR[3] := SX($A95930A4, 32);
    FCPU.GPR[4] := $30A4;
    FCPU.GPR[5] := SX($E067221F, 32);
    FCPU.GPR[12] := SX($BCB59510, 32);
    FCPU.GPR[13] := SX($BCB59510, 32);
    FCPU.GPR[14] := $5CD2B70F;
    FCPU.GPR[15] := $7A3C07F4;
    FCPU.GPR[22] := $85;
    FCPU.GPR[25] := $465E3F72;
  end;
  if FramesPerSecond = 50 then
  begin
    FCPU.GPR[20] := 0;
    FCPU.GPR[23] := 6;
    FCPU.GPR[24] := 0;
    FCPU.GPR[31] := SX($A4001554, 32);
    case CIC of
      6102:
        begin
          FCPU.GPR[5] := SX($C0F1D859, 32);
          FCPU.GPR[14] := $2DE108EA
        end;
      6103:
        begin
          FCPU.GPR[5] := SX($D4646273, 32);
          FCPU.GPR[14] := $1AF99984
        end;
      6105:
        begin
          FCPU.GPR[5] := SX($DECAAAD1, 32);
          FCPU.GPR[14] := $0CF85C13;
          FCPU.GPR[24] := 2;
          Write32($04001004, $BDA807FC)
        end;
      6106:
        begin
          FCPU.GPR[5] := SX($B04DC903, 32);
          FCPU.GPR[14] := $1AF99984;
          FCPU.GPR[24] := 2
        end;
    end;
  end;
  Write32($318, $800000);
  Write32($3F0, $800000);
end;

function TN64Console.Read8(Address: Cardinal): Byte;
begin
  if (Address >= $13FF0020) and (Address < $13FF0220) then
    Exit(FDebugBuffer[Address - $13FF0020]);
  if Address < $800000 then
    Exit(FRAM[Address]);
  if (Address >= $04000000) and (Address < $04002000) then
    Exit(FSP[Address - $04000000]);
  if (Address >= $1FC007C0) and (Address < $1FC00800) then
    Exit(FPIF[Address - $1FC007C0]);
  if (Address >= $10000000) and (UInt64(Address) < UInt64($10000000) + Cardinal(Length(FData))) then
    Exit(FData[Address - $10000000]);
  if (Address >= $08000000) and (Address < $08020000) then
  begin
    if HasFlash then
      Exit(Byte((FFlashStatus shr ((7 - (Address and 7)) * 8)) and $FF));
    if (Address < $08008000) and (FSaveType in [TN64SaveType.Auto, TN64SaveType.SRAM]) then
      Exit(FSave[2048 + Address - $08000000]);
    Exit(0);
  end;
  Result := 0;
  if (Address >= $03F00000) and (Address < $04900040) then
    Result := Byte((Read32(Address and $FFFFFFFC) shr ((3 - (Address and 3)) * 8)) and $FF);
end;

procedure TN64Console.Write8(Address: Cardinal; Value: Byte);
begin
  if (Address >= $13FF0020) and (Address < $13FF0220) then
  begin
    FDebugBuffer[Address - $13FF0020] := Value;
    Exit
  end;
  if Address < $800000 then
  begin
    FRAM[Address] := Value;
    FHiddenRAM[Address shr 1] := Byte(Ord((FRAM[Address or 1] and 1) <> 0) * 3);
  end
  else if (Address >= $04000000) and (Address < $04002000) then
    FSP[Address - $04000000] := Value
  else if (Address >= $1FC007C0) and (Address < $1FC00800) then
  begin
    FPIF[Address - $1FC007C0] := Value;
    if Address = $1FC007FF then
      PIFCommand;
  end
  else if (Address >= $08000000) and (Address < $08008000) then
    if not HasFlash and (FSaveType in [TN64SaveType.Auto, TN64SaveType.SRAM]) then
    begin
      FSave[2048 + Address - $08000000] := Value;
      FSaveDirty := True
    end;
end;

function TN64Console.Read32(Address: Cardinal): Cardinal;
begin
  // Only bypass the bus decoder when the entire word is in one memory bank.
  // Boundary reads and device registers retain their byte-wise side effects.
  if Address <= $7FFFFC then
    Exit((Cardinal(FRAM[Address]) shl 24) or (Cardinal(FRAM[Address + 1]) shl 16) or
      (Cardinal(FRAM[Address + 2]) shl 8) or FRAM[Address + 3]);
  if (Address >= $04000000) and (Address <= $04001FFC) then
  begin
    var Offset := Address - $04000000;
    Exit((Cardinal(FSP[Offset]) shl 24) or (Cardinal(FSP[Offset + 1]) shl 16) or
      (Cardinal(FSP[Offset + 2]) shl 8) or FSP[Offset + 3]);
  end;
  if (Address >= $10000000) and (Address <= $10000000 + Cardinal(Length(FData)) - 4) and
    not ((Address >= $13FF001D) and (Address < $13FF0220)) then
  begin
    var Offset := Address - $10000000;
    Exit((Cardinal(FData[Offset]) shl 24) or (Cardinal(FData[Offset + 1]) shl 16) or
      (Cardinal(FData[Offset + 2]) shl 8) or FData[Offset + 3]);
  end;
  if (Address >= $13FF0020) and (Address < $13FF0220) then
    Exit(inherited Read32(Address));
  Result := 0;
  if (Address < $800000) or ((Address >= $04000000) and (Address < $04002000)) or
    (Address >= $08000000) then
  begin
    if (Address < $800000) or ((Address >= $04000000) and (Address < $04002000)) or
      ((Address >= $08000000) and (Address < $08020000)) or
      ((Address >= $10000000) and (Address < $10000000 + Cardinal(Length(FData)))) or
      ((Address >= $1FC007C0) and (Address < $1FC00800)) then
      Exit(inherited Read32(Address));
  end;
  if (Address >= $04040000) and (Address < $04040020) then
  begin
    var I := (Address - $04040000) div 4;
    Result := FReg[0, I];
    if I = 7 then
      FReg[0, 7] := 1;
    Exit;
  end;
  if Address = $04080000 then
    Exit(FSPPC);
  if (Address >= $04100000) and (Address < $04900000) then
  begin
    var Bank := (Address - $04000000) div $100000;
    if Bank = 2 then
      Exit;
    if Bank >= 3 then
      Dec(Bank);
    var I := (Address and $FFFFF) div 4;
    if I < 16 then
    begin
      if (Bank = 3) and (I = 4) then
        Exit(Cardinal((FLine and not 1) or FField));
      if (Bank = 4) and (I = 1) then
        Exit((FAILength - FAIProgress) and $3FFF8);
      if (Bank = 4) and (I = 3) then
      begin
        Result := 0;
        if FAILength > 0 then
          Result := $40000000;
        if FAINextLength > 0 then
          Result := Result or $80000000;
        Exit;
      end;
      Exit(FReg[Bank, I]);
    end;
  end;
  if (Address >= $03F00000) and (Address < $04000000) then
    case Address and $FF of
      0:
        Exit($B4190010);
      4:
        Exit(0);
      12:
        Exit($00000500);
    end;
  Result := 0;
end;

procedure TN64Console.Write32(Address, Value: Cardinal);
begin
  if Address <= $7FFFFC then
  begin
    FRAM[Address] := Byte(Value shr 24);
    FRAM[Address + 1] := Byte((Value shr 16) and $FF);
    FRAM[Address + 2] := Byte((Value shr 8) and $FF);
    FRAM[Address + 3] := Byte(Value and $FF);
    FHiddenRAM[Address shr 1] := Byte(Ord((FRAM[Address + 1] and 1) <> 0) * 3);
    FHiddenRAM[(Address + 3) shr 1] := Byte(Ord((Value and 1) <> 0) * 3);
    Exit;
  end;
  if (Address >= $04000000) and (Address <= $04001FFC) then
  begin
    var Offset := Address - $04000000;
    FSP[Offset] := Byte(Value shr 24);
    FSP[Offset + 1] := Byte((Value shr 16) and $FF);
    FSP[Offset + 2] := Byte((Value shr 8) and $FF);
    FSP[Offset + 3] := Byte(Value and $FF);
    Exit;
  end;
  if Address = $13FF0014 then
  begin
    // ISViewer is used by libdragon's emulator diagnostics. Bound both buffers.
    var Count := Integer(Min(Value, Cardinal(Length(FDebugBuffer))));
    var Data: TBytes;
    SetLength(Data, Count);
    for var I := 0 to Count - 1 do
      Data[I] := FDebugBuffer[I];
    FDebugOutput := FDebugOutput + TEncoding.UTF8.GetString(Data);
    if Length(FDebugOutput) > 65536 then
      FDebugOutput := Copy(FDebugOutput, Length(FDebugOutput) - 65535, 65536);
    Exit;
  end;
  if (Address >= $13FF0020) and (Address < $13FF0220) then
  begin
    inherited Write32(Address, Value);
    Exit
  end;
  if Address = $08010000 then
  begin
    if FSaveType in [TN64SaveType.Auto, TN64SaveType.FlashRAM] then
      FlashCommand(Value);
    Exit;
  end;
  if (Address < $800000) or ((Address >= $04000000) and (Address < $04002000)) or
    ((Address >= $08000000) and (Address < $08008000)) or
    ((Address >= $1FC007C0) and (Address < $1FC00800)) then
  begin
    inherited Write32(Address, Value);
    Exit
  end;
  if Address = $04080000 then
  begin
    FSPPC := Value and $FFC;
    FRSP.ResetPipeline;
    Exit
  end;
  if (Address >= $04040000) and (Address < $04040020) then
  begin
    var I := (Address - $04040000) div 4;
    case I of
      0: FPendingSPAddress := Value and $1FFF;
      1: FPendingRAMAddress := Value and $FFFFFF;
      2, 3:
        SPDMA(I = 3, Value);
      4:
        begin
          var S := FReg[0, 4];
          if (Value and 3) = 1 then S := S and not 1;
          if (Value and 3) = 2 then S := S or 1;
          if (Value and 4) <> 0 then
            S := S and not 2;
          if (Value and $18) = 8 then SetInterrupts(FReg[2, 2] and not 1);
          if (Value and $18) = 16 then SetInterrupts(FReg[2, 2] or 1);
          for var J := 0 to 9 do
          begin
            var Flag := Cardinal(1) shl (J + 5);
            var Clear := Cardinal(1) shl (J * 2 + 5);
            if J < 2 then
              Flag := Cardinal(1) shl (J + 5);
            if (Value and (Clear or (Clear shl 1))) = Clear then S := S and not Flag;
            if (Value and (Clear or (Clear shl 1))) = (Clear shl 1) then S := S or Flag;
          end;
          FReg[0, 4] := S;
          if (S and 1) = 0 then ScheduleRSP else FTimeline.Cancel(TN64EventKind.RSPClock);
        end;
      7:
        FReg[0, 7] := 0;
    end;
    Exit;
  end;
  if (Address >= $04100000) and (Address < $04900000) then
  begin
    var Bank := (Address - $04000000) div $100000;
    if Bank = 2 then
      Exit;
    if Bank >= 3 then
      Dec(Bank);
    var I := (Address and $FFFFF) div 4;
    if I >= 16 then
      Exit;
    case Bank of
      1:
        case I of
          0:
            if (FReg[1, 3] and $400) = 0 then
            begin
              FReg[1, 0] := Value and $FFFFF8;
              FReg[1, 3] := FReg[1, 3] or $400
            end;
          1:
            begin
              FReg[1, 1] := Value and $FFFFF8;
              if (FReg[1, 3] and $400) <> 0 then
              begin
                FReg[1, 2] := FReg[1, 0];
                FReg[1, 3] := FReg[1, 3] and not $400
              end;
              ProcessRDP;
            end;
          3:
            begin
              for var J := 0 to 2 do
              begin
                var Clear := (Value and (Cardinal(1) shl (J * 2))) <> 0;
                var SetFlag := (Value and (Cardinal(2) shl (J * 2))) <> 0;
                if Clear <> SetFlag then
                  if Clear then
                    FReg[1, 3] := FReg[1, 3] and not (Cardinal(1) shl J)
                  else
                    FReg[1, 3] := FReg[1, 3] or (Cardinal(1) shl J);
              end;
              if (Value and $40) <> 0 then
                FReg[1, 7] := 0;
              if (Value and $80) <> 0 then
                FReg[1, 6] := 0;
              if (Value and $100) <> 0 then
                FReg[1, 5] := 0;
              if (Value and $200) <> 0 then
                FReg[1, 4] := 0;
              if (FReg[1, 3] and 2) = 0 then
                ProcessRDP;
            end;
        end;
      2:
        case I of
          0:
            begin
              FReg[2, 0] := (FReg[2, 0] and not $7F) or (Value and $7F);
              if (Value and $800) <> 0 then
                SetInterrupts(FReg[2, 2] and not $20);
            end;
          3:
            for var J := 0 to 5 do
            begin
              if (Value and (Cardinal(1) shl (J * 2))) <> 0 then
                FReg[2, 3] := FReg[2, 3] and not (Cardinal(1) shl J);
              if (Value and (Cardinal(2) shl (J * 2))) <> 0 then
                FReg[2, 3] := FReg[2, 3] or (Cardinal(1) shl J);
            end;
        end;
      3:
        if I = 4 then
          SetInterrupts(FReg[2, 2] and not 8)
        else
          FReg[3, I] := Value;
      4:
        case I of
          0:
            FReg[4, 0] := Value and $FFFFF8;
          1:
            if FAILength = 0 then
            begin
              FAIAddress := FReg[4, 0];
              FAILength := Value and $3FFF8;
              FAIProgress := 0;
              ScheduleAI;
            end
            else if FAINextLength = 0 then
            begin
              FAINextAddress := FReg[4, 0];
              FAINextLength := Value and $3FFF8;
            end;
          3:
            SetInterrupts(FReg[2, 2] and not 4);
          2:
            begin
              if (FReg[4, 2] and 1) = 0 then FAIAnchorTick := FTimeline.Now;
              FReg[4, 2] := Value and 1;
              if (Value and 1) = 0 then FTimeline.Cancel(TN64EventKind.AIConsume) else ScheduleAI;
            end;
          4:
            begin
              FReg[4, 4] := Value and $3FFF;
              FTimeline.Cancel(TN64EventKind.AIConsume); FAIDACPhase := 0;
              FAIAnchorTick := FTimeline.Now; ScheduleAI;
            end;
        else
          FReg[4, I] := Value;
        end;
      5:
        begin
          // Only PI_STATUS accepts writes while either DMA direction is busy.
          if (I <> 4) and FPITransfer.Active then
          begin FReg[5, 4] := FReg[5, 4] or 4; Exit end;
          case I of
          0: FReg[5, 0] := Value and $FFFFFE;
          1: FReg[5, 1] := Value and $FFFFFFFE;
          2, 3:
            PIDMA(I = 2, Value);
          4:
            begin
              if (Value and 2) <> 0 then
              begin SetInterrupts(FReg[2, 2] and not $10); FReg[5, 4] := FReg[5, 4] and not 8 end;
              if (Value and 1) <> 0 then
              begin
                FPITransfer := Default(TN64PITransfer);
                FTimeline.Cancel(TN64EventKind.PITransfer); FReg[5, 4] := FReg[5, 4] and not 5;
              end;
            end;
          5, 6, 9, 10: FReg[5, I] := Value and $FF;
          7, 11: FReg[5, I] := Value and 15;
          8, 12: FReg[5, I] := Value and 3;
          end;
        end;
      7:
        case I of
          1, 4:
            SIDMA(I = 4);
          6:
            begin
              SetInterrupts(FReg[2, 2] and not 2);
              FReg[7, 6] := FReg[7, 6] and not $1000;
            end;
        else
          FReg[7, I] := Value;
        end;
    else
      FReg[Bank, I] := Value;
    end;
  end;
end;

procedure TN64Console.SetInterrupts(Value: Cardinal);
begin
  if FReg[2, 2] = Value then Exit;
  FReg[2, 2] := Value;
  if TraceEnabled then Trace(TN64TraceKind.InterruptChange, FCPU.PC, $04300008, Value);
end;

procedure TN64Console.SPDMA(Writing: Boolean; Value: Cardinal);
begin
  if FSPQueued.Active then Exit;
  var Transfer := Default(TN64SPTransfer);
  Transfer.Active := True; Transfer.Writing := Writing;
  Transfer.Size := ((Value and $FFF) or 7) + 1;
  Transfer.Blocks := ((Value shr 12) and $FF) + 1;
  Transfer.Skip := (Value shr 20) and $FF8; Transfer.Control := Value;
  Transfer.Local := FPendingSPAddress and $1FF8;
  Transfer.RAM := FPendingRAMAddress and $FFFFF8;
  if FSPTransfer.Active then
  begin FSPQueued := Transfer; FReg[0, 5] := 1; FReg[0, 4] := FReg[0, 4] or 8 end
  else
  begin
    FSPTransfer := Transfer; FReg[0, 6] := 1;
    FReg[0, 4] := FReg[0, 4] or 4;
    FReg[0, 0] := Transfer.Local; FReg[0, 1] := Transfer.RAM;
    FReg[0, 2 + Ord(Writing)] := Value;
    // SGI RSP programmer's guide p96: 6-12 RCP clocks setup, then 8 B/clock.
    // Use the documented minimum setup in this functional arbitration model.
    FTimeline.Schedule(TN64EventKind.SPTransfer, 11);
  end;
  if TraceEnabled then Trace(TN64TraceKind.DMAStart, FCPU.PC, $04040008 + Ord(Writing) * 4, Value);
end;

procedure TN64Console.PIDMA(Writing: Boolean; Value: Cardinal);
begin
  if FPITransfer.Active then begin FReg[5, 4] := FReg[5, 4] or 4; Exit end;
  FPITransfer := Default(TN64PITransfer);
  FPITransfer.Active := True; FPITransfer.Writing := Writing;
  FPITransfer.RAM := FReg[5, 0] and $FFFFFE;
  FPITransfer.Cart := FReg[5, 1] and $FFFFFFFE;
  FPITransfer.Length := (Value and $FFFFFF) + 1;
  FPITransfer.Flash := HasFlash and (FPITransfer.Cart >= $08000000) and (FPITransfer.Cart < $08020000);
  FPITransfer.FlashMode := FFlashMode; FPITransfer.FlashStatus := FFlashStatus;
  var Domain := 5;
  if (FPITransfer.Cart >= $05000000) and (FPITransfer.Cart < $10000000) then Domain := 9;
  FPITransfer.Latency := FReg[5, Domain] and $FF;
  FPITransfer.PulseWidth := FReg[5, Domain + 1] and $FF;
  FPITransfer.PageSize := FReg[5, Domain + 2] and 15;
  FPITransfer.ReleaseDuration := FReg[5, Domain + 3] and 3;
  FPITransfer.ClockPhase := 1; // ceil of cumulative RCP clocks * 3/2, without per-beat drift.
  FPITransfer.FirstBlock := True; FPITransfer.MaxBlockSize := 128;
  FPITransfer.BlockRAM := FPITransfer.RAM;
  if not Writing and not FPITransfer.Flash then PreparePIBlock;
  FReg[5, 2 + Ord(not Writing)] := Value and $FFFFFF;
  FReg[5, 4] := FReg[5, 4] or 1;
  FTimeline.Schedule(TN64EventKind.PITransfer, PIBeatCycles);
  if TraceEnabled then Trace(TN64TraceKind.DMAStart, FCPU.PC, $04600008 + Ord(not Writing) * 4, Value);
end;

function TN64Console.HasFlash: Boolean;
begin
  Result := (FSaveType = TN64SaveType.FlashRAM) or ((FSaveType = TN64SaveType.Auto) and
    (FFlashUsed or (FDetectedSaveType = TN64SaveType.FlashRAM)));
end;

procedure TN64Console.FlashCommand(Value: Cardinal);
begin
  if not (Value shr 24 in [0, $4B, $78, $A5, $B4, $D2, $E1, $F0]) then
    Exit;
  FFlashUsed := True;
  case Value shr 24 of
    $E1:
      begin
        FFlashMode := 4;
        FFlashStatus := $1111800100C2001E
      end;
    $F0, 0:
      begin
        FFlashMode := 3;
        FFlashStatus := $11118004F0000000
      end;
    $4B:
      FFlashOffset := (Value and $FFFF) * 128;
    $78:
      begin
        FFlashMode := 1;
        FFlashStatus := $1111800800C2001E
      end;
    $B4:
      begin
        FFlashMode := 2;
        FFlashReady := False
      end;
    $A5:
      begin
        FFlashOffset := (Value and $FFFF) * 128;
        FFlashStatus := $1111800400C2001E
      end;
    $D2:
      begin
        if UInt64(FFlashOffset) + 128 <= Cardinal(Length(FFlashData)) then
          if (FFlashMode = 1) or ((FFlashMode = 2) and FFlashReady) then
          begin
            for var I := 0 to 127 do
              if FFlashMode = 1 then
                FFlashData[FFlashOffset + Cardinal(I)] := $FF
              else
                FFlashData[FFlashOffset + Cardinal(I)] := FFlashBuffer[I];
            FSaveDirty := True;
          end;
        FFlashMode := 0;
        FFlashReady := False;
      end;
  end;
end;

procedure TN64Console.ConfigureSaveType(Value: TN64SaveType);
begin
  FSaveType := Value
end;

function TN64Console.EEPROMSize: Integer;
begin
  Result := 0;
  if FSaveType = TN64SaveType.Auto then
  begin
    if FDetectedSaveType = TN64SaveType.EEPROM4K then
      Result := 512;
    if FDetectedSaveType = TN64SaveType.EEPROM16K then
      Result := 2048;
  end;
  if FSaveType = TN64SaveType.EEPROM4K then
    Result := 512;
  if FSaveType = TN64SaveType.EEPROM16K then
    Result := 2048;
  if HasFlash then
    Result := 0;
end;

function PakCRC(const Data: TBytes; Offset: Integer): Byte;
begin
  var C: Cardinal := 0;
  for var I := 0 to 32 do
    for var B := 7 downto 0 do
    begin
      var Top := C and $80;
      C := (C shl 1) and $FF;
      if (I < 32) and ((Data[Offset + I] and (1 shl B)) <> 0) then
        C := C or 1;
      if Top <> 0 then
        C := C xor $85;
    end;
  Result := Byte(C);
end;

procedure TN64Console.FormatControllerPaks;
const
  Copies: array[0..3] of Integer = ($20, $60, $80, $C0);
begin
  for var Port := 0 to 3 do
  begin
    var Base := 2048 + 32768 + Port * 32768;
    var ID: array[0..31] of Byte;
    for var I := 0 to 27 do
      ID[I] := Byte((I * 17 + Port * 31) and $FF);
    ID[24] := $FF;
    ID[25] := $FF;
    ID[26] := 1;
    ID[27] := 0;
    var Sum: Cardinal := 0;
    var Inverse: Cardinal := 0;
    for var I := 0 to 13 do
    begin
      var Value := (Cardinal(ID[I * 2]) shl 8) or ID[I * 2 + 1];
      Sum := Sum + Value;
      Inverse := Inverse + (Value xor $FFFF);
    end;
    ID[28] := Byte((Sum shr 8) and $FF);
    ID[29] := Byte(Sum and $FF);
    ID[30] := Byte((Inverse shr 8) and $FF);
    ID[31] := Byte(Inverse and $FF);
    FSave[Base] := $81;
    for var I := 1 to 31 do
      FSave[Base + I] := Byte(I);
    for var Offset in Copies do
      for var I := 0 to 31 do
        FSave[Base + Offset + I] := ID[I];
    // Pages 1/2 contain matching inode tables; pages 5..127 are free (0003).
    for var Page := 1 to 2 do
    begin
      for var I := 5 to 127 do
        FSave[Base + Page * 256 + I * 2 + 1] := 3;
      FSave[Base + Page * 256 + 1] := (123 * 3) and $FF;
    end;
  end;
end;

procedure TN64Console.CICChallenge;
const
  Lookup: array[0..1, 0..15] of Byte = (
    (4, 7, 10, 7, 14, 5, 14, 1, 12, 15, 8, 15, 6, 3, 6, 9),
    (4, 1, 10, 7, 14, 5, 14, 1, 12, 9, 8, 5, 6, 3, 12, 9));
begin
  var Response: array[0..14] of Byte;
  for var I := 0 to 14 do
    Response[I] := 0;
  var Key := 11;
  var Table := 0;
  for var I := 0 to 29 do
  begin
    var Challenge := Integer(FPIF[48 + I div 2]);
    if not Odd(I) then
      Challenge := Challenge shr 4
    else
      Challenge := Challenge and 15;
    var Value := (Key + 5 * Challenge) and 15;
    if Odd(I) then
      Response[I div 2] := Response[I div 2] or Byte(Value)
    else
      Response[I div 2] := Byte(Value shl 4);
    Key := Lookup[Table, Value];
    var Sign := Value shr 3;
    var Magnitude := Value and 7;
    if Sign <> 0 then
      Magnitude := Magnitude xor 7;
    var Next := 1 - Sign;
    if Magnitude mod 3 = 1 then
      Next := Sign;
    if (Table = 1) and (Value in [1, 9]) then
      Next := 1;
    if (Table = 1) and (Value in [11, 14]) then
      Next := 0;
    Table := Next;
  end;
  FPIF[46] := 0;
  FPIF[47] := 0;
  for var I := 0 to 14 do
    FPIF[48 + I] := Response[I];
  FPIF[63] := 0;
end;

procedure TN64Console.PIFCommand;
begin
  if FPIF[63] > 1 then
  begin
    case FPIF[63] of
      2:
        CICChallenge;
      8:
        begin
          FPIF[63] := 0;
          FReg[7, 6] := $1000;
          SetInterrupts(FReg[2, 2] or 2)
        end;
      $10:
        FPIF[63] := 0;
      $30:
        FPIF[63] := $80;
      $C0:
        for var I := 0 to 63 do
          FPIF[I] := 0;
    end;
    Exit;
  end;
  if (FPIF[63] and 1) = 0 then
    Exit;
  var Pos := 0;
  var Port := 0;
  while Pos < 63 do
  begin
    var Tx := FPIF[Pos];
    if Tx in [$FD, $FE] then
      Break;
    if Tx in [$FF, $B4, $56, $B8] then
    begin
      Inc(Pos);
      Continue
    end;
    if Tx = 0 then
    begin
      Inc(Pos);
      Inc(Port);
      Continue
    end;
    if Pos + 2 >= 63 then
      Break;
    var Rx := FPIF[Pos + 1] and $3F;
    var Payload := Pos + 2;
    if (Tx > 63) or (Payload + Tx + Rx > 63) then
      Break;
    var Answer := Payload + Tx;
    var Command := FPIF[Payload];
    var Valid := False;
    if Port < 4 then
    begin
      if FInputs[Port].Connected then
        case Command of
          0, $FF:
            if (Tx = 1) and (Rx = 3) then
            begin
              FPIF[Answer] := 5;
              FPIF[Answer + 1] := 0;
              FPIF[Answer + 2] := 1;
              Valid := True
            end;
          1:
            if (Tx = 1) and (Rx = 4) then
            begin
              FPIF[Answer] := Byte(FInputs[Port].Buttons shr 8);
              FPIF[Answer + 1] := Byte(FInputs[Port].Buttons and $FF);
              FPIF[Answer + 2] := Byte((Integer(FInputs[Port].StickX) + 256) and $FF);
              FPIF[Answer + 3] := Byte((Integer(FInputs[Port].StickY) + 256) and $FF);
              Valid := True;
            end;
          2, 3:
            if (Tx >= 3) and (((Command = 2) and (Rx = 33)) or ((Command = 3) and (Tx = 35) and (Rx = 1))) then
            begin
              var Address := ((Integer(FPIF[Payload + 1]) shl 8) or FPIF[Payload + 2]) and $FFE0;
              var Offset := 2048 + 32768 + Port * 32768 + (Address and $7FFF);
              if Command = 2 then
              begin
                for var I := 0 to 31 do
                  if Address < $8000 then
                    FPIF[Answer + I] := FSave[Offset + I]
                  else
                    FPIF[Answer + I] := 0;
                FPIF[Answer + 32] := PakCRC(FPIF, Answer);
              end
              else
              begin
                if Address < $8000 then
                begin
                  for var I := 0 to 31 do
                    FSave[Offset + I] := FPIF[Payload + 3 + I];
                  FSaveDirty := True;
                end;
                FPIF[Answer] := PakCRC(FPIF, Payload + 3);
              end;
              Valid := True;
            end;
        end;
    end
    else if (Port = 4) and (EEPROMSize <> 0) then
      case Command of
        0, $FF:
          if (Tx = 1) and (Rx = 3) then
          begin
            FPIF[Answer] := 0;
            FPIF[Answer + 1] := $80;
            if EEPROMSize = 2048 then
              FPIF[Answer + 1] := $C0;
            FPIF[Answer + 2] := 0;
            Valid := True
          end;
        4:
          if (Tx = 2) and (Rx = 8) and (Integer(FPIF[Payload + 1]) * 8 < EEPROMSize) then
          begin
            for var I := 0 to 7 do
              FPIF[Answer + I] := FSave[FPIF[Payload + 1] * 8 + I];
            Valid := True
          end;
        5:
          if (Tx = 10) and (Rx = 1) and (Integer(FPIF[Payload + 1]) * 8 < EEPROMSize) then
          begin
            for var I := 0 to 7 do
              FSave[FPIF[Payload + 1] * 8 + I] := FPIF[Payload + 2 + I];
            FPIF[Answer] := 0;
            FSaveDirty := True;
            Valid := True
          end;
      end;
    if not Valid then
      FPIF[Pos + 1] := FPIF[Pos + 1] or $80;
    Pos := Answer + Rx;
    Inc(Port);
  end;
  FPIF[63] := 0;
end;

procedure TN64Console.ReadPIFControllers;
begin
  if FPIF[63] = 2 then
    Exit;
  var Pos := 0;
  var Port := 0;
  while Pos < 63 do
  begin
    var Tx := FPIF[Pos];
    if Tx in [$FD, $FE] then
      Break;
    if Tx in [$FF, $B4, $56, $B8] then
    begin
      Inc(Pos);
      Continue
    end;
    if Tx = 0 then
    begin
      Inc(Pos);
      Inc(Port);
      Continue
    end;
    if (Tx > 63) or (Pos + 2 >= 63) then
      Break;
    var Rx := FPIF[Pos + 1] and $3F;
    var Answer := Pos + 2 + Tx;
    if Answer + Rx > 63 then
      Break;
    // Polling must sample live input without replaying EEPROM/pak writes.
    if (Port < 4) and (Tx = 1) and (Rx = 4) and (FPIF[Pos + 2] = 1) then
    begin
      FPIF[Pos + 1] := Rx;
      if FInputs[Port].Connected then
      begin
        FPIF[Answer] := Byte(FInputs[Port].Buttons shr 8);
        FPIF[Answer + 1] := Byte(FInputs[Port].Buttons and $FF);
        FPIF[Answer + 2] := Byte((Integer(FInputs[Port].StickX) + 256) and $FF);
        FPIF[Answer + 3] := Byte((Integer(FInputs[Port].StickY) + 256) and $FF);
      end
      else
        FPIF[Pos + 1] := Rx or $80;
    end;
    Pos := Answer + Rx;
    Inc(Port);
  end;
end;

procedure TN64Console.SIDMA(Writing: Boolean);
begin
  if FSITransfer.Active then begin FReg[7, 6] := FReg[7, 6] or 8; Exit end;
  FSITransfer := Default(TN64SITransfer);
  FSITransfer.Active := True; FSITransfer.Writing := Writing;
  FSITransfer.RAM := FReg[7, 0] and $FFFFF8;
  if not Writing then
  begin
    ReadPIFControllers;
    for var I := 0 to 63 do FSITransfer.Data[I] := FPIF[I];
  end;
  FReg[7, 6] := FReg[7, 6] or 1;
  // Sixteen four-byte beats: timing model is explicit and deterministic.
  // PIF/joybus command execution is a separate action after the write DMA.
  FTimeline.Schedule(TN64EventKind.SITransfer, 256);
  if TraceEnabled then Trace(TN64TraceKind.DMAStart, FCPU.PC, $04800000, FSITransfer.RAM);
end;

function TN64Console.InterruptPending: Boolean;
begin
  Result := (FReg[2, 2] and FReg[2, 3]) <> 0;
end;

function TN64Console.ReadHidden(Address: Cardinal): Byte;
begin
  if Address < Cardinal(Length(FRAM)) then Result := FHiddenRAM[Address shr 1] and 3 else Result := 0;
end;

procedure TN64Console.WriteHidden(Address: Cardinal; Value: Byte);
begin
  if Address < Cardinal(Length(FRAM)) then FHiddenRAM[Address shr 1] := Value and 3;
end;

function TN64Console.GuestTick: UInt64;
begin
  if FTimeline = nil then Result := 0 else Result := FTimeline.Now;
end;

function TN64Console.VideoClock: Cardinal;
begin
  Result := 48681812;
  if FData[$3E] = $42 then Result := 48628316
  else if FramesPerSecond = 50 then Result := 49656530;
end;

procedure TN64Console.ScheduleVI;
begin
  // H_SYNC is the video oscillator period, not a CPU instruction count.
  var Numerator := UInt64(93750000) * ((FReg[3, 7] and $FFF) + 1) + FVIPhase;
  var Denominator := UInt64(VideoClock) * 2;
  var Delay := Numerator div Denominator;
  FVIPhase := Numerator mod Denominator;
  if Delay = 0 then Delay := 1;
  FTimeline.Schedule(TN64EventKind.VIHalfLine, Delay);
end;

procedure TN64Console.ScheduleOutput;
begin
  Inc(FAudioClock, 93750000);
  var Delay := Cardinal(FAudioClock div 48000);
  FAudioClock := FAudioClock mod 48000;
  FTimeline.Schedule(TN64EventKind.OutputSample, Delay);
end;

procedure TN64Console.ScheduleAI;
  function AddMod(A, B, Modulus: UInt64): UInt64;
  begin
    if A >= Modulus - B then Result := A - (Modulus - B) else Result := A + B;
  end;
  function MultiplyMod(A: UInt64; B: Cardinal; Modulus: UInt64): UInt64;
  begin
    Result := 0; A := A mod Modulus;
    while B <> 0 do
    begin
      if (B and 1) <> 0 then Result := AddMod(Result, A, Modulus);
      A := AddMod(A, A, Modulus); B := B shr 1;
    end;
  end;
begin
  if ((FReg[4, 2] and 1) = 0) or FTimeline.Pending(TN64EventKind.AIConsume) then Exit;
  // An empty, silent FIFO has no observable completion event. Preserve the DAC
  // oscillator through its anchor instead of scheduling millions of empty ticks.
  if (FAILength = 0) and (FLastLeft = 0) and (FLastRight = 0) then Exit;
  var Period := UInt64(93750000) * ((FReg[4, 4] and $3FFF) + 1);
  var Phase := MultiplyMod(FTimeline.Now - FAIAnchorTick, VideoClock, Period);
  var Numerator := Period - Phase;
  var Delay := (Numerator + VideoClock - 1) div VideoClock;
  FTimeline.Schedule(TN64EventKind.AIConsume, Delay);
end;

procedure TN64Console.ScheduleRSP;
begin
  if ((FReg[0, 4] and 1) <> 0) or FTimeline.Pending(TN64EventKind.RSPClock) then Exit;
  FRSPPhase := FRSPPhase xor 1;
  // 62.5 MHz RCP versus 93.75 MHz CPU: alternate two and one CPU clocks.
  var Delay: Cardinal := 1;
  if FTimeline.Now mod 3 = 0 then Delay := 2;
  FTimeline.Schedule(TN64EventKind.RSPClock, Delay);
end;

procedure TN64Console.ConsumeAI;
begin
  if (FReg[4, 2] and 1) = 0 then Exit;
  if FAILength = 0 then begin FLastLeft := 0; FLastRight := 0 end
  else
  begin
    var Address := (FAIAddress + FAIProgress) and $FFFFFF;
    FLastLeft := SmallInt(SignedValue(SX((Cardinal(Read8(Address)) shl 8) or Read8(Address + 1), 16)));
    FLastRight := SmallInt(SignedValue(SX((Cardinal(Read8(Address + 2)) shl 8) or Read8(Address + 3), 16)));
    Inc(FAIProgress, 4);
    if FAIProgress = FAILength then
    begin
      SetInterrupts(FReg[2, 2] or 4);
      FAIAddress := FAINextAddress; FAILength := FAINextLength;
      FAINextLength := 0; FAIProgress := 0;
      if TraceEnabled then Trace(TN64TraceKind.DMAComplete, FCPU.PC, $04500004, FAILength);
    end;
  end;
  ScheduleAI;
end;

procedure TN64Console.SPTransferBeat;
begin
  if not FSPTransfer.Active then Exit;
  for var I := 0 to 7 do
  begin
    var Local := (FSPTransfer.Local and $1000) or ((FSPTransfer.Local + FSPTransfer.Position + Cardinal(I)) and $FFF);
    var RAM := (FSPTransfer.RAM + FSPTransfer.Position + Cardinal(I)) and $FFFFFF;
    if FSPTransfer.Writing then Write8(RAM, FSP[Local]) else FSP[Local] := Read8(RAM);
  end;
  Inc(FSPTransfer.Position, 8);
  if FSPTransfer.Position = FSPTransfer.Size then
  begin
    FSPTransfer.Local := (FSPTransfer.Local and $1000) or ((FSPTransfer.Local + FSPTransfer.Size) and $FFF);
    FSPTransfer.RAM := (FSPTransfer.RAM + FSPTransfer.Size) and $FFFFFF;
    Dec(FSPTransfer.Blocks); FSPTransfer.Position := 0;
    if FSPTransfer.Blocks > 0 then FSPTransfer.RAM := (FSPTransfer.RAM + FSPTransfer.Skip) and $FFFFFF;
  end;
  FReg[0, 0] := FSPTransfer.Local;
  FReg[0, 1] := FSPTransfer.RAM;
  if FSPTransfer.Blocks = 0 then
  begin
    FReg[0, 2] := (FSPTransfer.Control and $FF800000) or $FF8;
    FReg[0, 3] := FReg[0, 2];
    if TraceEnabled then Trace(TN64TraceKind.DMAComplete, FCPU.PC, $04040000, FSPTransfer.RAM);
    FSPTransfer := FSPQueued; FSPQueued := Default(TN64SPTransfer);
    FReg[0, 5] := 0; FReg[0, 4] := FReg[0, 4] and not 8;
    if not FSPTransfer.Active then
    begin FReg[0, 6] := 0; FReg[0, 4] := FReg[0, 4] and not 4; Exit end;
    FReg[0, 0] := FSPTransfer.Local; FReg[0, 1] := FSPTransfer.RAM;
    FReg[0, 2 + Ord(FSPTransfer.Writing)] := FSPTransfer.Control;
  end;
  // Indexed eight-byte DMA beats; bus arbitration remains a functional model.
  var Delay: Cardinal := 1;
  if FTimeline.Now mod 3 = 0 then Delay := 2;
  FTimeline.Schedule(TN64EventKind.SPTransfer, Delay);
end;

procedure TN64Console.PreparePIBlock;
begin
  // PI first fills a 128-byte cartridge buffer. RDRAM rows end at 0x800.
  // The first unaligned block shortens the write twice; these holes and the
  // following short block are visible in rasky's physical-hardware vectors.
  var Misalignment := FPITransfer.BlockRAM and 7;
  var RowRemaining := $800 - (FPITransfer.BlockRAM and $7FF);
  FPITransfer.BlockLength := Min(FPITransfer.Length - FPITransfer.Position,
    Min(FPITransfer.MaxBlockSize - Misalignment, RowRemaining));
  var Written := Integer(FPITransfer.BlockLength) - Integer(Misalignment);
  if Written < 0 then Written := 0;
  if not (FPITransfer.FirstBlock and (FPITransfer.BlockLength < 127 - Misalignment)) then
    Written := (Written + 1) and not 1;
  FPITransfer.BlockWriteSize := Cardinal(Written);
  FPITransfer.BlockRead := 0; FPITransfer.BlockWritten := 0; FPITransfer.Stage := 0;
end;

function TN64Console.PIBeatCycles: Cardinal;
begin
  var RCPCycles: Cardinal;
  if FPITransfer.Stage = 1 then RCPCycles := 1 // peak RDRAM write burst: 8 bytes/RCP clock
  else
  begin
    var Bytes := Min(Cardinal(8), FPITransfer.Length - FPITransfer.Position);
    if not FPITransfer.Writing and not FPITransfer.Flash then
      Bytes := Min(Cardinal(8), ((FPITransfer.BlockLength + 1) and not Cardinal(1)) - FPITransfer.BlockRead);
    RCPCycles := ((Bytes + 1) div 2) * (FPITransfer.PulseWidth + FPITransfer.ReleaseDuration + 2);
    var Page := Cardinal(1) shl (FPITransfer.PageSize + 2);
    for var I := 0 to Integer((Bytes + 1) div 2) - 1 do
    begin
      var Offset := FPITransfer.Position + Cardinal(I * 2);
      if (Offset = 0) or ((Add32(FPITransfer.Cart, Offset) and (Page - 1)) = 0) then
        Inc(RCPCycles, FPITransfer.Latency + 1);
    end;
  end;
  var Numerator := RCPCycles * 3 + FPITransfer.ClockPhase;
  Result := Numerator div 2; FPITransfer.ClockPhase := Numerator and 1;
  if Result = 0 then Result := 1;
end;

procedure TN64Console.CompletePI;
begin
  if FPITransfer.Flash and FPITransfer.Writing and (FPITransfer.FlashMode = 2) then
    FFlashReady := FPITransfer.Length >= 128;
  FPITransfer.Active := False; FReg[5, 4] := (FReg[5, 4] and not 1) or 8;
  SetInterrupts(FReg[2, 2] or $10);
  if TraceEnabled then Trace(TN64TraceKind.DMAComplete, FCPU.PC, $04600000, FPITransfer.Length);
end;

procedure TN64Console.FinishPIBlock;
begin
  var Misalignment := FPITransfer.BlockRAM and 7;
  var RowRemaining := $800 - (FPITransfer.BlockRAM and $7FF);
  FPITransfer.BlockRAM := (FPITransfer.BlockRAM + FPITransfer.BlockWriteSize + 7) and $FFFFF8;
  FReg[5, 0] := FPITransfer.BlockRAM;
  if FPITransfer.BlockLength <= 8 then FReg[5, 3] := 127 - Misalignment else FReg[5, 3] := 127;
  FPITransfer.FirstBlock := False;
  if RowRemaining < 8 then FPITransfer.MaxBlockSize := 128 - Misalignment else FPITransfer.MaxBlockSize := 128;
  if FPITransfer.Position >= FPITransfer.Length then CompletePI else PreparePIBlock;
end;

procedure TN64Console.PITransferBeat;
begin
  if not FPITransfer.Active then Exit;
  if not FPITransfer.Writing and not FPITransfer.Flash then
  begin
    if FPITransfer.Stage = 0 then
    begin
      var Bytes := Min(Cardinal(8), ((FPITransfer.BlockLength + 1) and not Cardinal(1)) - FPITransfer.BlockRead);
      for var I := 0 to Integer(Bytes) - 1 do
        FPITransfer.Buffer[FPITransfer.BlockRead + Cardinal(I)] := Read8(Add32(FPITransfer.Cart, FPITransfer.Position + Cardinal(I)));
      Inc(FPITransfer.Position, Bytes); Inc(FPITransfer.BlockRead, Bytes);
      FReg[5, 1] := Add32(FPITransfer.Cart, FPITransfer.Position);
      if FPITransfer.BlockRead = ((FPITransfer.BlockLength + 1) and not Cardinal(1)) then
        if FPITransfer.BlockWriteSize = 0 then FinishPIBlock else FPITransfer.Stage := 1;
    end
    else
    begin
      var Bytes := Min(Cardinal(8), FPITransfer.BlockWriteSize - FPITransfer.BlockWritten);
      for var I := 0 to Integer(Bytes) - 1 do
        Write8((FPITransfer.BlockRAM + FPITransfer.BlockWritten + Cardinal(I)) and $FFFFFF,
          FPITransfer.Buffer[FPITransfer.BlockWritten + Cardinal(I)]);
      Inc(FPITransfer.BlockWritten, Bytes);
      FReg[5, 0] := (FPITransfer.BlockRAM + FPITransfer.BlockWritten) and $FFFFFF;
      if FPITransfer.BlockWritten = FPITransfer.BlockWriteSize then FinishPIBlock;
    end;
    if FPITransfer.Active then FTimeline.Schedule(TN64EventKind.PITransfer, PIBeatCycles);
    Exit;
  end;
  // Cartridge writes and Flash's status/data protocol retain their own path.
  var Bytes := Min(Cardinal(8), FPITransfer.Length - FPITransfer.Position);
  for var I := 0 to Integer(Bytes) - 1 do
  begin
    var Offset := FPITransfer.Position + Cardinal(I);
    var RAM := (FPITransfer.RAM + Offset) and $FFFFFF;
    var Cart := Add32(FPITransfer.Cart, Offset);
    if FPITransfer.Flash then
    begin
      if FPITransfer.Writing then
      begin
        if (FPITransfer.FlashMode = 2) and (Offset < 128) then FFlashBuffer[Offset] := Read8(RAM);
      end
      else
      begin
        var Value: Byte := 0;
        if FPITransfer.FlashMode = 4 then Value := Byte((FPITransfer.FlashStatus shr ((7 - (Offset and 7)) * 8)) and $FF)
        else if FPITransfer.FlashMode = 3 then
        begin
          var Address := UInt64(FPITransfer.Cart - $08000000) * 2 + Offset;
          if Address < Cardinal(Length(FFlashData)) then Value := FFlashData[Address] else Value := $FF;
        end;
        Write8(RAM, Value);
      end;
    end
    else Write8(Cart, Read8(RAM));
  end;
  Inc(FPITransfer.Position, Bytes);
  FReg[5, 0] := (FPITransfer.RAM + FPITransfer.Position) and $FFFFFF;
  FReg[5, 1] := Add32(FPITransfer.Cart, FPITransfer.Position);
  if FPITransfer.Position = FPITransfer.Length then CompletePI
  else FTimeline.Schedule(TN64EventKind.PITransfer, PIBeatCycles);
end;

procedure TN64Console.SITransferBeat;
begin
  if not FSITransfer.Active then Exit;
  for var I := 0 to 3 do
  begin
    var Offset := FSITransfer.Position + Cardinal(I);
    var RAM := (FSITransfer.RAM + Offset) and $FFFFFF;
    if FSITransfer.Writing then FSITransfer.Data[Offset] := Read8(RAM) else Write8(RAM, FSITransfer.Data[Offset]);
  end;
  Inc(FSITransfer.Position, 4);
  if FSITransfer.Position = 64 then
  begin
    if FSITransfer.Writing then
    begin for var I := 0 to 63 do FPIF[I] := FSITransfer.Data[I]; PIFCommand end;
    FSITransfer.Active := False;
    FReg[7, 6] := (FReg[7, 6] and not 1) or $1000;
    SetInterrupts(FReg[2, 2] or 2);
    if TraceEnabled then Trace(TN64TraceKind.DMAComplete, FCPU.PC, $04800000, FSITransfer.RAM);
  end
  else FTimeline.Schedule(TN64EventKind.SITransfer, 256);
end;

procedure TN64Console.RenderFrame(ScanoutField: Integer);
begin
  var Registers: array[0..13] of Cardinal;
  var Pixels: TArray<Cardinal>;
  var Colours: TArray<TAlphaColor>;
  for var I := 0 to 13 do Registers[I] := FReg[3, I];
  Registers[4] := Cardinal((FLine and not 1) or ScanoutField);
  FVI.Render(Registers, FCurrentFrame.Width, FCurrentFrame.Height, Pixels);
  SetLength(Colours, Length(Pixels));
  for var I := 0 to High(Pixels) do Colours[I] := TAlphaColor(Pixels[I]);
  FCurrentFrame.Pixels := Colours;
  FCurrentFrame.FrameNumber := FFrame; FCurrentFrame.FramesPerSecond := FramesPerSecond;
end;

procedure TN64Console.HandleEvent(Kind: TN64EventKind);
begin
  case Kind of
    TN64EventKind.VIHalfLine:
      begin
        Inc(FLine);
        if FLine >= Integer(Max(Cardinal(1), FReg[3, 6] and $3FF)) then
        begin
          // ORIGIN/scale describe the field just scanned. CURRENT must still
          // identify that physical field for VI destination parity, although
          // the guest register advances immediately into the next field.
          var CompletedPhysicalField := FField;
          FLine := 0;
          if (FReg[3, 0] and $40) <> 0 then FField := FField xor 1 else FField := 0;
          FFrame := Add64(FFrame, 1);
          if FVideoOutputEnabled then RenderFrame(CompletedPhysicalField);
        end;
        if FLine = Integer(FReg[3, 3] and $3FF) then SetInterrupts(FReg[2, 2] or 8);
        ScheduleVI;
      end;
    TN64EventKind.OutputSample: begin AudioTick; ScheduleOutput end;
    TN64EventKind.AIConsume: ConsumeAI;
    TN64EventKind.SPTransfer: SPTransferBeat;
    TN64EventKind.PITransfer: PITransferBeat;
    TN64EventKind.SITransfer: SITransferBeat;
    TN64EventKind.RSPClock:
      begin
        // IMEM transfers own the instruction bank until their beat completes.
        if not (FSPTransfer.Active and not FSPTransfer.Writing and ((FSPTransfer.Local and $1000) <> 0)) then RunRSP;
        ScheduleRSP;
      end;
    TN64EventKind.DPInterrupt:
      begin SetInterrupts(FReg[2, 2] or $20); FReg[1, 3] := FReg[1, 3] and not $20 end;
  end;
end;

procedure TN64Console.AdvanceTime(Cycles: Cardinal);
begin
  if UInt64(Cycles) > High(UInt64) - FTimeline.Now then raise ERangeError.Create('N64 guest clock overflow');
  var Target := FTimeline.Now + Cycles;
  while (FTimeline.NextDue <> High(UInt64)) and (FTimeline.NextDue <= Target) do
  begin
    FTimeline.AdvanceTo(FTimeline.NextDue);
    var Event: TN64Event;
    while FTimeline.Pop(Event) do HandleEvent(Event.Kind);
  end;
  FTimeline.AdvanceTo(Target);
end;

procedure TN64Console.AudioTick;
begin
  // Guest DAC consumption has its own clock; this is only the 48 kHz sink.
  var N := Length(FSample);
  if N < 16384 then
  begin SetLength(FSample, N + 2); FSample[N] := FLastLeft; FSample[N + 1] := FLastRight end;
end;

procedure TN64Console.RunInstructions(Count: Integer);
begin
  if Count < 0 then raise EArgumentOutOfRangeException.Create('Negative N64 instruction budget');
  var Remaining := Count;
  while Remaining > 0 do
  begin
    AdvanceTime(0);
    var Executed := 0;
    // The deadline also bounds running RSP and DMA writes to the idle code.
    // SkipIdle validates the branch/NOP pair again after every device event.
    var UntilEvent := FTimeline.NextDue - FTimeline.Now;
    var Limit := Integer(Min(UInt64(Remaining), Min(UntilEvent div FCPU.IdleInstructionClocks, UInt64(High(Integer)))));
    if Limit > 0 then Executed := FCPU.SkipIdle(Limit);
    if Executed = 0 then begin FCPU.Step; Executed := 1 end;
    AdvanceTime(FCPU.CyclesConsumed);
    Dec(Remaining, Executed);
  end;
end;

procedure TN64Console.RunCycles(Cycles: Cardinal);
begin
  if UInt64(Cycles) > High(UInt64) - FTimeline.Now then raise ERangeError.Create('N64 cycle budget overflow');
  var Finish := FTimeline.Now + Cycles;
  while FTimeline.Now < Finish do RunInstructions(1);
end;

procedure TN64Console.RunFrame;
begin
  var Start := FFrame;
  while FFrame = Start do
    RunInstructions(512);
end;

function TN64Console.FramesPerSecond: Double;
begin
  if FData[$3E] in [$44, $46, $48, $49, $4C, $50, $53, $55, $57, $58, $59, $5A] then
    Result := 50
  else
    Result := 60;
end;

function TN64Console.GetFrame: TEmulatorFrame;
begin
  if Length(FCurrentFrame.Pixels) = 0 then RenderFrame(FField);
  Result := FCurrentFrame;
end;

procedure TN64Console.SetInputs(const Inputs: TN64Pads);
begin
  FInputs := Inputs
end;

function TN64Console.TakeSamples: TArray<SmallInt>;
begin
  Result := FSample;
  FSample := nil
end;

function TN64Console.SaveBattery: TBytes;
const
  Magic: AnsiString = 'RMN64F01';
begin
  if not FFlashUsed then
    Result := Copy(FSave)
  else
  begin
    SetLength(Result, 8 + Length(FSave) + Length(FFlashData));
    for var I := 0 to 7 do
      Result[I] := Ord(Magic[I + 1]);
    for var I := 0 to High(FSave) do
      Result[8 + I] := FSave[I];
    for var I := 0 to High(FFlashData) do
      Result[8 + Length(FSave) + I] := FFlashData[I];
  end;
  FSaveDirty := False;
end;

procedure TN64Console.LoadBattery(const Data: TBytes);
const
  Magic: AnsiString = 'RMN64F01';
begin
  if Length(Data) = Length(FSave) then
    FSave := Copy(Data)
  else
  begin
    if Length(Data) <> 8 + Length(FSave) + Length(FFlashData) then
      raise EReadError.Create('Invalid N64 save size');
    for var I := 0 to 7 do
      if Data[I] <> Ord(Magic[I + 1]) then
        raise EReadError.Create('Invalid N64 save header');
    for var I := 0 to High(FSave) do
      FSave[I] := Data[8 + I];
    for var I := 0 to High(FFlashData) do
      FFlashData[I] := Data[8 + Length(FSave) + I];
    FFlashUsed := True;
  end;
  FSaveDirty := False;
end;

procedure TN64Console.SerializeState(State: TStateArchive);
begin
  FCPU.SerializeState(State);
  FRSP.SerializeState(State);
  FRDP.SerializeState(State);
  FVI.SerializeState(State); FTimeline.SerializeState(State);
  State.Field(FHiddenRAM[0], Length(FHiddenRAM));
  State.Field(FSPTransfer, SizeOf(FSPTransfer)); State.Field(FSPQueued, SizeOf(FSPQueued));
  State.Field(FPITransfer, SizeOf(FPITransfer)); State.Field(FSITransfer, SizeOf(FSITransfer));
  State.Field(FPendingSPAddress, SizeOf(FPendingSPAddress)); State.Field(FPendingRAMAddress, SizeOf(FPendingRAMAddress));
  State.Field(FVIPhase, SizeOf(FVIPhase)); State.Field(FAIDACPhase, SizeOf(FAIDACPhase));
  State.Field(FAIAnchorTick, SizeOf(FAIAnchorTick));
  State.Field(FRSPPhase, SizeOf(FRSPPhase));
  State.Field(FLastLeft, SizeOf(FLastLeft)); State.Field(FLastRight, SizeOf(FLastRight));
  State.Field(FCurrentFrame.Width, SizeOf(FCurrentFrame.Width)); State.Field(FCurrentFrame.Height, SizeOf(FCurrentFrame.Height));
  State.Field(FCurrentFrame.FrameNumber, SizeOf(FCurrentFrame.FrameNumber));
  State.Field(FCurrentFrame.FramesPerSecond, SizeOf(FCurrentFrame.FramesPerSecond));
  // Length returns NativeInt; the v4 on-disk count is always signed 32-bit.
  var PixelCount: Integer := Length(FCurrentFrame.Pixels);
  State.Field(PixelCount, SizeOf(PixelCount));
  if State.Loading then
  begin
    if (PixelCount < 0) or (PixelCount > 1024 * 1024) or
      (FCurrentFrame.Width < 0) or (FCurrentFrame.Width > 1024) or
      (FCurrentFrame.Height < 0) or (FCurrentFrame.Height > 1024) or
      (Int64(FCurrentFrame.Width) * FCurrentFrame.Height <> PixelCount) then
      raise EReadError.Create('Invalid N64 cached VI raster');
    SetLength(FCurrentFrame.Pixels, PixelCount);
  end;
  if PixelCount > 0 then State.Field(FCurrentFrame.Pixels[0], PixelCount * SizeOf(Cardinal));
  State.Field(FRAM[0], Length(FRAM));
  State.Field(FSP[0], Length(FSP));
  State.Field(FPIF[0], Length(FPIF));
  State.Field(FSave[0], Length(FSave));
  State.Field(FReg, SizeOf(FReg));
  State.Field(FFrame, SizeOf(FFrame));
  State.Field(FTick, SizeOf(FTick));
  State.Field(FLine, SizeOf(FLine));
  State.Field(FField, SizeOf(FField));
  State.Field(FSPPC, SizeOf(FSPPC));
  State.Field(FAIAddress, SizeOf(FAIAddress));
  State.Field(FAILength, SizeOf(FAILength));
  State.Field(FAIProgress, SizeOf(FAIProgress));
  State.Field(FAIPhase, SizeOf(FAIPhase));
  State.Field(FAINextAddress, SizeOf(FAINextAddress));
  State.Field(FAINextLength, SizeOf(FAINextLength));
  State.Field(FAudioClock, SizeOf(FAudioClock));
  State.Field(FAIDACRemainder, SizeOf(FAIDACRemainder));
  State.Field(FSaveType, SizeOf(FSaveType));
  State.Field(FFlashData, SizeOf(FFlashData));
  State.Field(FFlashBuffer, SizeOf(FFlashBuffer));
  State.Field(FFlashUsed, SizeOf(FFlashUsed));
  State.Field(FFlashReady, SizeOf(FFlashReady));
  State.Field(FFlashMode, SizeOf(FFlashMode));
  State.Field(FFlashOffset, SizeOf(FFlashOffset));
  State.Field(FFlashStatus, SizeOf(FFlashStatus));
  State.Field(FDebugBuffer, SizeOf(FDebugBuffer));
  if State.Loading then
  begin
    FSample := nil;
    FSaveDirty := True;
    if (FVIPhase >= UInt64(VideoClock) * 2) or (FAIDACPhase >= VideoClock) or
      (FAIAnchorTick > FTimeline.Now) or
      (FRSPPhase < 0) or (FRSPPhase > 1) or
      (FLine < 0) or (FLine > 1024) or
      (FField < 0) or (FField > 1) or (FAIProgress > FAILength) or
      (FSPPC > $FFC) or ((FSPPC and 3) <> 0) or (FAIPhase > $7FFF) or
      (FAILength > $3FFF8) or (FAINextLength > $3FFF8) or
      (FAIAddress > $FFFFFF) or (FAINextAddress > $FFFFFF) or (FAIDACRemainder >= 48000) or
      (FAudioClock < 0) or (FAudioClock >= 93750000) then
      raise EReadError.Create('Invalid N64 console snapshot');
    var SaveTypeValue: Cardinal := 0;
    Move(FSaveType, SaveTypeValue, SizeOf(FSaveType));
    if (SaveTypeValue > Ord(High(TN64SaveType))) or (FFlashMode < 0) or (FFlashMode > 4) or
      (FFlashOffset > $FFFF * 128) or ((FFlashOffset and 127) <> 0) then
      raise EReadError.Create('Invalid N64 cartridge snapshot');
    ValidateState;
  end;
end;

procedure TN64Console.ValidateState;
  procedure ValidateSP(const T: TN64SPTransfer);
  begin
    var Flags: array[0..1] of Byte;
    Move(T, Flags, SizeOf(Flags));
    if (Flags[0] > 1) or (Flags[1] > 1) then
      raise EReadError.Create('Invalid N64 SP DMA Boolean');
    if not T.Active then Exit;
    if (T.Local > $1FF8) or ((T.Local and 7) <> 0) or
      (T.RAM > $FFFFF8) or ((T.RAM and 7) <> 0) or
      (T.Size < 8) or (T.Size > 4096) or ((T.Size and 7) <> 0) or
      (T.Blocks = 0) or (T.Blocks > 256) or (T.Position >= T.Size) or
      ((T.Position and 7) <> 0) or (T.Skip > $FF8) or ((T.Skip and 7) <> 0) or
      (T.Size <> ((T.Control and $FFF) or 7) + 1) or
      (T.Blocks > ((T.Control shr 12) and $FF) + 1) or
      (T.Skip <> ((T.Control shr 20) and $FF8)) then
      raise EReadError.Create('Invalid N64 SP DMA snapshot');
  end;
  procedure ExpectEvent(Kind: TN64EventKind; Expected: Boolean);
  begin
    if FTimeline.Count(Kind) <> Ord(Expected) then
      raise EReadError.Create('Inconsistent N64 device event snapshot');
  end;
begin
  ValidateSP(FSPTransfer); ValidateSP(FSPQueued);
  // Inspect stored bytes: the compiler may assume a Boolean is already 0/1
  // and eliminate an Ord(Boolean) range check on malformed snapshot data.
  var PIFlags: array[0..3] of Byte; var SIFlags: array[0..1] of Byte;
  var FlashUsed, FlashReady: Byte;
  Move(FPITransfer, PIFlags, SizeOf(PIFlags)); Move(FSITransfer, SIFlags, SizeOf(SIFlags));
  Move(FFlashUsed, FlashUsed, 1); Move(FFlashReady, FlashReady, 1);
  if (PIFlags[0] > 1) or (PIFlags[1] > 1) or (PIFlags[2] > 1) or (PIFlags[3] > 1) or
    (SIFlags[0] > 1) or (SIFlags[1] > 1) or (FlashUsed > 1) or (FlashReady > 1) then
    raise EReadError.Create('Invalid N64 DMA/cartridge Boolean');
  if (FPendingSPAddress > $1FFF) or (FPendingRAMAddress > $FFFFFF) or
    (FSPQueued.Active and (not FSPTransfer.Active or (FSPQueued.Position <> 0))) or
    (FReg[0, 6] <> Cardinal(Ord(FSPTransfer.Active))) or
    (FReg[0, 5] <> Cardinal(Ord(FSPQueued.Active))) or
    (((FReg[0, 4] and 4) <> 0) <> FSPTransfer.Active) or
    (((FReg[0, 4] and 8) <> 0) <> FSPQueued.Active) then
    raise EReadError.Create('Inconsistent N64 SP DMA registers');
  if FPITransfer.Active then
    if (FPITransfer.Length = 0) or (FPITransfer.Length > $1000000) or
      (FPITransfer.Position > ((FPITransfer.Length + 1) and not Cardinal(1))) or
      ((FPITransfer.Position and 1) <> 0) or (FPITransfer.Stage > 1) or
      (FPITransfer.Latency > $FF) or (FPITransfer.PulseWidth > $FF) or
      (FPITransfer.PageSize > 15) or (FPITransfer.ReleaseDuration > 3) or
      (FPITransfer.ClockPhase > 1) or
      (FPITransfer.RAM > $FFFFFE) or ((FPITransfer.RAM and 1) <> 0) or
      ((FPITransfer.Cart and 1) <> 0) or (FPITransfer.FlashMode < 0) or
      (FPITransfer.FlashMode > 4) then
      raise EReadError.Create('Invalid N64 PI DMA snapshot');
  if FPITransfer.Active and FPITransfer.Flash and
    ((FPITransfer.Cart < $08000000) or (FPITransfer.Cart >= $08020000)) then
    raise EReadError.Create('Invalid N64 Flash DMA cartridge address');
  if FPITransfer.Active and (FPITransfer.Writing or FPITransfer.Flash) then
    if (FPITransfer.Position >= FPITransfer.Length) or ((FPITransfer.Position and 7) <> 0) or (FPITransfer.Stage <> 0) then
      raise EReadError.Create('Invalid N64 PI direct transfer phase');
  if FPITransfer.Active and not FPITransfer.Writing and not FPITransfer.Flash then
  begin
    if (FPITransfer.BlockRAM > $FFFFFE) or ((FPITransfer.BlockRAM and 1) <> 0) or
      (FPITransfer.MaxBlockSize < 122) or (FPITransfer.MaxBlockSize > 128) or
      ((FPITransfer.MaxBlockSize and 1) <> 0) or
      (FPITransfer.BlockLength = 0) or (FPITransfer.BlockLength > 128) or
      (FPITransfer.BlockRead > ((FPITransfer.BlockLength + 1) and not Cardinal(1))) or
      ((FPITransfer.BlockRead and 1) <> 0) or (FPITransfer.BlockRead > FPITransfer.Position) or
      (FPITransfer.BlockWriteSize > FPITransfer.BlockLength + 1) or
      (FPITransfer.BlockWritten > FPITransfer.BlockWriteSize) then
      raise EReadError.Create('Invalid N64 PI buffer snapshot');
    var BlockStart := FPITransfer.Position - FPITransfer.BlockRead;
    if (BlockStart >= FPITransfer.Length) or
      (FPITransfer.BlockLength > FPITransfer.Length - BlockStart) then
      raise EReadError.Create('Invalid N64 PI block extent');
    var Misalignment := FPITransfer.BlockRAM and 7;
    var ExpectedWrite := Integer(FPITransfer.BlockLength) - Integer(Misalignment);
    if ExpectedWrite < 0 then ExpectedWrite := 0;
    if not (FPITransfer.FirstBlock and (FPITransfer.BlockLength < 127 - Misalignment)) then
      ExpectedWrite := (ExpectedWrite + 1) and not 1;
    if (FPITransfer.BlockWriteSize <> Cardinal(ExpectedWrite)) or
      (FReg[5, 0] <> ((FPITransfer.BlockRAM + FPITransfer.BlockWritten) and $FFFFFF)) or
      (FReg[5, 1] <> Add32(FPITransfer.Cart, FPITransfer.Position)) then
      raise EReadError.Create('Inconsistent N64 PI buffer readback');
    if ((FPITransfer.Stage = 0) and
      ((FPITransfer.BlockRead = ((FPITransfer.BlockLength + 1) and not Cardinal(1))) or (FPITransfer.BlockWritten <> 0))) or
      ((FPITransfer.Stage = 1) and
      ((FPITransfer.BlockRead <> ((FPITransfer.BlockLength + 1) and not Cardinal(1))) or
       (FPITransfer.BlockWritten >= FPITransfer.BlockWriteSize))) then
      raise EReadError.Create('Inconsistent N64 PI buffer phase');
  end;
  if (((FReg[5, 4] and 1) <> 0) <> FPITransfer.Active) then
    raise EReadError.Create('Inconsistent N64 PI DMA registers');
  if FSITransfer.Active then
    if (FSITransfer.RAM > $FFFFF8) or ((FSITransfer.RAM and 7) <> 0) or
      (FSITransfer.Position >= 64) or ((FSITransfer.Position and 3) <> 0) then
      raise EReadError.Create('Invalid N64 SI DMA snapshot');
  if (((FReg[7, 6] and 1) <> 0) <> FSITransfer.Active) then
    raise EReadError.Create('Inconsistent N64 SI DMA registers');
  if ((FAILength and 7) <> 0) or ((FAINextLength and 7) <> 0) or
    ((FAIProgress and 3) <> 0) or ((FAIAddress and 7) <> 0) or
    ((FAINextAddress and 7) <> 0) or ((FAINextLength > 0) and (FAILength = 0)) then
    raise EReadError.Create('Invalid N64 AI FIFO snapshot');
  ExpectEvent(TN64EventKind.VIHalfLine, True);
  ExpectEvent(TN64EventKind.OutputSample, True);
  ExpectEvent(TN64EventKind.SPTransfer, FSPTransfer.Active);
  ExpectEvent(TN64EventKind.PITransfer, FPITransfer.Active);
  ExpectEvent(TN64EventKind.SITransfer, FSITransfer.Active);
  ExpectEvent(TN64EventKind.RSPClock, (FReg[0, 4] and 1) = 0);
  ExpectEvent(TN64EventKind.DPInterrupt, (FReg[1, 3] and $20) <> 0);
  ExpectEvent(TN64EventKind.AIConsume, ((FReg[4, 2] and 1) <> 0) and
    ((FAILength > 0) or (FLastLeft <> 0) or (FLastRight <> 0)));
  if (FCurrentFrame.FrameNumber > FFrame) or
    ((Length(FCurrentFrame.Pixels) > 0) and
    (IsNan(FCurrentFrame.FramesPerSecond) or IsInfinite(FCurrentFrame.FramesPerSecond) or
    (FCurrentFrame.FramesPerSecond <> FramesPerSecond))) then
    raise EReadError.Create('Invalid N64 cached VI frame metadata');
  for var B in FHiddenRAM do
    if B > 3 then raise EReadError.Create('Invalid N64 RDRAM hidden bits');
end;

procedure TN64Console.ProcessRDP;
begin
  if (FReg[1, 3] and 2) <> 0 then
    Exit;
  // END can temporarily precede CURRENT while the RSP switches its buffers.
  if FReg[1, 1] <= FReg[1, 2] then
    Exit;
  var Consumed: Cardinal;
  if FRDP.Execute(FReg[1, 2], FReg[1, 1], (FReg[1, 3] and 1) <> 0, Consumed) then
  begin
    FReg[1, 3] := FReg[1, 3] or $20;
    var Delay := (FRDP.WorkClocks * 3 + 1) div 2;
    if Delay = 0 then Delay := 1;
    if not FTimeline.Pending(TN64EventKind.DPInterrupt) then FTimeline.Schedule(TN64EventKind.DPInterrupt, Delay);
  end;
  FReg[1, 2] := Consumed;
end;

function TN64Console.RendererDescription: string;
begin
  Result := FRDP.Describe
end;

procedure TN64Console.RunRSP;
begin
  // RSP owns persistent scalar/vector state; scheduled in bounded slices.
  FRSP.ExecuteCycles(FSPPC, FReg[0, 4], FReg[2, 2], 1);
end;

end.

