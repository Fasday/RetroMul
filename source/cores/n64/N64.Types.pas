unit N64.Types;

interface

uses
  System.SysUtils;

// All guest wraparound is explicit. These routines also work with {$Q+}{$R+}.
function Add64(A, B: UInt64): UInt64; inline;

function Sub64(A, B: UInt64): UInt64; inline;

function Add32(A, B: Cardinal): Cardinal; inline;

function SX(Value: UInt64; Bits: Integer): UInt64; inline;

function SignedValue(Value: UInt64): Int64; inline;

function SignedLess(A, B: UInt64): Boolean; inline;

function SAR(Value: UInt64; Count, Bits: Integer): UInt64; inline;

procedure Multiply64(A, B: UInt64; Signed: Boolean; out Hi, Lo: UInt64); inline;

procedure Divide64(A, B: UInt64; Signed: Boolean; out Hi, Lo: UInt64); inline;

type
  EN64Unsupported = class(Exception);

  TN64TraceKind = (Instruction, GuestException, MMIORead, MMIOWrite,
    DMAStart, DMAComplete, InterruptChange);

  TN64TraceRecord = record
    Tick, PC, Address, Value: UInt64;
    Kind: TN64TraceKind;
  end;

  TN64TraceSink = reference to procedure(const Event: TN64TraceRecord);

  TN64Bus = class abstract
  private
    FTraceSink: TN64TraceSink;
    function GetTraceEnabled: Boolean;
  public
    function Read8(Address: Cardinal): Byte; virtual; abstract;
    procedure Write8(Address: Cardinal; Value: Byte); virtual; abstract;
    function Read32(Address: Cardinal): Cardinal; virtual;
    procedure Write32(Address, Value: Cardinal); virtual;
    function InterruptPending: Boolean; virtual;
    // Two hidden RDRAM bits belong to each physical halfword. Byte addresses
    // keep the bus interface consistent with CPU/DMA/framebuffer accesses.
    function ReadHidden(Address: Cardinal): Byte; virtual;
    procedure WriteHidden(Address: Cardinal; Value: Byte); virtual;
    function GuestTick: UInt64; virtual;
    procedure SetTraceSink(const Sink: TN64TraceSink);
    procedure Trace(Kind: TN64TraceKind; PC, Address, Value: UInt64);
    property TraceEnabled: Boolean read GetTraceEnabled;
  end;

implementation

function Add64(A, B: UInt64): UInt64;
begin
  var L := (A and $FFFFFFFF) + (B and $FFFFFFFF);
  var H := (A shr 32) + (B shr 32) + (L shr 32);
  Result := ((H and $FFFFFFFF) shl 32) or (L and $FFFFFFFF);
end;

function Sub64(A, B: UInt64): UInt64;
begin
  Result := Add64(Add64(A, not B), 1);
end;

function Add32(A, B: Cardinal): Cardinal;
begin
  Result := Cardinal((UInt64(A) + B) and $FFFFFFFF);
end;

function SX(Value: UInt64; Bits: Integer): UInt64;
begin
  if Bits = 64 then
    Exit(Value);
  var Mask := (UInt64(1) shl Bits) - 1;
  Result := Value and Mask;
  if (Result and (UInt64(1) shl (Bits - 1))) <> 0 then
    Result := Result or not Mask;
end;

function SignedValue(Value: UInt64): Int64;
begin
  if Value <= UInt64(High(Int64)) then
    Result := Int64(Value)
  else
    Result := -1 - Int64(not Value);
end;

function SignedLess(A, B: UInt64): Boolean;
begin
  Result := (A xor (UInt64(1) shl 63)) < (B xor (UInt64(1) shl 63));
end;

function SAR(Value: UInt64; Count, Bits: Integer): UInt64;
begin
  Value := SX(Value, Bits);
  Count := Count and (Bits - 1);
  Result := Value shr Count;
  if (Count <> 0) and (Value shr 63 <> 0) then
    Result := Result or (High(UInt64) shl (64 - Count));
end;

procedure Multiply64(A, B: UInt64; Signed: Boolean; out Hi, Lo: UInt64);
begin
  var Negative := Signed and ((A xor B) shr 63 <> 0);
  if Signed and (A shr 63 <> 0) then
    A := Sub64(0, A);
  if Signed and (B shr 63 <> 0) then
    B := Sub64(0, B);
  Hi := 0;
  Lo := 0;
  var AH: UInt64 := 0;
  for var I := 0 to 63 do
  begin
    if (B and 1) <> 0 then
    begin
      var Old := Lo;
      Lo := Add64(Lo, A);
      Hi := Add64(Hi, AH);
      if Lo < Old then
        Hi := Add64(Hi, 1);
    end;
    AH := (AH shl 1) or (A shr 63);
    A := A shl 1;
    B := B shr 1;
  end;
  if Negative then
  begin
    Hi := not Hi;
    Lo := Add64(not Lo, 1);
    if Lo = 0 then
      Hi := Add64(Hi, 1);
  end;
end;

procedure Divide64(A, B: UInt64; Signed: Boolean; out Hi, Lo: UInt64);
begin
  var NA := Signed and (A shr 63 <> 0);
  var NB := Signed and (B shr 63 <> 0);
  if B = 0 then
  begin
    Hi := A;
    if NA then
      Lo := 1
    else
      Lo := High(UInt64);
    Exit;
  end;
  if NA then
    A := Sub64(0, A);
  if NB then
    B := Sub64(0, B);
  Hi := 0;
  Lo := 0;
  for var I := 63 downto 0 do
  begin
    var Carry := Hi shr 63 <> 0;
    Hi := (Hi shl 1) or ((A shr I) and 1);
    if Carry or (Hi >= B) then
    begin
      Hi := Sub64(Hi, B);
      Lo := Lo or (UInt64(1) shl I);
    end;
  end;
  if NA then
    Hi := Sub64(0, Hi);
  if NA <> NB then
    Lo := Sub64(0, Lo);
end;

function TN64Bus.Read32(Address: Cardinal): Cardinal;
begin
  Result := 0;
  for var I := 0 to 3 do
    Result := (Result shl 8) or Read8(Add32(Address, Cardinal(I)));
end;

procedure TN64Bus.Write32(Address, Value: Cardinal);
begin
  for var I := 0 to 3 do
    Write8(Add32(Address, Cardinal(I)), Byte((Value shr (24 - I * 8)) and $FF));
end;

function TN64Bus.InterruptPending: Boolean;
begin
  Result := False;
end;

function TN64Bus.ReadHidden(Address: Cardinal): Byte;
begin
  Result := 3;
end;

procedure TN64Bus.WriteHidden(Address: Cardinal; Value: Byte);
begin
end;

function TN64Bus.GuestTick: UInt64;
begin
  Result := 0;
end;

function TN64Bus.GetTraceEnabled: Boolean;
begin
  Result := Assigned(FTraceSink);
end;

procedure TN64Bus.SetTraceSink(const Sink: TN64TraceSink);
begin
  FTraceSink := Sink;
end;

procedure TN64Bus.Trace(Kind: TN64TraceKind; PC, Address, Value: UInt64);
begin
  if not Assigned(FTraceSink) then
    Exit;
  var Event := Default(TN64TraceRecord);
  Event.Tick := GuestTick;
  Event.Kind := Kind;
  Event.PC := PC;
  Event.Address := Address;
  Event.Value := Value;
  FTraceSink(Event);
end;

end.

