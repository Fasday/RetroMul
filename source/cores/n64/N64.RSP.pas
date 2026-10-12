unit N64.RSP;
{$Q+}{$R+}

interface

uses
  System.SysUtils, System.Classes, System.Math, N64.Types, Core.Snapshots;

type
  TRSPTimingInfo = record
    Flags, RRead, RWrite, VRead, VWrite, VCRead, VCWrite, VFake: Cardinal;
  end;
  TN64RSP = class
  private
    FBus: TN64Bus;
    FReg: array[0..31] of Cardinal;
    FVec: array[0..31, 0..7] of Word;
    FAcc: array[0..7] of Int64;
    FVCO, FVCC, FVCE: Word;
    FNextPC: Cardinal;
    FBranch: Boolean;
    FDivisionHigh: Boolean;
    FDivisionInput, FDivisionResult: Word;
    FScalarReady: array[0..31] of Byte;
    FVectorReady: array[0..31] of Byte;
    FSingleIssue: Byte;
    FStalledSecondOpcode: Cardinal;
    FHasStalledSecondOpcode: Boolean;
    FLoadHistory, FBranchBubble: Byte;
    FStalledOpcode, FStalledPC: Cardinal;
    FHasStalledOpcode: Boolean;
    procedure AgePipeline;
    function InfoEXECUTE(Op: Cardinal): TRSPTimingInfo;
    function InfoSPECIAL(Op: Cardinal): TRSPTimingInfo;
    function InfoREGIMM(Op: Cardinal): TRSPTimingInfo;
    function InfoSCC(Op: Cardinal): TRSPTimingInfo;
    function InfoVU(Op: Cardinal): TRSPTimingInfo;
    function InfoLWC2(Op: Cardinal): TRSPTimingInfo;
    function InfoSWC2(Op: Cardinal): TRSPTimingInfo;
    function CanPair(const A, B: TRSPTimingInfo): Boolean;
    procedure IssueInstruction(Op: Cardinal; var PC, Status, Interrupt: Cardinal);
    procedure VectorOp(Op: Cardinal);
    procedure VectorMemory(Op: Cardinal; Writing: Boolean);
    function GetByte(R, Index: Integer): Byte;
    procedure SetByte(R, Index: Integer; Value: Byte);
  public
    constructor Create(Bus: TN64Bus);
    procedure Reset;
    // SP_PC writes discard pending branches and fetched instructions.
    procedure ResetPipeline;
    procedure Execute(var PC, Status, Interrupt: Cardinal);
    // The budget includes SU load interlocks and taken-branch bubbles. Each
    // stalled clock returns to the console before another instruction executes.
    function ExecuteCycles(var PC, Status, Interrupt: Cardinal; Cycles: Integer): Integer;
    procedure SerializeState(State: TStateArchive);
  end;

implementation

constructor TN64RSP.Create(Bus: TN64Bus);
begin
  inherited Create;
  FBus := Bus;
  Reset
end;

procedure TN64RSP.Reset;
begin
  for var I := 0 to 31 do
  begin
    FReg[I] := 0;
    for var J := 0 to 7 do
      FVec[I, J] := 0
  end;
  for var I := 0 to 7 do
    FAcc[I] := 0;
  FVCO := 0;
  FVCC := 0;
  FVCE := 0;
  FDivisionHigh := False;
  FDivisionInput := 0;
  FDivisionResult := 0;
  ResetPipeline;
end;

procedure TN64RSP.ResetPipeline;
begin
  FNextPC := 0;
  FBranch := False;
  for var I := 0 to 31 do begin FScalarReady[I] := 0; FVectorReady[I] := 0 end;
  FSingleIssue := 0; FStalledSecondOpcode := 0; FHasStalledSecondOpcode := False;
  FLoadHistory := 0;
  FBranchBubble := 0;
  FStalledOpcode := 0;
  FStalledPC := 0;
  FHasStalledOpcode := False;
end;

function TN64RSP.GetByte(R, Index: Integer): Byte;
begin
  Index := Index and 15;
  if Odd(Index) then
    Result := Byte(FVec[R, Index div 2] and $FF)
  else
    Result := Byte(FVec[R, Index div 2] shr 8);
end;

procedure TN64RSP.SetByte(R, Index: Integer; Value: Byte);
begin
  Index := Index and 15;
  if Odd(Index) then
    FVec[R, Index div 2] := (FVec[R, Index div 2] and $FF00) or Value
  else
    FVec[R, Index div 2] := (FVec[R, Index div 2] and $FF) or (Word(Value) shl 8);
end;

function S16(Value: Word): Integer; inline;
begin
  Result := Integer(Value xor $8000) - $8000;
end;

function W16(Value: Int64): Word; inline;
begin
  Result := Word(Value and $FFFF)
end;

function AccMiddle(Value: Int64): Int64; inline;
begin
  if Value < 0 then
    Result := -1 - ((not Value) shr 16)
  else
    Result := Value shr 16;
end;

function WrapAcc48(Value: Int64): Int64; inline;
begin
  Result := (Value and $7FFFFFFFFFFF) - (Value and $800000000000);
end;

function ClampSigned(Value: Int64): Word; inline;
begin
  Result := W16(EnsureRange(Value, Int64(-32768), Int64(32767)))
end;

procedure TN64RSP.VectorOp(Op: Cardinal);
const
  Select: array[0..15, 0..7] of Byte = (
    (0, 1, 2, 3, 4, 5, 6, 7), (0, 1, 2, 3, 4, 5, 6, 7), (0, 0, 2, 2, 4, 4, 6, 6), (1, 1, 3, 3, 5, 5, 7, 7),
    (0, 0, 0, 0, 4, 4, 4, 4), (1, 1, 1, 1, 5, 5, 5, 5), (2, 2, 2, 2, 6, 6, 6, 6), (3, 3, 3, 3, 7, 7, 7, 7),
    (0, 0, 0, 0, 0, 0, 0, 0), (1, 1, 1, 1, 1, 1, 1, 1), (2, 2, 2, 2, 2, 2, 2, 2), (3, 3, 3, 3, 3, 3, 3, 3),
    (4, 4, 4, 4, 4, 4, 4, 4), (5, 5, 5, 5, 5, 5, 5, 5), (6, 6, 6, 6, 6, 6, 6, 6), (7, 7, 7, 7, 7, 7, 7, 7));
begin
  var E := (Op shr 21) and 15;
  var T := (Op shr 16) and 31;
  var S := (Op shr 11) and 31;
  var D := (Op shr 6) and 31;
  var Fn := Op and 63;
  if Fn in [48..54] then
  begin
    var DE := S and 7;
    var Source := FVec[T, E and 7];
    for var I := 0 to 7 do
      FAcc[I] := (FAcc[I] and not Int64($FFFF)) or FVec[T, Select[E, I]];
    if Fn = 51 then
      FVec[D, DE] := FVec[T, Select[E, DE]]
    else if Fn in [50, 54] then
    begin
      FVec[D, DE] := FDivisionResult;
      // The scalar divider always selects the raw E&7 lane. Select[] only
      // governs ACC_LO; capture Source before an aliased destination changes VT.
      FDivisionInput := Source;
      FDivisionHigh := True;
    end
    else
    begin
      var Input := Integer(SignedValue(SX(Source, 16)));
      if FDivisionHigh and (Fn in [49, 53]) then
        Input := Integer(SignedValue(SX((Cardinal(FDivisionInput) shl 16) or Source, 32)));
      var Data: Cardinal;
      var SignMask: Cardinal := 0;
      if Input < 0 then
        SignMask := $FFFFFFFF;
      Data := Cardinal(Int64(Input) and $FFFFFFFF) xor SignMask;
      if (Input < 0) and (Input > -32768) then
        Inc(Data);
      var Value: Cardinal := $7FFFFFFF;
      if Input = -32768 then
        Value := $FFFF0000
      else if Data <> 0 then
      begin
        var Shift := 0;
        while (Data and $80000000) = 0 do
        begin
          Data := Data shl 1;
          Inc(Shift)
        end;
        var Index := (Data shr 22) and 511;
        var TableValue: Cardinal;
        if Fn in [52, 53] then
        begin
          var Denominator := UInt64(512 + (Index and 510));
          if (Shift and 1) = 0 then
            Denominator := Denominator * 2;
          var LowBound: UInt64 := 65536;
          var HighBound: UInt64 := 131071;
          while LowBound < HighBound do
          begin
            var Mid := (LowBound + HighBound + 1) div 2;
            if Mid * Mid * Denominator <= (UInt64(1) shl 43) then
              LowBound := Mid
            else
              HighBound := Mid - 1;
          end;
          TableValue := Cardinal(LowBound - 65536);
          Value := ((($10000 or TableValue) shl 14) shr ((31 - Shift) div 2)) xor SignMask;
        end
        else
        begin
          TableValue := Cardinal(Min(UInt64($FFFF), ((((UInt64(1) shl 34) div (Index + 512)) + 1) shr 8) - $10000));
          Value := ((($10000 or TableValue) shl 14) shr (31 - Shift)) xor SignMask;
        end;
      end;
      FVec[D, DE] := Word(Value and $FFFF);
      FDivisionResult := Word(Value shr 16);
      FDivisionHigh := False;
    end;
    Exit;
  end;
  var Carry: Word := 0;
  var Compare: Word := 0;
  var Extension: Word := 0;
  if Fn = 36 then
    Compare := FVCC;
  var Output: array[0..7] of Word;
  for var I := 0 to 7 do
  begin
    var A := S16(FVec[S, I]);
    var B := S16(FVec[T, Select[E, I]]);
    var UA := Integer(FVec[S, I]);
    var UB := Integer(FVec[T, Select[E, I]]);
    var V: Int64 := 0;
    var R: Word := 0;
    var OldAcc := FAcc[I];
    case Fn of
      0, 1, 8, 9:
        begin
          V := Int64(A) * B * 2;
          if Fn in [0, 1] then
            FAcc[I] := V + $8000
          else
            FAcc[I] := WrapAcc48(FAcc[I] + V);
          if Fn in [0, 8] then
            R := ClampSigned(AccMiddle(FAcc[I]))
          else if FAcc[I] < 0 then
            R := 0
          else if FAcc[I] > $7FFFFFFF then
            R := $FFFF
          else
            R := W16(FAcc[I] shr 16);
        end;
      2, 10:
        begin
          V := B;
          if (S and 1) <> 0 then
            V := V * 65536;
          if ((Fn = 2) and (FAcc[I] >= 0)) or ((Fn = 10) and (FAcc[I] < 0)) then
            FAcc[I] := WrapAcc48(FAcc[I] + V);
          R := ClampSigned(AccMiddle(FAcc[I]));
        end;
      3:
        begin
          V := Int64(A) * B;
          if V < 0 then
            Inc(V, 31);
          FAcc[I] := V * 65536;
          var Half := V div 2;
          if (V < 0) and Odd(V) then
            Dec(Half);
          R := ClampSigned(Half) and $FFF0;
        end;
      11:
        begin
          V := AccMiddle(FAcc[I]);
          if (V < -32) and ((V and 32) = 0) then
            Inc(V, 32)
          else if (V > 32) and ((V and 32) = 0) then
            Dec(V, 32);
          FAcc[I] := V * 65536 + (FAcc[I] and $FFFF);
          var Half := V div 2;
          if (V < 0) and Odd(V) then
            Dec(Half);
          R := ClampSigned(Half) and $FFF0;
        end;
      4..7, 12..15:
        begin
          case Fn and 7 of
            4:
              V := (Int64(UA) * UB) shr 16;
            5:
              V := Int64(A) * UB;
            6:
              V := Int64(UA) * B;
            7:
              V := Int64(A) * B * 65536;
          end;
          if Fn < 8 then
            FAcc[I] := V
          else
            FAcc[I] := WrapAcc48(FAcc[I] + V);
          FAcc[I] := WrapAcc48(FAcc[I]);
          if (Fn and 7) in [5, 7] then
            R := ClampSigned(AccMiddle(FAcc[I]))
          else
            R := W16(FAcc[I]);
          if Fn in [12, 14] then
            if FAcc[I] < -2147483648 then
              R := 0
            else if FAcc[I] > 2147483647 then
              R := $FFFF;
        end;
      16, 17:
        begin
          if Fn = 16 then
            V := A + B + ((FVCO shr I) and 1)
          else
            V := A - B - ((FVCO shr I) and 1);
          FAcc[I] := V;
          R := ClampSigned(V);
        end;
      19:
        begin
          if A < 0 then
            V := -B
          else if A > 0 then
            V := B;
          FAcc[I] := V;
          R := ClampSigned(V)
        end;
      20:
        begin
          V := UA + UB;
          if V > $FFFF then
            Carry := Carry or (1 shl I);
          FAcc[I] := V;
          R := W16(V)
        end;
      21:
        begin
          V := UA - UB;
          if V < 0 then
            Carry := Carry or (1 shl I);
          if V <> 0 then
            Carry := Carry or (1 shl (I + 8));
          FAcc[I] := V;
          R := W16(V);
        end;
      29:
        case E of
          8:
            R := W16(FAcc[I] shr 32);
          9:
            R := W16(FAcc[I] shr 16);
          10:
            R := W16(FAcc[I]);
        end;
      32..35:
        begin
          var Test := False;
          case Fn of
            32:
              Test := (A < B) or ((A = B) and ((FVCO and (1 shl I)) <> 0) and ((FVCO and (1 shl (I + 8))) <> 0));
            33:
              Test := (A = B) and ((FVCO and (1 shl (I + 8))) = 0);
            34:
              Test := (A <> B) or ((FVCO and (1 shl (I + 8))) <> 0);
            35:
              Test := (A > B) or ((A = B) and not (((FVCO and (1 shl I)) <> 0) and ((FVCO and (1 shl (I + 8))) <> 0)));
          end;
          if Test then
          begin
            Compare := Compare or (1 shl I);
            R := Word(UA)
          end
          else
            R := Word(UB);
          FAcc[I] := S16(R);
        end;
      36..38:
        begin
          var SignDifferent := (A < 0) <> (B < 0);
          var LowFlag := False;
          var HighFlag := False;
          R := Word(UA);
          if Fn = 36 then
          begin
            LowFlag := (FVCC and (1 shl I)) <> 0;
            HighFlag := (FVCC and (1 shl (I + 8))) <> 0;
            if (FVCO and (1 shl I)) <> 0 then
            begin
              if (FVCO and (1 shl (I + 8))) = 0 then
                if (FVCE and (1 shl I)) <> 0 then
                  LowFlag := UA + UB <= 65536
                else
                  LowFlag := UA + UB = 0;
              if LowFlag then
                R := W16(-B);
            end
            else
            begin
              if (FVCO and (1 shl (I + 8))) = 0 then
                HighFlag := UA >= UB;
              if HighFlag then
                R := Word(UB);
            end;
          end
          else if SignDifferent then
          begin
            var Sum := A + B;
            if Fn = 37 then
              Sum := S16(W16(Sum));
            LowFlag := Sum + Ord(Fn = 38) <= 0;
            HighFlag := B < 0;
            if LowFlag then
              if Fn = 37 then
                R := W16(-B)
              else
                R := Word(UB xor $FFFF);
            if Fn = 37 then
            begin
              Carry := Carry or (1 shl I);
              if (Sum <> 0) and (A <> S16(Word(UB xor $FFFF))) then
                Carry := Carry or (1 shl (I + 8));
              if Sum = -1 then
                Extension := Extension or (1 shl I);
            end;
          end
          else
          begin
            var Difference := A - B;
            if Fn = 37 then
              Difference := S16(W16(Difference));
            LowFlag := B < 0;
            HighFlag := Difference >= 0;
            if HighFlag then
              R := Word(UB);
            if (Fn = 37) and (Difference <> 0) and (A <> S16(Word(UB xor $FFFF))) then
              Carry := Carry or (1 shl (I + 8));
          end;
          Compare := Compare and not (Word(1 shl I) or Word(1 shl (I + 8)));
          if LowFlag then
            Compare := Compare or (1 shl I);
          if HighFlag then
            Compare := Compare or (1 shl (I + 8));
        end;
      39:
        begin
          if (FVCC and (1 shl I)) <> 0 then
            R := Word(UA)
          else
            R := Word(UB);
          FAcc[I] := S16(R)
        end;
      40:
        R := Word(UA and UB);
      41:
        R := Word((UA and UB) xor $FFFF);
      42:
        R := Word(UA or UB);
      43:
        R := Word((UA or UB) xor $FFFF);
      44:
        R := Word(UA xor UB);
      45:
        R := Word((UA xor UB) xor $FFFF);
      51:
        R := Word(UB);
      55, 63:
        Exit;
    else
      begin
        // Reserved vector encodings still execute: sum to ACC_LO, zero VD.
        FAcc[I] := (OldAcc and not Int64($FFFF)) or W16(A + B);
        R := 0;
      end;
    end;
    // Add/compare/logical operations write only ACC_LO, preserving ACC_HI/MD.
    if Fn in [16, 17, 19, 20, 21, 32..38, 39..45] then
      FAcc[I] := (OldAcc and not Int64($FFFF)) or Word(V and $FFFF);
    if Fn in [32..38, 39..45] then
      FAcc[I] := (OldAcc and not Int64($FFFF)) or R;
    Output[I] := R;
  end;
  for var I := 0 to 7 do
    FVec[D, I] := Output[I];
  if Fn in [16, 17, 20, 21, 32..39] then
    FVCO := Carry;
  if Fn in [32..38] then
    FVCC := Compare;
  if Fn in [36..38] then
    FVCE := Extension;
end;

procedure TN64RSP.VectorMemory(Op: Cardinal; Writing: Boolean);
begin
  var Base := (Op shr 21) and 31;
  var V := (Op shr 16) and 31;
  var Kind := (Op shr 11) and 31;
  var E := Integer((Op shr 7) and 15);
  var Offset := Integer(SignedValue(SX(Op and 127, 7)));
  var Size := 1;
  case Kind of
    0..3:
      Size := 1 shl Kind;
    4, 5, 8..11:
      Size := 16;
    6, 7:
      Size := 8;
  else
    raise EN64Unsupported.CreateFmt('RSP vector memory opcode %d is not implemented', [Kind]);
  end;
  var Address := Cardinal(Add64(FReg[Base], SX(UInt64((Int64(Offset) * Size) and $FFFFFFFF), 32)) and $FFF);
  if Kind = 11 then
  begin
    var Start := Address and $FF8;
    var Position := (E + Integer(Address and 8)) and 15;
    if Writing then
      Position := (Integer(Address and 7) - (E and 14)) and 15;
    for var I := 0 to 7 do
      for var J := 0 to 1 do
      begin
        var R := (V and 24) + ((E div 2 + I) and 7);
        var Element := I * 2 + J;
        if Writing then
        begin
          R := (V and 24) + I;
          Element := (16 - (E and 14) + I * 2 + J) and 15
        end;
        var A := $04000000 + ((Start + Cardinal(Position)) and $FFF);
        if Writing then
          FBus.Write8(A, GetByte(R, Element))
        else
          SetByte(R, Element, FBus.Read8(A));
        Position := (Position + 1) and 15;
      end;
    Exit;
  end;
  if Kind = 10 then
  begin
    if not Writing then
      Exit; // LWV is a hardware no-op.
    var Start := Address and $FF8;
    var Position := Integer(Address and 7);
    for var I := 0 to 15 do
      FBus.Write8($04000000 + ((Start + Cardinal((Position + I) and 15)) and $FFF), GetByte(V, E + I));
    Exit;
  end;
  if Kind in [8, 9] then
  begin
    var Start := Address and $FF8;
    var Position := Integer(Address and 7) - E;
    if Kind = 8 then
    begin
      for var I := 0 to 7 do
        if Writing then
        begin
          var Value := ((Cardinal(GetByte(V, E + I * 2)) shl 1) or (GetByte(V, E + I * 2 + 1) shr 7)) and $FF;
          FBus.Write8($04000000 + ((Start + Cardinal((Integer(Address and 7) + I * 2) and 15)) and $FFF), Byte(Value));
        end
        else
          FVec[V, I] := Word(FBus.Read8($04000000 + ((Start + Cardinal((Position + I * 2) and 15)) and $FFF))) shl 7;
    end
    else if Writing then
    begin
      for var I := 0 to 3 do
      begin
        var Lane := -1;
        case E of
          0, 15:
            Lane := I;
          1:
            Lane := 4 + ((2 + I) and 3);
          4:
            Lane := (1 + I) and 3;
          5:
            Lane := 4 + ((3 + I) and 3);
          8:
            Lane := 4 + I;
          11:
            Lane := (3 + I) and 3;
          12:
            Lane := 4 + ((1 + I) and 3);
        end;
        var Value: Byte := 0;
        if Lane >= 0 then
          Value := Byte((FVec[V, Lane and 7] shr 7) and $FF);
        FBus.Write8($04000000 + ((Start + Cardinal((Integer(Address and 7) + I * 4) and 15)) and $FFF), Value);
      end;
    end
    else
    begin
      var Temp: array[0..7] of Word;
      for var I := 0 to 3 do
      begin
        Temp[I] := Word(FBus.Read8($04000000 + ((Start + Cardinal((Position + I * 4) and 15)) and $FFF))) shl 7;
        Temp[I + 4] := Word(FBus.Read8($04000000 + ((Start + Cardinal((Position + I * 4 + 8) and 15)) and $FFF))) shl 7;
      end;
      for var I := E to Min(15, E + 7) do
        if (I and 1) = 0 then
          SetByte(V, I, Byte(Temp[I div 2] shr 8))
        else
          SetByte(V, I, Byte(Temp[I div 2] and $FF));
    end;
    Exit;
  end;
  if Kind = 4 then
    if Writing then
      Size := 16 - Integer(Address and 15)
    else
      Size := Min(16 - Integer(Address and 15), 16 - E);
  if Kind = 5 then
  begin
    Size := Integer(Address and 15);
    E := 16 - Size + E;
    Address := Address and $FF0;
    if not Writing then
      Size := Min(Size, 16 - E);
  end;
  if Kind in [6, 7] then
  begin
    for var I := 0 to 7 do
      if Writing then
      begin
        var Shift := 8;
        if (((E + I) and 15) >= 8) xor (Kind = 7) then
          Shift := 7;
        FBus.Write8($04000000 + ((Address + Cardinal(I)) and $FFF), Byte((FVec[V, (E + I) and 7] shr Shift) and $FF));
      end
      else
      begin
        var Position := (Integer(Address and 7) - E + I) and 15;
        FVec[V, I] := Word(FBus.Read8($04000000 + (((Address and $FF8) + Cardinal(Position)) and $FFF))) shl (8 - Ord(Kind = 7));
      end;
  end
  else
    for var I := 0 to Size - 1 do
      if Writing then
        FBus.Write8($04000000 + ((Address + Cardinal(I)) and $FFF), GetByte(V, E + I))
      else if E + I < 16 then
        SetByte(V, E + I, FBus.Read8($04000000 + ((Address + Cardinal(I)) and $FFF)));
end;

procedure TN64RSP.Execute(var PC, Status, Interrupt: Cardinal);
begin
  ExecuteCycles(PC, Status, Interrupt, 32);
end;

procedure TN64RSP.AgePipeline;
begin
  for var I := 0 to 31 do begin
    if FScalarReady[I] > 0 then Dec(FScalarReady[I]);
    if FVectorReady[I] > 0 then Dec(FVectorReady[I]);
  end;
  FLoadHistory := (FLoadHistory shl 1) and 3;
end;

function TN64RSP.InfoEXECUTE(Op: Cardinal): TRSPTimingInfo;
begin
  var S := Integer((Op shr 21) and 31); var T := Integer((Op shr 16) and 31);
  var D := Integer((Op shr 11) and 31); var V := Integer((Op shr 6) and 31);
  var XT := Integer((Op shr 15) and 31); var XD := Integer((Op shr 20) and 31);
  Result := Default(TRSPTimingInfo);
  case Op shr 26 of
    $00: begin
      Exit(InfoSPECIAL(Op));
    end;
    $01: begin
      Exit(InfoREGIMM(Op));
    end;
    $02: begin
      Result.Flags := Result.Flags or 4;
      Exit;
    end;
    $03: begin
      Result.RWrite := Result.RWrite or (Cardinal(1) shl 31);
      Result.Flags := Result.Flags or 32;
      Result.Flags := Result.Flags or 4;
      Exit;
    end;
    $04: begin
      Result.RRead := Result.RRead or (Cardinal(1) shl S);
      Result.RRead := Result.RRead or (Cardinal(1) shl T);
      Result.Flags := Result.Flags or 4;
      Exit;
    end;
    $05: begin
      Result.RRead := Result.RRead or (Cardinal(1) shl S);
      Result.RRead := Result.RRead or (Cardinal(1) shl T);
      Result.Flags := Result.Flags or 4;
      Exit;
    end;
    $06: begin
      Result.RRead := Result.RRead or (Cardinal(1) shl S);
      Result.Flags := Result.Flags or 4;
      Exit;
    end;
    $07: begin
      Result.RRead := Result.RRead or (Cardinal(1) shl S);
      Result.Flags := Result.Flags or 4;
      Exit;
    end;
    $08: begin
      Result.RWrite := Result.RWrite or (Cardinal(1) shl T);
      Result.Flags := Result.Flags or 32;
      Result.RRead := Result.RRead or (Cardinal(1) shl S);
      Exit;
    end;
    $09: begin
      Result.RWrite := Result.RWrite or (Cardinal(1) shl T);
      Result.Flags := Result.Flags or 32;
      Result.RRead := Result.RRead or (Cardinal(1) shl S);
      Exit;
    end;
    $0a: begin
      Result.RWrite := Result.RWrite or (Cardinal(1) shl T);
      Result.Flags := Result.Flags or 32;
      Result.RRead := Result.RRead or (Cardinal(1) shl S);
      Exit;
    end;
    $0b: begin
      Result.RWrite := Result.RWrite or (Cardinal(1) shl T);
      Result.Flags := Result.Flags or 32;
      Result.RRead := Result.RRead or (Cardinal(1) shl S);
      Exit;
    end;
    $0c: begin
      Result.RWrite := Result.RWrite or (Cardinal(1) shl T);
      Result.Flags := Result.Flags or 32;
      Result.RRead := Result.RRead or (Cardinal(1) shl S);
      Exit;
    end;
    $0d: begin
      Result.RWrite := Result.RWrite or (Cardinal(1) shl T);
      Result.Flags := Result.Flags or 32;
      Result.RRead := Result.RRead or (Cardinal(1) shl S);
      Exit;
    end;
    $0e: begin
      Result.RWrite := Result.RWrite or (Cardinal(1) shl T);
      Result.Flags := Result.Flags or 32;
      Result.RRead := Result.RRead or (Cardinal(1) shl S);
      Exit;
    end;
    $0f: begin
      Result.RWrite := Result.RWrite or (Cardinal(1) shl T);
      Result.Flags := Result.Flags or 32;
      Exit;
    end;
    $10: begin
      Exit(InfoSCC(Op));
    end;
    $11: begin
      Exit;
    end;
    $12: begin
      Exit(InfoVU(Op));
    end;
    $13: begin
      Exit;
    end;
    $14: begin
      Exit;
    end;
    $15: begin
      Exit;
    end;
    $16: begin
      Exit;
    end;
    $17: begin
      Exit;
    end;
    $18: begin
      Exit;
    end;
    $19: begin
      Exit;
    end;
    $1a: begin
      Exit;
    end;
    $1b: begin
      Exit;
    end;
    $1c: begin
      Exit;
    end;
    $1d: begin
      Exit;
    end;
    $1e: begin
      Exit;
    end;
    $1f: begin
      Exit;
    end;
    $20: begin
      Result.RWrite := Result.RWrite or (Cardinal(1) shl T);
      Result.RRead := Result.RRead or (Cardinal(1) shl S);
      Result.Flags := Result.Flags or 1;
      Result.Flags := Result.Flags or 64;
      Exit;
    end;
    $21: begin
      Result.RWrite := Result.RWrite or (Cardinal(1) shl T);
      Result.RRead := Result.RRead or (Cardinal(1) shl S);
      Result.Flags := Result.Flags or 1;
      Result.Flags := Result.Flags or 64;
      Exit;
    end;
    $22: begin
      Exit;
    end;
    $23: begin
      Result.RWrite := Result.RWrite or (Cardinal(1) shl T);
      Result.RRead := Result.RRead or (Cardinal(1) shl S);
      Result.Flags := Result.Flags or 1;
      Result.Flags := Result.Flags or 64;
      Exit;
    end;
    $24: begin
      Result.RWrite := Result.RWrite or (Cardinal(1) shl T);
      Result.RRead := Result.RRead or (Cardinal(1) shl S);
      Result.Flags := Result.Flags or 1;
      Result.Flags := Result.Flags or 64;
      Exit;
    end;
    $25: begin
      Result.RWrite := Result.RWrite or (Cardinal(1) shl T);
      Result.RRead := Result.RRead or (Cardinal(1) shl S);
      Result.Flags := Result.Flags or 1;
      Result.Flags := Result.Flags or 64;
      Exit;
    end;
    $26: begin
      Exit;
    end;
    $27: begin
      Result.RWrite := Result.RWrite or (Cardinal(1) shl T);
      Result.RRead := Result.RRead or (Cardinal(1) shl S);
      Result.Flags := Result.Flags or 1;
      Result.Flags := Result.Flags or 64;
      Exit;
    end;
    $28: begin
      Result.RRead := Result.RRead or (Cardinal(1) shl T);
      Result.RRead := Result.RRead or (Cardinal(1) shl S);
      Result.Flags := Result.Flags or 2;
      Result.Flags := Result.Flags or 64;
      Exit;
    end;
    $29: begin
      Result.RRead := Result.RRead or (Cardinal(1) shl T);
      Result.RRead := Result.RRead or (Cardinal(1) shl S);
      Result.Flags := Result.Flags or 2;
      Result.Flags := Result.Flags or 64;
      Exit;
    end;
    $2a: begin
      Exit;
    end;
    $2b: begin
      Result.RRead := Result.RRead or (Cardinal(1) shl T);
      Result.RRead := Result.RRead or (Cardinal(1) shl S);
      Result.Flags := Result.Flags or 2;
      Result.Flags := Result.Flags or 64;
      Exit;
    end;
    $2c: begin
      Exit;
    end;
    $2d: begin
      Exit;
    end;
    $2e: begin
      Exit;
    end;
    $2f: begin
      Exit;
    end;
    $30: begin
      Exit;
    end;
    $31: begin
      Exit;
    end;
    $32: begin
      Exit(InfoLWC2(Op));
    end;
    $33: begin
      Exit;
    end;
    $34: begin
      Exit;
    end;
    $35: begin
      Exit;
    end;
    $36: begin
      Exit;
    end;
    $37: begin
      Exit;
    end;
    $38: begin
      Exit;
    end;
    $39: begin
      Exit;
    end;
    $3a: begin
      Exit(InfoSWC2(Op));
    end;
    $3b: begin
      Exit;
    end;
    $3c: begin
      Exit;
    end;
    $3d: begin
      Exit;
    end;
    $3e: begin
      Exit;
    end;
    $3f: begin
      Exit;
    end;
  end;
end;

function TN64RSP.InfoSPECIAL(Op: Cardinal): TRSPTimingInfo;
begin
  var S := Integer((Op shr 21) and 31); var T := Integer((Op shr 16) and 31);
  var D := Integer((Op shr 11) and 31); var V := Integer((Op shr 6) and 31);
  var XT := Integer((Op shr 15) and 31); var XD := Integer((Op shr 20) and 31);
  Result := Default(TRSPTimingInfo);
  case Op and  $3f of
    $00: begin
      Result.RWrite := Result.RWrite or (Cardinal(1) shl D);
      Result.Flags := Result.Flags or 32;
      Result.RRead := Result.RRead or (Cardinal(1) shl T);
      Exit;
    end;
    $01: begin
      Exit;
    end;
    $02: begin
      Result.RWrite := Result.RWrite or (Cardinal(1) shl D);
      Result.Flags := Result.Flags or 32;
      Result.RRead := Result.RRead or (Cardinal(1) shl T);
      Exit;
    end;
    $03: begin
      Result.RWrite := Result.RWrite or (Cardinal(1) shl D);
      Result.Flags := Result.Flags or 32;
      Result.RRead := Result.RRead or (Cardinal(1) shl T);
      Exit;
    end;
    $04: begin
      Result.RWrite := Result.RWrite or (Cardinal(1) shl D);
      Result.Flags := Result.Flags or 32;
      Result.RRead := Result.RRead or (Cardinal(1) shl T);
      Result.RRead := Result.RRead or (Cardinal(1) shl S);
      Exit;
    end;
    $05: begin
      Exit;
    end;
    $06: begin
      Result.RWrite := Result.RWrite or (Cardinal(1) shl D);
      Result.Flags := Result.Flags or 32;
      Result.RRead := Result.RRead or (Cardinal(1) shl T);
      Result.RRead := Result.RRead or (Cardinal(1) shl S);
      Exit;
    end;
    $07: begin
      Result.RWrite := Result.RWrite or (Cardinal(1) shl D);
      Result.Flags := Result.Flags or 32;
      Result.RRead := Result.RRead or (Cardinal(1) shl T);
      Result.RRead := Result.RRead or (Cardinal(1) shl S);
      Exit;
    end;
    $08: begin
      Result.RRead := Result.RRead or (Cardinal(1) shl S);
      Result.Flags := Result.Flags or 4;
      Exit;
    end;
    $09: begin
      Result.RWrite := Result.RWrite or (Cardinal(1) shl D);
      Result.Flags := Result.Flags or 32;
      Result.RRead := Result.RRead or (Cardinal(1) shl S);
      Result.Flags := Result.Flags or 4;
      Exit;
    end;
    $0a: begin
      Exit;
    end;
    $0b: begin
      Exit;
    end;
    $0c: begin
      Exit;
    end;
    $0d: begin
      Result.Flags := Result.Flags or 4;
      Result.Flags := Result.Flags or 128;
      Exit;
    end;
    $0e: begin
      Exit;
    end;
    $0f: begin
      Exit;
    end;
    $10: begin
      Exit;
    end;
    $11: begin
      Exit;
    end;
    $12: begin
      Exit;
    end;
    $13: begin
      Exit;
    end;
    $14: begin
      Exit;
    end;
    $15: begin
      Exit;
    end;
    $16: begin
      Exit;
    end;
    $17: begin
      Exit;
    end;
    $18: begin
      Exit;
    end;
    $19: begin
      Exit;
    end;
    $1a: begin
      Exit;
    end;
    $1b: begin
      Exit;
    end;
    $1c: begin
      Exit;
    end;
    $1d: begin
      Exit;
    end;
    $1e: begin
      Exit;
    end;
    $1f: begin
      Exit;
    end;
    $20: begin
      Result.RWrite := Result.RWrite or (Cardinal(1) shl D);
      Result.Flags := Result.Flags or 32;
      Result.RRead := Result.RRead or (Cardinal(1) shl S);
      Result.RRead := Result.RRead or (Cardinal(1) shl T);
      Exit;
    end;
    $21: begin
      Result.RWrite := Result.RWrite or (Cardinal(1) shl D);
      Result.Flags := Result.Flags or 32;
      Result.RRead := Result.RRead or (Cardinal(1) shl S);
      Result.RRead := Result.RRead or (Cardinal(1) shl T);
      Exit;
    end;
    $22: begin
      Result.RWrite := Result.RWrite or (Cardinal(1) shl D);
      Result.Flags := Result.Flags or 32;
      Result.RRead := Result.RRead or (Cardinal(1) shl S);
      Result.RRead := Result.RRead or (Cardinal(1) shl T);
      Exit;
    end;
    $23: begin
      Result.RWrite := Result.RWrite or (Cardinal(1) shl D);
      Result.Flags := Result.Flags or 32;
      Result.RRead := Result.RRead or (Cardinal(1) shl S);
      Result.RRead := Result.RRead or (Cardinal(1) shl T);
      Exit;
    end;
    $24: begin
      Result.RWrite := Result.RWrite or (Cardinal(1) shl D);
      Result.Flags := Result.Flags or 32;
      Result.RRead := Result.RRead or (Cardinal(1) shl S);
      Result.RRead := Result.RRead or (Cardinal(1) shl T);
      Exit;
    end;
    $25: begin
      Result.RWrite := Result.RWrite or (Cardinal(1) shl D);
      Result.Flags := Result.Flags or 32;
      Result.RRead := Result.RRead or (Cardinal(1) shl S);
      Result.RRead := Result.RRead or (Cardinal(1) shl T);
      Exit;
    end;
    $26: begin
      Result.RWrite := Result.RWrite or (Cardinal(1) shl D);
      Result.Flags := Result.Flags or 32;
      Result.RRead := Result.RRead or (Cardinal(1) shl S);
      Result.RRead := Result.RRead or (Cardinal(1) shl T);
      Exit;
    end;
    $27: begin
      Result.RWrite := Result.RWrite or (Cardinal(1) shl D);
      Result.Flags := Result.Flags or 32;
      Result.RRead := Result.RRead or (Cardinal(1) shl S);
      Result.RRead := Result.RRead or (Cardinal(1) shl T);
      Exit;
    end;
    $28: begin
      Exit;
    end;
    $29: begin
      Exit;
    end;
    $2a: begin
      Result.RWrite := Result.RWrite or (Cardinal(1) shl D);
      Result.Flags := Result.Flags or 32;
      Result.RRead := Result.RRead or (Cardinal(1) shl S);
      Result.RRead := Result.RRead or (Cardinal(1) shl T);
      Exit;
    end;
    $2b: begin
      Result.RWrite := Result.RWrite or (Cardinal(1) shl D);
      Result.Flags := Result.Flags or 32;
      Result.RRead := Result.RRead or (Cardinal(1) shl S);
      Result.RRead := Result.RRead or (Cardinal(1) shl T);
      Exit;
    end;
    $2c: begin
      Exit;
    end;
    $2d: begin
      Exit;
    end;
    $2e: begin
      Exit;
    end;
    $2f: begin
      Exit;
    end;
    $30: begin
      Exit;
    end;
    $31: begin
      Exit;
    end;
    $32: begin
      Exit;
    end;
    $33: begin
      Exit;
    end;
    $34: begin
      Exit;
    end;
    $35: begin
      Exit;
    end;
    $36: begin
      Exit;
    end;
    $37: begin
      Exit;
    end;
    $38: begin
      Exit;
    end;
    $39: begin
      Exit;
    end;
    $3a: begin
      Exit;
    end;
    $3b: begin
      Exit;
    end;
    $3c: begin
      Exit;
    end;
    $3d: begin
      Exit;
    end;
    $3e: begin
      Exit;
    end;
    $3f: begin
      Exit;
    end;
  end;
end;

function TN64RSP.InfoREGIMM(Op: Cardinal): TRSPTimingInfo;
begin
  var S := Integer((Op shr 21) and 31); var T := Integer((Op shr 16) and 31);
  var D := Integer((Op shr 11) and 31); var V := Integer((Op shr 6) and 31);
  var XT := Integer((Op shr 15) and 31); var XD := Integer((Op shr 20) and 31);
  Result := Default(TRSPTimingInfo);
  case Op shr 16 and  $1f of
    $00: begin
      Result.RRead := Result.RRead or (Cardinal(1) shl S);
      Result.Flags := Result.Flags or 4;
      Exit;
    end;
    $01: begin
      Result.RRead := Result.RRead or (Cardinal(1) shl S);
      Result.Flags := Result.Flags or 4;
      Exit;
    end;
    $02: begin
      Exit;
    end;
    $03: begin
      Exit;
    end;
    $04: begin
      Exit;
    end;
    $05: begin
      Exit;
    end;
    $06: begin
      Exit;
    end;
    $07: begin
      Exit;
    end;
    $08: begin
      Exit;
    end;
    $09: begin
      Exit;
    end;
    $0a: begin
      Exit;
    end;
    $0b: begin
      Exit;
    end;
    $0c: begin
      Exit;
    end;
    $0d: begin
      Exit;
    end;
    $0e: begin
      Exit;
    end;
    $0f: begin
      Exit;
    end;
    $10: begin
      Result.RWrite := Result.RWrite or (Cardinal(1) shl 31);
      Result.Flags := Result.Flags or 32;
      Result.RRead := Result.RRead or (Cardinal(1) shl S);
      Result.Flags := Result.Flags or 4;
      Exit;
    end;
    $11: begin
      Result.RWrite := Result.RWrite or (Cardinal(1) shl 31);
      Result.Flags := Result.Flags or 32;
      Result.RRead := Result.RRead or (Cardinal(1) shl S);
      Result.Flags := Result.Flags or 4;
      Exit;
    end;
    $12: begin
      Exit;
    end;
    $13: begin
      Exit;
    end;
    $14: begin
      Exit;
    end;
    $15: begin
      Exit;
    end;
    $16: begin
      Exit;
    end;
    $17: begin
      Exit;
    end;
    $18: begin
      Exit;
    end;
    $19: begin
      Exit;
    end;
    $1a: begin
      Exit;
    end;
    $1b: begin
      Exit;
    end;
    $1c: begin
      Exit;
    end;
    $1d: begin
      Exit;
    end;
    $1e: begin
      Exit;
    end;
    $1f: begin
      Exit;
    end;
  end;
end;

function TN64RSP.InfoSCC(Op: Cardinal): TRSPTimingInfo;
begin
  var S := Integer((Op shr 21) and 31); var T := Integer((Op shr 16) and 31);
  var D := Integer((Op shr 11) and 31); var V := Integer((Op shr 6) and 31);
  var XT := Integer((Op shr 15) and 31); var XD := Integer((Op shr 20) and 31);
  Result := Default(TRSPTimingInfo);
  case Op shr 21 and  $1f of
    $00: begin
      Result.RWrite := Result.RWrite or (Cardinal(1) shl T);
      Result.Flags := Result.Flags or 1;
      Result.Flags := Result.Flags or 2;
      Exit;
    end;
    $01: begin
      Exit;
    end;
    $02: begin
      Exit;
    end;
    $03: begin
      Exit;
    end;
    $04: begin
      Result.RRead := Result.RRead or (Cardinal(1) shl T);
      Result.Flags := Result.Flags or 1;
      Result.Flags := Result.Flags or 2;
      if ((D and 8) = 0) and ((D and 7) = 4) then Result.Flags := Result.Flags or 128;
      Exit;
    end;
    $05: begin
      Exit;
    end;
    $06: begin
      Exit;
    end;
    $07: begin
      Exit;
    end;
    $08: begin
      Exit;
    end;
    $09: begin
      Exit;
    end;
    $0a: begin
      Exit;
    end;
    $0b: begin
      Exit;
    end;
    $0c: begin
      Exit;
    end;
    $0d: begin
      Exit;
    end;
    $0e: begin
      Exit;
    end;
    $0f: begin
      Exit;
    end;
  end;
  case Op and  $3f of
    $20: begin
      Result.RWrite := Result.RWrite or (Cardinal(1) shl XD);
      Result.Flags := Result.Flags or 32;
      Exit;
    end;
    $23: begin
      Result.Flags := Result.Flags or 256;
      Exit;
    end;
    $24: begin
      Result.Flags := Result.Flags or 256;
      Exit;
    end;
    $25: begin
      Result.RRead := Result.RRead or (Cardinal(1) shl XD);
      Result.RRead := Result.RRead or (Cardinal(1) shl XT);
      Exit;
    end;
    $26: begin
      Result.RRead := Result.RRead or (Cardinal(1) shl XD);
      Exit;
    end;
    $27: begin
      Result.RRead := Result.RRead or (Cardinal(1) shl XD);
      Result.RRead := Result.RRead or (Cardinal(1) shl XT);
      Exit;
    end;
    $28: begin
      Result.RRead := Result.RRead or (Cardinal(1) shl XD);
      Exit;
    end;
    $29: begin
      Result.RRead := Result.RRead or (Cardinal(1) shl XD);
      Result.RRead := Result.RRead or (Cardinal(1) shl XT);
      Result.RWrite := Result.RWrite or (Cardinal(1) shl XT);
      Result.Flags := Result.Flags or 32;
      Exit;
    end;
    $2a: begin
      Result.RRead := Result.RRead or (Cardinal(1) shl XT);
      Exit;
    end;
    $2c: begin
      Exit;
    end;
  end;
end;

function TN64RSP.InfoVU(Op: Cardinal): TRSPTimingInfo;
begin
  var S := Integer((Op shr 21) and 31); var T := Integer((Op shr 16) and 31);
  var D := Integer((Op shr 11) and 31); var V := Integer((Op shr 6) and 31);
  var XT := Integer((Op shr 15) and 31); var XD := Integer((Op shr 20) and 31);
  Result := Default(TRSPTimingInfo);
  case Op shr 21 and  $1f of
    $00: begin
      Result.RWrite := Result.RWrite or (Cardinal(1) shl T);
      Result.VRead := Result.VRead or (Cardinal(1) shl D);
      Result.Flags := Result.Flags or 1;
      Result.Flags := Result.Flags or 2;
      Exit;
    end;
    $01: begin
      Exit;
    end;
    $02: begin
      Result.RWrite := Result.RWrite or (Cardinal(1) shl T);
      Result.VCRead := Result.VCRead or (Cardinal(1) shl D);
      Result.Flags := Result.Flags or 1;
      Result.Flags := Result.Flags or 2;
      Exit;
    end;
    $03: begin
      Exit;
    end;
    $04: begin
      Result.RRead := Result.RRead or (Cardinal(1) shl T);
      Result.VWrite := Result.VWrite or (Cardinal(1) shl D);
      Result.Flags := Result.Flags or 1;
      Result.Flags := Result.Flags or 2;
      Result.Flags := Result.Flags or 16;
      Exit;
    end;
    $05: begin
      Exit;
    end;
    $06: begin
      Result.RRead := Result.RRead or (Cardinal(1) shl T);
      Result.VCWrite := Result.VCWrite or (Cardinal(1) shl D);
      Result.Flags := Result.Flags or 1;
      Result.Flags := Result.Flags or 2;
      Exit;
    end;
    $07: begin
      Exit;
    end;
    $08: begin
      Exit;
    end;
    $09: begin
      Exit;
    end;
    $0a: begin
      Exit;
    end;
    $0b: begin
      Exit;
    end;
    $0c: begin
      Exit;
    end;
    $0d: begin
      Exit;
    end;
    $0e: begin
      Exit;
    end;
    $0f: begin
      Exit;
    end;
  end;
  case Op and  $3f of
    $00: begin
      Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
      Result.VRead := Result.VRead or (Cardinal(1) shl D);
      Result.VRead := Result.VRead or (Cardinal(1) shl T);
      Result.Flags := Result.Flags or 8;
      Exit;
    end;
    $01: begin
      Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
      Result.VRead := Result.VRead or (Cardinal(1) shl D);
      Result.VRead := Result.VRead or (Cardinal(1) shl T);
      Result.Flags := Result.Flags or 8;
      Exit;
    end;
    $02: begin
      Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
      Result.VRead := Result.VRead or (Cardinal(1) shl T);
      Result.Flags := Result.Flags or 8;
      Exit;
    end;
    $03: begin
      Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
      Result.VRead := Result.VRead or (Cardinal(1) shl D);
      Result.VRead := Result.VRead or (Cardinal(1) shl T);
      Result.Flags := Result.Flags or 8;
      Exit;
    end;
    $04: begin
      Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
      Result.VRead := Result.VRead or (Cardinal(1) shl D);
      Result.VRead := Result.VRead or (Cardinal(1) shl T);
      Result.Flags := Result.Flags or 8;
      Exit;
    end;
    $05: begin
      Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
      Result.VRead := Result.VRead or (Cardinal(1) shl D);
      Result.VRead := Result.VRead or (Cardinal(1) shl T);
      Result.Flags := Result.Flags or 8;
      Exit;
    end;
    $06: begin
      Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
      Result.VRead := Result.VRead or (Cardinal(1) shl D);
      Result.VRead := Result.VRead or (Cardinal(1) shl T);
      Result.Flags := Result.Flags or 8;
      Exit;
    end;
    $07: begin
      Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
      Result.VRead := Result.VRead or (Cardinal(1) shl D);
      Result.VRead := Result.VRead or (Cardinal(1) shl T);
      Result.Flags := Result.Flags or 8;
      Exit;
    end;
    $08: begin
      Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
      Result.VRead := Result.VRead or (Cardinal(1) shl D);
      Result.VRead := Result.VRead or (Cardinal(1) shl T);
      Result.Flags := Result.Flags or 8;
      Exit;
    end;
    $09: begin
      Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
      Result.VRead := Result.VRead or (Cardinal(1) shl D);
      Result.VRead := Result.VRead or (Cardinal(1) shl T);
      Result.Flags := Result.Flags or 8;
      Exit;
    end;
    $0a: begin
      Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
      Result.VRead := Result.VRead or (Cardinal(1) shl T);
      Result.Flags := Result.Flags or 8;
      Exit;
    end;
    $0b: begin
      Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
      Result.Flags := Result.Flags or 8;
      Exit;
    end;
    $0c: begin
      Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
      Result.VRead := Result.VRead or (Cardinal(1) shl D);
      Result.VRead := Result.VRead or (Cardinal(1) shl T);
      Result.Flags := Result.Flags or 8;
      Exit;
    end;
    $0d: begin
      Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
      Result.VRead := Result.VRead or (Cardinal(1) shl D);
      Result.VRead := Result.VRead or (Cardinal(1) shl T);
      Result.Flags := Result.Flags or 8;
      Exit;
    end;
    $0e: begin
      Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
      Result.VRead := Result.VRead or (Cardinal(1) shl D);
      Result.VRead := Result.VRead or (Cardinal(1) shl T);
      Result.Flags := Result.Flags or 8;
      Exit;
    end;
    $0f: begin
      Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
      Result.VRead := Result.VRead or (Cardinal(1) shl D);
      Result.VRead := Result.VRead or (Cardinal(1) shl T);
      Result.Flags := Result.Flags or 8;
      Exit;
    end;
    $10: begin
      Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
      Result.VRead := Result.VRead or (Cardinal(1) shl D);
      Result.VRead := Result.VRead or (Cardinal(1) shl T);
      Result.VCRead := Result.VCRead or (Cardinal(1) shl 0);
      Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 0);
      Result.Flags := Result.Flags or 8;
      Exit;
    end;
    $11: begin
      Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
      Result.VRead := Result.VRead or (Cardinal(1) shl D);
      Result.VRead := Result.VRead or (Cardinal(1) shl T);
      Result.VCRead := Result.VCRead or (Cardinal(1) shl 0);
      Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 0);
      Result.Flags := Result.Flags or 8;
      Exit;
    end;
    $12: begin
      Result.Flags := Result.Flags or 8;
      Exit;
    end;
    $13: begin
      Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
      Result.VRead := Result.VRead or (Cardinal(1) shl D);
      Result.VRead := Result.VRead or (Cardinal(1) shl T);
      Result.VCRead := Result.VCRead or (Cardinal(1) shl 0);
      Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 0);
      Result.Flags := Result.Flags or 8;
      Exit;
    end;
    $14: begin
      Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
      Result.VRead := Result.VRead or (Cardinal(1) shl D);
      Result.VRead := Result.VRead or (Cardinal(1) shl T);
      Result.VCRead := Result.VCRead or (Cardinal(1) shl 0);
      Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 0);
      Result.Flags := Result.Flags or 8;
      Exit;
    end;
    $15: begin
      Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
      Result.VRead := Result.VRead or (Cardinal(1) shl D);
      Result.VRead := Result.VRead or (Cardinal(1) shl T);
      Result.VCRead := Result.VCRead or (Cardinal(1) shl 0);
      Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 0);
      Result.Flags := Result.Flags or 8;
      Exit;
    end;
    $16: begin
      Result.Flags := Result.Flags or 8;
      Exit;
    end;
    $17: begin
      Result.Flags := Result.Flags or 8;
      Exit;
    end;
    $18: begin
      Result.Flags := Result.Flags or 8;
      Exit;
    end;
    $19: begin
      Result.Flags := Result.Flags or 8;
      Exit;
    end;
    $1a: begin
      Result.Flags := Result.Flags or 8;
      Exit;
    end;
    $1b: begin
      Result.Flags := Result.Flags or 8;
      Exit;
    end;
    $1c: begin
      Result.Flags := Result.Flags or 8;
      Exit;
    end;
    $1d: begin
      Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
      Result.Flags := Result.Flags or 8;
      Exit;
    end;
    $1e: begin
      Result.Flags := Result.Flags or 8;
      Exit;
    end;
    $1f: begin
      Result.Flags := Result.Flags or 8;
      Exit;
    end;
    $20: begin
      Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
      Result.VRead := Result.VRead or (Cardinal(1) shl D);
      Result.VRead := Result.VRead or (Cardinal(1) shl T);
      Result.VCRead := Result.VCRead or (Cardinal(1) shl 0);
      Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 0);
      Result.VCRead := Result.VCRead or (Cardinal(1) shl 1);
      Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 1);
      Result.Flags := Result.Flags or 8;
      Exit;
    end;
    $21: begin
      Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
      Result.VRead := Result.VRead or (Cardinal(1) shl D);
      Result.VRead := Result.VRead or (Cardinal(1) shl T);
      Result.VCRead := Result.VCRead or (Cardinal(1) shl 0);
      Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 0);
      Result.VCRead := Result.VCRead or (Cardinal(1) shl 1);
      Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 1);
      Result.Flags := Result.Flags or 8;
      Exit;
    end;
    $22: begin
      Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
      Result.VRead := Result.VRead or (Cardinal(1) shl D);
      Result.VRead := Result.VRead or (Cardinal(1) shl T);
      Result.VCRead := Result.VCRead or (Cardinal(1) shl 0);
      Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 0);
      Result.VCRead := Result.VCRead or (Cardinal(1) shl 1);
      Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 1);
      Result.Flags := Result.Flags or 8;
      Exit;
    end;
    $23: begin
      Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
      Result.VRead := Result.VRead or (Cardinal(1) shl D);
      Result.VRead := Result.VRead or (Cardinal(1) shl T);
      Result.VCRead := Result.VCRead or (Cardinal(1) shl 0);
      Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 0);
      Result.VCRead := Result.VCRead or (Cardinal(1) shl 1);
      Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 1);
      Result.Flags := Result.Flags or 8;
      Exit;
    end;
    $24: begin
      Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
      Result.VRead := Result.VRead or (Cardinal(1) shl D);
      Result.VRead := Result.VRead or (Cardinal(1) shl T);
      Result.VCRead := Result.VCRead or (Cardinal(1) shl 0);
      Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 0);
      Result.VCRead := Result.VCRead or (Cardinal(1) shl 1);
      Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 1);
      Result.VCRead := Result.VCRead or (Cardinal(1) shl 2);
      Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 2);
      Result.Flags := Result.Flags or 8;
      Exit;
    end;
    $25: begin
      Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
      Result.VRead := Result.VRead or (Cardinal(1) shl D);
      Result.VRead := Result.VRead or (Cardinal(1) shl T);
      Result.VCRead := Result.VCRead or (Cardinal(1) shl 0);
      Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 0);
      Result.VCRead := Result.VCRead or (Cardinal(1) shl 1);
      Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 1);
      Result.VCRead := Result.VCRead or (Cardinal(1) shl 2);
      Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 2);
      Result.Flags := Result.Flags or 8;
      Exit;
    end;
    $26: begin
      Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
      Result.VRead := Result.VRead or (Cardinal(1) shl D);
      Result.VRead := Result.VRead or (Cardinal(1) shl T);
      Result.VCRead := Result.VCRead or (Cardinal(1) shl 0);
      Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 0);
      Result.VCRead := Result.VCRead or (Cardinal(1) shl 1);
      Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 1);
      Result.VCRead := Result.VCRead or (Cardinal(1) shl 2);
      Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 2);
      Result.Flags := Result.Flags or 8;
      Exit;
    end;
    $27: begin
      Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
      Result.VRead := Result.VRead or (Cardinal(1) shl D);
      Result.VRead := Result.VRead or (Cardinal(1) shl T);
      Result.VCRead := Result.VCRead or (Cardinal(1) shl 0);
      Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 0);
      Result.VCRead := Result.VCRead or (Cardinal(1) shl 1);
      Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 1);
      Result.Flags := Result.Flags or 8;
      Exit;
    end;
    $28: begin
      Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
      Result.VRead := Result.VRead or (Cardinal(1) shl D);
      Result.VRead := Result.VRead or (Cardinal(1) shl T);
      Result.Flags := Result.Flags or 8;
      Exit;
    end;
    $29: begin
      Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
      Result.VRead := Result.VRead or (Cardinal(1) shl D);
      Result.VRead := Result.VRead or (Cardinal(1) shl T);
      Result.Flags := Result.Flags or 8;
      Exit;
    end;
    $2a: begin
      Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
      Result.VRead := Result.VRead or (Cardinal(1) shl D);
      Result.VRead := Result.VRead or (Cardinal(1) shl T);
      Result.Flags := Result.Flags or 8;
      Exit;
    end;
    $2b: begin
      Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
      Result.VRead := Result.VRead or (Cardinal(1) shl D);
      Result.VRead := Result.VRead or (Cardinal(1) shl T);
      Result.Flags := Result.Flags or 8;
      Exit;
    end;
    $2c: begin
      Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
      Result.VRead := Result.VRead or (Cardinal(1) shl D);
      Result.VRead := Result.VRead or (Cardinal(1) shl T);
      Result.Flags := Result.Flags or 8;
      Exit;
    end;
    $2d: begin
      Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
      Result.VRead := Result.VRead or (Cardinal(1) shl D);
      Result.VRead := Result.VRead or (Cardinal(1) shl T);
      Result.Flags := Result.Flags or 8;
      Exit;
    end;
    $2e: begin
      Result.Flags := Result.Flags or 8;
      Exit;
    end;
    $2f: begin
      Result.Flags := Result.Flags or 8;
      Exit;
    end;
    $30: begin
      Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
      Result.VFake := Result.VFake or (Cardinal(1) shl D);
      Result.VRead := Result.VRead or (Cardinal(1) shl T);
      Result.Flags := Result.Flags or 8;
      Exit;
    end;
    $31: begin
      Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
      Result.VFake := Result.VFake or (Cardinal(1) shl D);
      Result.VRead := Result.VRead or (Cardinal(1) shl T);
      Result.Flags := Result.Flags or 8;
      Exit;
    end;
    $32: begin
      Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
      Result.VFake := Result.VFake or (Cardinal(1) shl D);
      Result.VRead := Result.VRead or (Cardinal(1) shl T);
      Result.Flags := Result.Flags or 8;
      Exit;
    end;
    $33: begin
      Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
      Result.VFake := Result.VFake or (Cardinal(1) shl D);
      Result.VRead := Result.VRead or (Cardinal(1) shl T);
      Result.Flags := Result.Flags or 8;
      Exit;
    end;
    $34: begin
      Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
      Result.VFake := Result.VFake or (Cardinal(1) shl D);
      Result.VRead := Result.VRead or (Cardinal(1) shl T);
      Result.Flags := Result.Flags or 8;
      Exit;
    end;
    $35: begin
      Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
      Result.VFake := Result.VFake or (Cardinal(1) shl D);
      Result.VRead := Result.VRead or (Cardinal(1) shl T);
      Result.Flags := Result.Flags or 8;
      Exit;
    end;
    $36: begin
      Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
      Result.VFake := Result.VFake or (Cardinal(1) shl D);
      Result.VRead := Result.VRead or (Cardinal(1) shl T);
      Result.Flags := Result.Flags or 8;
      Exit;
    end;
    $37: begin
      Result.VFake := Result.VFake or (Cardinal(1) shl V);
      Result.Flags := Result.Flags or 8;
      Result.Flags := Result.Flags or 16;
      Exit;
    end;
    $38: begin
      Result.Flags := Result.Flags or 8;
      Exit;
    end;
    $39: begin
      Result.Flags := Result.Flags or 8;
      Exit;
    end;
    $3a: begin
      Result.Flags := Result.Flags or 8;
      Exit;
    end;
    $3b: begin
      Result.Flags := Result.Flags or 8;
      Exit;
    end;
    $3c: begin
      Result.Flags := Result.Flags or 8;
      Exit;
    end;
    $3d: begin
      Result.Flags := Result.Flags or 8;
      Exit;
    end;
    $3e: begin
      Result.Flags := Result.Flags or 8;
      Exit;
    end;
    $3f: begin
      Result.Flags := Result.Flags or 8;
      Exit;
    end;
  end;
end;

function TN64RSP.InfoLWC2(Op: Cardinal): TRSPTimingInfo;
begin
  var S := Integer((Op shr 21) and 31); var T := Integer((Op shr 16) and 31);
  var D := Integer((Op shr 11) and 31); var V := Integer((Op shr 6) and 31);
  var XT := Integer((Op shr 15) and 31); var XD := Integer((Op shr 20) and 31);
  Result := Default(TRSPTimingInfo);
  case Op shr 11 and  $1f of
    $00: begin
      Result.VWrite := Result.VWrite or (Cardinal(1) shl T);
      Result.RRead := Result.RRead or (Cardinal(1) shl S);
      Result.Flags := Result.Flags or 1;
      Result.Flags := Result.Flags or 64;
      Exit;
    end;
    $01: begin
      Result.VWrite := Result.VWrite or (Cardinal(1) shl T);
      Result.RRead := Result.RRead or (Cardinal(1) shl S);
      Result.Flags := Result.Flags or 1;
      Result.Flags := Result.Flags or 64;
      Exit;
    end;
    $02: begin
      Result.VWrite := Result.VWrite or (Cardinal(1) shl T);
      Result.RRead := Result.RRead or (Cardinal(1) shl S);
      Result.Flags := Result.Flags or 1;
      Result.Flags := Result.Flags or 64;
      Exit;
    end;
    $03: begin
      Result.VWrite := Result.VWrite or (Cardinal(1) shl T);
      Result.RRead := Result.RRead or (Cardinal(1) shl S);
      Result.Flags := Result.Flags or 1;
      Result.Flags := Result.Flags or 64;
      Exit;
    end;
    $04: begin
      Result.VWrite := Result.VWrite or (Cardinal(1) shl T);
      Result.RRead := Result.RRead or (Cardinal(1) shl S);
      Result.Flags := Result.Flags or 1;
      Result.Flags := Result.Flags or 64;
      Exit;
    end;
    $05: begin
      Result.VWrite := Result.VWrite or (Cardinal(1) shl T);
      Result.RRead := Result.RRead or (Cardinal(1) shl S);
      Result.Flags := Result.Flags or 1;
      Result.Flags := Result.Flags or 64;
      Exit;
    end;
    $06: begin
      Result.VWrite := Result.VWrite or (Cardinal(1) shl T);
      Result.RRead := Result.RRead or (Cardinal(1) shl S);
      Result.Flags := Result.Flags or 1;
      Result.Flags := Result.Flags or 64;
      Exit;
    end;
    $07: begin
      Result.VWrite := Result.VWrite or (Cardinal(1) shl T);
      Result.RRead := Result.RRead or (Cardinal(1) shl S);
      Result.Flags := Result.Flags or 1;
      Result.Flags := Result.Flags or 64;
      Exit;
    end;
    $08: begin
      Result.VWrite := Result.VWrite or (Cardinal(1) shl T);
      Result.RRead := Result.RRead or (Cardinal(1) shl S);
      Result.Flags := Result.Flags or 1;
      Result.Flags := Result.Flags or 64;
      Exit;
    end;
    $09: begin
      Result.VWrite := Result.VWrite or (Cardinal(1) shl T);
      Result.RRead := Result.RRead or (Cardinal(1) shl S);
      Result.Flags := Result.Flags or 1;
      Result.Flags := Result.Flags or 64;
      Exit;
    end;
    $0b: begin
      Result.VWrite := Result.VWrite or (Cardinal($FF) shl (T and not 7));
      Result.RRead := Result.RRead or (Cardinal(1) shl S);
      Result.Flags := Result.Flags or 1;
      Result.Flags := Result.Flags or 16;
      Result.Flags := Result.Flags or 64;
      Exit;
    end;
  end;
end;

function TN64RSP.InfoSWC2(Op: Cardinal): TRSPTimingInfo;
begin
  var S := Integer((Op shr 21) and 31); var T := Integer((Op shr 16) and 31);
  var D := Integer((Op shr 11) and 31); var V := Integer((Op shr 6) and 31);
  var XT := Integer((Op shr 15) and 31); var XD := Integer((Op shr 20) and 31);
  Result := Default(TRSPTimingInfo);
  case Op shr 11 and  $1f of
    $00: begin
      Result.VRead := Result.VRead or (Cardinal(1) shl T);
      Result.RRead := Result.RRead or (Cardinal(1) shl S);
      Result.Flags := Result.Flags or 2;
      Result.Flags := Result.Flags or 64;
      Exit;
    end;
    $01: begin
      Result.VRead := Result.VRead or (Cardinal(1) shl T);
      Result.RRead := Result.RRead or (Cardinal(1) shl S);
      Result.Flags := Result.Flags or 2;
      Result.Flags := Result.Flags or 64;
      Exit;
    end;
    $02: begin
      Result.VRead := Result.VRead or (Cardinal(1) shl T);
      Result.RRead := Result.RRead or (Cardinal(1) shl S);
      Result.Flags := Result.Flags or 2;
      Result.Flags := Result.Flags or 64;
      Exit;
    end;
    $03: begin
      Result.VRead := Result.VRead or (Cardinal(1) shl T);
      Result.RRead := Result.RRead or (Cardinal(1) shl S);
      Result.Flags := Result.Flags or 2;
      Result.Flags := Result.Flags or 64;
      Exit;
    end;
    $04: begin
      Result.VRead := Result.VRead or (Cardinal(1) shl T);
      Result.RRead := Result.RRead or (Cardinal(1) shl S);
      Result.Flags := Result.Flags or 2;
      Result.Flags := Result.Flags or 64;
      Exit;
    end;
    $05: begin
      Result.VRead := Result.VRead or (Cardinal(1) shl T);
      Result.RRead := Result.RRead or (Cardinal(1) shl S);
      Result.Flags := Result.Flags or 2;
      Result.Flags := Result.Flags or 64;
      Exit;
    end;
    $06: begin
      Result.VRead := Result.VRead or (Cardinal(1) shl T);
      Result.RRead := Result.RRead or (Cardinal(1) shl S);
      Result.Flags := Result.Flags or 2;
      Result.Flags := Result.Flags or 64;
      Exit;
    end;
    $07: begin
      Result.VRead := Result.VRead or (Cardinal(1) shl T);
      Result.RRead := Result.RRead or (Cardinal(1) shl S);
      Result.Flags := Result.Flags or 2;
      Result.Flags := Result.Flags or 64;
      Exit;
    end;
    $08: begin
      Result.VRead := Result.VRead or (Cardinal(1) shl T);
      Result.RRead := Result.RRead or (Cardinal(1) shl S);
      Result.Flags := Result.Flags or 2;
      Result.Flags := Result.Flags or 64;
      Exit;
    end;
    $09: begin
      Result.VRead := Result.VRead or (Cardinal(1) shl T);
      Result.RRead := Result.RRead or (Cardinal(1) shl S);
      Result.Flags := Result.Flags or 2;
      Result.Flags := Result.Flags or 64;
      Exit;
    end;
    $0a: begin
      Result.VRead := Result.VRead or (Cardinal(1) shl T);
      Result.RRead := Result.RRead or (Cardinal(1) shl S);
      Result.Flags := Result.Flags or 2;
      Result.Flags := Result.Flags or 64;
      Exit;
    end;
    $0b: begin
      Result.VRead := Result.VRead or (Cardinal($FF) shl (T and not 7));
      Result.RRead := Result.RRead or (Cardinal(1) shl S);
      Result.Flags := Result.Flags or 2;
      Result.Flags := Result.Flags or 64;
      Exit;
    end;
  end;
end;

function TN64RSP.CanPair(const A, B: TRSPTimingInfo): Boolean;
begin
  Result := (((A.Flags xor B.Flags) and 8) <> 0) and
    ((A.VWrite and (B.VRead or B.VWrite)) = 0) and
    ((A.VCWrite and (B.VCRead or B.VCWrite)) = 0) and
    not ((((A.Flags or not B.Flags) and 16) <> 0) and ((A.VWrite and B.VFake) <> 0));
end;

procedure TN64RSP.IssueInstruction(Op: Cardinal; var PC, Status, Interrupt: Cardinal);
begin
    if FBus.TraceEnabled then
      FBus.Trace(TN64TraceKind.Instruction, $04001000 + (PC and $FFC),
        $04001000 + (PC and $FFC), Op);
    var Current := PC;
    if FBranch then
    begin
      PC := FNextPC;
      FBranch := False
    end
    else
      PC := (PC + 4) and $FFC;
    var Code := Op shr 26;
    var S := (Op shr 21) and 31;
    var T := (Op shr 16) and 31;
    var D := (Op shr 11) and 31;
    var N := (Op shr 6) and 31;
    var A := FReg[S];
    var B := FReg[T];
    var Imm := SX(Op and $FFFF, 16);
    var Address := Cardinal(Add64(A, Imm) and $FFF);
    var Target := Cardinal(Add64(Current + 4, Imm shl 2) and $FFC);
    var Taken := False;
    case Code of
      0:
        case Op and 63 of
          0:
            FReg[D] := B shl N;
          2:
            FReg[D] := B shr N;
          3:
            FReg[D] := Cardinal(SAR(B, N, 32) and $FFFFFFFF);
          4:
            FReg[D] := B shl (A and 31);
          6:
            FReg[D] := B shr (A and 31);
          7:
            FReg[D] := Cardinal(SAR(B, A and 31, 32) and $FFFFFFFF);
          8, 9:
            begin
              if (Op and 63) = 9 then
                FReg[D] := (Current + 8) and $FFF;
              FNextPC := A and $FFC;
              FBranch := True
            end;
          13:
            begin
              Status := Status or 3;
              if (Status and $40) <> 0 then
                Interrupt := Interrupt or 1
            end;
          32, 33:
            FReg[D] := Add32(A, B);
          34, 35:
            FReg[D] := Cardinal(Sub64(A, B) and $FFFFFFFF);
          36:
            FReg[D] := A and B;
          37:
            FReg[D] := A or B;
          38:
            FReg[D] := A xor B;
          39:
            FReg[D] := not (A or B);
          42:
            FReg[D] := Ord(SignedLess(SX(A, 32), SX(B, 32)));
          43:
            FReg[D] := Ord(A < B);
        else
          raise EN64Unsupported.CreateFmt('RSP scalar opcode %8.8x', [Op]);
        end;
      1, 4..7:
        begin
          case Code of
            1:
              begin
                if not (T in [0, 1, 16, 17]) then
                  raise EN64Unsupported.CreateFmt('RSP REGIMM opcode %8.8x', [Op]);
                Taken := SignedLess(SX(A, 32), 0);
                if (T and 1) <> 0 then
                  Taken := not Taken;
                if (T and 16) <> 0 then
                  FReg[31] := (Current + 8) and $FFF
              end;
            4:
              Taken := A = B;
            5:
              Taken := A <> B;
            6:
              Taken := not SignedLess(0, SX(A, 32));
            7:
              Taken := SignedLess(0, SX(A, 32));
          end;
          if Taken then
          begin
            FNextPC := Target;
            FBranch := True
          end;
        end;
      2, 3:
        begin
          if Code = 3 then
            FReg[31] := (Current + 8) and $FFF;
          FNextPC := (Op shl 2) and $FFC;
          FBranch := True
        end;
      8, 9:
        FReg[T] := Cardinal(Add64(A, Imm) and $FFFFFFFF);
      10:
        FReg[T] := Ord(SignedLess(SX(A, 32), Imm));
      11:
        FReg[T] := Ord(UInt64(A) < (Imm and $FFFFFFFF));
      12:
        FReg[T] := A and (Op and $FFFF);
      13:
        FReg[T] := A or (Op and $FFFF);
      14:
        FReg[T] := A xor (Op and $FFFF);
      15:
        FReg[T] := (Op and $FFFF) shl 16;
      16:
        begin
          var IOIndex := D and 15;
          var IOAddress := $04040000 + IOIndex * 4;
          if IOIndex >= 8 then
            IOAddress := $04100000 + (IOIndex - 8) * 4;
          if S = 0 then
          begin
            FReg[T] := FBus.Read32(IOAddress);
            if FBus.TraceEnabled then FBus.Trace(TN64TraceKind.MMIORead,
              $04001000 + Current, IOAddress, FReg[T]);
          end
          else if S = 4 then
          begin
            if FBus.TraceEnabled then FBus.Trace(TN64TraceKind.MMIOWrite,
              $04001000 + Current, IOAddress, B);
            FBus.Write32(IOAddress, B);
          end
          else
            raise EN64Unsupported.CreateFmt('RSP COP0 opcode %8.8x', [Op]);
        end;
      18:
        if S >= 16 then
          VectorOp(Op)
        else
        begin
          var E := Integer((Op shr 7) and 15);
          case S of
            0:
              FReg[T] := Cardinal(SX((Word(GetByte(D, E)) shl 8) or GetByte(D, E + 1), 16) and $FFFFFFFF);
            2:
              case D and 3 of
                0:
                  FReg[T] := Cardinal(SX(FVCO, 16) and $FFFFFFFF);
                1:
                  FReg[T] := Cardinal(SX(FVCC, 16) and $FFFFFFFF);
              else
                FReg[T] := FVCE
              end;
            4:
              begin
                SetByte(D, E, Byte((B shr 8) and $FF));
                if E < 15 then
                  SetByte(D, E + 1, Byte(B and $FF))
              end;
            6:
              case D and 3 of
                0:
                  FVCO := Word(B and $FFFF);
                1:
                  FVCC := Word(B and $FFFF);
              else
                FVCE := Word(B and $FF)
              end;
          else
            raise EN64Unsupported.CreateFmt('RSP COP2 opcode %8.8x', [Op]);
          end;
        end;
      32, 33, 35..37, 39:
        begin
          var Size := 1;
          if Code in [33, 37] then
            Size := 2
          else if Code in [35, 39] then
            Size := 4;
          var V: Cardinal := 0;
          for var I := 0 to Size - 1 do
            V := (V shl 8) or FBus.Read8($04000000 + ((Address + Cardinal(I)) and $FFF));
          if Code in [32, 33] then
            V := Cardinal(SX(V, Size * 8) and $FFFFFFFF);
          FReg[T] := V;
        end;
      40, 41, 43:
        begin
          var Size := 1;
          if Code = 41 then
            Size := 2
          else if Code = 43 then
            Size := 4;
          for var I := 0 to Size - 1 do
            FBus.Write8($04000000 + ((Address + Cardinal(I)) and $FFF), Byte((B shr ((Size - 1 - I) * 8)) and $FF));
        end;
      50:
        VectorMemory(Op, False);
      58:
        VectorMemory(Op, True);
    else
      raise EN64Unsupported.CreateFmt('RSP opcode %8.8x', [Op]);
    end;
    FReg[0] := 0;
end;

function TN64RSP.ExecuteCycles(var PC, Status, Interrupt: Cardinal; Cycles: Integer): Integer;
begin
  Result := 0;
  for var Iteration := 1 to Cycles do begin
    if (Status and 1) <> 0 then Break;
    if FBranchBubble > 0 then begin Dec(FBranchBubble); AgePipeline; Inc(Result); Continue end;
    if FHasStalledOpcode and (FStalledPC <> PC) then begin
      FHasStalledOpcode := False; FHasStalledSecondOpcode := False;
    end;
    var Op, Second: Cardinal; var Pair: Boolean;
    if FHasStalledOpcode then begin
      Op := FStalledOpcode; Second := FStalledSecondOpcode; Pair := FHasStalledSecondOpcode;
    end else begin
      Op := FBus.Read32($04001000 + (PC and $FFC)); Second := 0; Pair := False;
      var FirstInfo := InfoEXECUTE(Op);
      if (FSingleIssue = 0) and ((Status and $20) = 0) and ((FirstInfo.Flags and 4) = 0) then begin
        Second := FBus.Read32($04001000 + ((PC + 4) and $FFC));
        Pair := CanPair(FirstInfo, InfoEXECUTE(Second));
      end;
    end;
    var Info := InfoEXECUTE(Op); var Other := Default(TRSPTimingInfo);
    if Pair then Other := InfoEXECUTE(Second);
    var Sources := Info.RRead or Other.RRead;
    var Vectors := Info.VRead or Other.VRead;
    var Loading := ((Info.Flags or Other.Flags) and 1) <> 0;
    var Storing := ((Info.Flags or Other.Flags) and 2) <> 0;
    var Hazard := Storing and ((FLoadHistory and 2) <> 0);
    for var I := 0 to 31 do begin
      if ((Sources and (Cardinal(1) shl I)) <> 0) and (FScalarReady[I] > 0) then Hazard := True;
      if ((Vectors and (Cardinal(1) shl I)) <> 0) and (FVectorReady[I] > 0) then Hazard := True;
    end;
    if Hazard then begin
      FStalledOpcode := Op; FStalledPC := PC; FHasStalledOpcode := True;
      FStalledSecondOpcode := Second; FHasStalledSecondOpcode := Pair;
      AgePipeline; Inc(Result); Continue;
    end;
    FHasStalledOpcode := False; FHasStalledSecondOpcode := False;
    var DelaySlot := FBranch;
    IssueInstruction(Op, PC, Status, Interrupt);
    if Pair and ((Status and 1) = 0) then IssueInstruction(Second, PC, Status, Interrupt);
    AgePipeline;
    var Writes: Cardinal := 0;
    if (Info.Flags and 32) = 0 then Writes := Info.RWrite;
    if Pair and ((Other.Flags and 32) = 0) then Writes := Writes or Other.RWrite;
    for var I := 1 to 31 do if (Writes and (Cardinal(1) shl I)) <> 0 then FScalarReady[I] := 2;
    Writes := Info.VWrite or Other.VWrite;
    for var I := 0 to 31 do if (Writes and (Cardinal(1) shl I)) <> 0 then FVectorReady[I] := 3;
    if Loading then FLoadHistory := FLoadHistory or 1;
    FSingleIssue := Byte(Ord(((Info.Flags or Other.Flags) and 4) <> 0));
    if DelaySlot then begin
      FBranchBubble := 1;
      if (PC and 4) <> 0 then FSingleIssue := 1;
    end;
    Inc(Result);
    if (Status and $20) <> 0 then Status := Status or 1;
  end;
end;

procedure TN64RSP.SerializeState(State: TStateArchive);
  function CanonicalBoolean(const Value: Boolean): Boolean;
  begin
    // Delphi may eliminate Ord(Boolean)>1 as impossible: inspect storage.
    var Stored: Byte := 0;
    Move(Value, Stored, SizeOf(Stored));
    Result := Stored <= 1;
  end;
begin
  State.Field(FReg, SizeOf(FReg));
  State.Field(FVec, SizeOf(FVec));
  State.Field(FAcc, SizeOf(FAcc));
  State.Field(FVCO, SizeOf(FVCO));
  State.Field(FVCC, SizeOf(FVCC));
  State.Field(FVCE, SizeOf(FVCE));
  State.Field(FNextPC, SizeOf(FNextPC));
  State.Field(FBranch, SizeOf(FBranch));
  State.Field(FDivisionHigh, SizeOf(FDivisionHigh));
  State.Field(FDivisionInput, SizeOf(FDivisionInput));
  State.Field(FDivisionResult, SizeOf(FDivisionResult));
  State.Field(FScalarReady, SizeOf(FScalarReady));
  State.Field(FLoadHistory, SizeOf(FLoadHistory));
  State.Field(FBranchBubble, SizeOf(FBranchBubble));
  State.Field(FStalledOpcode, SizeOf(FStalledOpcode));
  State.Field(FStalledPC, SizeOf(FStalledPC));
  State.Field(FHasStalledOpcode, SizeOf(FHasStalledOpcode));
  State.Field(FVectorReady, SizeOf(FVectorReady));
  State.Field(FSingleIssue, SizeOf(FSingleIssue));
  State.Field(FStalledSecondOpcode, SizeOf(FStalledSecondOpcode));
  State.Field(FHasStalledSecondOpcode, SizeOf(FHasStalledSecondOpcode));
  if State.Loading then
  begin
    if (FNextPC > $FFC) or ((FNextPC and 3) <> 0) then
      raise EReadError.Create('Invalid RSP PC');
    if (FLoadHistory > 3) or (FBranchBubble > 1) or
      (FStalledPC > $FFC) or ((FStalledPC and 3) <> 0) or
      not CanonicalBoolean(FHasStalledOpcode) or not CanonicalBoolean(FBranch) or
      not CanonicalBoolean(FDivisionHigh) or (FScalarReady[0] <> 0) then
      raise EReadError.Create('Invalid RSP pipeline snapshot');
    for var I := 1 to 31 do
      if FScalarReady[I] > 2 then raise EReadError.Create('Invalid RSP scalar readiness');
    if (FSingleIssue > 1) or not CanonicalBoolean(FHasStalledSecondOpcode) or
      (FHasStalledSecondOpcode and not FHasStalledOpcode) then raise EReadError.Create('Invalid RSP pairing snapshot');
    for var I := 0 to 31 do
      if FVectorReady[I] > 3 then raise EReadError.Create('Invalid RSP vector readiness');
    for var I := 0 to 7 do
      if (FAcc[I] < -140737488355328) or (FAcc[I] > 140737488355327) then
        raise EReadError.Create('Invalid RSP accumulator');
  end;
end;

end.

