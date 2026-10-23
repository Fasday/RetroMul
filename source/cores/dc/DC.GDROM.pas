unit DC.GDROM;

// GD-ROM drive on the G1 ATA interface (005F7000..). Packet commands run
// against a TDCDisc image; data reaches the SH-4 by PIO or G1 DMA.
{$IFDEF DC_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, Core.Snapshots, DC.Types, DC.Scheduler, DC.Interrupts;

type
  TDCGDROMState = record
    Status, Error, Features, SectorCount, SectorNumber, ByteCount, DriveSelect, DeviceControl: Cardinal;
    DiscStatus: Cardinal;
  end;

  TDCGDROM = class
  private
    FScheduler: TDCScheduler;
    FInterrupts: TDCInterrupts;
  public
    S: TDCGDROMState;
    constructor Create(Scheduler: TDCScheduler; Interrupts: TDCInterrupts);
    procedure Reset;
    function Read(Offset: Cardinal; Size: Integer): Cardinal;
    procedure Write(Offset, Value: Cardinal; Size: Integer);
    procedure Event;
    // Copies up to Count bytes of pending DMA data; returns the bytes moved.
    function DMARead(Dest: PByte; Count: Integer): Integer;
    procedure SerializeState(Archive: TStateArchive);
  end;

implementation

const
  ATAStatusDRDY = $40;
  ATAStatusDSC = $10;
  DiscNone = 7;

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
  S.DiscStatus := DiscNone;
  S.SectorNumber := DiscNone;
end;

function TDCGDROM.Read(Offset: Cardinal; Size: Integer): Cardinal;
begin
  case Offset and $FF of
    $18: Result := S.Status;
    $84: Result := S.Error;
    $88: Result := S.SectorCount;
    $8C: Result := S.SectorNumber;
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
    $8C: ;
    $90: S.ByteCount := (S.ByteCount and $FF00) or (Value and $FF);
    $94: S.ByteCount := (S.ByteCount and $FF) or ((Value and $FF) shl 8);
    $98: S.DriveSelect := Value and $FF;
    $9C:
      begin
        // Without a disc every command ends with ABRT.
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
end;

end.
