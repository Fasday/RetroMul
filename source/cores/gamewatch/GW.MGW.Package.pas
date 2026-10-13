unit GW.MGW.Package;

interface

uses
  System.SysUtils, System.Generics.Collections;

type
  TMGWPackage = class
  private
    FEntries: TDictionary<string, TBytes>;
  public
    constructor Create(const Data: TBytes);
    destructor Destroy; override;
    function Read(const Name: string): TBytes;
    function Script(const Name: string): string;
    function Names: TArray<string>;
  end;

implementation

uses
  System.Classes, GW.BZip2;

// Token alphabet from gw-libretro (zlib license, Andre Leiradella).
const
  TokenCodes: array[0..63] of Cardinal = (2, 12, 26, 216, 434, 435, 872, 873, 1748, 1749, 3500, 3501, 3502, 3503, 438, 1756, 3514, 3515, 1758, 3518, 7038, 7039, 55, 28, 464, 465, 233, 117, 118, 238, 478, 3832, 3833, 1917, 1918, 15352, 30706, 122828, 122829, 61415, 7677, 7678, 15358, 61436, 61437, 245752, 7864096, 7864097, 7864098, 15728198, 15728199, 15728200, 15728201, 15728202, 15728203, 15728204, 15728205, 15728206, 15728207, 983013, 491507, 122877, 61439, 15);
  TokenText: array[0..63] of string = (' ', '.', '=', 'end', 'if', '==', 'function', 'local', '<=', 'while', ':', '<', '-', 'for', 'then', 'and', '>=', '>', 'elseif', 'else', '%', 'nil', 'self', #10, 'true', ',', '[', ')', '(', ']', 'false', '{', '}', 'do', '+', '~=', 'return', '/', '^', '#', 'or', 'not', '//', 'in', '*', 'until', '|', 'goto', 'break', '>>', #9, '~', '::', ';', 'eof', '<<', #11, #13, #12, '...', 'repeat', '&', '..', 'literal');

procedure Check(Condition: Boolean; const Message: string);
begin
  if not Condition then
    raise EReadError.Create('MGW: ' + Message);
end;

constructor TMGWPackage.Create(const Data: TBytes);
begin
  inherited Create;
  FEntries := TDictionary<string, TBytes>.Create;
  var Raw := DecodeGWBZip2(Data);
  var P := 0;
  while (P + 512 <= Length(Raw)) and (Raw[P] <> 0) do
  begin
    var L := 0;
    while (L < 100) and (Raw[P + L] <> 0) do
      Inc(L);
    var Name := TEncoding.ASCII.GetString(Raw, P, L);

    var Size: Int64 := 0;
    for var i := 124 to 135 do
      if Raw[P + i] in [Ord('0')..Ord('7')] then
        Size := Size * 8 + Raw[P + i] - Ord('0')
      else
        Check(Raw[P + i] in [0, 32], 'invalid entry size');
    Check((Size >= 0) and (Size <= Length(Raw) - P - 512), 'truncated entry ' + Name);
    Check(FEntries.Count < 8192, 'too many entries');
    if not FEntries.ContainsKey(Name) then
      FEntries.Add(Name, Copy(Raw, P + 512, Integer(Size)));
    Inc(P, 512 + ((Integer(Size) + 511) div 512) * 512);
  end;
  Check(FEntries.ContainsKey('main.bs') or FEntries.ContainsKey('main.lua'), 'missing main script');
end;

destructor TMGWPackage.Destroy;
begin
  FEntries.Free;
  inherited;
end;

function TMGWPackage.Read(const Name: string): TBytes;
begin
  if not FEntries.TryGetValue(Name, Result) then
    Result := nil;
end;

function TMGWPackage.Names: TArray<string>;
begin
  Result := FEntries.Keys.ToArray;
end;

function TMGWPackage.Script(const Name: string): string;
var
  Data: TBytes;
  P: Integer;

  function Bits(N: Integer): Cardinal;
  begin
    Check(Int64(P) + N <= Int64(Length(Data)) * 8, 'truncated script');
    Result := 0;
    for var i := 1 to N do
    begin
      Result := (Result shl 1) or ((Data[P shr 3] shr (7 - (P and 7))) and 1);
      Inc(P);
    end;
  end;

begin
  Data := Read(Name + '.lua');
  if Length(Data) > 0 then
    Exit(TEncoding.UTF8.GetString(Data));

  Data := Read(Name + '.bs');
  Check(Length(Data) > 0, 'missing script ' + Name);
  P := 0;
  var Text := TStringBuilder.Create;
  try
    while True do
    begin
      var Code: Cardinal := 1;
      var Token := -1;
      for var Len := 1 to 24 do
      begin
        Code := (Code shl 1) or Bits(1);
        for var i := 0 to 63 do
          if TokenCodes[i] = Code then
          begin
            Token := i;
            Break;
          end;

        if Token >= 0 then
          Break;
      end;
      Check(Token >= 0, 'invalid script token');
      if Token = 54 then
        Break;

      if Token = 63 then
      begin
        if (P and 7) = 0 then
          Bits(1);
        var Count := 0;
        repeat
          var Value := Bits(8);
          if Value = 0 then
            Break;

          Text.Append(Char(Value));
          Inc(Count);
          Check(Count <= 512, 'oversized literal');
        until False;
      end
      else
        Text.Append(TokenText[Token]);
      Check(Text.Length <= 4 * 1024 * 1024, 'script too large');
    end;
    Result := Text.ToString;
  finally
    Text.Free;
  end;
end;

end.

