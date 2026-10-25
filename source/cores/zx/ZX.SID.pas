unit ZX.SID;

interface

uses
  System.SysUtils, C64.Sound.SID, Core.Snapshots;

type
  // Single-SID application interface documented for eLeMeNt ZX / MB03+.
  TZXSID = class
  private
    FChip: TSID;
    FAddress, FParameters: Byte;
    FClock, FChipClock, FChipPhase, FSamplePhase: Integer;
    FLevel: SmallInt;
    procedure SetParameters(Value: Byte);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Reset(Clock, Model: Integer; NTSC: Boolean);
    class function Decodes(Address: Word): Boolean; static;
    procedure WritePort(Address: Word; Value: Byte);
    function ReadPort(Address: Word): Byte;
    procedure Tick;
    function Level: Double;
    procedure SerializeState(State: TStateArchive);
    property Chip: TSID read FChip;
  end;

implementation

uses
  System.Classes;

constructor TZXSID.Create;
begin
  inherited;
  FChip := TSID.Create;
  Reset(3500000, 0, False);
end;

destructor TZXSID.Destroy;
begin
  FChip.Free;
  inherited;
end;

procedure TZXSID.SetParameters(Value: Byte);
begin
  FParameters := Value and 3;
  FChipClock := 985248;
  if (FParameters and 2) <> 0 then
    FChipClock := 1022730; // eZX/MB Programmer's Reference, SID register 1F.
  FChip.Configure(TSIDModel(FParameters and 1), FChipClock);
end;

procedure TZXSID.Reset(Clock, Model: Integer; NTSC: Boolean);
begin
  if (Clock < 1000000) or (Clock > 8000000) or (Model < 0) or (Model > 1) then
    raise EArgumentOutOfRangeException.Create('Invalid eZX/MB SID configuration');
  FClock := Clock;
  FAddress := 0;
  FChipPhase := 0;
  FSamplePhase := 0;
  FLevel := 0;
  SetParameters(Model or (Ord(NTSC) shl 1));
  FChip.Reset;
end;

class function TZXSID.Decodes(Address: Word): Boolean;
begin
  Result := (Address = $6C3B) or (Address = $6D3B);
end;

procedure TZXSID.WritePort(Address: Word; Value: Byte);
begin
  case Address of
    $6C3B:
      FAddress := Value;
    $6D3B:
      case FAddress of
        $00..$1C: FChip.WriteRegister(FAddress, Value);
        $1F: SetParameters(Value);
        // 20 is reserved for optional multiple SIDs. This profile has one chip.
      end;
  end;
end;

function TZXSID.ReadPort(Address: Word): Byte;
begin
  Result := $FF;
  if Address <> $6D3B then
    Exit;
  case FAddress of
    $00..$1C: Result := FChip.ReadRegister(FAddress);
    $1F: Result := FParameters;
    $20: Result := 0;
  end;
end;

procedure TZXSID.Tick;
begin
  Inc(FChipPhase, FChipClock);
  while FChipPhase >= FClock do
  begin
    Dec(FChipPhase, FClock);
    FChip.Clock;
  end;
  Inc(FSamplePhase, 44100);
  if FSamplePhase >= FClock then
  begin
    Dec(FSamplePhase, FClock);
    FLevel := FChip.Sample;
  end;
end;

function TZXSID.Level: Double;
begin
  Result := FLevel / 32768;
end;

procedure TZXSID.SerializeState(State: TStateArchive);
begin
  State.Field(FAddress, SizeOf(FAddress));
  State.Field(FParameters, SizeOf(FParameters));
  State.Field(FClock, SizeOf(FClock));
  State.Field(FChipClock, SizeOf(FChipClock));
  State.Field(FChipPhase, SizeOf(FChipPhase));
  State.Field(FSamplePhase, SizeOf(FSamplePhase));
  State.Field(FLevel, SizeOf(FLevel));
  FChip.SerializeState(State.Field, State.Loading);
  if (FParameters > 3) or (FClock < 1000000) or (FClock > 8000000) or
    (FChipPhase < 0) or (FChipPhase >= FClock) or
    (FSamplePhase < 0) or (FSamplePhase >= FClock) or
    (Ord(FChip.Model) <> Integer(FParameters and 1)) or (FChip.ChipClock <> FChipClock) or
    (FChip.SampleRate <> 44100) then
    raise EReadError.Create('Invalid eZX/MB SID state');
  if (((FParameters and 2) = 0) and (FChipClock <> 985248)) or
    (((FParameters and 2) <> 0) and (FChipClock <> 1022730)) then
    raise EReadError.Create('Mismatched eZX/MB SID clock');
end;

end.
