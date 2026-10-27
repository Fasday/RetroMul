unit PSP.Misc;

// Small libraries: sceCcc, sceReg, and the network libraries (sceNet*,
// sceHttp, sceSsl, sceParseUri/Http, sceUsb, sceWlan) as a PSP sees them with
// no network around.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, System.Generics.Collections, PSP.Types, PSP.Memory, PSP.CPU, PSP.HLE, PSP.Kernel,
  PSP.Scheduler, PSP.Service;

type
  TRegKey = class
  public
    Name: string;
    Kind: Integer;
    IntValue: Integer;
    Data: TBytes;
    Children: TObjectList<TRegKey>;
    constructor Create(const AName: string; AKind: Integer);
    destructor Destroy; override;
    function Find(const AName: string): TRegKey;
    function Dir(const AName: string): TRegKey;
    function AddInt(const AName: string; V: Integer): TRegKey;
    function AddStr(const AName, V: string; Size: Integer = 0): TRegKey;
    function AddBin(const AName: string; const V: TBytes): TRegKey;
    function Size: Cardinal;
    function Value: TBytes;
  end;

  TPSPMisc = class(TPSPService)
  private
    // sceCcc
    FJis2Ucs, FUcs2Jis: Cardinal;
    FErrorChar: array[0..2] of Cardinal;
    // sceReg
    FRegRoot: TRegKey;
    FRegHandles: TDictionary<Cardinal, TRegKey>;
    FRegNextHandle: Cardinal;
    function JisToUcs(Jis: Cardinal): Cardinal;
    function UcsToJis(Ucs: Cardinal): Cardinal;
    function DecodeUtf8(var P: Cardinal): Cardinal;
    function DecodeUtf16(var P: Cardinal): Cardinal;
    function DecodeSjis(var P: Cardinal): Cardinal;
    function Decode(Kind: Integer; var P: Cardinal): Cardinal;
    function EncodeTo(Kind: Integer; Dst: Cardinal; C: Cardinal; Room: Integer): Integer;
    procedure Convert(FromKind, ToKind: Integer);
    procedure Strlen(Kind: Integer);
    procedure Encode(Kind: Integer);
    procedure DecodeCall(Kind: Integer);
    procedure SetErrorChar(Kind: Integer);
    procedure hCccSetTable;
    procedure hCccUtf8ToUtf16;
    procedure hCccUtf8ToSjis;
    procedure hCccUtf16ToUtf8;
    procedure hCccUtf16ToSjis;
    procedure hCccSjisToUtf8;
    procedure hCccSjisToUtf16;
    procedure hCccStrlenUtf8;
    procedure hCccStrlenUtf16;
    procedure hCccStrlenSjis;
    procedure hCccEncodeUtf8;
    procedure hCccEncodeUtf16;
    procedure hCccEncodeSjis;
    procedure hCccDecodeUtf8;
    procedure hCccDecodeUtf16;
    procedure hCccDecodeSjis;
    procedure hCccSetErrorCharUtf8;
    procedure hCccSetErrorCharUtf16;
    procedure hCccSetErrorCharSjis;
    procedure hCccIsValidUtf8;
    procedure hCccIsValidUtf16;
    procedure hCccIsValidSjis;
    procedure hCccIsValidUcs2;
    procedure hCccIsValidUcs4;
    procedure hCccIsValidJis;
    procedure hCccUcsToJis;
    procedure hCccJisToUcs;
    procedure BuildRegistry;
    function RegCategory(Handle: Cardinal): TRegKey;
    function RegPath(const Path: string): TRegKey;
    procedure RegWriteValue(K: TRegKey; Buf, Size: Cardinal);
    procedure hRegOpenRegistry;
    procedure hRegCloseRegistry;
    procedure hRegOpenCategory;
    procedure hRegCloseCategory;
    procedure hRegZero;
    procedure hRegGetKeysNum;
    procedure hRegGetKeys;
    procedure hRegGetKeyInfo;
    procedure hRegGetKeyValue;
    procedure hRegGetKeyInfoByName;
    procedure hRegGetKeyValueByName;
    procedure hRegSetKeyValue;
    procedure hRegCreateKey;
    procedure hRegGetCategoryNumAtRoot;
    procedure hRegGetCategoryListAtRoot;
  public
    constructor Create(System: TPSPSystem); override;
    destructor Destroy; override;
    procedure Reset; override;
    procedure Register; override;
  end;

// The 18 fonts of flash0:/font in the registry's order.
function PSPFontFileName(Index: Integer): string;

implementation

uses
  System.Math, PSP.Settings;

function PSPFontFileName(Index: Integer): string;
begin
  case Index of
    0..15: Result := Format('ltn%d.pgf', [Index]);
    16: Result := 'jpn0.pgf';
  else
    Result := 'kr0.pgf';
  end;
end;

{$I PSP.Misc.Ccc.inc}
{$I PSP.Misc.Reg.inc}

constructor TPSPMisc.Create(System: TPSPSystem);
begin
  inherited Create(System);
  FRegHandles := TDictionary<Cardinal, TRegKey>.Create;
end;

destructor TPSPMisc.Destroy;
begin
  FRegHandles.Free;
  FRegRoot.Free;
  inherited;
end;

procedure TPSPMisc.Reset;
begin
  FJis2Ucs := 0;
  FUcs2Jis := 0;
  FErrorChar[0] := Ord('?');
  FErrorChar[1] := Ord('?');
  FErrorChar[2] := Ord('?');
  FRegHandles.Clear;
  FRegNextHandle := 0;
  BuildRegistry;
end;

procedure TPSPMisc.Register;
const
  C = 'sceCcc';
  R = 'sceReg';
begin
  var H := FHLE;
  H.Register(C, $B4D1CBBF, 'sceCccSetTable', hCccSetTable);
  H.Register(C, $00D1378F, 'sceCccUTF8toUTF16', hCccUtf8ToUtf16);
  H.Register(C, $6F82EE03, 'sceCccUTF8toSJIS', hCccUtf8ToSjis);
  H.Register(C, $41B724A5, 'sceCccUTF16toUTF8', hCccUtf16ToUtf8);
  H.Register(C, $F1B73D12, 'sceCccUTF16toSJIS', hCccUtf16ToSjis);
  H.Register(C, $A62E6E80, 'sceCccSJIStoUTF8', hCccSjisToUtf8);
  H.Register(C, $BEB47224, 'sceCccSJIStoUTF16', hCccSjisToUtf16);
  H.Register(C, $B7D3C112, 'sceCccStrlenUTF8', hCccStrlenUtf8);
  H.Register(C, $4BDEB2A8, 'sceCccStrlenUTF16', hCccStrlenUtf16);
  H.Register(C, $D9392CCB, 'sceCccStrlenSJIS', hCccStrlenSjis);
  H.Register(C, $92C05851, 'sceCccEncodeUTF8', hCccEncodeUtf8);
  H.Register(C, $8406F469, 'sceCccEncodeUTF16', hCccEncodeUtf16);
  H.Register(C, $068C4320, 'sceCccEncodeSJIS', hCccEncodeSjis);
  H.Register(C, $C6A8BEE2, 'sceCccDecodeUTF8', hCccDecodeUtf8);
  H.Register(C, $E0CF8091, 'sceCccDecodeUTF16', hCccDecodeUtf16);
  H.Register(C, $953E6C10, 'sceCccDecodeSJIS', hCccDecodeSjis);
  H.Register(C, $90521AC5, 'sceCccIsValidUTF8', hCccIsValidUtf8);
  H.Register(C, $CC0A8BDA, 'sceCccIsValidUTF16', hCccIsValidUtf16);
  H.Register(C, $67BF0D19, 'sceCccIsValidSJIS', hCccIsValidSjis);
  H.Register(C, $76E33E9C, 'sceCccIsValidUCS2', hCccIsValidUcs2);
  H.Register(C, $D2B18485, 'sceCccIsValidUCS4', hCccIsValidUcs4);
  H.Register(C, $A2D5D209, 'sceCccIsValidJIS', hCccIsValidJis);
  H.Register(C, $17E1D813, 'sceCccSetErrorCharUTF8', hCccSetErrorCharUtf8);
  H.Register(C, $B8476CF4, 'sceCccSetErrorCharUTF16', hCccSetErrorCharUtf16);
  H.Register(C, $C56949AD, 'sceCccSetErrorCharSJIS', hCccSetErrorCharSjis);
  H.Register(C, $70ECAA10, 'sceCccUCStoJIS', hCccUcsToJis);
  H.Register(C, $FB7846E2, 'sceCccJIStoUCS', hCccJisToUcs);

  H.Register(R, $92E41280, 'sceRegOpenRegistry', hRegOpenRegistry);
  H.Register(R, $FA8A5739, 'sceRegCloseRegistry', hRegCloseRegistry);
  H.Register(R, $DEDA92BF, 'sceRegRemoveRegistry', hRegZero);
  H.Register(R, $1D8A762E, 'sceRegOpenCategory', hRegOpenCategory);
  H.Register(R, $0CAE832B, 'sceRegCloseCategory', hRegCloseCategory);
  H.Register(R, $39461B4D, 'sceRegFlushRegistry', hRegZero);
  H.Register(R, $0D69BF40, 'sceRegFlushCategory', hRegZero);
  H.Register(R, $57641A81, 'sceRegCreateKey', hRegCreateKey);
  H.Register(R, $17768E14, 'sceRegSetKeyValue', hRegSetKeyValue);
  H.Register(R, $D4475AA8, 'sceRegGetKeyInfo', hRegGetKeyInfo);
  H.Register(R, $28A8E98A, 'sceRegGetKeyValue', hRegGetKeyValue);
  H.Register(R, $2C0DB9DD, 'sceRegGetKeysNum', hRegGetKeysNum);
  H.Register(R, $2D211135, 'sceRegGetKeys', hRegGetKeys);
  H.Register(R, $C5768D02, 'sceRegGetKeyInfoByName', hRegGetKeyInfoByName);
  H.Register(R, $30BE0259, 'sceRegGetKeyValueByName', hRegGetKeyValueByName);
  H.Register(R, $4CA16893, 'sceRegRemoveCategory', hRegZero);
  H.Register(R, $3615BC87, 'sceRegRemoveKey', hRegZero);
  H.Register(R, $9B25EDF1, 'sceRegExit', hRegZero);
  H.Register(R, $BE8C1263, 'sceRegGetCategoryNumAtRoot', hRegGetCategoryNumAtRoot);
  H.Register(R, $835ECE6F, 'sceRegGetCategoryListAtRoot', hRegGetCategoryListAtRoot);
end;

initialization
  RegisterPSPService(TPSPMisc);

finalization
  CccJisToUcs.Free;
  CccUcsToJis.Free;

end.
