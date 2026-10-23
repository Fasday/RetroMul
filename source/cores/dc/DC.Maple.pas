unit DC.Maple;

// Maple bus: DMA command lists and the devices on ports A-D. The standard
// controller and its expansion devices (VMU, Puru Puru) answer the frame
// protocol: device info, get/set condition, block read/write, reset.
// Reference: Marcus Comstedt, "Maple bus" and "Controller" pages.
{$IFDEF DC_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$POINTERMATH ON}

interface

uses
  System.SysUtils, System.Classes, Core.Snapshots, DC.Types, DC.Memory;

const
  MapleFuncController = $01000000;
  MapleFuncStorage = $02000000;
  MapleFuncLCD = $04000000;
  MapleFuncClock = $08000000;
  MapleFuncVibration = $00010000;

  // Controller buttons (active low on the bus).
  MapleC = $0001;
  MapleB = $0002;
  MapleA = $0004;
  MapleStart = $0008;
  MapleUp = $0010;
  MapleDown = $0020;
  MapleLeft = $0040;
  MapleRight = $0080;
  MapleZ = $0100;
  MapleY = $0200;
  MapleX = $0400;
  MapleD = $0800;

type
  TDCPad = record
    Buttons: Word;        // Maple* bits set when pressed
    StickX, StickY: Byte; // 0..255, 128 centred
    LeftTrigger, RightTrigger: Byte;
  end;

  TDCMapleDevice = class
  public
    // Handles one frame: the response code and its length in words.
    function Handle(Command, Address: Byte; Data: PCardinal; Words: Integer; Reply: PCardinal;
      out Response: Byte): Integer; virtual; abstract;
    procedure SerializeState(Archive: TStateArchive); virtual;
  end;

  TDCController = class(TDCMapleDevice)
  public
    Pad: TDCPad;
    function Handle(Command, Address: Byte; Data: PCardinal; Words: Integer; Reply: PCardinal;
      out Response: Byte): Integer; override;
  end;

  TDCMaple = class
  private
    FMemory: TDCMemory;
    function DispatchFrame(Port: Integer; Frame: PCardinal; Words: Integer; Reply: PCardinal): Integer;
  public
    // [port, unit]: unit 0 is the main device, 1..5 its expansion sockets.
    Devices: array[0..3, 0..5] of TDCMapleDevice;
    constructor Create(Memory: TDCMemory);
    destructor Destroy; override;
    procedure Attach(Port, AUnit: Integer; Device: TDCMapleDevice);
    // Runs a DMA command table at physical Table; returns the bus words moved.
    function RunDMA(Table: Cardinal): Integer;
    procedure SerializeState(Archive: TStateArchive);
  end;

// Fixed-size ASCII field, padded with spaces, packed into little-endian words.
procedure MapleText(Dest: PByte; const Text: AnsiString; Size: Integer);

implementation

procedure MapleText(Dest: PByte; const Text: AnsiString; Size: Integer);
begin
  for var I := 0 to Size - 1 do
    if I < Length(Text) then
      Dest[I] := Ord(Text[I + 1])
    else
      Dest[I] := $20;
end;

{ TDCMapleDevice }

procedure TDCMapleDevice.SerializeState(Archive: TStateArchive);
begin
end;

{ TDCController }

function TDCController.Handle(Command, Address: Byte; Data: PCardinal; Words: Integer; Reply: PCardinal;
  out Response: Byte): Integer;
begin
  Response := $FE;
  Result := 0;
  case Command of
    1, 2:
      begin
        // Device info: function, three function data words, area, direction,
        // product name, license, standby and maximum power.
        FillChar(Reply^, 28 * 4, 0);
        Reply[0] := MapleFuncController;
        Reply[1] := $000F06FE; // buttons C B A Start, pad, triggers, analog X/Y
        var B := PByte(@Reply[4]);
        B[0] := $FF;
        B[1] := 0;
        MapleText(B + 2, 'Dreamcast Controller', 30);
        MapleText(B + 32, 'Produced By or Under License From SEGA ENTERPRISES,LTD.', 60);
        PWord(B + 92)^ := $01AE;
        PWord(B + 94)^ := $01F4;
        Response := 5;
        Exit(28);
      end;
    3:
      begin
        Response := 7;
        Exit(0);
      end;
    9:
      begin
        if (Words < 1) or (Data[0] <> MapleFuncController) then
        begin
          Response := $FD;
          Exit(0);
        end;
        Reply[0] := MapleFuncController;
        Reply[1] := (not Cardinal(Pad.Buttons) and $FFFF) or (Cardinal(Pad.RightTrigger) shl 16) or
          (Cardinal(Pad.LeftTrigger) shl 24);
        Reply[2] := Cardinal(Pad.StickX) or (Cardinal(Pad.StickY) shl 8) or (Cardinal($80) shl 16) or (Cardinal($80) shl 24);
        Response := 8;
        Exit(3);
      end;
  end;
end;

{ TDCMaple }

constructor TDCMaple.Create(Memory: TDCMemory);
begin
  inherited Create;
  FMemory := Memory;
end;

destructor TDCMaple.Destroy;
begin
  for var P := 0 to 3 do
    for var U := 0 to 5 do
      Devices[P, U].Free;
  inherited;
end;

procedure TDCMaple.Attach(Port, AUnit: Integer; Device: TDCMapleDevice);
begin
  if Devices[Port, AUnit] <> Device then
    Devices[Port, AUnit].Free;
  Devices[Port, AUnit] := Device;
end;

function TDCMaple.DispatchFrame(Port: Integer; Frame: PCardinal; Words: Integer; Reply: PCardinal): Integer;
begin
  // Header: command, recipient, sender, length (words).
  var Header := Frame[0];
  var Command := Byte(Header);
  var Recipient := Byte(Header shr 8);
  var AUnit := 0;
  if (Recipient and $20) = 0 then
    for var Bit := 0 to 4 do
      if (Recipient and (1 shl Bit)) <> 0 then
      begin
        AUnit := Bit + 1;
        Break;
      end;
  var Device := Devices[Port, AUnit];
  if (Device = nil) or (Devices[Port, 0] = nil) then
  begin
    Reply[0] := $FFFFFFFF;
    Exit(1);
  end;
  var Response: Byte;
  var Length := Device.Handle(Command, Recipient, @Frame[1], Words - 1, @Reply[1], Response);
  // The sender field names the device and the sockets that hold expansions.
  var Sender := Byte(Port shl 6);
  if AUnit = 0 then
  begin
    Sender := Sender or $20;
    for var U := 1 to 5 do
      if Devices[Port, U] <> nil then
        Sender := Sender or (1 shl (U - 1));
  end
  else
    Sender := Sender or (1 shl (AUnit - 1));
  Reply[0] := Cardinal(Response) or (Cardinal(Byte(Header shr 16)) shl 8) or (Cardinal(Sender) shl 16) or
    (Cardinal(Length) shl 24);
  Result := Length + 1;
end;

function TDCMaple.RunDMA(Table: Cardinal): Integer;
var
  Frame: array[0..255] of Cardinal;
  Reply: array[0..255] of Cardinal;
begin
  Result := 0;
  var RAM := FMemory.RAM;
  var Address := Table and $FFFFE0;
  for var Guard := 0 to 63 do
  begin
    var Control := PCardinal(RAM + (Address and $FFFFFC))^;
    var Destination := PCardinal(RAM + ((Address + 4) and $FFFFFC))^;
    var Pattern := (Control shr 8) and 7;
    var Port := Integer((Control shr 16) and 3);
    var Words := Integer(Control and $FF) + 1;
    Inc(Address, 8);
    if Pattern = 0 then
    begin
      for var I := 0 to Words - 1 do
        Frame[I] := PCardinal(RAM + ((Address + Cardinal(I) * 4) and $FFFFFC))^;
      Inc(Address, Cardinal(Words) * 4);
      var Count := DispatchFrame(Port, @Frame[0], Words, @Reply[0]);
      var Target := Destination and $FFFFFC;
      for var I := 0 to Count - 1 do
        PCardinal(RAM + ((Target + Cardinal(I) * 4) and $FFFFFC))^ := Reply[I];
      FMemory.TouchRAM(Target, Cardinal(Count) * 4);
      Inc(Result, Words + Count);
    end;
    if (Control and $80000000) <> 0 then
      Break;
  end;
end;

procedure TDCMaple.SerializeState(Archive: TStateArchive);
begin
  for var P := 0 to 3 do
    for var U := 0 to 5 do
    begin
      var Present := Devices[P, U] <> nil;
      Archive.Field(Present, SizeOf(Present));
      if Present <> (Devices[P, U] <> nil) then
        raise EReadError.Create('Dreamcast snapshot Maple devices differ');
      if Present then
        Devices[P, U].SerializeState(Archive);
    end;
end;

end.
