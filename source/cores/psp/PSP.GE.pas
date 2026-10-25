unit PSP.GE;

{$Q-}{$R-}{$POINTERMATH ON}

interface

uses System.SysUtils, System.Generics.Collections, PSP.Memory, PSP.CPU, PSP.Kernel;

type
  TPSPGEVertexLayout = record
    Key,Stride,OneSize:Cardinal;
    TextureOffset,ColorOffset,NormalOffset,PositionOffset:Integer;
    TexType,ColorType,NormalType,PositionType,WeightType,WeightCount,MorphCount:Cardinal;
  end;
  TPSPGETextureState=record
    Width,Height,Format,BitsPerPixel,Stride,RowBytes,Address:Cardinal;
    ClampU,ClampV,Swizzled:Boolean;
    CLUTShift,CLUTMask,CLUTStart,CLUTIndexMask:Cardinal;
  end;
  TPSPGEVertex = record
    X,Y,Z,U,V: Double;
    Color: Cardinal;
  end;
  TPSPGEList = class
    Id, PC, Stall, CallbackId, Status, Offset, FinishToken, SignalMode, SignalToken, PreviousCommand: Cardinal;
    Stack: TArray<Cardinal>;
    Finish, Waiting, Paused: Boolean;
  end;
  TPSPGECallback = record
    Signal, SignalArg, Finish, FinishArg: Cardinal;
  end;
  TPSPGE = class
  private
    FMemory: TPSPMemory;
    FCPU: TPSPCPU;
    FKernel: TPSPKernel;
    FRegisters: array[0..255] of Cardinal;
    FWorld,FView: array[0..11] of Single;
    FBones:array[0..95] of Single;
    FBoneIndex:Integer;
    FLayout:TPSPGEVertexLayout;
    FLayoutValid:Boolean;
    FProjection: array[0..15] of Single;
    FWorldIndex,FViewIndex,FProjectionIndex: Integer;
    FVertexAddress,FIndexAddress,FTranslation: Cardinal;
    FLists: TObjectList<TPSPGEList>;
    FQueue: TList<TPSPGEList>;
    FCallbacks: TDictionary<Cardinal,TPSPGECallback>;
    FNextList,FNextCallback: Cardinal;
    FCLUT: TBytes;
    FTexture:TPSPGETextureState;
    FCLUTColors:array[0..1023] of Cardinal;
    FCLUTDirty:Boolean;
    FCLUTFormat:Cardinal;
    procedure ConfigureTexture;
    function Light(X,Y,Z,NX,NY,NZ:Double;Color:Cardinal;HasColor:Boolean):Cardinal;
    function FloatAt(Address:Cardinal):Single;inline;
    procedure ConfigureVertexLayout(VType:Cardinal);
    function Relative(Data,Offset: Cardinal): Cardinal;
    function Vertex(Index,VType: Cardinal; out Stride: Cardinal): TPSPGEVertex;
    function Texture(U,V: Double): Cardinal;
    procedure Pixel(X,Y: Integer; Z: Double; Color: Cardinal);
    function Shade(Color: Cardinal; U,V: Double): Cardinal;
    procedure Line(A,B: TPSPGEVertex);
    procedure Triangle(A,B,C: TPSPGEVertex);
    procedure Sprite(const A,C:TPSPGEVertex);
    function BlitSprite(const A,C:TPSPGEVertex;MinX,MinY,MaxX,MaxY:Integer):Boolean;
    procedure Draw(Primitive,Count: Cardinal);
    procedure RunList(List: TPSPGEList);
    procedure Transfer;
  public
    constructor Create(Memory: TPSPMemory; CPU: TPSPCPU; Kernel: TPSPKernel);
    destructor Destroy; override;
    function Handle(NID: Cardinal; out Value: Cardinal): Boolean;
    procedure Update;
  end;

implementation

uses System.Math;

function Float24(Value: Cardinal): Single;
begin
  Value := Value shl 8;
  Move(Value,Result,4);
end;

function Expand5(Value: Cardinal): Cardinal;
begin
  Result := (Value shl 3) or (Value shr 2);
end;

function DecodeColor(Value,Format: Cardinal): Cardinal;
begin
  case Format of
    0:
      begin
        var G := (Value shr 5) and 63;
        Result := $FF000000 or Expand5(Value and 31) or (((G shl 2) or (G shr 4)) shl 8) or
          (Expand5((Value shr 11) and 31) shl 16);
      end;
    1: Result := Expand5(Value and 31) or (Expand5((Value shr 5) and 31) shl 8) or
      (Expand5((Value shr 10) and 31) shl 16) or (Cardinal(Ord(Value and $8000<>0))*$FF000000);
    2: Result := (Value and 15)*17 or (((Value shr 4) and 15)*17 shl 8) or
      (((Value shr 8) and 15)*17 shl 16) or (((Value shr 12) and 15)*17 shl 24);
  else Result := Value;
  end;
end;

function EncodeColor(Value,Format: Cardinal): Cardinal;
begin
  case Format of
    0: Result := ((Value shr 3) and 31) or (((Value shr 10) and 63) shl 5) or (((Value shr 19) and 31) shl 11);
    1: Result := ((Value shr 3) and 31) or (((Value shr 11) and 31) shl 5) or
      (((Value shr 19) and 31) shl 10) or ((Value shr 16) and $8000);
    2: Result := ((Value shr 4) and 15) or (((Value shr 12) and 15) shl 4) or
      (((Value shr 20) and 15) shl 8) or ((Value shr 16) and $F000);
  else Result := Value;
  end;
end;

constructor TPSPGE.Create(Memory: TPSPMemory; CPU: TPSPCPU; Kernel: TPSPKernel);
begin
  inherited Create;
  FMemory := Memory;
  FCPU := CPU;
  FKernel := Kernel;
  FLists := TObjectList<TPSPGEList>.Create(True);
  FQueue := TList<TPSPGEList>.Create;
  FCallbacks := TDictionary<Cardinal,TPSPGECallback>.Create;
  FNextList := 1;
  SetLength(FCLUT,2048);FCLUTDirty:=True;FCLUTFormat:=$FFFFFFFF;
end;

destructor TPSPGE.Destroy;
begin
  FCallbacks.Free;
  FQueue.Free;
  FLists.Free;
  inherited;
end;

function TPSPGE.Relative(Data,Offset: Cardinal): Cardinal;
begin
  Result := Cardinal((UInt64(Offset)+((FRegisters[$10] and $F0000) shl 8)+(Data and $FFFFFF)) and $0FFFFFFF);
end;

function TPSPGE.Light(X,Y,Z,NX,NY,NZ:Double;Color:Cardinal;HasColor:Boolean):Cardinal;
  procedure Normalize(var X,Y,Z:Double);
  begin
    var Size:=Sqrt(X*X+Y*Y+Z*Z);
    if Size>0 then begin X:=X/Size;Y:=Y/Size;Z:=Z/Size end;
  end;
  function Component(Color:Cardinal;Index:Integer):Double;inline;
  begin Result:=(Color shr (Index*8)) and 255 end;
begin
  if FRegisters[$51] and 1<>0 then begin NX:=-NX;NY:=-NY;NZ:=-NZ end;
  Normalize(NX,NY,NZ);
  var Material:array[0..2] of Cardinal;
  Material[0]:=(FRegisters[$55] and $FFFFFF) or ((FRegisters[$58] and 255) shl 24);
  Material[1]:=FRegisters[$56];Material[2]:=FRegisters[$57];
  if HasColor then for var I:=0 to 2 do if FRegisters[$53] and (1 shl I)<>0 then Material[I]:=Color;
  var Sum:array[0..2] of Double;
  for var I:=0 to 2 do Sum[I]:=Component(FRegisters[$54],I)+Component(FRegisters[$5C],I)*Component(Material[0],I)/255;
  var Exponent:=Max(0.0,Double(Float24(FRegisters[$5B])));
  for var Light:=0 to 3 do
  begin
    if FRegisters[$18+Light] and 1=0 then Continue;
    var LX:Double:=Float24(FRegisters[$63+Light*3]);
    var LY:Double:=Float24(FRegisters[$64+Light*3]);
    var LZ:Double:=Float24(FRegisters[$65+Light*3]);
    var Kind:=(FRegisters[$5F+Light] shr 8) and 3;
    var Attenuation:Double:=1;
    if Kind<>0 then
    begin
      LX:=LX-X;LY:=LY-Y;LZ:=LZ-Z;
      var Distance:=Sqrt(LX*LX+LY*LY+LZ*LZ);
      var Denominator:=Float24(FRegisters[$7B+Light*3])+Distance*Float24(FRegisters[$7C+Light*3])+Distance*Distance*Float24(FRegisters[$7D+Light*3]);
      if Denominator>0 then Attenuation:=Min(1.0,1/Denominator);
    end;
    Normalize(LX,LY,LZ);
    if Kind>=2 then
    begin
      var DX:Double:=Float24(FRegisters[$6F+Light*3]);
      var DY:Double:=Float24(FRegisters[$70+Light*3]);
      var DZ:Double:=Float24(FRegisters[$71+Light*3]);
      Normalize(DX,DY,DZ);
      var Dot:=-(LX*DX+LY*DY+LZ*DZ);
      if Dot<Double(Float24(FRegisters[$8B+Light])) then Attenuation:=0
      else Attenuation:=Attenuation*Power(Max(0.0,Dot),Max(0.0,Double(Float24(FRegisters[$87+Light]))));
    end;
    var Dot:=NX*LX+NY*LY+NZ*LZ;
    var Diffuse:=Max(0.0,Dot);
    var Computation:=FRegisters[$5F+Light] and 3;
    if Computation=2 then Diffuse:=Power(Diffuse,Exponent);
    var Specular:Double:=0;
    if (Computation=1) and (Dot>=0) then
    begin
      LZ:=LZ+1;Normalize(LX,LY,LZ);
      Specular:=Power(Max(0.0,NX*LX+NY*LY+NZ*LZ),Exponent);
    end;
    for var I:=0 to 2 do Sum[I]:=Sum[I]+Attenuation*(
      Component(FRegisters[$8F+Light*3],I)*Component(Material[0],I)+
      Diffuse*Component(FRegisters[$90+Light*3],I)*Component(Material[1],I)+
      Specular*Component(FRegisters[$91+Light*3],I)*Component(Material[2],I))/255;
  end;
  Result:=Cardinal(EnsureRange(Round(Component(Material[0],3)*(FRegisters[$5D] and 255)/255),Int64(0),Int64(255))) shl 24;
  for var I:=0 to 2 do Result:=Result or (Cardinal(EnsureRange(Round(Sum[I]),Int64(0),Int64(255))) shl (I*8));
end;

function TPSPGE.FloatAt(Address:Cardinal):Single;
begin var Bits:=FMemory.Read32(Address);Move(Bits,Result,4) end;

procedure TPSPGE.ConfigureVertexLayout(VType:Cardinal);
begin
  FLayout:=Default(TPSPGEVertexLayout);
  FLayout.Key:=VType;
  FLayout.TexType:=VType and 3;FLayout.ColorType:=(VType shr 2) and 7;
  FLayout.NormalType:=(VType shr 5) and 3;FLayout.PositionType:=(VType shr 7) and 3;
  FLayout.WeightType:=(VType shr 9) and 3;
  FLayout.WeightCount:=((VType shr 14) and 7)+1;
  FLayout.MorphCount:=((VType shr 18) and 7)+1;
  var Offset:Cardinal:=0;var Alignment:Cardinal:=1;
  FLayout.TextureOffset:=-1;FLayout.ColorOffset:=-1;FLayout.NormalOffset:=-1;
  if FLayout.WeightType<>0 then
  begin
    Alignment:=1 shl (FLayout.WeightType-1);Offset:=Alignment*FLayout.WeightCount;
  end;
  if FLayout.TexType<>0 then
  begin
    var Size:=Cardinal(1 shl (FLayout.TexType-1));
    Offset:=(Offset+Size-1) and not (Size-1);FLayout.TextureOffset:=Offset;
    Inc(Offset,Size*2);Alignment:=Max(Alignment,Size);
  end;
  if FLayout.ColorType<>0 then
  begin
    if FLayout.ColorType<4 then raise EPSPInstruction.Create('PSP: invalid GE vertex color format');
    var Size:Cardinal:=2;if FLayout.ColorType=7 then Size:=4;
    Offset:=(Offset+Size-1) and not (Size-1);FLayout.ColorOffset:=Offset;
    Inc(Offset,Size);Alignment:=Max(Alignment,Size);
  end;
  if FLayout.NormalType<>0 then
  begin
    var Size:=Cardinal(1 shl (FLayout.NormalType-1));
    Offset:=(Offset+Size-1) and not (Size-1);FLayout.NormalOffset:=Offset;
    Inc(Offset,Size*3);Alignment:=Max(Alignment,Size);
  end;
  if FLayout.PositionType=0 then raise EPSPInstruction.Create('PSP: GE vertex has no position');
  var Size:=Cardinal(1 shl (FLayout.PositionType-1));
  Offset:=(Offset+Size-1) and not (Size-1);FLayout.PositionOffset:=Offset;
  Inc(Offset,Size*3);Alignment:=Max(Alignment,Size);
  FLayout.OneSize:=(Offset+Alignment-1) and not (Alignment-1);
  FLayout.Stride:=FLayout.OneSize*FLayout.MorphCount;FLayoutValid:=True;
end;

function TPSPGE.Vertex(Index,VType: Cardinal; out Stride: Cardinal): TPSPGEVertex;
  function SignedValue(Address,Kind:Cardinal):Double;
  begin
    case Kind of
      1:Result:=ShortInt(FMemory.Read8(Address))/128;
      2:Result:=SmallInt(FMemory.Read16(Address))/32768;
    else Result:=FloatAt(Address);
    end;
  end;
begin
  if not FLayoutValid or (FLayout.Key<>VType) then ConfigureVertexLayout(VType);
  Stride:=FLayout.Stride;
  var Address:=UInt64(FVertexAddress)+UInt64(Index)*Stride;
  if Address+Stride>High(Cardinal) then raise EPSPMemory.Create('PSP: GE vertex address overflow');
  var P:=Cardinal(Address);
  if not FMemory.IsValid(P,Stride) then raise EPSPMemory.Create('PSP: GE vertex outside memory');
  var Through:=VType and $800000<>0;
  Result:=Default(TPSPGEVertex);
  var Normal:array[0..2] of Double;Normal[0]:=0;Normal[1]:=0;Normal[2]:=0;
  var Colors:array[0..3] of Double;FillChar(Colors,SizeOf(Colors),0);
  for var Morph:=0 to Integer(FLayout.MorphCount)-1 do
  begin
    var Q:=P+Cardinal(Morph)*FLayout.OneSize;
    var Weight:Double:=1;
    if FLayout.MorphCount>1 then Weight:=Float24(FRegisters[$2C+Morph]);
    if FLayout.TextureOffset>=0 then
     for var Component:=0 to 1 do
     begin
       var At:=Q+Cardinal(FLayout.TextureOffset)+Cardinal(Component)*(1 shl (FLayout.TexType-1));
       var Value:Double;
       case FLayout.TexType of
         1:begin Value:=FMemory.Read8(At);if not Through then Value:=Value/128 end;
         2:begin Value:=FMemory.Read16(At);if not Through then Value:=Value/32768 end;
       else Value:=FloatAt(At);
       end;
       if Component=0 then Result.U:=Result.U+Value*Weight else Result.V:=Result.V+Value*Weight;
     end;
    if FLayout.ColorOffset>=0 then
    begin
      var Color:Cardinal;
      if FLayout.ColorType=7 then Color:=FMemory.Read32(Q+Cardinal(FLayout.ColorOffset))
      else Color:=DecodeColor(FMemory.Read16(Q+Cardinal(FLayout.ColorOffset)),FLayout.ColorType-4);
      for var Component:=0 to 3 do Colors[Component]:=Colors[Component]+((Color shr (Component*8)) and 255)*Weight;
    end;
    for var Component:=0 to 2 do
    begin
      var At:=Q+Cardinal(FLayout.PositionOffset)+Cardinal(Component)*(1 shl (FLayout.PositionType-1));
      var Value:Double;
      if Through then
        case FLayout.PositionType of
          1:Value:=ShortInt(FMemory.Read8(At));
          2:Value:=SmallInt(FMemory.Read16(At));
        else Value:=FloatAt(At);
        end
      else Value:=SignedValue(At,FLayout.PositionType);
      if Through and (Component=2) and (FLayout.PositionType=2) then Value:=FMemory.Read16(At);
      case Component of
        0:Result.X:=Result.X+Value*Weight;
        1:Result.Y:=Result.Y+Value*Weight;
        2:Result.Z:=Result.Z+Value*Weight;
      end;
      if FLayout.NormalOffset>=0 then
      begin
        At:=Q+Cardinal(FLayout.NormalOffset)+Cardinal(Component)*(1 shl (FLayout.NormalType-1));
        Normal[Component]:=Normal[Component]+SignedValue(At,FLayout.NormalType)*Weight;
      end;
    end;
  end;
  if FLayout.ColorOffset>=0 then
  begin
    for var Component:=0 to 3 do Result.Color:=Result.Color or
      (Cardinal(EnsureRange(Round(Colors[Component]),Int64(0),Int64(255))) shl (Component*8));
  end
  else Result.Color:=(FRegisters[$55] and $FFFFFF) or ((FRegisters[$58] and $FF) shl 24);
  if (FLayout.WeightType<>0) and not Through then
  begin
    var Matrix:array[0..11] of Double;FillChar(Matrix,SizeOf(Matrix),0);
    for var Bone:=0 to Integer(FLayout.WeightCount)-1 do
    begin
      var At:=P+Cardinal(Bone)*(1 shl (FLayout.WeightType-1));
      var Weight:Double;
      case FLayout.WeightType of
        1:Weight:=FMemory.Read8(At)/128;
        2:Weight:=FMemory.Read16(At)/32768;
      else Weight:=FloatAt(At);
      end;
      if Weight<>0 then for var I:=0 to 11 do Matrix[I]:=Matrix[I]+FBones[Bone*12+I]*Weight;
    end;
    var X:=Result.X*Matrix[0]+Result.Y*Matrix[3]+Result.Z*Matrix[6]+Matrix[9];
    var Y:=Result.X*Matrix[1]+Result.Y*Matrix[4]+Result.Z*Matrix[7]+Matrix[10];
    var Z:=Result.X*Matrix[2]+Result.Y*Matrix[5]+Result.Z*Matrix[8]+Matrix[11];
    Result.X:=X;Result.Y:=Y;Result.Z:=Z;
    X:=Normal[0]*Matrix[0]+Normal[1]*Matrix[3]+Normal[2]*Matrix[6];
    Y:=Normal[0]*Matrix[1]+Normal[1]*Matrix[4]+Normal[2]*Matrix[7];
    Z:=Normal[0]*Matrix[2]+Normal[1]*Matrix[5]+Normal[2]*Matrix[8];
    Normal[0]:=X;Normal[1]:=Y;Normal[2]:=Z;
  end;
  if not Through then
  begin
    var X := Result.X*FWorld[0]+Result.Y*FWorld[3]+Result.Z*FWorld[6]+FWorld[9];
    var Y := Result.X*FWorld[1]+Result.Y*FWorld[4]+Result.Z*FWorld[7]+FWorld[10];
    var Z := Result.X*FWorld[2]+Result.Y*FWorld[5]+Result.Z*FWorld[8]+FWorld[11];
    if FRegisters[$17] and 1<>0 then
    begin
      var NX:=Normal[0]*FWorld[0]+Normal[1]*FWorld[3]+Normal[2]*FWorld[6];
      var NY:=Normal[0]*FWorld[1]+Normal[1]*FWorld[4]+Normal[2]*FWorld[7];
      var NZ:=Normal[0]*FWorld[2]+Normal[1]*FWorld[5]+Normal[2]*FWorld[8];
      Result.Color:=Light(X,Y,Z,NX,NY,NZ,Result.Color,FLayout.ColorOffset>=0);
    end;
    var VX := X*FView[0]+Y*FView[3]+Z*FView[6]+FView[9];
    var VY := X*FView[1]+Y*FView[4]+Z*FView[7]+FView[10];
    var VZ := X*FView[2]+Y*FView[5]+Z*FView[8]+FView[11];
    var W := VX*FProjection[3]+VY*FProjection[7]+VZ*FProjection[11]+FProjection[15];
    if Abs(W)<1E-12 then W := 1E-12;
    Result.X := (VX*FProjection[0]+VY*FProjection[4]+VZ*FProjection[8]+FProjection[12])/W*Float24(FRegisters[$42])+
      Float24(FRegisters[$45])-(FRegisters[$4C] and $FFFF)/16;
    Result.Y := (VX*FProjection[1]+VY*FProjection[5]+VZ*FProjection[9]+FProjection[13])/W*Float24(FRegisters[$43])+
      Float24(FRegisters[$46])-(FRegisters[$4D] and $FFFF)/16;
    Result.Z := (VX*FProjection[2]+VY*FProjection[6]+VZ*FProjection[10]+FProjection[14])/W*Float24(FRegisters[$44])+Float24(FRegisters[$47]);
    Result.U := (Result.U*Float24(FRegisters[$48])+Float24(FRegisters[$4A]))*(1 shl (FRegisters[$B8] and 15));
    Result.V := (Result.V*Float24(FRegisters[$49])+Float24(FRegisters[$4B]))*(1 shl ((FRegisters[$B8] shr 8) and 15));
  end;
end;

procedure TPSPGE.ConfigureTexture;
begin
  FTexture.Width:=1 shl (FRegisters[$B8] and 15);
  FTexture.Height:=1 shl ((FRegisters[$B8] shr 8) and 15);
  FTexture.Format:=FRegisters[$C3] and 15;
  FTexture.ClampU:=FRegisters[$C7] and 1<>0;FTexture.ClampV:=FRegisters[$C7] and $100<>0;
  FTexture.Stride:=FRegisters[$A8] and $7FF;
  FTexture.Address:=(FRegisters[$A0] and $FFFFF0) or ((FRegisters[$A8] shl 8) and $0F000000);
  FTexture.BitsPerPixel:=16;
  case FTexture.Format of 3,7:FTexture.BitsPerPixel:=32;4:FTexture.BitsPerPixel:=4;5:FTexture.BitsPerPixel:=8 end;
  FTexture.RowBytes:=FTexture.Stride*FTexture.BitsPerPixel div 8;
  FTexture.Swizzled:=FRegisters[$C2] and 1<>0;
  FTexture.CLUTShift:=(FRegisters[$C5] shr 2) and 31;
  FTexture.CLUTMask:=(FRegisters[$C5] shr 8) and $FF;
  FTexture.CLUTStart:=((FRegisters[$C5] shr 16) and 31) shl 4;
  var Format:=FRegisters[$C5] and 3;
  FTexture.CLUTIndexMask:=1023;if Format=3 then FTexture.CLUTIndexMask:=511;
  if (FTexture.Format in [4..7]) and (FCLUTDirty or (FCLUTFormat<>Format)) then
  begin
    var Size:Cardinal:=2;if Format=3 then Size:=4;
    for var I:Cardinal:=0 to FTexture.CLUTIndexMask do
    begin
      var P:=I*Size;var Value:=Cardinal(FCLUT[P]) or (Cardinal(FCLUT[P+1]) shl 8);
      if Size=4 then Value:=Value or (Cardinal(FCLUT[P+2]) shl 16) or (Cardinal(FCLUT[P+3]) shl 24);
      FCLUTColors[I]:=DecodeColor(Value,Format);
    end;
    FCLUTFormat:=Format;FCLUTDirty:=False;
  end;
end;

function TPSPGE.Texture(U,V: Double): Cardinal;
begin
  var Width:=Integer(FTexture.Width);var Height:=Integer(FTexture.Height);
  if (Width>512) or (Height>512) then raise EPSPInstruction.Create('PSP: invalid GE texture size');
  var X := Integer(Floor(U));
  var Y := Integer(Floor(V));
  if FTexture.ClampU then X := EnsureRange(X,0,Width-1) else X := X and (Width-1);
  if FTexture.ClampV then Y := EnsureRange(Y,0,Height-1) else Y := Y and (Height-1);
  var Format:=FTexture.Format;
  if Format>10 then raise EPSPInstruction.CreateFmt('PSP: invalid GE texture format %d',[Format]);
  if Format>=8 then
  begin
    var BlockSize: Cardinal := 8;
    if Format<>8 then BlockSize := 16;
    var Stride:=FTexture.Stride;
    var Address:=FTexture.Address;
    Inc(Address,(Cardinal(Y div 4)*Max(Cardinal(1),Stride div 4)+Cardinal(X div 4))*BlockSize);
    var First := FMemory.Read16(Address+4);
    var Second := FMemory.Read16(Address+6);
    var Index := (FMemory.Read8(Address+Cardinal(Y and 3)) shr ((X and 3)*2)) and 3;
    var Colors: array[0..1,0..2] of Cardinal;
    Colors[0,0] := Expand5(First shr 11); Colors[1,0] := Expand5(Second shr 11);
    Colors[0,1] := ((First shr 5) and 63)*255 div 63; Colors[1,1] := ((Second shr 5) and 63)*255 div 63;
    Colors[0,2] := Expand5(First and 31); Colors[1,2] := Expand5(Second and 31);
    Result := $FF000000;
    for var Component := 0 to 2 do
    begin
      var Value: Cardinal := 0;
      case Index of
        0,1: Value := Colors[Index,Component];
        2: if (First>Second) or (Format<>8) then Value := (Colors[0,Component]*2+Colors[1,Component]) div 3
          else Value := (Colors[0,Component]+Colors[1,Component]) div 2;
        3: if (First>Second) or (Format<>8) then Value := (Colors[0,Component]+Colors[1,Component]*2) div 3
          else Result := 0;
      end;
      Result := Result or (Value shl (Component*8));
    end;
    if Format=9 then
    begin
      var Alpha := (FMemory.Read16(Address+8+Cardinal(Y and 3)*2) shr ((X and 3)*4)) and 15;
      Result := (Result and $FFFFFF) or (Alpha*17 shl 24);
    end
    else if Format=10 then
    begin
      var FirstAlpha := Cardinal(FMemory.Read8(Address+14));
      var SecondAlpha := Cardinal(FMemory.Read8(Address+15));
      var Bits := UInt64(FMemory.Read32(Address+8)) or (UInt64(FMemory.Read16(Address+12)) shl 32);
      var AlphaIndex := (Bits shr (((Y and 3)*4+(X and 3))*3)) and 7;
      var Alpha: Cardinal;
      if AlphaIndex=0 then Alpha := FirstAlpha
      else if AlphaIndex=1 then Alpha := SecondAlpha
      else if FirstAlpha>SecondAlpha then Alpha := ((8-AlphaIndex)*FirstAlpha+(AlphaIndex-1)*SecondAlpha) div 7
      else if AlphaIndex=6 then Alpha := 0
      else if AlphaIndex=7 then Alpha := 255
      else Alpha := ((6-AlphaIndex)*FirstAlpha+(AlphaIndex-1)*SecondAlpha) div 5;
      Result := (Result and $FFFFFF) or (Alpha shl 24);
    end;
    Exit;
  end;
  var BitsPerPixel:=Integer(FTexture.BitsPerPixel);
  var RowBytes:=FTexture.RowBytes;
  var ByteX := Cardinal(X*BitsPerPixel div 8);
  var Offset := Cardinal(Y)*RowBytes+ByteX;
  if FTexture.Swizzled then
    Offset := (Cardinal(Y) div 8)*RowBytes*8+(ByteX div 16)*128+(Cardinal(Y) mod 8)*16+ByteX mod 16;
  var Address:=FTexture.Address;
  Inc(Address,Offset);
  var Value: Cardinal;
  case BitsPerPixel of
    4: Value := (FMemory.Read8(Address) shr ((X and 1)*4)) and 15;
    8: Value := FMemory.Read8(Address);
    16: Value := FMemory.Read16(Address);
  else Value := FMemory.Read32(Address);
  end;
  if Format<4 then Exit(DecodeColor(Value,Format));
  var Index:=((Value shr FTexture.CLUTShift) and FTexture.CLUTMask) or FTexture.CLUTStart;
  Result:=FCLUTColors[Index and FTexture.CLUTIndexMask];
end;

function Compare(A,B: Cardinal; Kind: Cardinal): Boolean;
begin
  case Kind of
    0: Result := False;
    1: Result := True;
    2: Result := A=B;
    3: Result := A<>B;
    4: Result := A<B;
    5: Result := A<=B;
    6: Result := A>B;
  else Result := A>=B;
  end;
end;

procedure TPSPGE.Pixel(X,Y: Integer; Z: Double; Color: Cardinal);
begin
  if (X<0) or (Y<0) or (X>1023) or (Y>1023) then Exit;
  if (X<Integer(FRegisters[$D4] and $3FF)) or (Y<Integer((FRegisters[$D4] shr 10) and $3FF)) or
    (X>Integer(FRegisters[$D5] and $3FF)) or (Y>Integer((FRegisters[$D5] shr 10) and $3FF)) then Exit;
  var Clear := FRegisters[$D3] and 1<>0;
  var Format := FRegisters[$D2] and 3;
  var Bytes: Cardinal := 2;
  if Format=3 then Bytes := 4;
  var Stride := FRegisters[$9D] and $7FC;
  if (Stride=0) or (Cardinal(X)>=Stride) then Exit;
  var Address := PSPVRAMBase+(FRegisters[$9C] and $1FFFF0)+(Cardinal(Y)*Stride+Cardinal(X))*Bytes;
  if not FMemory.IsValid(Address,Bytes) then Exit;
  var WriteMask:=(FRegisters[$E8] and $FFFFFF) or ((FRegisters[$E9] and $FF) shl 24);
  if Clear then
  begin
    WriteMask:=$FFFFFFFF;
    if FRegisters[$D3] and $100<>0 then WriteMask:=WriteMask and $FF000000;
    if FRegisters[$D3] and $200<>0 then WriteMask:=WriteMask and $00FFFFFF;
  end;
  var Blending:=not Clear and (FRegisters[$21] and 1<>0);
  var StandardAlpha:=FRegisters[$DF] and $7FF=$32;
  var IdentityBlend:=Blending and StandardAlpha and (Color shr 24=255);
  var Old:Cardinal:=0;
  if (WriteMask<>0) or (Blending and not IdentityBlend) then
    if Bytes=4 then Old:=FMemory.Read32(Address) else Old:=DecodeColor(FMemory.Read16(Address),Format);
  if not Clear and (FRegisters[$22] and 1<>0) then
  begin
    var Test := FRegisters[$DB];
    var Mask := (Test shr 16) and $FF;
    if not Compare((Color shr 24) and Mask,(Test shr 8) and Mask,Test and 7) then Exit;
  end;
  var DepthTest:=not Clear and (FRegisters[$23] and 1<>0);
  var DepthWrite:=(not Clear and (FRegisters[$E7] and 1=0)) or (Clear and (FRegisters[$D3] and $400<>0));
  var Depth:Cardinal:=0;var DepthAddress:Cardinal:=0;
  if DepthTest or DepthWrite then
  begin
    Depth:=Cardinal(EnsureRange(Round(Z),Int64(0),Int64(65535)));
    DepthAddress:=PSPVRAMBase+(FRegisters[$9E] and $1FFFF0)+(Cardinal(Y)*(FRegisters[$9F] and $7FC)+Cardinal(X))*2;
    if DepthTest and not Compare(Depth,FMemory.Read16(DepthAddress),FRegisters[$DE] and 7) then Exit;
  end;
  if Blending and StandardAlpha and (Color shr 24=0) then Color:=Old and $FFFFFF
  else if Blending and not IdentityBlend then
  begin
    var Blended: Cardinal := 0;
    var SourceAlpha := Integer(Color shr 24);
    var DestAlpha := Integer(Old shr 24);
    var SrcKind:=FRegisters[$DF] and 15;var DstKind:=(FRegisters[$DF] shr 4) and 15;
    var Equation:=(FRegisters[$DF] shr 8) and 7;
    for var Component := 0 to 2 do
    begin
      var Src := Integer((Color shr (Component*8)) and $FF);
      var Dst := Integer((Old shr (Component*8)) and $FF);
      var SF,DF: Integer;
      case SrcKind of
        0: SF := Dst; 1: SF := 255-Dst; 2: SF := SourceAlpha; 3: SF := 255-SourceAlpha;
        4: SF := DestAlpha; 5: SF := 255-DestAlpha;
        6: SF := SourceAlpha*2;7:SF:=255-SourceAlpha*2;
        8: SF := DestAlpha*2;9:SF:=255-DestAlpha*2;
        10: SF := (FRegisters[$E0] shr (Component*8)) and $FF;
      else raise EPSPInstruction.CreateFmt('PSP: GE blend factor %d is not implemented',[SrcKind]);
      end;
      case DstKind of
        0: DF := Src; 1: DF := 255-Src; 2: DF := SourceAlpha; 3: DF := 255-SourceAlpha;
        4: DF := DestAlpha; 5: DF := 255-DestAlpha;
        6: DF := SourceAlpha*2;7:DF:=255-SourceAlpha*2;
        8: DF := DestAlpha*2;9:DF:=255-DestAlpha*2;
        10: DF := (FRegisters[$E1] shr (Component*8)) and $FF;
      else raise EPSPInstruction.CreateFmt('PSP: GE blend factor %d is not implemented',[DstKind]);
      end;
      var SourceTerm:=((Src*2+1)*(Abs(SF)*2+1)) shr 10;
      var DestTerm:=((Dst*2+1)*(Abs(DF)*2+1)) shr 10;
      if SF<0 then SourceTerm:=-SourceTerm;
      if DF<0 then DestTerm:=-DestTerm;
      var OutValue: Integer;
      case Equation of
        0: OutValue := SourceTerm+DestTerm;
        1: OutValue := SourceTerm-DestTerm;
        2: OutValue := DestTerm-SourceTerm;
        3: OutValue := Min(Src,Dst);
        4: OutValue := Max(Src,Dst);
        5: OutValue := Abs(Src-Dst);
      else raise EPSPInstruction.Create('PSP: invalid GE blend equation');
      end;
      Blended := Blended or (Cardinal(EnsureRange(OutValue,0,255)) shl (Component*8));
    end;
    Color := Blended or (Color and $FF000000);
  end;
  if WriteMask<>0 then Color:=(Color and not WriteMask) or (Old and WriteMask);
  if Bytes=4 then FMemory.Write32(Address,Color) else FMemory.Write16(Address,EncodeColor(Color,Format));
  if DepthWrite and FMemory.IsValid(DepthAddress,2) then FMemory.Write16(DepthAddress,Depth);
end;

function TPSPGE.Shade(Color: Cardinal; U,V: Double): Cardinal;
begin
      if (FRegisters[$1E] and 1<>0) and (FRegisters[$D3] and 1=0) then
      begin
        var Texel := Texture(U,V);
        var FunctionCode := FRegisters[$C9] and 7;
        if FunctionCode=3 then
        begin
          if FRegisters[$C9] and $100<>0 then Exit(Texel);
          Exit((Texel and $FFFFFF) or (Color and $FF000000));
        end;
        if (FunctionCode=0) and (Color and $FFFFFF=$FFFFFF) then
        begin
          if FRegisters[$C9] and $100=0 then Exit((Texel and $FFFFFF) or (Color and $FF000000));
          var Alpha:=((Texel shr 24)*(Color shr 24)) div 255;
          Exit((Texel and $FFFFFF) or (Alpha shl 24));
        end;
        var Textured: Cardinal := 0;
        for var I := 0 to 3 do
        begin
          var ComponentValue := Integer((Texel shr (I*8)) and $FF);
          var Original := Integer((Color shr (I*8)) and $FF);
          if (I=3) and (FRegisters[$C9] and $100=0) then ComponentValue := Original
          else case FunctionCode of
            0: ComponentValue := (ComponentValue*Original) div 255;
            3: ;
            4: ComponentValue := Min(255,ComponentValue+Original);
          else raise EPSPInstruction.CreateFmt('PSP: GE texture function %d is not implemented',[FunctionCode]);
          end;
          Textured := Textured or (Cardinal(ComponentValue) shl (I*8));
        end;
        Color := Textured;
      end;
  Result := Color;
end;

procedure TPSPGE.Line(A,B: TPSPGEVertex);
var Start,Finish: Double;
  function Clip(P,Q: Double): Boolean;
  begin
    if P=0 then Exit(Q>=0);
    var R := Q/P;
    if P<0 then begin if R>Finish then Exit(False); Start := Max(Start,R); end
    else begin if R<Start then Exit(False); Finish := Min(Finish,R); end;
    Result := True;
  end;
begin
  var DX := B.X-A.X;
  var DY := B.Y-A.Y;
  Start := 0; Finish := 1;
  if not Clip(-DX,A.X) or not Clip(DX,1024-A.X) or
    not Clip(-DY,A.Y) or not Clip(DY,1024-A.Y) then Exit;
  var Steps := Integer(Ceil(Max(Abs(DX),Abs(DY))*(Finish-Start)));
  if Steps=0 then Steps := 1;
  for var I := 0 to Steps-1 do
  begin
    var T := Start+(Finish-Start)*I/Steps;
    var Color := B.Color;
    if FRegisters[$50] and 1<>0 then
    begin
      Color := 0;
      for var Lane := 0 to 3 do
      begin
        var Component := Round(((A.Color shr (Lane*8)) and $FF)*(1-T)+((B.Color shr (Lane*8)) and $FF)*T);
        Color := Color or (Cardinal(EnsureRange(Component,Int64(0),Int64(255))) shl (Lane*8));
      end;
    end;
    Pixel(Floor(A.X+DX*T),Floor(A.Y+DY*T),A.Z*(1-T)+B.Z*T,
      Shade(Color,A.U*(1-T)+B.U*T,A.V*(1-T)+B.V*T));
  end;
end;

procedure TPSPGE.Triangle(A,B,C: TPSPGEVertex);
begin
  // Preserve the provoking vertex before normalizing triangle winding.
  var ProvokingColor:=C.Color;
  var FlatColor:=(FRegisters[$50] and 1=0) or ((A.Color=B.Color) and (A.Color=C.Color));
  var FlatDepth:=(A.Z=B.Z) and (A.Z=C.Z);
  var Textured:=(FRegisters[$1E] and 1<>0) and (FRegisters[$D3] and 1=0);
  var Interpolate:=not FlatColor or not FlatDepth or Textured;
  var Area := (B.X-A.X)*(C.Y-A.Y)-(B.Y-A.Y)*(C.X-A.X);
  if Abs(Area)<1E-8 then Exit;
  if Area<0 then begin var Temp := B; B := C; C := Temp; Area := -Area; end;
  var MinX := Max(Integer(FRegisters[$D4] and $3FF),Integer(Floor(Min(A.X,Min(B.X,C.X)))));
  var MinY := Max(Integer((FRegisters[$D4] shr 10) and $3FF),Integer(Floor(Min(A.Y,Min(B.Y,C.Y)))));
  var MaxX := Min(Integer(FRegisters[$D5] and $3FF),Integer(Ceil(Max(A.X,Max(B.X,C.X))))-1);
  var MaxY := Min(Integer((FRegisters[$D5] shr 10) and $3FF),Integer(Ceil(Max(A.Y,Max(B.Y,C.Y))))-1);
  var InverseArea:=1.0/Area;
  for var Y := MinY to MaxY do
    for var X := MinX to MaxX do
    begin
      var PX := X+0.5;
      var PY := Y+0.5;
      var EA := (C.X-B.X)*(PY-B.Y)-(C.Y-B.Y)*(PX-B.X);
      var EB := (A.X-C.X)*(PY-C.Y)-(A.Y-C.Y)*(PX-C.X);
      var EC := (B.X-A.X)*(PY-A.Y)-(B.Y-A.Y)*(PX-A.X);
      if (EA<0) or (EB<0) or (EC<0) then Continue;
      if (EA=0) and not ((C.Y<B.Y) or ((C.Y=B.Y) and (C.X>B.X))) then Continue;
      if (EB=0) and not ((A.Y<C.Y) or ((A.Y=C.Y) and (A.X>C.X))) then Continue;
      if (EC=0) and not ((B.Y<A.Y) or ((B.Y=A.Y) and (B.X>A.X))) then Continue;
      var WA:Double:=0;var WB:Double:=0;var WC:Double:=0;
      if Interpolate then begin WA:=EA*InverseArea;WB:=EB*InverseArea;WC:=EC*InverseArea end;
      var Color:=ProvokingColor;
      if not FlatColor then
      begin
        Color:=0;
        for var I := 0 to 3 do
        begin
          var Value := Round(((A.Color shr (I*8)) and $FF)*WA+((B.Color shr (I*8)) and $FF)*WB+((C.Color shr (I*8)) and $FF)*WC);
          Color := Color or (Cardinal(EnsureRange(Value,Int64(0),Int64(255))) shl (I*8));
        end;
      end;
      if Textured then Color:=Shade(Color,A.U*WA+B.U*WB+C.U*WC,A.V*WA+B.V*WB+C.V*WC);
      var Depth:=A.Z;if not FlatDepth then Depth:=A.Z*WA+B.Z*WB+C.Z*WC;
      Pixel(X,Y,Depth,Color);
    end;
end;

function TPSPGE.BlitSprite(const A,C:TPSPGEVertex;MinX,MinY,MaxX,MaxY:Integer):Boolean;
var SourceX:array[0..1023] of Cardinal;
begin
  Result:=False;
  if (FTexture.Format<>3) or FTexture.Swizzled or (FRegisters[$D2] and 3<>3) or
    (FRegisters[$22] and 1<>0) or (FRegisters[$23] and 1<>0) or (FRegisters[$E7] and 1=0) or
    (FRegisters[$E8] and $FFFFFF<>0) or (FRegisters[$E9] and $FF<>0) then Exit;
  var FunctionCode:=FRegisters[$C9] and 7;
  if (FunctionCode<>3) and ((FunctionCode<>0) or (C.Color and $FFFFFF<>$FFFFFF)) then Exit;
  var Blending:=FRegisters[$21] and 1<>0;
  if Blending and (FRegisters[$DF] and $7FF<>$32) then Exit;
  if (FTexture.Width>512) or (FTexture.Height>512) or (FTexture.Stride<FTexture.Width) then Exit;
  var Stride:=FRegisters[$9D] and $7FC;MaxX:=Min(MaxX,Integer(Stride)-1);
  if MaxX<MinX then Exit(True);
  var Width:=MaxX-MinX+1;
  var Address:=PSPVRAMBase+(FRegisters[$9C] and $1FFFF0)+(Cardinal(MinY)*Stride+Cardinal(MinX))*4;
  var Span:=(Cardinal(MaxY-MinY)*Stride+Cardinal(Width))*4;
  var SourceSpan:=((FTexture.Height-1)*FTexture.Stride+FTexture.Width)*4;
  if not FMemory.IsValid(Address,Span) or not FMemory.IsValid(FTexture.Address,SourceSpan) then Exit;
  var SourceBase:=FTexture.Address and $1FFFFFFF;var DestBase:=Address and $1FFFFFFF;
  // Rendering into the sampled texture needs the general pixel ordering.
  if (UInt64(SourceBase)<UInt64(DestBase)+Span) and (UInt64(DestBase)<UInt64(SourceBase)+SourceSpan) then Exit;
  var DU:=(C.U-A.U)/(C.X-A.X);var DV:=(C.V-A.V)/(C.Y-A.Y);
  var FirstU:=A.U+(MinX+0.5-A.X)*DU;
  for var X:=0 to Width-1 do
  begin
    var Sample:=Integer(Floor(FirstU+X*DU));
    if FTexture.ClampU then Sample:=EnsureRange(Sample,0,Integer(FTexture.Width)-1) else Sample:=Sample and (Integer(FTexture.Width)-1);
    SourceX[X]:=Sample;
  end;
  var SourceData,DestData:TBytes;SetLength(DestData,Width*4);var PreviousY:Integer:=-1;
  var TextureAlpha:=FRegisters[$C9] and $100<>0;
  for var Y:=MinY to MaxY do
  begin
    var SampleY:=Integer(Floor(A.V+(Y+0.5-A.Y)*DV));
    if FTexture.ClampV then SampleY:=EnsureRange(SampleY,0,Integer(FTexture.Height)-1) else SampleY:=SampleY and (Integer(FTexture.Height)-1);
    if SampleY<>PreviousY then
    begin
      SourceData:=FMemory.ReadBytes(FTexture.Address+Cardinal(SampleY)*FTexture.RowBytes,FTexture.Width*4);
      PreviousY:=SampleY;
    end;
    if Blending then DestData:=FMemory.ReadBytes(Address,Width*4);
    var Source:=PCardinal(@SourceData[0]);var Destination:=PCardinal(@DestData[0]);
    for var X:=0 to Width-1 do
    begin
      var Color:=Source[SourceX[X]];
      if not TextureAlpha then Color:=(Color and $FFFFFF) or (C.Color and $FF000000)
      else if FunctionCode=0 then Color:=(Color and $FFFFFF) or ((((Color shr 24)*(C.Color shr 24)) div 255) shl 24);
      var Alpha:=Color shr 24;
      if Blending and (Alpha<>255) then
      begin
        var Old:=Destination[X];
        if Alpha=0 then Color:=Old and $FFFFFF
        else
        begin
          var Blended:=Color and $FF000000;
          for var Component:=0 to 2 do
          begin
            var Src:=(Color shr (Component*8)) and $FF;var Dst:=(Old shr (Component*8)) and $FF;
            var Value:=(((Src*2+1)*(Alpha*2+1)) shr 10)+(((Dst*2+1)*((255-Alpha)*2+1)) shr 10);
            Blended:=Blended or (Min(Cardinal(255),Value) shl (Component*8));
          end;
          Color:=Blended;
        end;
      end;
      Destination[X]:=Color;
    end;
    FMemory.Load(Address,DestData);Inc(Address,Stride*4);
  end;
  Result:=True;
end;

procedure TPSPGE.Sprite(const A,C:TPSPGEVertex);
begin
  var DX:=C.X-A.X;var DY:=C.Y-A.Y;if (DX=0) or (DY=0) then Exit;
  var MinX:=Max(Integer(FRegisters[$D4] and $3FF),Integer(Ceil(Min(A.X,C.X)-0.5)));
  var MinY:=Max(Integer((FRegisters[$D4] shr 10) and $3FF),Integer(Ceil(Min(A.Y,C.Y)-0.5)));
  var MaxX:=Min(Integer(FRegisters[$D5] and $3FF),Integer(Ceil(Max(A.X,C.X)-0.5))-1);
  var MaxY:=Min(Integer((FRegisters[$D5] shr 10) and $3FF),Integer(Ceil(Max(A.Y,C.Y)-0.5))-1);
  if (MinX>MaxX) or (MinY>MaxY) then Exit;
  var Textured:=(FRegisters[$1E] and 1<>0) and (FRegisters[$D3] and 1=0);
  if not Textured and (FRegisters[$D3] and 1=0) and
    (FRegisters[$21] and 1=0) and (FRegisters[$22] and 1=0) and (FRegisters[$23] and 1=0) and
    (FRegisters[$E8] and $FFFFFF=0) and (FRegisters[$E9] and $FF=0) then
  begin
    var Stride:=FRegisters[$9D] and $7FC;
    var Right:=Min(MaxX,Integer(Stride)-1);
    if Right<MinX then Exit;
    var Format:=FRegisters[$D2] and 3;var Bytes:Cardinal:=2;if Format=3 then Bytes:=4;
    var Address:=PSPVRAMBase+(FRegisters[$9C] and $1FFFF0)+(Cardinal(MinY)*Stride+Cardinal(MinX))*Bytes;
    var Span:=(Cardinal(MaxY-MinY)*Stride+Cardinal(Right-MinX+1))*Bytes;
    var DepthWrite:=FRegisters[$E7] and 1=0;
    var DepthStride:=FRegisters[$9F] and $7FC;
    var DepthAddress:=PSPVRAMBase+(FRegisters[$9E] and $1FFFF0)+(Cardinal(MinY)*DepthStride+Cardinal(MinX))*2;
    var DepthSpan:=(Cardinal(MaxY-MinY)*DepthStride+Cardinal(Right-MinX+1))*2;
    var Overlap:=DepthWrite and (UInt64(Address)<UInt64(DepthAddress)+DepthSpan) and (UInt64(DepthAddress)<UInt64(Address)+Span);
    if not Overlap and FMemory.IsValid(Address,Span) and (not DepthWrite or FMemory.IsValid(DepthAddress,DepthSpan)) then
    begin
      var Color:=C.Color;if Format<>3 then Color:=EncodeColor(Color,Format);
      var Depth:Word:=0;if DepthWrite then Depth:=Word(EnsureRange(Round(C.Z),Int64(0),Int64(65535)));
      for var Y:=MinY to MaxY do
      begin
        if Format=3 then FMemory.Fill32(Address,Right-MinX+1,Color)
        else FMemory.Fill16(Address,Right-MinX+1,Word(Color));
        if DepthWrite then FMemory.Fill16(DepthAddress,Right-MinX+1,Depth);
        Inc(Address,Stride*Bytes);Inc(DepthAddress,DepthStride*2);
      end;
      Exit;
    end;
  end;
  if not Textured then
  begin
    for var Y:=MinY to MaxY do for var X:=MinX to MaxX do Pixel(X,Y,C.Z,C.Color);
    Exit;
  end;
  if BlitSprite(A,C,MinX,MinY,MaxX,MaxY) then Exit;
  var DU:=(C.U-A.U)/DX;var DV:=(C.V-A.V)/DY;
  var FirstU:=A.U+(MinX+0.5-A.X)*DU;
  for var Y:=MinY to MaxY do
  begin
    var V:=A.V+(Y+0.5-A.Y)*DV;
    for var X:=MinX to MaxX do Pixel(X,Y,C.Z,Shade(C.Color,FirstU+(X-MinX)*DU,V));
  end;
end;

procedure TPSPGE.Draw(Primitive,Count: Cardinal);
begin
  if (FRegisters[$1E] and 1<>0) and (FRegisters[$D3] and 1=0) then ConfigureTexture;
  var VType := FRegisters[$12];
  var Vertices: TArray<TPSPGEVertex>;
  SetLength(Vertices,Count);
  var Stride: Cardinal := 0;
  var IndexType := (VType shr 11) and 3;
  for var I := 0 to Integer(Count)-1 do
  begin
    var Index := Cardinal(I);
    case IndexType of
      0: ;
      1: Index := FMemory.Read8(FIndexAddress+Cardinal(I));
      2: Index := FMemory.Read16(FIndexAddress+Cardinal(I)*2);
    else raise EPSPInstruction.Create('PSP: invalid GE index format');
    end;
    Vertices[I] := Vertex(Index,VType,Stride);
  end;
  case Primitive of
    0: for var Vertex in Vertices do
      Pixel(Floor(Vertex.X),Floor(Vertex.Y),Vertex.Z,Shade(Vertex.Color,Vertex.U,Vertex.V));
    1: for var I := 0 to Integer(Count div 2)-1 do Line(Vertices[I*2],Vertices[I*2+1]);
    2: for var I := 0 to Integer(Count)-2 do Line(Vertices[I],Vertices[I+1]);
    3: for var I := 0 to Integer(Count div 3)-1 do Triangle(Vertices[I*3],Vertices[I*3+1],Vertices[I*3+2]);
    4: for var I := 0 to Integer(Count)-3 do Triangle(Vertices[I],Vertices[I+1],Vertices[I+2]);
    5: for var I := 1 to Integer(Count)-2 do Triangle(Vertices[0],Vertices[I],Vertices[I+1]);
    6:for var I:=0 to Integer(Count div 2)-1 do Sprite(Vertices[I*2],Vertices[I*2+1]);
  else raise EPSPInstruction.CreateFmt('PSP: GE primitive %d is not implemented',[Primitive]);
  end;
  if IndexType=0 then Inc(FVertexAddress,Count*Stride)
  else Inc(FIndexAddress,Count*(1 shl (IndexType-1)));
end;

procedure TPSPGE.Transfer;
begin
  var Source := (FRegisters[$B2] and $FFFFF0) or ((FRegisters[$B3] shl 8) and $0F000000);
  var Dest := (FRegisters[$B4] and $FFFFF0) or ((FRegisters[$B5] shl 8) and $0F000000);
  var Bytes: Cardinal := 2;
  if FRegisters[$EA] and 1<>0 then Bytes := 4;
  var Width := (FRegisters[$EE] and $3FF)+1;
  var Height := ((FRegisters[$EE] shr 10) and $3FF)+1;
  var SX := FRegisters[$EB] and $3FF;
  var SY := (FRegisters[$EB] shr 10) and $3FF;
  var DX := FRegisters[$EC] and $3FF;
  var DY := (FRegisters[$EC] shr 10) and $3FF;
  for var Y := 0 to Integer(Height)-1 do
    FMemory.CopyMemory(Dest+((DY+Cardinal(Y))*(FRegisters[$B5] and $7F8)+DX)*Bytes,
      Source+((SY+Cardinal(Y))*(FRegisters[$B3] and $7F8)+SX)*Bytes,Width*Bytes);
end;

procedure TPSPGE.RunList(List: TPSPGEList);
begin
  if (List.Status=0) or List.Waiting then Exit;
  List.Status := 2;
  for var Budget := 1 to 100000 do
  begin
    if (List.Stall<>0) and (List.PC=List.Stall) then begin List.Status := 3; Exit; end;
    var Command := FMemory.Read32(List.PC);
    var Code := Command shr 24;
    var Data := Command and $FFFFFF;
    Inc(List.PC,4);
    var Previous := List.PreviousCommand;
    List.PreviousCommand := Command;
    FRegisters[Code] := Data;
    case Code of
      $01: FVertexAddress := Relative(Data,List.Offset);
      $02: FIndexAddress := Relative(Data,List.Offset);
      $04: Draw((Data shr 16) and 7,Data and $FFFF);
      $05,$06: raise EPSPInstruction.Create('PSP: GE bezier/spline patches are not implemented');
      $08: List.PC := Relative(Data,List.Offset) and $FFFFFFFC;
      $0A:
        begin
          if Length(List.Stack)>=96 then raise EPSPInstruction.Create('PSP: GE call stack overflow');
          List.Stack := List.Stack+[List.PC,List.Offset,Cardinal(0)];
          List.PC := Relative(Data,List.Offset) and $FFFFFFFC;
        end;
      $0B:
        begin
          var N := Length(List.Stack);
          if N<3 then Continue; // Empty RET advances to the following command.
          List.PC := List.Stack[N-3] and $0FFFFFFF;
          List.Offset := List.Stack[N-2]; // Ordinary CALL/RET does not restore BASE.
          SetLength(List.Stack,N-3);
        end;
      $0C:
        begin
          var Callback: TPSPGECallback;
          var HasCallback := FCallbacks.TryGetValue(List.CallbackId,Callback);
          var CallbackPC: Cardinal := 0;
          if FKernel.SDK>$02000010 then CallbackPC := List.PC;
          if Previous shr 24=$0E then
          begin
            var Behavior := (Previous shr 16) and $FF;
            var Token := Previous and $FFFF;
            case Behavior of
              0: ;
              1,2:
                if HasCallback and (Callback.Signal<>0) then
                begin
                  if Behavior=1 then
                  begin
                    List.Waiting := True; List.Status := 4;
                    FKernel.QueueCall(Callback.Signal,Token,Callback.SignalArg,CallbackPC,True,
                      procedure begin List.Waiting := False; List.Status := 1; Update; end);
                    Exit;
                  end
                  else FKernel.QueueCall(Callback.Signal,Token,Callback.SignalArg,CallbackPC);
                end;
              3: begin List.SignalMode := 3; List.SignalToken := Token; end;
              8: List.SignalMode := 8;
              $10,$11,$13,$14,$15,$16:
                begin
                  var Target := (Token shl 16) or (Data and $FFFF);
                  if Behavior in [$13,$14] then Target := Cardinal((UInt64(Target)+List.PC-8) and $0FFFFFFF)
                  else if Behavior in [$15,$16] then
                    Target := Cardinal((UInt64(Target)+List.Offset+((FRegisters[$10] and $F0000) shl 8)) and $0FFFFFFF);
                  Target := Target and $0FFFFFFC;
                  if not FMemory.IsValid(Target,4) then raise EPSPMemory.Create('PSP: invalid GE signal target');
                  if Behavior in [$11,$14,$16] then
                  begin
                    if Length(List.Stack)>=96 then raise EPSPInstruction.Create('PSP: GE signal stack overflow');
                    List.Stack := List.Stack+[List.PC,List.Offset,FRegisters[$10]];
                  end;
                  List.PC := Target;
                end;
              $12:
                begin
                  var N := Length(List.Stack);
                  if N<3 then raise EPSPInstruction.Create('PSP: GE signal return without call');
                  List.PC := List.Stack[N-3]; List.Offset := List.Stack[N-2]; FRegisters[$10] := List.Stack[N-1];
                  SetLength(List.Stack,N-3);
                end;
            else raise EPSPInstruction.CreateFmt('PSP: GE signal behavior %.2x is not implemented',[Behavior]);
            end;
            Continue;
          end;
          if (Previous shr 24=$0F) and (List.SignalMode=8) then
          begin List.SignalMode := 0; List.Finish := False; Continue; end;
          if (Previous shr 24=$0F) and (List.SignalMode=3) then
          begin
            List.Waiting := True; List.Paused := True; List.Status := 4; List.Finish := False;
            if HasCallback and (Callback.Signal<>0) then
              FKernel.QueueCall(Callback.Signal,List.SignalToken,Callback.SignalArg,CallbackPC);
            List.SignalMode := 0;
            Exit;
          end;
          if List.Finish and HasCallback and (Callback.Finish<>0) then
          begin
            List.Waiting := True; List.Status := 4;
            FKernel.QueueCall(Callback.Finish,List.FinishToken,Callback.FinishArg,CallbackPC,True,
              procedure begin List.Waiting := False; List.Status := 0; Update; end);
          end
          else List.Status := 0;
          Exit;
        end;
      $0E: ; // SIGNAL takes effect together with the following END.
      $0F: begin List.Finish := True; List.FinishToken := Data and $FFFF; end;
      $13: List.Offset := Data shl 8;
      $14: List.Offset := List.PC-4;
      $2A: FBoneIndex:=Data and $7F;
      $2B: begin if FBoneIndex<96 then FBones[FBoneIndex]:=Float24(Data);FBoneIndex:=(FBoneIndex+1) and $7F end;
      $3A: FWorldIndex := Data and 15;
      $3B: begin if FWorldIndex<12 then FWorld[FWorldIndex] := Float24(Data); FWorldIndex := (FWorldIndex+1) and 15; end;
      $3C: FViewIndex := Data and 15;
      $3D: begin if FViewIndex<12 then FView[FViewIndex] := Float24(Data); FViewIndex := (FViewIndex+1) and 15; end;
      $3E: FProjectionIndex := Data and 15;
      $3F: begin FProjection[FProjectionIndex] := Float24(Data); FProjectionIndex := (FProjectionIndex+1) and 15; end;
      $C4:
        begin
          var Address := (FRegisters[$B0] and $FFFFF0) or ((FRegisters[$B1] shl 8) and $0F000000);
          var Count := Min(Cardinal(2048),(Data and $3F)*32);
          for var I := 0 to Integer(Count)-1 do FCLUT[I] := FMemory.Read8(Address+Cardinal(I));
          FCLUTDirty:=True;
        end;
      $EA: Transfer;
    end;
  end;
  raise EPSPInstruction.Create('PSP: GE list exceeded command budget');
end;

procedure TPSPGE.Update;
begin
  while FQueue.Count>0 do
  begin
    var List := FQueue[0];
    RunList(List);
    if List.Status<>0 then Break;
    FKernel.CompleteDevice(1,List.Id,0);
    FQueue.Delete(0);
  end;
  if FQueue.Count=0 then FKernel.CompleteDevice(2,0,0);
end;

function TPSPGE.Handle(NID: Cardinal; out Value: Cardinal): Boolean;
begin
  Result := True;
  Value := 0;
  var A := FCPU.Registers[4];
  var B := FCPU.Registers[5];
  var C := FCPU.Registers[6];
  case NID of
    $E47E40E4: Value := PSPVRAMBase;
    $1F6752AD: Value := PSPVRAMSize;
    $B77905EA: begin Value := FTranslation; FTranslation := A; end;
    $A4FC06A4:
      begin
        var Callback: TPSPGECallback;
        Callback.Signal := FMemory.Read32(A);
        Callback.SignalArg := FMemory.Read32(A+4);
        Callback.Finish := FMemory.Read32(A+8);
        Callback.FinishArg := FMemory.Read32(A+12);
        Value := FNextCallback;
        Inc(FNextCallback);
        FCallbacks.Add(Value,Callback);
      end;
    $05DB22CE: FCallbacks.Remove(A);
    $AB49E76A,$1C0D95A6:
      begin
        var List: TPSPGEList := nil;
        if FLists.Count<64 then
        begin
          List := TPSPGEList.Create;
          List.Id := FNextList; Inc(FNextList);
          FLists.Add(List);
        end
        else for var Entry in FLists do if Entry.Status=0 then begin List := Entry; Break; end;
        if List=nil then begin Value := $80000104; Exit; end;
        List.PC := A and $0FFFFFFF;
        List.Stall := B and $0FFFFFFF;
        List.CallbackId := C;
        List.Status := 1;
        List.Offset := 0; List.Stack := nil; List.Finish := False; List.FinishToken := 0;
        List.SignalMode := 0; List.SignalToken := 0; List.PreviousCommand := 0;
        List.Waiting := False; List.Paused := False;
        if NID=$1C0D95A6 then FQueue.Insert(0,List) else FQueue.Add(List);
        Value := List.Id;
        Update;
      end;
    $E0D68148:
      begin
        Value := $80000100;
        for var List in FLists do if List.Id=A then
        begin List.Stall := B and $0FFFFFFF; Update; Value := 0; Break; end;
      end;
    $03444EB4:
      begin
        Value := $80000100;
        for var List in FLists do if List.Id=A then
        begin
          if B=1 then Value := List.Status
          else if List.Status=0 then Value := 0
          else FKernel.WaitDevice(1,List.Id);
          Break;
        end;
      end;
    $B287BD61:
      begin
        Update;
        if FQueue.Count>0 then
          if A=1 then Value := FQueue[0].Status else FKernel.WaitDevice(2,0);
      end;
    $4C06E472:
      begin
        Value := $80000020;
        if (FQueue.Count>0) and FQueue[0].Paused then
        begin
          FQueue[0].Paused := False; FQueue[0].Waiting := False; FQueue[0].Status := 1;
          Value := 0; Update;
        end;
      end;
    $DC93CFEF: if A>255 then Value := $80000102 else Value := FRegisters[A] or (A shl 24);
  else Result := False;
  end;
end;

end.
