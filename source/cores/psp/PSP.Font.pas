unit PSP.Font;

// sceLibFont: PGF fonts. A library lives in memory the program hands out
// through its own allocator callbacks, and so does what it keeps of each
// font: the program sees the allocations, frees and file callbacks the
// firmware library makes. Fonts come from flash0:/font (when the user
// supplied it), the program's files and memory images; a flash0 font that is
// missing is replaced by a built-in one of the same size and weight drawn
// from the Hershey strokes, with the Latin-1 characters only.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, System.Math, System.Generics.Collections, PSP.Types, PSP.Memory, PSP.CPU, PSP.HLE,
  PSP.Kernel, PSP.Scheduler, PSP.Service;

const
  // Lookups that find no glyph: below the font's first character (drawn and
  // measured as nothing), and not in the font (the alternative character
  // stands in).
  PGFBelow = -1;
  PGFMissing = -2;

type
  TPGFMetric = record
    X, Y: Integer;
  end;

  // A decoded glyph: one 0..15 level per pixel, rows from the top, and its
  // metrics in 26.6 fixed point.
  TPGFGlyph = class
  public
    W, H, Left, Top: Integer;
    // Dimension (width, height); BearingX (horizontal, vertical layout X);
    // BearingY (horizontal, vertical layout Y); advance (horizontal, vertical).
    Dim, BearingX, BearingY, Advance: TPGFMetric;
    ShadowFlags, ShadowId: Integer;
    // Bytes of the glyph in the file.
    DataSize: Integer;
    Pixels: TBytes;
    function Pixel(X, Y: Integer): Integer; inline;
  end;

  TPGFLayout = record
    HeaderSize, Revision: Integer;
    CharMapLength, CharPtrLength, CharMapBpe, CharPtrBpe: Integer;
    ShadowMapLength, ShadowMapBpe: Integer;
    TableLength: array[0..3] of Integer;
    ShadowMapPos, CharMapPos, CharPtrPos, GlyphPos: Int64;
    // What a font opened in mode 0 keeps, in the order the library allocates
    // it: the four metric tables, the shadow map, two charmap compression
    // tables, the charmap and the glyph pointers.
    Parts: array[0..8] of Cardinal;
    function Read(const Header: TBytes): Boolean;
  end;

  TPGFFont = class
  protected
    FGlyphs, FShadows: TObjectDictionary<Integer, TPGFGlyph>;
    function DecodeGlyph(Index: Integer): TPGFGlyph; virtual; abstract;
    function DecodeShadow(Index: Integer): TPGFGlyph; virtual; abstract;
  public
    // Header; sizes and resolutions in 26.6.
    HSize, VSize, HRes, VRes: Integer;
    Bpp: Integer;
    FirstCode, LastCode: Integer;
    GlyphCount: Integer;
    MaxAscender, MaxDescender, MaxLeftX, MaxBaseY, MinCenterX, MaxTopY: Integer;
    MaxAdvanceH, MaxAdvanceV, MaxSizeH, MaxSizeV: Integer;
    MaxGlyphWidth, MaxGlyphHeight: Integer;
    // The file's size, 0 when there is no file.
    FileSize: Cardinal;
    // The blocks a mode 0 open allocates (see TPGFLayout.Parts).
    Parts: TArray<Cardinal>;
    constructor Create;
    destructor Destroy; override;
    // A glyph index, PGFBelow or PGFMissing.
    function Lookup(Code: Integer): Integer; virtual; abstract;
    function Glyph(Index: Integer): TPGFGlyph;
    function Shadow(Index: Integer): TPGFGlyph;
  end;

  TPGFFile = class(TPGFFont)
  private
    FData: TBytes;
    FLayout: TPGFLayout;
    FCharMap, FCharPtr, FShadowMap: TArray<Integer>;
    FTables: array[0..3] of TArray<TPGFMetric>;
    function Bits(BitPos: Int64; N: Integer): Cardinal;
    function SBits(BitPos: Int64; N: Integer): Integer;
    function ReadMap(Pos: Int64; Count, Bpe: Integer): TArray<Integer>;
    function GlyphBitPos(Index: Integer): Int64;
    procedure DecodeBitmap(G: TPGFGlyph; BitPos: Int64; Layout: Integer);
  protected
    function DecodeGlyph(Index: Integer): TPGFGlyph; override;
    function DecodeShadow(Index: Integer): TPGFGlyph; override;
  public
    // nil when Data is no PGF font. Data may stop after the glyph pointers.
    class function Parse(const Data: TBytes): TPGFFile;
    function Lookup(Code: Integer): Integer; override;
  end;

  TPGFBuiltin = class(TPGFFont)
  protected
    function DecodeGlyph(Index: Integer): TPGFGlyph; override;
    function DecodeShadow(Index: Integer): TPGFGlyph; override;
  public
    constructor Create(Points: Single; Bold, Italic: Boolean);
    function Lookup(Code: Integer): Integer; override;
  end;

  // A font a library has loaded, shared by the handles opening the same one.
  TPSPFontData = class
  public
    Key: string;
    Font: TPGFFont;
    OwnsFont: Boolean;
    Refs: Integer;
    // The library's blocks for the font, in the order it frees them.
    Blocks: TArray<Cardinal>;
    // Opened in mode 0: glyphs are read from the file when first asked
    // about, and the one drawn last is loaded into two blocks.
    Streamed: Boolean;
    Seen: TDictionary<Integer, Boolean>;
    CacheKey: Integer;
    Cache: TArray<Cardinal>;
    destructor Destroy; override;
    // Whether the glyph has to come from the file first.
    function FirstLook(Index: Integer): Boolean;
  end;

  TPSPFontLib = class;

  TPSPFontSlot = class
  public
    Lib: TPSPFontLib;
    Handle: Cardinal;
    // The slot's record in the library's memory.
    Memory: Cardinal;
    Busy: Boolean;
    // What the slot opened last; a closed handle still reaches it.
    Data: TPSPFontData;
  end;

  TPSPFontLib = class
  public
    Addr: Cardinal;
    // The library, its font handles, its font records, the font list.
    Blocks: TArray<Cardinal>;
    Slots: TObjectList<TPSPFontSlot>;
    Datas: TObjectList<TPSPFontData>;
    Done: Boolean;
    constructor Create;
    destructor Destroy; override;
  end;

  TFontAllocDone = reference to procedure(const Addrs: TArray<Cardinal>; Ok: Boolean);
  TFontFail = reference to procedure(Error: Cardinal);
  TFontIOKind = (fiSeek, fiRead, fiClose);
  TFontIOOp = record
    Kind: TFontIOKind;
    A, B, C: Cardinal;
  end;
  TFontIO = record
    UserData, OpenF, CloseF, ReadF, SeekF, FH, ErrAddr: Cardinal;
  end;

  TPSPFont = class(TPSPService)
  private
    FLibs: TObjectDictionary<Cardinal, TPSPFontLib>;
    FSlots: TDictionary<Cardinal, TPSPFontSlot>;
    // flash0 and built-in fonts, shared by every library.
    FFonts: TObjectDictionary<Integer, TPGFFont>;
    function LibOf(Addr: Cardinal): TPSPFontLib;
    function SlotOf(Handle: Cardinal): TPSPFontSlot;
    procedure SetError(Ptr, Code: Cardinal);
    procedure Finish(Value: Cardinal; YieldUs: Integer);
    procedure AllocStep(AllocF, FreeF, UserData: Cardinal; const Sizes, Addrs: TArray<Cardinal>; I: Integer;
      const Done: TFontAllocDone);
    procedure AllocBlocks(Lib: TPSPFontLib; const Sizes: TArray<Cardinal>; const Done: TFontAllocDone);
    procedure FreeStep(FreeF, UserData: Cardinal; const Addrs: TArray<Cardinal>; I: Integer; const Done: TProc);
    procedure FreeBlocks(Lib: TPSPFontLib; const Addrs: TArray<Cardinal>; const Done: TProc);
    procedure RunIO(const IO: TFontIO; const Ops: TArray<TFontIOOp>; I: Integer; const Done: TProc;
      const Fail: TFontFail);
    procedure RemoveLib(Addr: Cardinal);
    function CreateLib(const Addrs: TArray<Cardinal>; Count: Integer; const Params: TBytes): TPSPFontLib;
    function FreeSlot(Lib: TPSPFontLib): TPSPFontSlot;
    function SharedData(Lib: TPSPFontLib; const Key: string): TPSPFontData;
    function AddData(Lib: TPSPFontLib; const Key: string; Font: TPGFFont; Owns: Boolean;
      const Blocks: TArray<Cardinal>): TPSPFontData;
    procedure Attach(Slot: TPSPFontSlot; Data: TPSPFontData);
    function InternalFont(Index: Integer): TPGFFont;
    function GuestBytes(Addr, Size: Cardinal): TBytes;
    procedure OpenStreamed(Lib: TPSPFontLib; NamePtr: Cardinal; const Name: string; ErrPtr: Cardinal);
    procedure OpenWhole(Lib: TPSPFontLib; const Name: string; ErrPtr: Cardinal);
    function Resolve(Slot: TPSPFontSlot; Code: Integer): Integer;
    procedure WriteStyle(Addr: Cardinal; Index: Integer);
    procedure WriteCharInfo(Addr: Cardinal; G, Bitmap: TPGFGlyph);
    procedure Draw(G: TPGFGlyph; Image: Cardinal; ClipX, ClipY, ClipW, ClipH: Integer);
    procedure DrawCall(Shadow, Clip: Boolean);
    procedure InfoCall(Shadow: Boolean);
    procedure RectCall(Shadow: Boolean);
    procedure Convert(Vertical, ToPoints: Boolean);
    function Match(Lib: TPSPFontLib; Style: Cardinal; Optimum: Boolean): Integer;
    procedure hNewLib;
    procedure hDoneLib;
    procedure hOpen;
    procedure hOpenUserMemory;
    procedure hOpenUserFile;
    procedure hClose;
    procedure hGetNumFontList;
    procedure hGetFontList;
    procedure hFindOptimumFont;
    procedure hFindFont;
    procedure hGetFontInfo;
    procedure hGetFontInfoByIndexNumber;
    procedure hGetCharInfo;
    procedure hGetShadowInfo;
    procedure hGetCharImageRect;
    procedure hGetShadowImageRect;
    procedure hGetCharGlyphImage;
    procedure hGetCharGlyphImageClip;
    procedure hGetShadowGlyphImage;
    procedure hGetShadowGlyphImageClip;
    procedure hSetAltCharacterCode;
    procedure hSetResolution;
    procedure hPixelToPointH;
    procedure hPixelToPointV;
    procedure hPointToPixelH;
    procedure hPointToPixelV;
    procedure hFlush;
  public
    constructor Create(System: TPSPSystem); override;
    destructor Destroy; override;
    procedure Reset; override;
    procedure Register; override;
    // The font behind a handle the program opened, for a renderer (nil if none).
    function FontOf(Handle: Cardinal): TPGFFont;
  end;

implementation

uses
  PSP.IO;

const
  SCE_FONT_ERROR_NOMEMORY = Cardinal($80460001);
  SCE_FONT_ERROR_LIBID = Cardinal($80460002);
  SCE_FONT_ERROR_ARG = Cardinal($80460003);
  SCE_FONT_ERROR_FILEOPEN = Cardinal($80460005);
  SCE_FONT_ERROR_FILEREAD = Cardinal($80460007);
  SCE_FONT_ERROR_FILESEEK = Cardinal($80460008);
  SCE_FONT_ERROR_TOOMANYOPENED = Cardinal($80460009);
  SCE_FONT_ERROR_DATAINCONSISTENT = Cardinal($8046000B);

{$I PSP.Font.PGF.inc}
{$I PSP.Font.Builtin.inc}
{$I PSP.Font.Lib.inc}
{$I PSP.Font.Draw.inc}

initialization
  RegisterPSPService(TPSPFont);

end.
