unit GW.CPU;

// Native Sharp LCD MCU. Hardware: Sharp Microcomputers Data Book (1990),
// SM510/SM511/SM512; SM5A pin/PLA evidence cross-checked against MAME (hap).

interface

uses
  System.SysUtils, System.Classes, Core.Snapshots;

{$SCOPEDENUMS ON}
type
  TGWCPUModel = (SM5A, SM5L, SM500, SM510, SM511, SM512);

  TGWCPUState = packed record
    RAM: array[0..127] of Byte;
    Stack: array[0..1] of Word;
    PC, PreviousPC, Op, PreviousOp, Divider: Word;
    A, BL, BM, BMask, Carry, W, S, R, ROut, L, X, Y, BP: Byte;
    Skip, Halt, Gamma, Bleeder, RSub: Boolean;
    O, OX: array[0..8] of Byte;
    CB, MX, MelodyControl, MelodyAddress, MelodyStep, MelodyDuty, MelodyPhase: Byte;
    ClockDivider, ClocksLeft: Byte;
  end;

  TGWCPU = class
  private
    FModel: TGWCPUModel;
    FProgram, FMelody: TBytes;
    FState: TGWCPUState;
    FK: Byte;
    FBA, FB, FWake: Boolean;
    FRMask: Integer;
    function ReadProgram(Address: Word): Byte;
    function RAMAddress: Integer;
    function ReadRAM: Byte;
    procedure WriteRAM(Value: Byte);
    procedure IncrementPC;
    procedure Branch(PU, PM, PL: Integer);
    procedure Push;
    procedure Pop;
    procedure IncrementBL;
    procedure ShiftLCDRegister(Value: Byte; Partial: Boolean = False);
    function Digit: Byte;
    procedure Execute(Op, Param: Byte; var Cycles: Integer);
    procedure ClockSound;
    function GetShiftLCD: Boolean;
    function GetSOutput: Byte;
    function GetROutput: Byte;
  public
    constructor Create(Model: TGWCPUModel; const ProgramData, MelodyData: TBytes; RMask: Integer = -1);
    procedure Reset;
    procedure SetInput(K: Byte; BA, B, Wake: Boolean);
    // One crystal clock, including halted time. Returns current R-pin output.
    function Tick: Byte;
    function StepInstruction: Integer;
    function Segment(Index: Integer): Boolean;
    procedure SerializeState(Archive: TStateArchive);
    property State: TGWCPUState read FState write FState;
    property Model: TGWCPUModel read FModel;
    property ShiftLCD: Boolean read GetShiftLCD;
    property SOutput: Byte read GetSOutput;
    property ROutput: Byte read GetROutput;
  end;

implementation

const
  // SM511/512 tone period table, Sharp databook fig. 5.
  TonePeriods: array[0..63] of Byte = (
    0, 0, 7, 8, 8, 9, 9, 10, 11, 11, 12, 13, 14, 14, 0, 0,
    0, 0, 8, 8, 9, 9, 10, 11, 11, 12, 13, 13, 14, 15, 0, 0,
    0, 0, 8, 8, 9, 9, 10, 10, 11, 12, 12, 13, 14, 15, 0, 0,
    0, 0, 8, 9, 9, 10, 10, 11, 11, 12, 13, 14, 14, 15, 0, 0);
  DigitPLA: array[0..31] of Byte = (
    $e, 0, $c, 8, 2, $a, $e, 2, $e, $a, 0, 0, 2, $a, 2, 2,
    $b, 9, 7, $f, $d, $e, $e, $b, $f, $f, 4, 0, $d, $e, 4, 0);

constructor TGWCPU.Create(Model: TGWCPUModel; const ProgramData, MelodyData: TBytes; RMask: Integer);
begin
  inherited Create;
  FModel := Model;
  FProgram := Copy(ProgramData);
  FMelody := Copy(MelodyData);
  FRMask := RMask;
  FBA := True;
  FB := True;
  FState := Default(TGWCPUState);
  Reset;
end;

function TGWCPU.GetShiftLCD: Boolean;
begin
  Result := FModel in [TGWCPUModel.SM5A, TGWCPUModel.SM5L, TGWCPUModel.SM500];
end;

function TGWCPU.GetSOutput: Byte;
begin
  Result := FState.S;
end;

function TGWCPU.GetROutput: Byte;
begin
  Result := FState.ROut;
end;

procedure TGWCPU.Reset;
begin
  FState.Skip := False;
  FState.Halt := False;
  FState.BMask := 0;
  FState.Op := 0;
  FState.PreviousOp := 0;
  FState.BP := 1;
  FState.Bleeder := False;
  FState.Y := 0;
  FState.R := 0;
  FState.ROut := 0;
  FState.ClockDivider := 2;
  if FModel in [TGWCPUModel.SM511, TGWCPUModel.SM512] then
    FState.ClockDivider := 4;
  FState.MelodyControl := FState.MelodyControl and $FE;
  FState.ClocksLeft := 0;
  if ShiftLCD then
  begin
    Branch(0, 15, 0);
    Push;
    FState.Divider := FState.Divider and $3F;
    FState.Gamma := True;
    FState.CB := 0;
    FState.RSub := False;
    FState.R := 15;
  end
  else
    Branch(3, 7, 0);
  if FModel in [TGWCPUModel.SM511, TGWCPUModel.SM512] then
  begin
    FState.ClockDivider := 4;
    FState.MelodyControl := FState.MelodyControl and $FE;
  end;
  FState.PreviousPC := FState.PC;
end;

function TGWCPU.ReadProgram(Address: Word): Byte;
begin
  if FModel in [TGWCPUModel.SM5A, TGWCPUModel.SM5L] then
    if Address >= $700 then
      Address := $700 or (Address and $3F);
  if Address < Length(FProgram) then
    Result := FProgram[Address]
  else
    Result := 0;
end;

function TGWCPU.RAMAddress: Integer;
begin
  Result := (FState.BMask or (FState.BM shl 4) or FState.BL) and $7F;
  if FModel in [TGWCPUModel.SM5A, TGWCPUModel.SM5L] then
  begin
    if Result >= $50 then
      Result := $40 or (Result and 15);
    if (Result and 15) > 12 then
      Result := (Result and $70) or 12;
  end
  else if FModel = TGWCPUModel.SM500 then
    Result := Result and $3F;
end;

function TGWCPU.ReadRAM: Byte;
begin
  var Address := RAMAddress;
  if (FModel = TGWCPUModel.SM500) and ((Address and 15) > 9) then
    Exit(0);

  Result := FState.RAM[Address] and 15;
end;

procedure TGWCPU.WriteRAM(Value: Byte);
begin
  var Address := RAMAddress;
  if (FModel = TGWCPUModel.SM500) and ((Address and 15) > 9) then
    Exit;

  FState.RAM[Address] := Value and 15;
end;

procedure TGWCPU.IncrementPC;
begin
  var Feed := 0;
  if ((FState.PC xor (FState.PC shr 1)) and 1) = 0 then
    Feed := $20;
  FState.PC := (FState.PC and $FC0) or ((FState.PC shr 1) and $1F) or Feed;
end;

procedure TGWCPU.Branch(PU, PM, PL: Integer);
begin
  FState.PC := ((PU shl 10) or ((PM and 15) shl 6) or (PL and 63)) and $FFF;
  if ShiftLCD then
    FState.PC := FState.PC and $7FF;
end;

procedure TGWCPU.Push;
begin
  if not ShiftLCD then
    FState.Stack[1] := FState.Stack[0];
  FState.Stack[0] := FState.PC;
end;

procedure TGWCPU.Pop;
begin
  FState.PC := FState.Stack[0];
  if not ShiftLCD then
    FState.Stack[0] := FState.Stack[1];
  FState.RSub := False;
end;

procedure TGWCPU.IncrementBL;
begin
  FState.BL := (FState.BL + 1) and 15;
  if ShiftLCD then
    FState.Skip := FState.BL = 8
  else
    FState.Skip := FState.BL = 0;
end;

procedure TGWCPU.ShiftLCDRegister(Value: Byte; Partial: Boolean);
begin
  var Last := 8;
  if FModel = TGWCPUModel.SM500 then
    Last := 6;
  if Partial then
    FState.OX[Last - 1] := FState.OX[Last]
  else
    for var I := 0 to Last - 1 do
      FState.OX[I] := FState.OX[I + 1];
  FState.OX[Last] := Value and 15;
end;

function TGWCPU.Digit: Byte;
begin
  var Row := (FState.BP shr 3) and 1;
  Result := DigitPLA[Row * 16 + FState.A] or ((Row xor 1) and FState.MX);
end;

procedure TGWCPU.Execute(Op, Param: Byte; var Cycles: Integer);
var
  Value, SU, Last: Integer;

  procedure Rotate;
  begin
    Value := FState.A and 1;
    FState.A := (FState.A shr 1) or (FState.Carry shl 3);
    FState.Carry := Value;
  end;

  procedure OutputW(Bit: Byte);
  begin
    if ShiftLCD then
      ShiftLCDRegister(FState.A and 7 or (Bit shl 3))
    else
    begin
      FState.W := ((FState.W shl 1) or Bit) and $FF;
      if FModel = TGWCPUModel.SM510 then
        FState.S := FState.W;
    end;
  end;

begin
  Last := 8;
  if FModel = TGWCPUModel.SM500 then
    Last := 6;
  case Op and $F0 of
    $20:
      begin
        if (FState.PreviousOp and $F0) <> $20 then
          FState.A := Op and 15;
        Exit;
      end;
    $30:
      begin
        if (FModel = TGWCPUModel.SM500) and (Op = $30) then
          FState.S := FState.A
        else
        begin
          Value := FState.A + (Op and 15);
          FState.Skip := ((Op and 15) <> 10) and (Value > 15);
          FState.A := Value and 15;
        end;
        Exit;
      end;
    $40:
      begin
        if ShiftLCD then
        begin
          FState.BM := Op and 3;
          FState.BL := ((Op shr 2) and 3);
          if (Op and 12) <> 0 then
            FState.BL := FState.BL or 8;
        end
        else
        begin
          FState.BM := (FState.BM and 4) or (Op and 3);
          FState.BL := ((Op shr 2) and 3);
          if (Op and 12) <> 0 then
            FState.BL := FState.BL or 12;
        end;
        Exit;
      end;
    $70:
      if ShiftLCD then
      begin
        FState.Stack[0] := (FState.Stack[0] and $43F) or ((Op and 15) shl 6);
        Exit;
      end;
    $80, $90, $A0, $B0:
      begin
        FState.PC := (FState.PC and $FC0) or (Op and 63);
        if ShiftLCD and not FState.RSub then
          Branch(FState.CB, (FState.Stack[0] shr 6) and 15, Op and 63);
        Exit;
      end;
    $C0, $D0, $E0, $F0:
      begin
        if not ShiftLCD then
        begin
          Inc(Cycles);
          Push;
          Value := ReadProgram(Op and 63);
          Branch(Value shr 6, 4, Value and 63);
        end
        else if not FState.RSub then
        begin
          FState.RSub := True;
          SU := (FState.Stack[0] shr 6) and 15;
          Push;
          if FModel = TGWCPUModel.SM500 then
            Branch(0, 0, Op and 63)
          else
            Branch(1, 0, Op and 63);
          if (FState.PreviousOp and $F0) = $70 then
            Branch(FState.CB, SU, Op and 63);
        end
        else
          FState.PC := (FState.PC and $700) or ((Op shl 2) and $C0) or (Op and 15);
        Exit;
      end;
  end;
  if not ShiftLCD then
  begin
    if ((FModel = TGWCPUModel.SM510) and (Op >= $7C)) or ((FModel <> TGWCPUModel.SM510) and ((Op and $FC) = $68)) then
    begin
      Push;
      Branch(Param shr 6, Op and 3, Param and 63);
      Exit;
    end;
    if (Op and $F0) = $70 then
    begin
      Branch(Param shr 6, Op and 15, Param and 63);
      Exit;
    end;
  end;
  case Op and $FC of
    $04:
      begin
        WriteRAM(ReadRAM and ($F xor (1 shl (Op and 3))));
        Exit;
      end;
    $0C:
      begin
        WriteRAM(ReadRAM or (1 shl (Op and 3)));
        Exit;
      end;
    $10, $14, $1C:
      begin
        Value := ReadRAM;
        WriteRAM(FState.A);
        FState.A := Value;
        FState.BM := FState.BM xor (Op and 3);
        if (Op and $FC) = $14 then
          IncrementBL;
        if (Op and $FC) = $1C then
        begin
          FState.BL := (FState.BL + 15) and 15;
          FState.Skip := FState.BL = 15;
        end;
        Exit;
      end;
    $18:
      begin
        FState.A := ReadRAM;
        FState.BM := FState.BM xor (Op and 3);
        Exit;
      end;
    $54:
      begin
        FState.Skip := (ReadRAM and (1 shl (Op and 3))) <> 0;
        Exit;
      end;
  end;
  case Op of
    $00:
      if FModel in [TGWCPUModel.SM511, TGWCPUModel.SM512] then
        Rotate;
    $01:
      if ShiftLCD then
        FState.R := FState.A
      else if FModel = TGWCPUModel.SM510 then
        FState.BP := FState.A
      else
        FState.A := (FState.Divider shr 11) and 15;
    $02:
      if FModel in [TGWCPUModel.SM5A, TGWCPUModel.SM5L] then
        FState.BM := FState.BM or 4;
    $03:
      if ShiftLCD then
        FState.BP := FState.A
      else
        FState.PC := (FState.PreviousPC and $FF0) or FState.A;
    $08:
      FState.A := (FState.A + ReadRAM) and 15;
    $09:
      begin
        Value := FState.A + ReadRAM + FState.Carry;
        FState.Carry := (Value shr 4) and 1;
        FState.Skip := FState.Carry <> 0;
        FState.A := Value and 15;
      end;
    $0A:
      FState.A := FState.A xor 15;
    $0B:
      begin
        Value := FState.BL;
        FState.BL := FState.A;
        FState.A := Value;
      end;
    $50:
      if ShiftLCD then
        FState.Skip := FBA
      else
        FState.A := FK;
    $51:
      FState.Skip := FB;
    $52:
      FState.Skip := FState.Carry = 0;
    $53:
      FState.Skip := FState.A = ReadRAM;
    $58:
      begin
        FState.Skip := not FState.Gamma;
        FState.Gamma := False;
      end;
    $59:
      if ShiftLCD then
      begin
        FState.O[Last] := FState.OX[Last];
        FState.O[Last - 1] := FState.OX[Last - 1];
      end
      else
        FState.L := FState.A;
    $5A:
      FState.Skip := FState.A = 0;
    $5B:
      FState.Skip := FState.A = FState.BL;
    $5C:
      if ShiftLCD then
        FState.O := FState.OX
      else
        FState.X := FState.A;
    $5D:
      if ShiftLCD then
        ShiftLCDRegister(Digit)
      else
        FState.Halt := True;
    $5E:
      if ShiftLCD then
      begin
        case Param of
          0:
            FState.Halt := True;
          4:
            FState.A := (FState.Divider shr 11) and 15;
        else
          raise EReadError.CreateFmt('Unknown Sharp instruction 5E%2.2x', [Param]);
        end;
      end
      else
        FState.Skip := FBA;
    $5F:
      begin
        FState.BL := Param and 15;
        FState.BM := (Param shr 4) and 7;
        if FModel = TGWCPUModel.SM500 then
          FState.BM := FState.BM and 3;
      end;
    $60:
      if ShiftLCD then
        FState.BP := FState.BP xor 8
      else if FModel = TGWCPUModel.SM510 then
        FState.Y := FState.A
      else
        case Param of
          $30:
            FState.MelodyControl := FState.MelodyControl and $FE;
          $31:
            FState.MelodyControl := FState.MelodyControl or 1;
          $32:
            begin
              FState.Skip := (FState.MelodyControl and 2) <> 0;
              FState.MelodyControl := FState.MelodyControl and $FD;
            end;
          $33:
            FState.Y := FState.A;
          $34:
            FState.Bleeder := FState.Carry <> 0;
          $35:
            FState.BP := FState.A;
          $36:
            FState.ClockDivider := 2;
          $37:
            FState.ClockDivider := 4;
        else
          raise EReadError.CreateFmt('Unknown Sharp instruction 60%2.2x', [Param]);
        end;
    $61:
      if ShiftLCD then
        ShiftLCDRegister(Digit, True)
      else if FModel = TGWCPUModel.SM510 then
        FState.R := FState.A
      else
      begin
        FState.MelodyAddress := Param;
        FState.MelodyStep := 0;
      end;
    $62:
      OutputW(0);
    $63:
      OutputW(1);
    $64:
      IncrementBL;
    $65:
      if ShiftLCD then
        FState.Divider := FState.Divider and $3F
      else
        FState.Divider := 0;
    $66:
      FState.Carry := 0;
    $67:
      FState.Carry := 1;
    $68:
      if ShiftLCD then
      begin
        FState.MX := 0;
        FState.A := 0;
      end
      else
        FState.Skip := (FState.Divider and $4000) <> 0;
    $69:
      if ShiftLCD then
        FState.MX := 1
      else
        FState.Skip := (FState.Divider and $800) <> 0;
    $6A:
      FState.A := FK;
    $6B:
      if ShiftLCD then
      begin
        if FModel <> TGWCPUModel.SM500 then
          FState.BM := FState.BM and 3;
      end
      else
        Rotate;
    $6C:
      begin
        FState.BL := (FState.BL + 15) and 15;
        FState.Skip := FState.BL = 15;
      end;
    $6D:
      if ShiftLCD then
        FState.CB := FState.CB xor 1
      else if FModel = TGWCPUModel.SM510 then
        FState.Bleeder := FState.Carry <> 0
      else
        FState.S := FState.W;
    $6E:
      Pop;
    $6F:
      begin
        Pop;
        FState.Skip := True;
      end;
  else
    raise EReadError.CreateFmt('Unknown Sharp instruction %2.2x at %3.3x', [Op, FState.PreviousPC]);
  end;

  if not ShiftLCD then
    if Op = $02 then
      FState.BMask := $40
    else
      FState.BMask := 0;
end;

procedure TGWCPU.SetInput(K: Byte; BA, B, Wake: Boolean);
begin
  FK := K and 15;
  FBA := BA;
  FB := B;
  FWake := Wake;
end;

function TGWCPU.StepInstruction: Integer;
begin
  Result := 1;
  if FState.Halt then
  begin
    if not (FWake or FState.Gamma) then
      Exit(FState.ClockDivider);

    FState.Halt := False;
    if ShiftLCD then
    begin
      FState.CB := 0;
      Branch(0, 0, 0);
    end
    else
      Branch(1, 0, 0);
    Inc(Result);
  end;
  FState.PreviousOp := FState.Op;
  FState.PreviousPC := FState.PC;
  var Op := ReadProgram(FState.PC);
  FState.Op := Op;
  IncrementPC;
  var Param: Byte := 0;
  var TwoBytes: Boolean;
  if ShiftLCD then
    TwoBytes := Op in [$5E, $5F]
  else if FModel = TGWCPUModel.SM510 then
    TwoBytes := (Op = $5F) or ((Op and $F0) = $70)
  else
    TwoBytes := (Op >= $5F) and (Op <= $61) or ((Op and $F0) = $70) or ((Op and $FC) = $68);
  if TwoBytes then
  begin
    Param := ReadProgram(FState.PC);
    IncrementPC;
    Inc(Result);
  end;
  if FState.Skip then
  begin
    FState.Skip := False;
    FState.Op := 0;
  end
  else
  begin
    Execute(Op, Param, Result);
    // Bank extension expires after every executed instruction, including groups.
    if not ShiftLCD then
      if Op = $02 then
        FState.BMask := $40
      else
        FState.BMask := 0;
  end;
  Result := Result * FState.ClockDivider;
end;

procedure TGWCPU.ClockSound;
begin
  if FModel in [TGWCPUModel.SM511, TGWCPUModel.SM512] then
  begin
    FState.ROut := 0;
    if Length(FMelody) = 0 then
      Exit;

    var Cmd := FMelody[FState.MelodyAddress] and $3F;
    var Note := Cmd and 15;
    if (Note >= 2) and (Note <= 13) then
    begin
      FState.ROut := FState.MelodyPhase and FState.MelodyControl and 1;
      Inc(FState.MelodyDuty);
      var Period := TonePeriods[FState.MelodyPhase * 16 + Note];
      if (Cmd and 16) = 0 then
        Period := Period * 2;
      if FState.MelodyDuty >= Period then
      begin
        FState.MelodyDuty := 0;
        FState.MelodyPhase := (FState.MelodyPhase + 1) and 3;
      end;
    end
    else if Note = 1 then
      FState.MelodyControl := FState.MelodyControl or 2;
    if (FState.Divider and $7F) = 0 then
    begin
      var Mask := 15;
      if (Cmd and 32) <> 0 then
        Mask := 31;
      FState.MelodyStep := (FState.MelodyStep + 1) and Mask;
      if FState.MelodyStep = 0 then
        FState.MelodyAddress := (FState.MelodyAddress + 1) and $FF;
    end;
  end
  else if ShiftLCD then
  begin
    var Bit := 1;
    if FRMask >= 0 then
      Bit := (FState.Divider shr FRMask) and 1;
    FState.ROut := ((FState.R xor 15) and 14) or ((FState.R xor 15) and Bit);
    FState.S := FState.ROut shr 1;
  end
  else
  begin
    if FRMask < 0 then
      FState.ROut := FState.R and 3
    else
    begin
      var Bit := (FState.Divider shr FRMask) and 1;
      FState.ROut := (Bit or ((Bit xor 1) shl 1)) and FState.R;
    end;
  end;
end;

function TGWCPU.Tick: Byte;
begin
  FState.Divider := (FState.Divider + 1) and $7FFF;
  if FState.Divider = 0 then
    FState.Gamma := True;
  if FState.ClocksLeft = 0 then
    FState.ClocksLeft := StepInstruction - 1
  else
    Dec(FState.ClocksLeft);
  ClockSound;
  Result := FState.ROut;
end;

function TGWCPU.Segment(Index: Integer): Boolean;
begin
  Result := False;
  if (Index < 0) or (Index > 255) or ((FState.BP and 1) = 0) then
    Exit;

  if ShiftLCD then
  begin
    var Group := Index shr 3;
    var Common := Index and 1;
    var Bit := (Index shr 1) and 3;
    var Last := 8;
    if FModel = TGWCPUModel.SM500 then
      Last := 6;
    if Group > Last then
      Exit;

    if Common = 0 then
      Result := (FState.O[Group] and (1 shl Bit)) <> 0
    else
      Result := (FState.OX[Group] and (1 shl Bit)) <> 0;
    Exit;
  end;

  if FState.Bleeder then
    Exit;

  var Group := Index shr 6;
  var Common := Index and 3;
  var Bit := (Index shr 2) and 15;
  case Group of
    0:
      Result := (FState.RAM[$60 + Bit] and (1 shl Common)) <> 0;
    1:
      Result := (FState.RAM[$70 + Bit] and (1 shl Common)) <> 0;
    2:
      if Bit = 0 then
      begin
        var Blink := 0;
        if (FState.Divider and $4000) <> 0 then
          Blink := FState.Y;
        Result := (FState.L and ($F xor Blink) and (1 shl Common)) <> 0;
      end
      else if Bit = 1 then
        Result := (FState.X and (1 shl Common)) <> 0;
    3:
      if FModel = TGWCPUModel.SM512 then
        Result := (FState.RAM[$50 + Bit] and (1 shl Common)) <> 0;
  end;
end;

procedure TGWCPU.SerializeState(Archive: TStateArchive);
begin
  var Saved := FState;
  Archive.Field(Saved, SizeOf(Saved));
  if Archive.Loading then
  begin
    if (Saved.A > 15) or (Saved.BL > 15) or (Saved.BM > 7) or
      (Saved.Carry > 1) or (Saved.Divider > $7FFF) or (Saved.PC > $FFF) or
      not (Saved.ClockDivider in [2, 4]) or (Saved.ClocksLeft > 15) or
      (Saved.MelodyPhase > 3) then
      raise EReadError.Create('Invalid Sharp snapshot state');

    FState := Saved;
  end;
end;

end.

