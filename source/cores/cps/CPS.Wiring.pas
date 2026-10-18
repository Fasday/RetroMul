unit CPS.Wiring;

interface

uses
  System.SysUtils, CPS.Cartridge;

function CPSProgram(Cart: TCPSCartridge): TBytes;

function CPSGraphics(Cart: TCPSCartridge): TBytes;

implementation

const
  M8Offsets: array[0..7] of Integer = ($000000, $100000, $000001, $100001, $080000, $180000, $080001, $180001);

function Permute(Value: Cardinal; const Order: array of Byte): Cardinal;
begin
  Result := 0;
  for var i := 0 to High(Order) do
    Result := (Result shl 1) or ((Value shr Order[i]) and 1);
end;

function CPSProgram(Cart: TCPSCartridge): TBytes;
begin
  Result := Cart['maincpu'];
  if Cart.RomSet.Init = 'init_cps1mult' then
  begin
    var Raw := Result;
    Result := Copy(Raw);
    for var i := 0 to High(Result) do
    begin
      var Index := Permute(i, [27, 26, 18, 23, 16, 17, 21, 24, 19, 25, 22, 20, 5, 6, 7, 8, 13, 15, 14, 9, 10, 12, 11, 1, 2, 3, 4, 0]);
      if Index >= Cardinal(Length(Raw)) then
        raise ECPSRom.Create('Invalid multi-game program wiring');

      Result[i] := Raw[Index];
    end;
  end;
end;

function CPSGraphics(Cart: TCPSCartridge): TBytes;
begin
  Result := Cart['gfx'];
  var Mode := Cart.RomSet.Init;

  if Mode = 'init_gigaman2' then
  begin
    if Length(Result) <> $800000 then
      raise ECPSRom.Create('Truncated Giga Man 2 graphics');

    var Raw := Result;
    Result := Copy(Raw);
    for var i := 0 to Length(Result) div 2 - 1 do
    begin
      var Index := ((i and not 7) shr 2) or ((i and 4) shl 18) or ((i and 2) shr 1) or ((i and 1) shl 21);
      Result[i * 2] := Raw[Index * 2];
      Result[i * 2 + 1] := Raw[Index * 2 + 1];
    end;
  end;

  if Mode = 'init_captcommb2' then
  begin
    Result := Copy(Result);
    for var i := 0 to High(Result) do
      Result[i] := (Result[i] and $EB) or ((Result[i] and 4) shl 2) or ((Result[i] and $10) shr 2);
  end;

  if (Mode = 'init_sf2mdt') or (Mode = 'init_sf2mdtb') then
  begin
    Result := Copy(Result);
    for var i := 0 to Length(Result) div 8 - 1 do
    begin
      var T := Result[i * 8 + 1];
      Result[i * 8 + 1] := Result[i * 8 + 4];
      Result[i * 8 + 4] := T;
      T := Result[i * 8 + 3];
      Result[i * 8 + 3] := Result[i * 8 + 6];
      Result[i * 8 + 6] := T;
    end;
  end;

  if Mode = 'init_sf2rk' then
  begin
    Result := Copy(Result);
    for var i := 0 to High(Result) do
      if (i < $400000) or (i >= $480000) then
        Result[i] := (Result[i] and $7E) or ((Result[i] and 1) shl 7) or (Result[i] shr 7);
  end;

  if Mode = 'init_sf2m8' then
  begin
    var Extra := Cart['user2'];
    Result := Copy(Result);
    if (Length(Extra) < $200000) or (Length(Result) < $600000) then
      raise ECPSRom.Create('Truncated M8 graphics wiring');

    var Dest := $480000;
    for var J := $10000 to $3FFFF do
      for var Mask in M8Offsets do
      begin
        Result[Dest] := Extra[(J * 2) or Mask];
        Inc(Dest);
      end;
  end;

  if Mode = 'init_cps1mult' then
  begin
    var Raw := Result;
    Result := Copy(Raw);
    for var i := 0 to High(Result) do
    begin
      var Index := Permute(i, [27, 1, 20, 21, 18, 19, 23, 25, 2, 26, 24, 22, 7, 8, 9, 10, 15, 17, 16, 11, 12, 14, 13, 3, 4, 5, 6, 0]);
      if Index >= Cardinal(Length(Raw)) then
        raise ECPSRom.Create('Invalid multi-game graphics wiring');

      Result[i] := Raw[Index];
    end;
  end;
end;

end.

