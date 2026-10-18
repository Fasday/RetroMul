unit CPS3.Flash;

// Fujitsu MBM29F016A 2 MiB x8 flash: AMD command-set bus protocol.
interface

uses
  System.SysUtils, Core.Snapshots;

type
  TCPS3Flash = class
  private
    FData: TBytes;
    FBase, FStride, FState: Integer;
    FID, FBypass: Boolean;
  public
    constructor Create(const Data: TBytes; Base, Stride: Integer);
    procedure Reset;
    function Read(Address: Cardinal): Byte;
    // Changed offset/length are chip addresses, for rebuilding opcode views.
    function Write(Address: Cardinal; Value: Byte; out Changed, Count: Integer): Boolean;
    procedure SerializeState(State: TStateArchive);
  end;

implementation

uses
  System.Classes;

constructor TCPS3Flash.Create(const Data: TBytes; Base, Stride: Integer);
begin
  inherited Create;
  FData := Data;
  FBase := Base;
  FStride := Stride;
  Reset;
end;

procedure TCPS3Flash.Reset;
begin
  FState := 0;
  FID := False;
  FBypass := False;
end;

function TCPS3Flash.Read(Address: Cardinal): Byte;
begin
  Address := Address and $1FFFFF;
  if FID then
  begin
    case Address and $FF of
      0:
        Exit($04);
      1:
        Exit($AD);
      2:
        Exit(0);
    end;
    Exit(0);
  end;

  Result := FData[FBase + Integer(Address) * FStride];
end;

function TCPS3Flash.Write(Address: Cardinal; Value: Byte; out Changed, Count: Integer): Boolean;
begin
  Address := Address and $1FFFFF;
  Result := False;
  Changed := 0;
  Count := 0;

  // Programming data can itself be F0: reset is only a command outside the byte-program state.
  if FState = 3 then
  begin
    var At := FBase + Integer(Address) * FStride;
    var B := FData[At] and Value;
    Result := FData[At] <> B;
    FData[At] := B;
    Changed := Address;
    Count := 1;
    FState := 0;
    Exit;
  end;

  if Value = $F0 then
  begin
    Reset;
    Exit;
  end;

  case FState of
    0:
      if FBypass then
      begin
        if Value = $A0 then
          FState := 3
        else if Value = $90 then
          FState := 7;
      end
      else if (Address and $7FF = $555) and (Value = $AA) then
        FState := 1;
    1:
      if (Address and $7FF = $2AA) and (Value = $55) then
        FState := 2
      else
        FState := 0;
    2:
      begin
        FState := 0;
        if Address and $7FF = $555 then
          case Value of
            $90:
              FID := True;
            $A0:
              begin
                FState := 3;
                FID := False;
              end;
            $80:
              begin
                FState := 4;
                FID := False;
              end;
            $20:
              begin
                FBypass := True;
                FID := False;
              end;
          end;
      end;
    4:
      if (Address and $7FF = $555) and (Value = $AA) then
        FState := 5
      else
        FState := 0;
    5:
      if (Address and $7FF = $2AA) and (Value = $55) then
        FState := 6
      else
        FState := 0;
    6:
      begin
        FState := 0;
        if Value = $30 then
        begin
          Changed := Address and $1F0000;
          Count := $10000;
        end
        else if (Address and $7FF = $555) and (Value = $10) then
        begin
          Changed := 0;
          Count := $200000;
        end;
        for var i := Changed to Changed + Count - 1 do
          FData[FBase + i * FStride] := $FF;
        Result := Count <> 0;
      end;
    7:
      begin
        FState := 0;
        if Value = 0 then
          FBypass := False;
      end;
  end;
end;

procedure TCPS3Flash.SerializeState(State: TStateArchive);
begin
  State.Field(FState, SizeOf(FState));
  State.Field(FID, SizeOf(FID));
  State.Field(FBypass, SizeOf(FBypass));

  if (FState < 0) or (FState > 7) then
    raise EReadError.Create('Invalid CPS3 flash command state');
end;

end.

