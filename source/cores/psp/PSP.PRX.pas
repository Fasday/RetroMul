unit PSP.PRX;

// PRX protocol implementation, GPL-3.0-or-later. See PSP.PRX-LICENSE.md for
// PPSSPP/libkirk provenance and notices. No external binary is used.

interface

uses System.SysUtils, System.Classes;

type
  EPSPPRX = class(EReadError);

function DecryptPSPPRX(const Data: TBytes): TBytes;

implementation

uses System.Hash, System.ZLib, PSP.AES;

function DecodeHex(const Text: string): TBytes;
begin
  SetLength(Result,Text.Length div 2);
  for var I := 0 to High(Result) do Result[I] := StrToInt('$'+Text.Substring(I*2,2));
end;

{$I PSP.Keys.inc}

function LE32(const Data: TBytes; Offset: Integer): Cardinal;
begin
  if (Offset < 0) or (Offset > Length(Data)-4) then raise EPSPPRX.Create('PSP: truncated PRX word');
  Result := Cardinal(Data[Offset]) or (Cardinal(Data[Offset+1]) shl 8) or
    (Cardinal(Data[Offset+2]) shl 16) or (Cardinal(Data[Offset+3]) shl 24);
end;

procedure Put32(var Data: TBytes; Offset: Integer; Value: Cardinal);
begin
  for var I := 0 to 3 do Data[Offset+I] := Byte((Value shr (I*8)) and $FF);
end;

function EqualBytes(const A,B: TBytes): Boolean;
begin
  Result := (Length(A)=Length(B)) and ((Length(A)=0) or CompareMem(@A[0],@B[0],Length(A)));
end;

function SHA1(const Data: TBytes): TBytes;
begin
  var Hash := THashSHA1.Create;
  Hash.Update(Data);
  Result := Hash.HashAsBytes;
end;

function Kirk7(const Data: TBytes; Code: Integer): TBytes;
begin
  Result := PSPAESDecrypt(Data,KirkKey(Code));
end;

function ExpandSeed(const Key: TBytes; Code: Integer): TBytes;
begin
  SetLength(Result,$90);
  for var Block := 0 to 8 do
  begin
    Move(Key[0],Result[Block*16],16);
    Result[Block*16] := Block;
  end;
  Result := Kirk7(Result,Code);
end;

function Kirk1(const Data: TBytes): TBytes;
begin
  if (Length(Data)<$90) or (LE32(Data,$60)<>1) then raise EPSPPRX.Create('PSP: invalid KIRK1 header');
  if Data[$64]<>0 then raise EPSPPRX.Create('PSP: KIRK ECDSA authentication is not implemented');
  var Size := Int64(LE32(Data,$70));
  var Offset := Int64(LE32(Data,$74));
  var Aligned := (Size+15) and not Int64(15);
  if (Size=0) or (Size>64*1024*1024) or ($90+Offset+Aligned>Length(Data)) then
    raise EPSPPRX.Create('PSP: invalid KIRK1 data extent');
  var Keys := PSPAESDecrypt(Copy(Data,0,32),DecodeHex('98C940975C1D10E87FE60EA3FD03A8BA'));
  var AES: TPSPAES;
  AES.Init(Copy(Keys,16,16));
  if not EqualBytes(AES.CMAC(Copy(Data,$60,$30)),Copy(Data,$20,16)) then
    raise EPSPPRX.Create('PSP: KIRK1 header CMAC mismatch');
  if not EqualBytes(AES.CMAC(Copy(Data,$60,$30+Offset+Aligned)),Copy(Data,$30,16)) then
    raise EPSPPRX.Create('PSP: KIRK1 data CMAC mismatch');
  Result := PSPAESDecrypt(Copy(Data,$90+Offset,Aligned),Copy(Keys,0,16));
  SetLength(Result,Size);
end;

function LegacyHeader(const Data, Seed: TBytes; Code: Integer; Variant: Integer; out Block: TBytes): Boolean;
begin
  var Layout: TBytes;
  SetLength(Layout,$150);
  Move(Data[$D0],Layout[0],4);
  Move(Data[$D4],Layout[4],$14);
  Move(Data[$E8],Layout[$18],$28);
  Move(Data[$110],Layout[$40],$40);
  Move(Data[$80],Layout[$80],$50);
  Move(Data[0],Layout[$D0],$80);
  if Variant=1 then
  begin
    var Decoded := Kirk7(Copy(Layout,$10,$A0),Code);
    Move(Decoded[0],Layout[$10],$A0);
  end;
  var Digest := SHA1(Copy(Seed,0,$14)+Copy(Layout,$18,$28)+
    Copy(Layout,$40,$90)+Copy(Layout,$D0,$80));
  Result := EqualBytes(Digest,Copy(Layout,4,$14));
  if not Result then Exit;
  Block := Copy(Layout,$40,$90);
  var Header := Copy(Block,0,$70);
  for var I := 0 to $6F do Header[I] := Header[I] xor Seed[$14+I];
  Header := Kirk7(Header,Code);
  for var I := 0 to $6F do Block[I] := Header[I] xor Seed[$20+I];
end;

function ModernHeader(const Data, Seed, XorSeed: TBytes; Code, Variant: Integer; out Block: TBytes): Boolean;
begin
  var Layout: TBytes;
  SetLength(Layout,$150);
  Move(Data[$D0],Layout[0],4);
  Move(Data[$140],Layout[$5C],16);
  Move(Data[$12C],Layout[$6C],$14);
  Move(Data[$80],Layout[$80],$30);
  Move(Data[$C0],Layout[$B0],$10);
  Move(Data[$B0],Layout[$C0],16);
  Move(Data[0],Layout[$D0],$80);
  if Variant=5 then
  begin
    var Extra := XorSeed;
    if Data[$7C]=23 then Extra := DecodeHex('847BF5FEE84DAD7AB506280E09FA81E1');
    var Work := Copy(Layout,$80,$40)+Copy(Layout,$6C,$10);
    if Length(Extra)=16 then
      for var I := 0 to High(Work) do Work[I] := Work[I] xor Extra[I mod 16];
    Work := Kirk7(Work,Code);
    Move(Work[0],Layout[$80],$40);
    Move(Work[$40],Layout[$6C],$10);
    if Length(Extra)=16 then
      for var I := $5C to $BB do Layout[I] := Layout[I] xor Extra[(I-$5C) mod 16];
  end;
  var Decoded := Kirk7(Copy(Layout,$5C,$60),Code);
  Move(Decoded[0],Layout[$5C],$60);
  var Digest := SHA1(Copy(Layout,0,4)+Copy(Seed,0,16)+Copy(Layout,4,$58)+
    Copy(Layout,$5C,16)+Copy(Layout,$80,$40)+Copy(Layout,$C0,16)+Copy(Layout,$D0,$80));
  Result := EqualBytes(Digest,Copy(Layout,$6C,$14));
  if not Result then Exit;
  SetLength(Block,$90);
  FillChar(Block[0],Length(Block),0);
  Move(Layout[$C0],Block[$70],16);
  var Header := Copy(Layout,$80,$40);
  for var I := 0 to $3F do Header[I] := Header[I] xor Seed[$10+I];
  Header := Kirk7(Header,Code);
  for var I := 0 to $3F do Block[I] := Header[I] xor Seed[$50+I];
  Put32(Block,$60,1);
end;

function DecryptPSPPRX(const Data: TBytes): TBytes;
begin
  if (Length(Data)>=8) and (LE32(Data,0)=$4543537E) then
  begin
    var HeaderSize := LE32(Data,4);
    if (HeaderSize<8) or (HeaderSize>Cardinal(Length(Data)-4)) then raise EPSPPRX.Create('PSP: invalid SCE wrapper extent');
    var Magic := LE32(Data,HeaderSize);
    if (Magic<>$5053507E) and (Magic<>$464C457F) then raise EPSPPRX.Create('PSP: invalid SCE module payload');
    Exit(DecryptPSPPRX(Copy(Data,HeaderSize,Length(Data)-Integer(HeaderSize))));
  end;
  if (Length(Data)<4) or (LE32(Data,0)<>$5053507E) then Exit(Copy(Data));
  if Length(Data)<$150 then raise EPSPPRX.Create('PSP: truncated encrypted PRX');
  var Tag := LE32(Data,$D0);
  var Size := LE32(Data,$B0);
  if (Size=0) or (Size>64*1024*1024) then raise EPSPPRX.Create('PSP: invalid PRX output size');
  var Key, XorSeed, Seed, Header: TBytes;
  var Code: Integer;
  var Scramble: Boolean;
  var Found := False;
  if TagKey(Tag,True,Key,XorSeed,Code,Scramble) then
  begin
    Seed := Key;
    if Scramble then Seed := Kirk7(Seed,Code);
    Found := LegacyHeader(Data,Seed,Code,0,Header) or LegacyHeader(Data,Seed,Code,1,Header);
  end;
  if not Found and TagKey(Tag,False,Key,XorSeed,Code,Scramble) then
  begin
    Seed := ExpandSeed(Key,Code);
    Found := ModernHeader(Data,Seed,XorSeed,Code,2,Header) or ModernHeader(Data,Seed,XorSeed,Code,5,Header);
  end;
  if not Found then raise EPSPPRX.CreateFmt('PSP: PRX tag %.8x is unknown or header SHA-1 is invalid',[Tag]);
  // KIRK starts at original offset 0x40; its 0x90 header is followed by the
  // original 0x80-byte PSP header, then encrypted payload at original 0x150.
  var Wrapped := Header+Copy(Data,0,$80)+Copy(Data,$150,Length(Data)-$150);
  Result := Kirk1(Wrapped);
  if Cardinal(Length(Result))<>Size then raise EPSPPRX.Create('PSP: PRX/KIRK size mismatch');
  if (Length(Result)>=2) and (Result[0]=$1F) and (Result[1]=$8B) then
  begin
    var Expected := LE32(Data,$28);
    if (Expected<52) or (Expected>64*1024*1024) then raise EPSPPRX.Create('PSP: invalid decompressed ELF size');
    var Input := TBytesStream.Create(Result);
    try
      var Decoder := TZDecompressionStream.Create(Input,15+16);
      try
        SetLength(Result,Expected);
        Decoder.ReadBuffer(Result[0],Length(Result));
        var Extra: Byte;
        if Decoder.Read(Extra,1)<>0 then raise EPSPPRX.Create('PSP: decompressed module exceeds ELF size');
      finally
        Decoder.Free;
      end;
    finally
      Input.Free;
    end;
  end;
  if (Length(Result)<52) or (LE32(Result,0)<>$464C457F) then
    raise EPSPPRX.Create('PSP: decrypted module is not an ELF (unsupported compression)');
end;

end.
