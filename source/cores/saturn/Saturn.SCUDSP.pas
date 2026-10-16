unit Saturn.SCUDSP;

interface

uses
  System.SysUtils, System.Classes, HW.SH2, Core.Snapshots;

type
  TDSPDone = procedure of object;

  TSCUDSP = class
  private
    FProgram: array[0..255] of Cardinal;
    FData: array[0..3, 0..63] of Cardinal;
    FCT: array[0..3] of Byte;
    FIncrement: array[0..3] of Boolean;
    FPC, FTop, FDataAddress: Byte;
    FLoop: Word;
    FX, FY: Integer;
    FA, FP, FALU, FMul: Int64;
    FReadAddress, FWriteAddress, FControl: Cardinal;
    FJump: Integer;
    FPause: Boolean;
    FTime, FNext, FDMAAt: Int64;
    FDMACount, FDMABank, FDMAIndex, FDMAAdd: Integer;
    FDMAAddress: Cardinal;
    FDMAWrite, FDMAPreserve: Boolean;
    FRead: TSH2Read;
    FWrite: TSH2Write;
    FUser: Pointer;
    FDone: TDSPDone;
    function Source(Index: Integer): Cardinal;
    procedure Destination(Index: Integer; Value: Cardinal; Immediate: Boolean);
    function Condition(Code: Integer): Boolean;
    procedure Step;
    procedure DMAStep;
    procedure AdvanceEvents(Target: Int64);
  public
    constructor Create(Read: TSH2Read; Write: TSH2Write; User: Pointer; Done: TDSPDone);
    procedure Reset;
    procedure Advance(Target: Int64); inline;
    // Board scheduler only: Target is already known to be monotonic.
    procedure AdvanceForward(Target: Int64); inline;
    function ReadPort(Address: Cardinal): Cardinal;
    procedure WritePort(Address, Value: Cardinal);
    procedure SerializeState(Archive: TStateArchive);
    function DMAActive: Boolean;
  end;

implementation

uses
  System.Math;

{$Q+}{$R+}

function Signed(Value: Int64; Bits: Integer): Int64;
begin
  Result := Value and ((Int64(1) shl Bits) - 1);
  if Result and (Int64(1) shl (Bits - 1)) <> 0 then
    Dec(Result, Int64(1) shl Bits);
end;

constructor TSCUDSP.Create(Read: TSH2Read; Write: TSH2Write; User: Pointer; Done: TDSPDone);
begin
  inherited Create;
  FRead := Read;
  FWrite := Write;
  FUser := User;
  FDone := Done;
  Reset;
end;

procedure TSCUDSP.Reset;
begin
  FillChar(FProgram, SizeOf(FProgram), 0);
  FillChar(FData, SizeOf(FData), 0);
  FillChar(FCT, SizeOf(FCT), 0);
  FillChar(FIncrement, SizeOf(FIncrement), 0);
  FPC := 0;
  FTop := 0;
  FLoop := 0;
  FDataAddress := 0;
  FX := 0;
  FY := 0;
  FA := 0;
  FP := 0;
  FALU := 0;
  FMul := 0;
  FReadAddress := 0;
  FWriteAddress := 0;
  FControl := 0;
  FJump := -1;
  FPause := False;
  FTime := 0;
  FNext := 0;
  FDMAAt := 0;
  FDMACount := 0;
  FDMABank := 0;
  FDMAIndex := 0;
  FDMAAdd := 0;
  FDMAAddress := 0;
  FDMAWrite := False;
  FDMAPreserve := False;
end;

function TSCUDSP.DMAActive: Boolean;
begin
  Result := FDMACount > 0;
end;

function TSCUDSP.Source(Index: Integer): Cardinal;
begin
  Result := 0;
  if Index < 8 then
  begin
    Result := FData[Index and 3, FCT[Index and 3]];
    if Index >= 4 then
      FIncrement[Index and 3] := True;
  end
  else if Index = 9 then
    Result := Cardinal(FALU)
  else if Index = 10 then
    Result := Cardinal(UInt64(FALU) shr 16);
end;

procedure TSCUDSP.Destination(Index: Integer; Value: Cardinal; Immediate: Boolean);
begin
  case Index of
    0..3:
      begin
        FData[Index, FCT[Index]] := Value;
        FIncrement[Index] := True;
      end;
    4:
      FX := Integer(Value);
    5:
      FP := Integer(Value);
    6:
      FReadAddress := Value and $1FFFFFF;
    7:
      FWriteAddress := Value and $1FFFFFF;
    10:
      FLoop := Value and $FFF;
    11:
      if not Immediate then
        FTop := Value and $FF;
    12:
      if Immediate then
      begin
        FTop := Byte((Integer(FPC) + 1) and $FF);
        FJump := Value and $FF;
      end
      else
      begin
        FCT[0] := Value and $3F;
        FIncrement[0] := False;
      end;
    13..15:
      if not Immediate then
      begin
        FCT[Index - 12] := Value and $3F;
        FIncrement[Index - 12] := False;
      end;
  end;
end;

function TSCUDSP.Condition(Code: Integer): Boolean;
begin
  if Code = 0 then
    Exit(True);

  case Code and 15 of
    1:
      Result := FControl and $200000 <> 0;
    2:
      Result := FControl and $400000 <> 0;
    3:
      Result := FControl and $600000 <> 0;
    4:
      Result := FControl and $100000 <> 0;
    8:
      Result := FDMACount > 0;
  else
    Exit(False);
  end;

  if Code and $20 = 0 then
    Result := not Result;
end;

procedure TSCUDSP.Step;
begin
  var Op := FProgram[FPC];

  // Another D0 transfer cannot replace one that is still using the bus.
  if (Op shr 28 = $C) and (FDMACount > 0) then
    Exit;

  var Jump := FJump;
  FJump := -1;
  FillChar(FIncrement, SizeOf(FIncrement), 0);
  case Op shr 30 of
    0:
      begin
        var A: Cardinal := Cardinal(FA);
        var P: Cardinal := Cardinal(FP);
        var V: Cardinal := A;
        var Carry, Overflow: Boolean;
        Carry := False;
        Overflow := False;
        var Kind: Integer := (Op shr 26) and 15;
        case Kind of
          1:
            V := A and P;
          2:
            V := A or P;
          3:
            V := A xor P;
          4:
            begin
              var Sum := UInt64(A) + P;
              V := Cardinal(Sum);
              Carry := Sum > $FFFFFFFF;
              Overflow := ((not (A xor P)) and (A xor V) and $80000000) <> 0;
            end;
          5:
            begin
              V := Cardinal((Int64(A) - P) and $FFFFFFFF);
              Carry := A < P;
              Overflow := ((A xor P) and (A xor V) and $80000000) <> 0;
            end;
          6:
            begin
              FALU := Signed(FA + FP, 48);
              Carry := UInt64(FA and $FFFFFFFFFFFF) + UInt64(FP and $FFFFFFFFFFFF) > $FFFFFFFFFFFF;
              Overflow := ((not (FA xor FP)) and (FA xor FALU) and $800000000000) <> 0;
            end;
          8:
            begin
              V := (A shr 1) or (A and $80000000);
              Carry := Odd(A);
            end;
          9:
            begin
              V := (A shr 1) or (A shl 31);
              Carry := Odd(A);
            end;
          10:
            begin
              V := A shl 1;
              Carry := A and $80000000 <> 0;
            end;
          11:
            begin
              V := (A shl 1) or (A shr 31);
              Carry := A and $80000000 <> 0;
            end;
          15:
            begin
              V := (A shl 8) or (A shr 24);
              Carry := A and $1000000 <> 0;
            end;
        end;
        if Kind <> 6 then
          FALU := Signed((FA and $FFFF00000000) or Int64(V), 48);
        if Kind <> 0 then
        begin
          FControl := FControl and not $700000;
          var Zero, Negative: Boolean;
          if Kind = 6 then
          begin
            Zero := FALU = 0;
            Negative := FALU < 0;
          end
          else
          begin
            Zero := V = 0;
            Negative := Integer(V) < 0;
          end;
          if Zero then
            FControl := FControl or $200000;
          if Negative then
            FControl := FControl or $400000;
          if Carry then
            FControl := FControl or $100000;
          if Overflow then
            FControl := FControl or $80000;
        end;

        // All buses see the previous cycle's counters and multiplier result.
        var XS: Cardinal := 0;
        var YS: Cardinal := 0;
        if (Op shr 23) and 7 in [3, 4, 5, 6, 7] then
          XS := Source((Op shr 20) and 7);
        if (Op shr 17) and 7 in [3, 4, 5, 6, 7] then
          YS := Source((Op shr 14) and 7);
        if Op and $2000000 <> 0 then
          FX := Integer(XS);
        case (Op shr 23) and 3 of
          2:
            FP := FMul;
          3:
            FP := Integer(XS);
        end;
        if Op and $80000 <> 0 then
          FY := Integer(YS);
        case (Op shr 17) and 3 of
          1:
            FA := 0;
          2:
            FA := FALU;
          3:
            FA := Integer(YS);
        end;
        case (Op shr 12) and 3 of
          1:
            Destination((Op shr 8) and 15, Cardinal(Integer(ShortInt(Op and $FF))), False);
          3:
            Destination((Op shr 8) and 15, Source(Op and 15), False);
        end;
      end;
    2:
      begin
        if Op and $2000000 = 0 then
          Destination((Op shr 26) and 15, Cardinal(Signed(Op and $1FFFFFF, 25)), True)
        else if Condition((Op shr 19) and $3F) then
          Destination((Op shr 26) and 15, Cardinal(Signed(Op and $7FFFF, 19)), True);
      end;
    3:
      case Op shr 28 of
        $C:
          begin
            if FDMACount = 0 then
            begin
              FDMACount := Op and $FF;
              if Op and $2000 <> 0 then
                FDMACount := Source(Op and 7) and $FF;
              if FDMACount = 0 then
                FDMACount := 256;
              FDMABank := (Op shr 8) and 7;
              if FDMABank > 4 then
                FDMABank := FDMABank and 3;
              FDMAWrite := Op and $1000 <> 0;
              FDMAPreserve := Op and $4000 <> 0;
              for var i := 0 to 3 do
                if FIncrement[i] then
                begin
                  FCT[i] := (FCT[i] + 1) and $3F;
                  FIncrement[i] := False;
                end;
              FDMAIndex := FCT[FDMABank and 3];
              if FDMABank = 4 then
                FDMAIndex := 0;
              FDMAAddress := Cardinal((UInt64(FReadAddress) * 4) and $FFFFFFFF);
              if FDMAWrite then
                FDMAAddress := Cardinal((UInt64(FWriteAddress) * 4) and $FFFFFFFF);
              FDMAAdd := (Op shr 15) and 7;
              if FDMAAdd > 0 then
                FDMAAdd := 1 shl (FDMAAdd - 1);

              // Add is expressed in 16-bit units on B/CPU buses and 32-bit units
              // on A-bus; a fixed FIFO address is valid there.
              if (FDMAAddress >= $02000000) and (FDMAAddress < $05A00000) then
                FDMAAdd := Min(FDMAAdd, 1) * 4
              else
              begin
                FDMAAdd := FDMAAdd * 2;
                if FDMAAdd = 2 then
                  FDMAAdd := 4;
              end;

              // Forward the post-transfer address when issuing DMA. The DSP
              // continues running and may prepare RA0/WA0 for the next transfer
              // before the current transfer finishes; completion must not undo it.
              if not FDMAPreserve then
              begin
                var NextAddress := Cardinal((UInt64(FDMAAddress) +
                  UInt64(FDMAAdd) * Cardinal(FDMACount)) and $FFFFFFFF) shr 2;
                if FDMAWrite then
                  FWriteAddress := NextAddress
                else
                  FReadAddress := NextAddress;
              end;
              FDMAAt := FNext + 4;
              FControl := FControl or $800000;
              if FDMABank < 4 then
                FCT[FDMABank] := (FDMAIndex + FDMACount) and $3F;
            end;
          end;
        $D:
          if Condition((Op shr 19) and $7F) then
            FJump := Op and $FF;
        $E:
          if FLoop <> 0 then
          begin
            Dec(FLoop);
            FJump := FTop;
            if Op and $8000000 <> 0 then
              FJump := FPC;
          end;
        $F:
          begin
            FControl := FControl and not $10000;
            if Op and $8000000 <> 0 then
            begin
              FControl := FControl or $40000;
              if Assigned(FDone) then
                FDone;
            end;
          end;
      end;
  end;
  for var i := 0 to 3 do
    if FIncrement[i] then
      FCT[i] := (FCT[i] + 1) and $3F;
  FMul := Signed(Int64(FX) * FY, 48);
  FPC := Byte((Integer(FPC) + 1) and $FF);
  if Jump >= 0 then
    FPC := Jump;
end;

procedure TSCUDSP.DMAStep;
begin
  var A := FDMAAddress and $1FFFFFFF;
  if FDMAWrite then
  begin
    var V := FData[FDMABank and 3, FDMAIndex and $3F];
    if (A >= $05A00000) and (A < $05FE0000) then
    begin
      FWrite(FUser, A, V shr 16, 2);
      FWrite(FUser, A + 2, V and $FFFF, 2);
    end
    else
      FWrite(FUser, A, V, 4);
  end
  else
  begin
    var V := FRead(FUser, A, 4);
    if FDMABank = 4 then
      FProgram[FDMAIndex and $FF] := V
    else
      FData[FDMABank, FDMAIndex and $3F] := V;
  end;
  Inc(FDMAIndex);
  FDMAAddress := Cardinal((Int64(FDMAAddress) + FDMAAdd) and $FFFFFFFF);
  Dec(FDMACount);
  if FDMACount = 0 then
    FControl := FControl and not $800000;
end;

procedure TSCUDSP.Advance(Target: Int64);
begin
  if Target < FTime then
    raise EArgumentException.Create('DSP time');

  AdvanceForward(Target);
end;

procedure TSCUDSP.AdvanceForward(Target: Int64);
begin
  if ((FControl and $10000 <> 0) and not FPause) or (FDMACount > 0) then
    AdvanceEvents(Target);
  FTime := Target;
end;

procedure TSCUDSP.AdvanceEvents(Target: Int64);
begin
  while True do
  begin
    var Next := High(Int64);
    if (FControl and $10000 <> 0) and not FPause then
      Next := FNext;
    if FDMACount > 0 then
      Next := Min(Next, FDMAAt);
    if Next > Target then
      Break;

    if (FDMACount > 0) and (FDMAAt = Next) then
    begin
      DMAStep;
      Inc(FDMAAt, 4);
    end
    else
    begin
      Step;
      Inc(FNext, 2);
    end;
  end;
end;

function TSCUDSP.ReadPort(Address: Cardinal): Cardinal;
begin
  Result := 0;
  case Address and $FC of
    $80:
      begin
        Result := (FControl and $00FD0000) or FPC;
        FControl := FControl and not $C0000;
      end;
    $8C:
      if FControl and $10000 = 0 then
      begin
        Result := FData[FDataAddress shr 6, FDataAddress and 63];
        FDataAddress := (FDataAddress and $C0) or ((FDataAddress + 1) and $3F);
      end;
  end;
end;

procedure TSCUDSP.WritePort(Address, Value: Cardinal);
begin
  case Address and $FC of
    $80:
      begin
        if (FControl and $10000 = 0) and (Value and $8000 <> 0) then
        begin
          FPC := Value and $FF;
          FJump := -1;
        end;
        if Value and $2000000 <> 0 then
          FPause := True;
        if Value and $4000000 <> 0 then
          FPause := False;
        var Starting: Boolean := (Value and $10000 <> 0) and (FControl and $10000 = 0);
        FControl := (FControl and not $10000) or (Value and $10000);
        if Starting then
        begin
          FNext := FTime + 2;
          FPause := False;
        end;
        if (Value and $20000 <> 0) and (FControl and $10000 = 0) then
        begin
          FNext := FTime;
          Step;
        end;
      end;
    $84:
      if FControl and $10000 = 0 then
      begin
        FProgram[FPC] := Value;
        FPC := Byte((Integer(FPC) + 1) and $FF);
      end;
    $88:
      if FControl and $10000 = 0 then
        FDataAddress := Value and $FF;
    $8C:
      if FControl and $10000 = 0 then
      begin
        FData[FDataAddress shr 6, FDataAddress and 63] := Value;
        FDataAddress := (FDataAddress and $C0) or ((FDataAddress + 1) and $3F);
      end;
  end;
end;

procedure TSCUDSP.SerializeState(Archive: TStateArchive);
begin
  Archive.Field(FProgram, SizeOf(FProgram));
  Archive.Field(FData, SizeOf(FData));
  Archive.Field(FCT, SizeOf(FCT));
  Archive.Field(FIncrement, SizeOf(FIncrement));
  Archive.Field(FPC, SizeOf(FPC));
  Archive.Field(FTop, SizeOf(FTop));
  Archive.Field(FDataAddress, SizeOf(FDataAddress));
  Archive.Field(FLoop, SizeOf(FLoop));
  Archive.Field(FX, SizeOf(FX));
  Archive.Field(FY, SizeOf(FY));
  Archive.Field(FA, SizeOf(FA));
  Archive.Field(FP, SizeOf(FP));
  Archive.Field(FALU, SizeOf(FALU));
  Archive.Field(FMul, SizeOf(FMul));
  Archive.Field(FReadAddress, SizeOf(FReadAddress));
  Archive.Field(FWriteAddress, SizeOf(FWriteAddress));
  Archive.Field(FControl, SizeOf(FControl));
  Archive.Field(FJump, SizeOf(FJump));
  Archive.Field(FPause, SizeOf(FPause));
  Archive.Field(FTime, SizeOf(FTime));
  Archive.Field(FNext, SizeOf(FNext));
  Archive.Field(FDMAAt, SizeOf(FDMAAt));
  Archive.Field(FDMACount, SizeOf(FDMACount));
  Archive.Field(FDMABank, SizeOf(FDMABank));
  Archive.Field(FDMAIndex, SizeOf(FDMAIndex));
  Archive.Field(FDMAAdd, SizeOf(FDMAAdd));
  Archive.Field(FDMAAddress, SizeOf(FDMAAddress));
  Archive.Field(FDMAWrite, SizeOf(FDMAWrite));
  Archive.Field(FDMAPreserve, SizeOf(FDMAPreserve));
  if (FTime < 0) or (FDMACount < 0) or (FDMACount > 256) or (FDMABank < 0) or (FDMABank > 4) or (FJump < -1) or (FJump > 255) then
    raise EReadError.Create('Invalid SCU DSP state');

  for var i := 0 to 3 do
    if FCT[i] > 63 then
      raise EReadError.Create('Invalid SCU DSP counter');
end;

end.

