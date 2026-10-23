unit HW.SH4;

// Hitachi SH-4 (SH7750/SH7091) instruction interpreter: integer and FPU
// instructions, delay slots, exceptions and interrupt acceptance, store
// queues, operand-cache RAM and the UTLB/ITLB arrays. Decoded blocks are
// cached per virtual PC and execution mode and validated against write
// generations of their 4 KiB code pages.
// References: Renesas SH-4 Software Manual (REJ09B0318) and SH7750 Series
// Hardware Manual (REJ09B0366). Define DC_CHECKED for range/overflow checks.
{$IFDEF DC_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$EXCESSPRECISION OFF}
{$POINTERMATH ON}

interface

uses
  System.SysUtils, System.Math, Core.Snapshots;

const
  // Exception codes (EXPEVT) and vector offsets from VBR.
  SH4ExcTLBMissRead = $040;
  SH4ExcTLBMissWrite = $060;
  SH4ExcInitialWrite = $080;
  SH4ExcTLBProtRead = $0A0;
  SH4ExcTLBProtWrite = $0C0;
  SH4ExcAddressRead = $0E0;
  SH4ExcAddressWrite = $100;
  SH4ExcFPU = $120;
  SH4ExcTrap = $160;
  SH4ExcIllegal = $180;
  SH4ExcSlotIllegal = $1A0;
  SH4ExcFPUDisabled = $800;
  SH4ExcSlotFPUDisabled = $820;

  SH4SRWriteMask = $700083F3;
  SH4FPSCRMask = $003FFFFF;

type
  // Bus callbacks receive physical (29-bit) addresses outside the direct
  // pages. Size is 1, 2, 4 or 8 bytes; values are little-endian.
  TSH4BusRead = function(User: Pointer; Address: Cardinal; Size: Integer): UInt64;
  TSH4BusWrite = procedure(User: Pointer; Address: Cardinal; Value: UInt64; Size: Integer);
  // 32-byte store-queue or similar burst to a physical address.
  TSH4BusBurst = procedure(User: Pointer; Address: Cardinal; Data: PCardinal; Count: Integer);
  // On-chip modules outside the CPU core (P4 0xFF000000.., area 7).
  TSH4OnChipRead = function(User: Pointer; Address: Cardinal; Size: Integer): Cardinal;
  TSH4OnChipWrite = procedure(User: Pointer; Address, Value: Cardinal; Size: Integer);
  // Optional instruction fetch hook for test harnesses (all fetches when set).
  TSH4Fetch = function(User: Pointer; Address: Cardinal): Word;
  // Called for an illegal instruction; True when the owner handled it (HLE
  // firmware entry points) and set PC itself.
  TSH4IllegalHook = function(User: Pointer; Address: Cardinal): Boolean;

  // Physical 64 KiB pages: host memory or nil (callbacks). Gens points to
  // sixteen write-generation counters, one per 4 KiB of the page.
  TSH4PhysicalPages = array[0..8191] of PByte;
  TSH4PhysicalGens = array[0..8191] of PCardinal;
  PSH4PhysicalPages = ^TSH4PhysicalPages;
  PSH4PhysicalGens = ^TSH4PhysicalGens;

  TSH4Bus = record
    User: Pointer;
    Read: TSH4BusRead;
    Write: TSH4BusWrite;
    Burst: TSH4BusBurst;
    OnChipRead: TSH4OnChipRead;
    OnChipWrite: TSH4OnChipWrite;
    OnChipUser: Pointer;
    ReadPages, WritePages: PSH4PhysicalPages;
    Gens: PSH4PhysicalGens;
  end;

  TSH4FPBank = record
    case Integer of
      0: (S: array[0..15] of Single);
      1: (U: array[0..15] of Cardinal);
      2: (D: array[0..7] of Double);
      3: (Q: array[0..7] of UInt64);
  end;

  TSH4TLBEntry = record
    VPN, ASID, PPN, Flags, PTEA: Cardinal; // Flags: V SZ PR C D SH WT (PTEL bits)
  end;

  // Complete architectural state. FR/XF hold FRn at index n xor 1, so that
  // DRn (even n) is the native double D[n div 2]. R0..R7 always hold the
  // active bank; RBank the inactive one (swapped on SR.RB changes).
  TSH4Registers = array[0..15] of Cardinal;

  TSH4State = record
    R: TSH4Registers;
    RBank: array[0..7] of Cardinal;
    FR, XF: TSH4FPBank;
    PC, PR, GBR, VBR, SSR, SPC, SGR, DBR, MACH, MACL, FPUL, FPSCR: Cardinal;
    SR, T: Cardinal; // SR without T; T separately (0/1)
    // Delay slot across Step calls.
    DelaySlot: Boolean;
    DelayTarget: Cardinal;
    // RTE restores SR after its delay slot.
    RTEPending: Boolean;
    RTESR: Cardinal;
    Sleeping: Boolean;
    // CCN.
    PTEH, PTEL, PTEA, TTB, TEA, MMUCR, CCR, TRA, EXPEVT, INTEVT, QACR0, QACR1, BASRA, BASRB: Cardinal;
    SQ: array[0..1, 0..7] of Cardinal;
    UTLB: array[0..63] of TSH4TLBEntry;
    ITLB: array[0..3] of TSH4TLBEntry;
    OCRAM: array[0..8191] of Byte;
  end;

  TSH4Inst = record
    Kind: Byte;
    N, M: Byte;
    Flags: Byte;
    Imm: Cardinal;
    Addr: Cardinal;
  end;
  PSH4Inst = ^TSH4Inst;

  PSH4Block = ^TSH4Block;
  TSH4Block = record
    PC, Mode: Cardinal;
    Count: Integer;
    Insts: PSH4Inst;
    Code: PWord;
    Words: Integer;
    GenPtr, GenPtr2: PCardinal;
    Gen, Gen2: Cardinal;
    Next: PSH4Block;
    Idle: Boolean;
  end;

  TSH4 = class
  private
    const
      BlockBuckets = 16384;
      BlockChunkSize = 1024;
      InstChunkSize = 16384;
      MaxBlockInsts = 128;
      {$IFDEF CPU64BITS}
      MaxBlocks = 65536;
      MaxInstChunks = 96;
      {$ELSE}
      MaxBlocks = 16384;
      MaxInstChunks = 24;
      {$ENDIF}
  private
    FBus: TSH4Bus;
    FFetch: TSH4Fetch;
    FFetchUser: Pointer;
    FIllegalHook: TSH4IllegalHook;
    FIllegalUser: Pointer;
    // Virtual 64 KiB pages for direct access (nil: slow path).
    FReadMap: array[0..65535] of PByte;
    FWriteMap: array[0..65535] of PByte;
    FGenMap: array[0..65535] of PCardinal;
    FZeroGens, FSinkGens: array[0..15] of Cardinal;
    // Pending interrupt from INTC (0: none).
    FIRQLevel: Integer;
    FIRQCode: Cardinal;
    // Set by slow paths; the executing instruction stops without side effects.
    FFault: Boolean;
    // Set by MMIO writes that need the run loop to return to the scheduler.
    FExitRequest: Boolean;
    FHostRoundSaved: TRoundingMode;
    FHostMaskSaved: TArithmeticExceptionMask;
    // Blocks.
    FBlockHead: array[0..BlockBuckets - 1] of PSH4Block;
    FBlockChunks: TArray<TArray<TSH4Block>>;
    FInstChunks: TArray<TArray<TSH4Inst>>;
    FCodeChunks: TArray<TArray<Word>>;
    FBlockCount, FInstChunk, FInstUsed, FCodeChunk, FCodeUsed: Integer;
    FBlocksBuilt: Int64;
    FBlocksEnabled: Boolean;
    FLenient: Boolean;
    FScratch: array[0..1] of TSH4Inst;
    procedure BuildMaps;
    function PhysicalPage(Virtual: Cardinal; Writing: Boolean): PByte;
    function SlowRead(Address: Cardinal; Size: Integer): UInt64;
    procedure SlowWrite(Address: Cardinal; Value: UInt64; Size: Integer);
    function ReadControl(Address: Cardinal; Size: Integer): Cardinal;
    procedure WriteControl(Address, Value: Cardinal; Size: Integer);
    function Translate(Address: Cardinal; Writing: Boolean; out Physical: Cardinal): Boolean;
    procedure StoreQueueFlush(Address: Cardinal);
    procedure SwapBanks; inline;
    procedure SwapFPBanks; inline;
    procedure SetSRValue(Value: Cardinal);
    procedure SetFPSCRValue(Value: Cardinal);
    procedure ApplyHostRounding;
    function GetSRValue: Cardinal; inline;
    function Mode: Cardinal;
    procedure EnterException(Code, Offset, ReturnPC: Cardinal);
    procedure Fault(Code: Cardinal; const I: TSH4Inst; Slot: Boolean);
    function FetchWord(Address: Cardinal; out Op: Word): Boolean;
    function Decode(Op: Word; Address, AMode: Cardinal; Slot: Boolean; out I: TSH4Inst): Boolean;
    function Execute(Insts: PSH4Inst; Count: Integer; out Next: Cardinal): Integer;
    procedure ClearBlocks;
    function FindBlock(PC, AMode: Cardinal): PSH4Block;
    function BuildBlock(PC, AMode: Cardinal): PSH4Block;
    function BlockValid(B: PSH4Block): Boolean;
    function Read8(A: Cardinal): Cardinal; inline;
    function Read16(A: Cardinal): Cardinal; inline;
    function Read32(A: Cardinal): Cardinal; inline;
    function Read64(A: Cardinal): UInt64; inline;
    procedure Write8(A, V: Cardinal); inline;
    procedure Write16(A, V: Cardinal); inline;
    procedure Write32(A, V: Cardinal); inline;
    procedure Write64(A: Cardinal; V: UInt64); inline;
  public
    S: TSH4State;
    // Advanced by executed instructions; the run loop stops at Deadline^.
    Now, Deadline: PInt64;
    InstructionsExecuted: Int64;
    // Diagnostics (not serialized): exceptions taken and the first one.
    ExceptionCount: Int64;
    FirstExceptionPC, FirstExceptionCode, FirstExceptionPR: Cardinal;
    constructor Create(const Bus: TSH4Bus; NowCounter, DeadlineCounter: PInt64);
    procedure Reset;
    // Physical page tables or MMU/OCRAM state changed.
    procedure RemapMemory;
    procedure InvalidateBlocks;
    procedure SetFetchHook(Fetch: TSH4Fetch; User: Pointer);
    procedure SetIllegalHook(Hook: TSH4IllegalHook; User: Pointer);
    // Highest pending INTC request: priority level 1..15 and INTEVT code.
    procedure SetInterrupt(Level: Integer; Code: Cardinal);
    procedure RequestExit; inline;
    // Executes until Now^ >= Deadline^ (whole blocks).
    procedure Run;
    // Executes exactly one instruction (a delay slot is a separate step).
    procedure Step;
    // Physical address from a virtual one with the current MMU state, for DMA.
    function PhysicalAddress(Virtual: Cardinal): Cardinal;
    function ReadVirtual32(Address: Cardinal): Cardinal;
    procedure WriteVirtual32(Address, Value: Cardinal);
    procedure SerializeState(Archive: TStateArchive);
    function SRValue: Cardinal;
    procedure SetSR(Value: Cardinal);
    procedure SetFPSCR(Value: Cardinal);
    property BlocksBuilt: Int64 read FBlocksBuilt;
    property BlocksEnabled: Boolean read FBlocksEnabled write FBlocksEnabled;
    // SingleStepTests conventions: no alignment, privilege or FPU-disable
    // exceptions. Never set for emulation.
    property Lenient: Boolean read FLenient write FLenient;
    property IRQLevel: Integer read FIRQLevel;
  end;

implementation

// Guest integer arithmetic wraps modulo 2^32 by definition; DC_CHECKED keeps
// range checks for host indexing.
{$Q-}

const
  SRT = $00000001;
  SRS = $00000002;
  SRQ = $00000100;
  SRM = $00000200;
  SRFD = $00008000;
  SRBL = $10000000;
  SRRB = $20000000;
  SRMD = $40000000;

  FPSCRDN = $00040000;
  FPSCRPR = $00080000;
  FPSCRSZ = $00100000;
  FPSCRFR = $00200000;

  ModeMD = 1;
  ModeFD = 2;
  ModePR = 4;
  ModeSZ = 8;

  // TSH4Inst.Flags
  IFEnd = 1;       // the block ends after this instruction
  IFDelayed = 2;   // delayed branch; the next instruction is its slot
  IFSlot = 4;      // executes in a delay slot

type
  TOp = (
    oIllegal, oSlotIllegal, oFPUDisabled, oSlotFPUDisabled,
    oNOP, oMOV, oMOVI, oMOVWPC, oMOVLPC, oMOVA,
    oMOVBS, oMOVWS, oMOVLS, oMOVBL, oMOVWL, oMOVLL,
    oMOVBM, oMOVWM, oMOVLM, oMOVBP, oMOVWP, oMOVLP,
    oMOVBS0, oMOVWS0, oMOVLS0, oMOVBL0, oMOVWL0, oMOVLL0,
    oMOVBS4, oMOVWS4, oMOVLS4, oMOVBL4, oMOVWL4, oMOVLL4,
    oMOVBSG, oMOVWSG, oMOVLSG, oMOVBLG, oMOVWLG, oMOVLLG,
    oMOVT, oSWAPB, oSWAPW, oXTRCT,
    oADD, oADDI, oADDC, oADDV, oCMPEQ, oCMPEQI, oCMPHS, oCMPGE, oCMPHI, oCMPGT, oCMPPZ, oCMPPL, oCMPSTR,
    oDIV0S, oDIV0U, oDIV1, oDMULS, oDMULU, oDT, oEXTSB, oEXTSW, oEXTUB, oEXTUW,
    oMACL, oMACW, oMULL, oMULSW, oMULUW, oNEG, oNEGC, oSUB, oSUBC, oSUBV,
    oAND, oANDI, oANDB, oNOT, oOR, oORI, oORB, oTASB, oTST, oTSTI, oTSTB, oXOR, oXORI, oXORB,
    oROTL, oROTR, oROTCL, oROTCR, oSHAD, oSHAL, oSHAR, oSHLD, oSHLL, oSHLL2, oSHLL8, oSHLL16,
    oSHLR, oSHLR2, oSHLR8, oSHLR16,
    oBF, oBFS, oBT, oBTS, oBRA, oBRAF, oBSR, oBSRF, oJMP, oJSR, oRTS, oRTE,
    oCLRMAC, oCLRS, oCLRT, oSETS, oSETT, oLDTLB, oMOVCAL, oOCB, oPREF, oSLEEP, oTRAPA,
    oLDCSR, oLDCGBR, oLDCVBR, oLDCSSR, oLDCSPC, oLDCDBR, oLDCBANK,
    oLDCMSR, oLDCMGBR, oLDCMVBR, oLDCMSSR, oLDCMSPC, oLDCMDBR, oLDCMBANK,
    oLDSMACH, oLDSMACL, oLDSPR, oLDSMMACH, oLDSMMACL, oLDSMPR,
    oSTCSR, oSTCGBR, oSTCVBR, oSTCSSR, oSTCSPC, oSTCSGR, oSTCDBR, oSTCBANK,
    oSTCMSR, oSTCMGBR, oSTCMVBR, oSTCMSSR, oSTCMSPC, oSTCMSGR, oSTCMDBR, oSTCMBANK,
    oSTSMACH, oSTSMACL, oSTSPR, oSTSMMACH, oSTSMMACL, oSTSMPR,
    oLDSFPSCR, oLDSFPUL, oLDSMFPSCR, oLDSMFPUL, oSTSFPSCR, oSTSFPUL, oSTSMFPSCR, oSTSMFPUL,
    oFMOV, oFMOVLD, oFMOVLD0, oFMOVLDP, oFMOVST, oFMOVST0, oFMOVSTM,
    oFMOVD, oFMOVDLD, oFMOVDLD0, oFMOVDLDP, oFMOVDST, oFMOVDST0, oFMOVDSTM,
    oFLDI0, oFLDI1, oFLDS, oFSTS, oFABS, oFNEG, oFADD, oFSUB, oFMUL, oFDIV, oFMAC, oFSQRT,
    oFCMPEQ, oFCMPGT, oFLOAT, oFTRC, oFSRRA, oFIPR, oFTRV, oFSCA, oFSCHG, oFRCHG,
    oDABS, oDNEG, oDADD, oDSUB, oDMUL, oDDIV, oDSQRT, oDCMPEQ, oDCMPGT, oDFLOAT, oDFTRC,
    oFCNVSD, oFCNVDS);

{ Memory }

function TSH4.PhysicalPage(Virtual: Cardinal; Writing: Boolean): PByte;
begin
  Result := nil;
  if Virtual >= $E0000000 then
    Exit;
  if ((Virtual < $80000000) or (Virtual >= $C0000000)) and ((S.MMUCR and 1) <> 0) then
    Exit;
  var Physical := Virtual and $1FFFFFFF;
  // Area 7 holds on-chip registers; 7C000000..7FFFFFFF the operand-cache RAM.
  if Physical >= $1C000000 then
    Exit;
  if Writing then
    Result := FBus.WritePages[Physical shr 16]
  else
    Result := FBus.ReadPages[Physical shr 16];
end;

procedure TSH4.BuildMaps;
begin
  for var Page := 0 to 65535 do
  begin
    var Virtual := Cardinal(Page) shl 16;
    FReadMap[Page] := PhysicalPage(Virtual, False);
    FWriteMap[Page] := PhysicalPage(Virtual, True);
    FGenMap[Page] := @FSinkGens[0];
    if FReadMap[Page] <> nil then
    begin
      var G := FBus.Gens[(Virtual and $1FFFFFFF) shr 16];
      if G <> nil then
        FGenMap[Page] := G
      else if FWriteMap[Page] = nil then
        FGenMap[Page] := @FZeroGens[0];
    end;
  end;
end;

procedure TSH4.RemapMemory;
begin
  BuildMaps;
end;

function TSH4.Read8(A: Cardinal): Cardinal;
begin
  var P := FReadMap[A shr 16];
  if P <> nil then
    Result := (P + (A and $FFFF))^
  else
    Result := Cardinal(SlowRead(A, 1));
end;

function TSH4.Read16(A: Cardinal): Cardinal;
begin
  var P := FReadMap[A shr 16];
  if (P <> nil) and ((A and 1) = 0) then
    Result := PWord(P + (A and $FFFF))^
  else
    Result := Cardinal(SlowRead(A, 2));
end;

function TSH4.Read32(A: Cardinal): Cardinal;
begin
  var P := FReadMap[A shr 16];
  if (P <> nil) and ((A and 3) = 0) then
    Result := PCardinal(P + (A and $FFFF))^
  else
    Result := Cardinal(SlowRead(A, 4));
end;

function TSH4.Read64(A: Cardinal): UInt64;
begin
  var P := FReadMap[A shr 16];
  if (P <> nil) and ((A and 7) = 0) then
    Result := PUInt64(P + (A and $FFFF))^
  else
    Result := SlowRead(A, 8);
end;

procedure TSH4.Write8(A, V: Cardinal);
begin
  var P := FWriteMap[A shr 16];
  if P <> nil then
  begin
    (P + (A and $FFFF))^ := Byte(V);
    Inc(FGenMap[A shr 16][(A shr 12) and 15]);
  end
  else
    SlowWrite(A, V and $FF, 1);
end;

procedure TSH4.Write16(A, V: Cardinal);
begin
  var P := FWriteMap[A shr 16];
  if (P <> nil) and ((A and 1) = 0) then
  begin
    PWord(P + (A and $FFFF))^ := Word(V);
    Inc(FGenMap[A shr 16][(A shr 12) and 15]);
  end
  else
    SlowWrite(A, V and $FFFF, 2);
end;

procedure TSH4.Write32(A, V: Cardinal);
begin
  var P := FWriteMap[A shr 16];
  if (P <> nil) and ((A and 3) = 0) then
  begin
    PCardinal(P + (A and $FFFF))^ := V;
    Inc(FGenMap[A shr 16][(A shr 12) and 15]);
  end
  else
    SlowWrite(A, V, 4);
end;

procedure TSH4.Write64(A: Cardinal; V: UInt64);
begin
  var P := FWriteMap[A shr 16];
  if (P <> nil) and ((A and 7) = 0) then
  begin
    PUInt64(P + (A and $FFFF))^ := V;
    Inc(FGenMap[A shr 16][(A shr 12) and 15]);
  end
  else
    SlowWrite(A, V, 8);
end;

function TSH4.Translate(Address: Cardinal; Writing: Boolean; out Physical: Cardinal): Boolean;
begin
  // UTLB search (ITLB shares it). Without AT, P0..P3 map to the low 29 bits.
  Result := True;
  Physical := Address and $1FFFFFFF;
  if ((S.MMUCR and 1) = 0) or ((Address >= $80000000) and (Address < $C0000000)) then
    Exit;
  var ASID := S.PTEH and $FF;
  var Shared := (S.MMUCR and $100) <> 0; // SV: single virtual memory
  var Found := -1;
  for var I := 0 to 63 do
  begin
    var E := S.UTLB[I];
    if (E.Flags and $100) = 0 then
      Continue;
    var Mask: Cardinal;
    case ((E.Flags shr 6) and 2) or ((E.Flags shr 4) and 1) of
      0: Mask := $FFFFFC00;
      1: Mask := $FFFFF000;
      2: Mask := $FFFF0000;
    else
      Mask := $FFF00000;
    end;
    if ((E.VPN xor Address) and Mask) <> 0 then
      Continue;
    if ((E.Flags and 2) = 0) and not (Shared and ((S.SR and SRMD) <> 0)) and (E.ASID <> ASID) then
      Continue;
    if Found >= 0 then
    begin
      // Multiple hit: treated as a miss (the hardware raises a reset).
      Found := -1;
      Break;
    end;
    Found := I;
    Physical := (E.PPN and Mask) or (Address and not Mask);
  end;
  if Found < 0 then
  begin
    S.TEA := Address;
    S.PTEH := (S.PTEH and $FF) or (Address and $FFFFFC00);
    FFault := True;
    if Writing then
      S.EXPEVT := SH4ExcTLBMissWrite
    else
      S.EXPEVT := SH4ExcTLBMissRead;
    Exit(False);
  end;
  var E := S.UTLB[Found];
  var PR := (E.Flags shr 5) and 3;
  var Privileged := (S.SR and SRMD) <> 0;
  if (not Privileged and (PR < 2)) or (Writing and ((PR and 1) = 0)) then
  begin
    S.TEA := Address;
    S.PTEH := (S.PTEH and $FF) or (Address and $FFFFFC00);
    FFault := True;
    if Writing then
      S.EXPEVT := SH4ExcTLBProtWrite
    else
      S.EXPEVT := SH4ExcTLBProtRead;
    Exit(False);
  end;
  if Writing and ((E.Flags and 4) = 0) then
  begin
    S.TEA := Address;
    S.PTEH := (S.PTEH and $FF) or (Address and $FFFFFC00);
    FFault := True;
    S.EXPEVT := SH4ExcInitialWrite;
    Exit(False);
  end;
  Physical := Physical and $1FFFFFFF;
end;

function TSH4.PhysicalAddress(Virtual: Cardinal): Cardinal;
begin
  if not Translate(Virtual, False, Result) then
  begin
    FFault := False;
    Result := Virtual and $1FFFFFFF;
  end;
end;

function TSH4.ReadVirtual32(Address: Cardinal): Cardinal;
begin
  Result := Read32(Address);
  FFault := False;
end;

procedure TSH4.WriteVirtual32(Address, Value: Cardinal);
begin
  Write32(Address, Value);
  FFault := False;
end;

function OCRAMOffset(Address, CCR: Cardinal): Integer; inline;
begin
  // Two 4 KiB halves selected by A12 (OIX=0) or A25 (OIX=1).
  if (CCR and $80) <> 0 then
    Result := Integer(((Address shr 13) and $1000) or (Address and $FFF))
  else
    Result := Integer(Address and $1FFF);
end;

function TSH4.SlowRead(Address: Cardinal; Size: Integer): UInt64;
begin
  Result := 0;
  if FLenient then
    Exit(FBus.Read(FBus.User, Address and $1FFFFFFF, Size));
  if (Address and Cardinal(Size - 1)) <> 0 then
  begin
    S.TEA := Address;
    S.EXPEVT := SH4ExcAddressRead;
    FFault := True;
    Exit;
  end;
  if Address >= $E0000000 then
  begin
    if Address < $E4000000 then
    begin
      // Store queues read back their contents.
      var Q := (Address shr 5) and 1;
      var Index := (Address shr 2) and 7;
      if Size = 8 then
        Result := S.SQ[Q, Index] or (UInt64(S.SQ[Q, (Index + 1) and 7]) shl 32)
      else
        Result := S.SQ[Q, Index];
      Exit;
    end;
    if Address >= $F0000000 then
      Exit(ReadControl(Address, Size));
    Exit;
  end;
  if ((Address and $FC000000) = $7C000000) and ((S.CCR and $21) = $21) then
  begin
    var Offset := OCRAMOffset(Address, S.CCR);
    case Size of
      1: Result := S.OCRAM[Offset];
      2: Result := PWord(@S.OCRAM[Offset])^;
      4: Result := PCardinal(@S.OCRAM[Offset])^;
    else
      Result := PUInt64(@S.OCRAM[Offset])^;
    end;
    Exit;
  end;
  var Physical: Cardinal;
  if not Translate(Address, False, Physical) then
    Exit;
  if Physical >= $1C000000 then
    Exit(ReadControl(Physical or $E0000000, Size));
  var P := FBus.ReadPages[Physical shr 16];
  if P <> nil then
  begin
    P := P + (Physical and $FFFF);
    case Size of
      1: Result := P^;
      2: Result := PWord(P)^;
      4: Result := PCardinal(P)^;
    else
      Result := PUInt64(P)^;
    end;
    Exit;
  end;
  Result := FBus.Read(FBus.User, Physical, Size);
end;

procedure TSH4.SlowWrite(Address: Cardinal; Value: UInt64; Size: Integer);
begin
  if FLenient then
  begin
    FBus.Write(FBus.User, Address and $1FFFFFFF, Value, Size);
    Exit;
  end;
  if (Address and Cardinal(Size - 1)) <> 0 then
  begin
    S.TEA := Address;
    S.EXPEVT := SH4ExcAddressWrite;
    FFault := True;
    Exit;
  end;
  if Address >= $E0000000 then
  begin
    if Address < $E4000000 then
    begin
      var Q := (Address shr 5) and 1;
      var Index := (Address shr 2) and 7;
      if Size = 8 then
      begin
        S.SQ[Q, Index] := Cardinal(Value);
        S.SQ[Q, (Index + 1) and 7] := Cardinal(Value shr 32);
      end
      else
        S.SQ[Q, Index] := Cardinal(Value);
      Exit;
    end;
    if Address >= $F0000000 then
      WriteControl(Address, Cardinal(Value), Size);
    Exit;
  end;
  if ((Address and $FC000000) = $7C000000) and ((S.CCR and $21) = $21) then
  begin
    var Offset := OCRAMOffset(Address, S.CCR);
    case Size of
      1: S.OCRAM[Offset] := Byte(Value);
      2: PWord(@S.OCRAM[Offset])^ := Word(Value);
      4: PCardinal(@S.OCRAM[Offset])^ := Cardinal(Value);
    else
      PUInt64(@S.OCRAM[Offset])^ := Value;
    end;
    Exit;
  end;
  var Physical: Cardinal;
  if not Translate(Address, True, Physical) then
    Exit;
  if Physical >= $1C000000 then
  begin
    WriteControl(Physical or $E0000000, Cardinal(Value), Size);
    Exit;
  end;
  var P := FBus.WritePages[Physical shr 16];
  if P <> nil then
  begin
    P := P + (Physical and $FFFF);
    case Size of
      1: P^ := Byte(Value);
      2: PWord(P)^ := Word(Value);
      4: PCardinal(P)^ := Cardinal(Value);
    else
      PUInt64(P)^ := Value;
    end;
    var G := FBus.Gens[Physical shr 16];
    if G <> nil then
      Inc(G[(Physical shr 12) and 15]);
    Exit;
  end;
  FBus.Write(FBus.User, Physical, Value, Size);
end;

procedure TSH4.StoreQueueFlush(Address: Cardinal);
begin
  var Q := (Address shr 5) and 1;
  var Target: Cardinal;
  if (S.MMUCR and 1) <> 0 then
  begin
    if not Translate(Address, True, Target) then
      Exit;
    Target := Target and $1FFFFFE0;
  end
  else
  begin
    var QACR := S.QACR0;
    if Q <> 0 then
      QACR := S.QACR1;
    Target := ((QACR and $1C) shl 24) or (Address and $03FFFFE0);
  end;
  var P := FBus.WritePages[Target shr 16];
  if P <> nil then
  begin
    Move(S.SQ[Q, 0], (P + (Target and $FFFF))^, 32);
    var G := FBus.Gens[Target shr 16];
    if G <> nil then
      Inc(G[(Target shr 12) and 15]);
  end
  else
    FBus.Burst(FBus.User, Target, @S.SQ[Q, 0], 8);
end;

function TSH4.ReadControl(Address: Cardinal; Size: Integer): Cardinal;
begin
  Result := 0;
  case Address shr 24 of
    $F2, $F3:
      begin
        // ITLB address/data arrays.
        var E := S.ITLB[(Address shr 8) and 3];
        if (Address shr 24) = $F2 then
          Result := (E.VPN and $FFFFFC00) or ((E.Flags shr 8) and 1) shl 8 or E.ASID
        else
          Result := (E.PPN and $1FFFFC00) or (E.Flags and $1FF);
      end;
    $F6, $F7:
      begin
        var E := S.UTLB[(Address shr 8) and 63];
        if (Address shr 24) = $F6 then
          Result := (E.VPN and $FFFFFC00) or (((E.Flags shr 2) and 1) shl 9) or (((E.Flags shr 8) and 1) shl 8) or E.ASID
        else if (Address and $00800000) = 0 then
          Result := (E.PPN and $1FFFFC00) or (E.Flags and $1FF)
        else
          Result := E.PTEA;
      end;
    $FF, $1F:
      case Address and $00FFFFFF of
        $000000: Result := S.PTEH;
        $000004: Result := S.PTEL;
        $000008: Result := S.TTB;
        $00000C: Result := S.TEA;
        $000010: Result := S.MMUCR;
        $000014: Result := S.BASRA;
        $000018: Result := S.BASRB;
        $00001C: Result := S.CCR;
        $000020: Result := S.TRA;
        $000024: Result := S.EXPEVT;
        $000028: Result := S.INTEVT;
        $000034: Result := S.PTEA;
        $000038: Result := S.QACR0;
        $00003C: Result := S.QACR1;
      else
        if Assigned(FBus.OnChipRead) then
          Result := FBus.OnChipRead(FBus.OnChipUser, (Address and $00FFFFFF) or $FF000000, Size);
      end;
  end;
  case Size of
    1: Result := Result and $FF;
    2: Result := Result and $FFFF;
  end;
end;

procedure TSH4.WriteControl(Address, Value: Cardinal; Size: Integer);
begin
  case Address shr 24 of
    $F2, $F3:
      begin
        var Index := (Address shr 8) and 3;
        if (Address shr 24) = $F2 then
        begin
          S.ITLB[Index].VPN := Value and $FFFFFC00;
          S.ITLB[Index].ASID := Value and $FF;
          S.ITLB[Index].Flags := (S.ITLB[Index].Flags and not Cardinal($100)) or ((Value and $100));
        end
        else
        begin
          S.ITLB[Index].PPN := Value and $1FFFFC00;
          S.ITLB[Index].Flags := Value and $1FF;
        end;
      end;
    $F6, $F7:
      begin
        var Index := (Address shr 8) and 63;
        if (Address shr 24) = $F6 then
        begin
          // Non-associative write (A bit 7 = 0); associative writes update V/D of the matching entry.
          if (Address and $80) = 0 then
          begin
            S.UTLB[Index].VPN := Value and $FFFFFC00;
            S.UTLB[Index].ASID := Value and $FF;
            S.UTLB[Index].Flags := (S.UTLB[Index].Flags and not Cardinal($104)) or
              (Value and $100) or ((Value shr 7) and 4);
          end
          else
            for var I := 0 to 63 do
              if (S.UTLB[I].VPN and $FFFFFC00) = (Value and $FFFFFC00) then
                S.UTLB[I].Flags := (S.UTLB[I].Flags and not Cardinal($104)) or
                  (Value and $100) or ((Value shr 7) and 4);
        end
        else if (Address and $00800000) = 0 then
        begin
          S.UTLB[Index].PPN := Value and $1FFFFC00;
          S.UTLB[Index].Flags := Value and $1FF;
        end
        else
          S.UTLB[Index].PTEA := Value and $F;
        InvalidateBlocks;
      end;
    $FF, $1F:
      case Address and $00FFFFFF of
        $000000: S.PTEH := Value and $FFFFFCFF;
        $000004: S.PTEL := Value and $1FFFFDFF;
        $000008: S.TTB := Value;
        $00000C: S.TEA := Value;
        $000010:
          begin
            var Old := S.MMUCR;
            S.MMUCR := Value and $FCFCFF05;
            if (Value and 4) <> 0 then
            begin
              // TI: invalidate all TLB entries.
              for var I := 0 to 63 do
                S.UTLB[I].Flags := S.UTLB[I].Flags and not Cardinal($100);
              for var I := 0 to 3 do
                S.ITLB[I].Flags := S.ITLB[I].Flags and not Cardinal($100);
            end;
            if ((Old xor S.MMUCR) and 1) <> 0 then
            begin
              BuildMaps;
              InvalidateBlocks;
            end;
          end;
        $000014: S.BASRA := Value and $FF;
        $000018: S.BASRB := Value and $FF;
        $00001C:
          begin
            S.CCR := Value and $000089AF;
            S.CCR := S.CCR and not Cardinal($0808); // ICI/OCI read as 0
          end;
        $000020: S.TRA := Value and $3FC;
        $000024: S.EXPEVT := Value and $FFF;
        $000028: S.INTEVT := Value and $FFF;
        $000034: S.PTEA := Value and $F;
        $000038: S.QACR0 := Value and $1C;
        $00003C: S.QACR1 := Value and $1C;
      else
        if Assigned(FBus.OnChipWrite) then
          FBus.OnChipWrite(FBus.OnChipUser, (Address and $00FFFFFF) or $FF000000, Value, Size);
      end;
  end;
end;

{ Registers }

procedure TSH4.SwapBanks;
begin
  for var I := 0 to 7 do
  begin
    var T := S.R[I];
    S.R[I] := S.RBank[I];
    S.RBank[I] := T;
  end;
end;

procedure TSH4.SwapFPBanks;
begin
  var T := S.FR;
  S.FR := S.XF;
  S.XF := T;
end;

function TSH4.GetSRValue: Cardinal;
begin
  Result := S.SR or S.T;
end;

function TSH4.SRValue: Cardinal;
begin
  Result := GetSRValue;
end;

procedure TSH4.SetSRValue(Value: Cardinal);
begin
  Value := Value and SH4SRWriteMask;
  // RB reads as 0 outside privileged mode (SingleStepTests).
  if (Value and SRMD) = 0 then
    Value := Value and not Cardinal(SRRB);
  // R0..R7 hold bank 1 only while both MD and RB are set.
  var OldBank := (S.SR and (SRMD or SRRB)) = (SRMD or SRRB);
  var NewBank := (Value and (SRMD or SRRB)) = (SRMD or SRRB);
  if OldBank <> NewBank then
    SwapBanks;
  S.T := Value and SRT;
  S.SR := Value and not Cardinal(SRT);
end;

procedure TSH4.SetSR(Value: Cardinal);
begin
  SetSRValue(Value);
end;

procedure TSH4.SetFPSCRValue(Value: Cardinal);
begin
  Value := Value and SH4FPSCRMask;
  if ((S.FPSCR xor Value) and FPSCRFR) <> 0 then
    SwapFPBanks;
  var RoundChanged := ((S.FPSCR xor Value) and 3) <> 0;
  S.FPSCR := Value;
  if RoundChanged then
    ApplyHostRounding;
end;

procedure TSH4.SetFPSCR(Value: Cardinal);
begin
  SetFPSCRValue(Value);
end;

procedure TSH4.ApplyHostRounding;
begin
  if (S.FPSCR and 3) = 1 then
    SetRoundMode(rmTruncate)
  else
    SetRoundMode(rmNearest);
end;

function TSH4.Mode: Cardinal;
begin
  Result := 0;
  if (S.SR and SRMD) <> 0 then
    Result := ModeMD;
  if (S.SR and SRFD) <> 0 then
    Result := Result or ModeFD;
  if (S.FPSCR and FPSCRPR) <> 0 then
    Result := Result or ModePR;
  if (S.FPSCR and FPSCRSZ) <> 0 then
    Result := Result or ModeSZ;
end;

procedure TSH4.EnterException(Code, Offset, ReturnPC: Cardinal);
begin
  if Offset <> $600 then
  begin
    if ExceptionCount = 0 then
    begin
      FirstExceptionPC := ReturnPC;
      FirstExceptionCode := Code;
      FirstExceptionPR := S.PR;
    end;
    Inc(ExceptionCount);
  end;
  S.SPC := ReturnPC;
  S.SSR := GetSRValue;
  S.SGR := S.R[15];
  SetSRValue(GetSRValue or SRMD or SRRB or SRBL);
  S.PC := S.VBR + Offset;
  S.DelaySlot := False;
  S.RTEPending := False;
  S.Sleeping := False;
end;

procedure TSH4.Fault(Code: Cardinal; const I: TSH4Inst; Slot: Boolean);
begin
  // The faulting instruction (or the branch owning a delay slot) restarts.
  var At := I.Addr;
  if Slot then
    At := At - 2;
  S.EXPEVT := Code;
  var Offset: Cardinal := $100;
  if (Code = SH4ExcTLBMissRead) or (Code = SH4ExcTLBMissWrite) then
    Offset := $400;
  EnterException(Code, Offset, At);
end;

{ Decoder }

function SignExtend8(V: Cardinal): Cardinal; inline;
begin
  Result := Cardinal(Integer(ShortInt(Byte(V))));
end;

function SignExtend12(V: Cardinal): Cardinal; inline;
begin
  V := V and $FFF;
  if (V and $800) <> 0 then
    Result := V or $FFFFF000
  else
    Result := V;
end;

function SignExtend16(V: Cardinal): Cardinal; inline;
begin
  Result := Cardinal(Integer(SmallInt(Word(V))));
end;

function TSH4.Decode(Op: Word; Address, AMode: Cardinal; Slot: Boolean; out I: TSH4Inst): Boolean;
var
  K: TOp;
  N, M: Integer;
  Imm: Cardinal;
  Privileged, FPU, Branch, Delayed, Ends: Boolean;
  PR, SZ: Boolean;
begin
  N := (Op shr 8) and 15;
  M := (Op shr 4) and 15;
  Imm := 0;
  K := oIllegal;
  Privileged := False;
  FPU := False;
  Branch := False;
  Delayed := False;
  Ends := False;
  PR := (AMode and ModePR) <> 0;
  SZ := (AMode and ModeSZ) <> 0;
  case Op shr 12 of
    0:
      case Op and $F of
        2:
          if (M and 8) <> 0 then
          begin
            K := oSTCBANK;
            M := M and 7;
            Privileged := True;
          end
          else
            case M of
              0: begin K := oSTCSR; Privileged := True; end;
              1: K := oSTCGBR;
              2: begin K := oSTCVBR; Privileged := True; end;
              3: begin K := oSTCSSR; Privileged := True; end;
              4: begin K := oSTCSPC; Privileged := True; end;
            end;
        3:
          case M of
            0: begin K := oBSRF; Branch := True; Delayed := True; end;
            2: begin K := oBRAF; Branch := True; Delayed := True; end;
            8: K := oPREF;
            9, 10, 11: K := oOCB;
            12: K := oMOVCAL;
          end;
        4: K := oMOVBS0;
        5: K := oMOVWS0;
        6: K := oMOVLS0;
        7: K := oMULL;
        8:
          case Op of
            $0008: K := oCLRT;
            $0018: K := oSETT;
            $0028: K := oCLRMAC;
            $0038: begin K := oLDTLB; Privileged := True; Ends := True; end;
            $0048: K := oCLRS;
            $0058: K := oSETS;
          end;
        9:
          if Op = $0009 then
            K := oNOP
          else if Op = $0019 then
            K := oDIV0U
          else if M = 2 then
            K := oMOVT;
        10:
          case M of
            0: K := oSTSMACH;
            1: K := oSTSMACL;
            2: K := oSTSPR;
            3: begin K := oSTCSGR; Privileged := True; end;
            5: begin K := oSTSFPUL; FPU := True; end;
            6: begin K := oSTSFPSCR; FPU := True; end;
            15: begin K := oSTCDBR; Privileged := True; end;
          end;
        11:
          case Op of
            $000B: begin K := oRTS; Branch := True; Delayed := True; end;
            $001B: begin K := oSLEEP; Privileged := True; Ends := True; end;
            $002B: begin K := oRTE; Privileged := True; Branch := True; Delayed := True; end;
          end;
        12: K := oMOVBL0;
        13: K := oMOVWL0;
        14: K := oMOVLL0;
        15: K := oMACL;
      end;
    1:
      begin
        K := oMOVLS4;
        Imm := (Op and 15) * 4;
      end;
    2:
      case Op and 15 of
        0: K := oMOVBS;
        1: K := oMOVWS;
        2: K := oMOVLS;
        4: K := oMOVBM;
        5: K := oMOVWM;
        6: K := oMOVLM;
        7: K := oDIV0S;
        8: K := oTST;
        9: K := oAND;
        10: K := oXOR;
        11: K := oOR;
        12: K := oCMPSTR;
        13: K := oXTRCT;
        14: K := oMULUW;
        15: K := oMULSW;
      end;
    3:
      case Op and 15 of
        0: K := oCMPEQ;
        2: K := oCMPHS;
        3: K := oCMPGE;
        4: K := oDIV1;
        5: K := oDMULU;
        6: K := oCMPHI;
        7: K := oCMPGT;
        8: K := oSUB;
        10: K := oSUBC;
        11: K := oSUBV;
        12: K := oADD;
        13: K := oDMULS;
        14: K := oADDC;
        15: K := oADDV;
      end;
    4:
      case Op and 15 of
        0:
          case M of
            0: K := oSHLL;
            1: K := oDT;
            2: K := oSHAL;
          end;
        1:
          case M of
            0: K := oSHLR;
            1: K := oCMPPZ;
            2: K := oSHAR;
          end;
        2:
          case M of
            0: K := oSTSMMACH;
            1: K := oSTSMMACL;
            2: K := oSTSMPR;
            3: begin K := oSTCMSGR; Privileged := True; end;
            5: begin K := oSTSMFPUL; FPU := True; end;
            6: begin K := oSTSMFPSCR; FPU := True; end;
            15: begin K := oSTCMDBR; Privileged := True; end;
          end;
        3:
          if (M and 8) <> 0 then
          begin
            K := oSTCMBANK;
            M := M and 7;
            Privileged := True;
          end
          else
            case M of
              0: begin K := oSTCMSR; Privileged := True; end;
              1: K := oSTCMGBR;
              2: begin K := oSTCMVBR; Privileged := True; end;
              3: begin K := oSTCMSSR; Privileged := True; end;
              4: begin K := oSTCMSPC; Privileged := True; end;
            end;
        4:
          case M of
            0: K := oROTL;
            2: K := oROTCL;
          end;
        5:
          case M of
            0: K := oROTR;
            1: K := oCMPPL;
            2: K := oROTCR;
          end;
        6:
          case M of
            0: K := oLDSMMACH;
            1: K := oLDSMMACL;
            2: K := oLDSMPR;
            5: begin K := oLDSMFPUL; FPU := True; end;
            6: begin K := oLDSMFPSCR; FPU := True; Ends := True; end;
            15: begin K := oLDCMDBR; Privileged := True; end;
          end;
        7:
          if (M and 8) <> 0 then
          begin
            K := oLDCMBANK;
            M := M and 7;
            Privileged := True;
          end
          else
            case M of
              0: begin K := oLDCMSR; Privileged := True; Ends := True; end;
              1: K := oLDCMGBR;
              2: begin K := oLDCMVBR; Privileged := True; end;
              3: begin K := oLDCMSSR; Privileged := True; end;
              4: begin K := oLDCMSPC; Privileged := True; end;
            end;
        8:
          case M of
            0: K := oSHLL2;
            1: K := oSHLL8;
            2: K := oSHLL16;
          end;
        9:
          case M of
            0: K := oSHLR2;
            1: K := oSHLR8;
            2: K := oSHLR16;
          end;
        10:
          case M of
            0: K := oLDSMACH;
            1: K := oLDSMACL;
            2: K := oLDSPR;
            5: begin K := oLDSFPUL; FPU := True; end;
            6: begin K := oLDSFPSCR; FPU := True; Ends := True; end;
            15: begin K := oLDCDBR; Privileged := True; end;
          end;
        11:
          case M of
            0: begin K := oJSR; Branch := True; Delayed := True; end;
            1: K := oTASB;
            2: begin K := oJMP; Branch := True; Delayed := True; end;
          end;
        12: K := oSHAD;
        13: K := oSHLD;
        14:
          if (M and 8) <> 0 then
          begin
            K := oLDCBANK;
            M := M and 7;
            Privileged := True;
          end
          else
            case M of
              0: begin K := oLDCSR; Privileged := True; Ends := True; end;
              1: K := oLDCGBR;
              2: begin K := oLDCVBR; Privileged := True; end;
              3: begin K := oLDCSSR; Privileged := True; end;
              4: begin K := oLDCSPC; Privileged := True; end;
            end;
        15: K := oMACW;
      end;
    5:
      begin
        K := oMOVLL4;
        Imm := (Op and 15) * 4;
      end;
    6:
      case Op and 15 of
        0: K := oMOVBL;
        1: K := oMOVWL;
        2: K := oMOVLL;
        3: K := oMOV;
        4: K := oMOVBP;
        5: K := oMOVWP;
        6: K := oMOVLP;
        7: K := oNOT;
        8: K := oSWAPB;
        9: K := oSWAPW;
        10: K := oNEGC;
        11: K := oNEG;
        12: K := oEXTUB;
        13: K := oEXTUW;
        14: K := oEXTSB;
        15: K := oEXTSW;
      end;
    7:
      begin
        K := oADDI;
        Imm := SignExtend8(Op);
      end;
    8:
      case N of
        0: begin K := oMOVBS4; Imm := Op and 15; end;
        1: begin K := oMOVWS4; Imm := (Op and 15) * 2; end;
        4: begin K := oMOVBL4; Imm := Op and 15; end;
        5: begin K := oMOVWL4; Imm := (Op and 15) * 2; end;
        8: begin K := oCMPEQI; Imm := SignExtend8(Op); end;
        9, 11, 13, 15:
          begin
            case N of
              9: K := oBT;
              11: K := oBF;
              13: K := oBTS;
            else
              K := oBFS;
            end;
            Branch := True;
            Delayed := N >= 13;
            Ends := not Delayed;
            Imm := Address + 4 + SignExtend8(Op) * 2;
          end;
      end;
    9:
      begin
        K := oMOVWPC;
        Imm := Address + 4 + (Op and $FF) * 2;
      end;
    10, 11:
      begin
        if (Op shr 12) = 10 then
          K := oBRA
        else
          K := oBSR;
        Branch := True;
        Delayed := True;
        Imm := Address + 4 + SignExtend12(Op) * 2;
      end;
    12:
      case N of
        0: begin K := oMOVBSG; Imm := Op and $FF; end;
        1: begin K := oMOVWSG; Imm := (Op and $FF) * 2; end;
        2: begin K := oMOVLSG; Imm := (Op and $FF) * 4; end;
        3: begin K := oTRAPA; Imm := Op and $FF; Branch := True; Ends := True; end;
        4: begin K := oMOVBLG; Imm := Op and $FF; end;
        5: begin K := oMOVWLG; Imm := (Op and $FF) * 2; end;
        6: begin K := oMOVLLG; Imm := (Op and $FF) * 4; end;
        7: begin K := oMOVA; Imm := (Address and $FFFFFFFC) + 4 + (Op and $FF) * 4; end;
        8: begin K := oTSTI; Imm := Op and $FF; end;
        9: begin K := oANDI; Imm := Op and $FF; end;
        10: begin K := oXORI; Imm := Op and $FF; end;
        11: begin K := oORI; Imm := Op and $FF; end;
        12: begin K := oTSTB; Imm := Op and $FF; end;
        13: begin K := oANDB; Imm := Op and $FF; end;
        14: begin K := oXORB; Imm := Op and $FF; end;
        15: begin K := oORB; Imm := Op and $FF; end;
      end;
    13:
      begin
        K := oMOVLPC;
        Imm := (Address and $FFFFFFFC) + 4 + (Op and $FF) * 4;
      end;
    14:
      begin
        K := oMOVI;
        Imm := SignExtend8(Op);
      end;
    15:
      begin
        FPU := True;
        case Op and 15 of
          0..5:
            begin
              if PR then
              begin
                case Op and 15 of
                  0: K := oDADD;
                  1: K := oDSUB;
                  2: K := oDMUL;
                  3: K := oDDIV;
                  4: K := oDCMPEQ;
                else
                  K := oDCMPGT;
                end;
                N := N and 14;
                M := M and 14;
              end
              else
              begin
                case Op and 15 of
                  0: K := oFADD;
                  1: K := oFSUB;
                  2: K := oFMUL;
                  3: K := oFDIV;
                  4: K := oFCMPEQ;
                else
                  K := oFCMPGT;
                end;
                N := N xor 1;
                M := M xor 1;
              end;
            end;
          6:
            if SZ then
              K := oFMOVDLD0
            else
            begin
              K := oFMOVLD0;
              N := N xor 1;
            end;
          7:
            if SZ then
              K := oFMOVDST0
            else
            begin
              K := oFMOVST0;
              M := M xor 1;
            end;
          8:
            if SZ then
              K := oFMOVDLD
            else
            begin
              K := oFMOVLD;
              N := N xor 1;
            end;
          9:
            if SZ then
              K := oFMOVDLDP
            else
            begin
              K := oFMOVLDP;
              N := N xor 1;
            end;
          10:
            if SZ then
              K := oFMOVDST
            else
            begin
              K := oFMOVST;
              M := M xor 1;
            end;
          11:
            if SZ then
              K := oFMOVDSTM
            else
            begin
              K := oFMOVSTM;
              M := M xor 1;
            end;
          12:
            if SZ then
              K := oFMOVD
            else
            begin
              K := oFMOV;
              N := N xor 1;
              M := M xor 1;
            end;
          13:
            case M of
              0: begin K := oFSTS; N := N xor 1; end;
              1: begin K := oFLDS; N := N xor 1; end;
              2:
                if PR then
                begin
                  K := oDFLOAT;
                  N := N and 14;
                end
                else
                begin
                  K := oFLOAT;
                  N := N xor 1;
                end;
              3:
                if PR then
                begin
                  K := oDFTRC;
                  N := N and 14;
                end
                else
                begin
                  K := oFTRC;
                  N := N xor 1;
                end;
              4:
                if PR then
                begin
                  K := oDNEG;
                  N := N and 14;
                end
                else
                begin
                  K := oFNEG;
                  N := N xor 1;
                end;
              5:
                if PR then
                begin
                  K := oDABS;
                  N := N and 14;
                end
                else
                begin
                  K := oFABS;
                  N := N xor 1;
                end;
              6:
                if PR then
                begin
                  K := oDSQRT;
                  N := N and 14;
                end
                else
                begin
                  K := oFSQRT;
                  N := N xor 1;
                end;
              7: begin K := oFSRRA; N := N xor 1; end;
              8: begin K := oFLDI0; N := N xor 1; end;
              9: begin K := oFLDI1; N := N xor 1; end;
              // Defined only for PR=1; PR=0 leaves state unchanged (SingleStepTests).
              10:
                if PR then
                begin
                  K := oFCNVSD;
                  N := N and 14;
                end
                else
                  K := oNOP;
              11:
                if PR then
                begin
                  K := oFCNVDS;
                  N := N and 14;
                end
                else
                  K := oNOP;
              14:
                begin
                  K := oFIPR;
                  N := ((Op shr 10) and 3) * 4;
                  M := ((Op shr 8) and 3) * 4;
                end;
              15:
                if (Op and $0300) = $0100 then
                begin
                  K := oFTRV;
                  N := ((Op shr 10) and 3) * 4;
                end
                else if (Op and $0100) = 0 then
                begin
                  K := oFSCA;
                  N := N and 14;
                end
                else if Op = $F3FD then
                begin
                  K := oFSCHG;
                  Ends := True;
                end
                else if Op = $FBFD then
                begin
                  K := oFRCHG;
                  Ends := True;
                end;
            end;
          14:
            begin
              K := oFMAC;
              N := N xor 1;
              M := M xor 1;
            end;
        end;
      end;
  end;

  if (K <> oIllegal) and Privileged and ((AMode and ModeMD) = 0) and not FLenient then
    K := oIllegal;
  if (K <> oIllegal) and FPU and ((AMode and ModeFD) <> 0) and not FLenient then
  begin
    if Slot then
      K := oSlotFPUDisabled
    else
      K := oFPUDisabled;
  end;
  if Slot and ((K = oIllegal) or Branch) then
    K := oSlotIllegal;
  if K in [oIllegal, oSlotIllegal, oFPUDisabled, oSlotFPUDisabled] then
  begin
    Delayed := False;
    Ends := True;
  end;
  I.Kind := Ord(K);
  I.N := N;
  I.M := M;
  I.Imm := Imm;
  I.Addr := Address;
  I.Flags := 0;
  if Ends then
    I.Flags := I.Flags or IFEnd;
  if Delayed then
    I.Flags := I.Flags or IFDelayed;
  if Slot then
    I.Flags := I.Flags or IFSlot;
  Result := Delayed;
end;

{ FPU helpers }

function IsNaNBits(V: Cardinal): Boolean; inline;
begin
  Result := ((V and $7F800000) = $7F800000) and ((V and $007FFFFF) <> 0);
end;

function IsNaN64(V: UInt64): Boolean; inline;
begin
  Result := ((V and $7FF0000000000000) = $7FF0000000000000) and ((V and $000FFFFFFFFFFFFF) <> 0);
end;

function FlushBits(V: Cardinal): Cardinal; inline;
begin
  if (V and $7F800000) = 0 then
    Result := V and $80000000
  else
    Result := V;
end;

function FlushSingle(V: Single): Single; inline;
begin
  if (PCardinal(@V)^ and $7F800000) = 0 then
    PCardinal(@Result)^ := PCardinal(@V)^ and $80000000
  else
    Result := V;
end;

function SingleBits(V: Single): Cardinal; inline;
begin
  Result := PCardinal(@V)^;
end;

function BitsSingle(V: Cardinal): Single; inline;
begin
  Result := PSingle(@V)^;
end;

// Separate calls round every intermediate to single precision on x87 too.
function SingleProduct(A, B: Single): Single;
begin
  Result := A * B;
end;

// A*B is exact in double precision; the sum rounds once to double, then to single.
function FusedSingle(A, B, C: Single): Single;
begin
  Result := Double(A) * Double(B) + Double(C);
end;

function FlushDouble(V: Double): Double; inline;
begin
  if (PUInt64(@V)^ and $7FF0000000000000) = 0 then
    PUInt64(@Result)^ := PUInt64(@V)^ and $8000000000000000
  else
    Result := V;
end;

function RoundToSingle(V: Double): Single; inline;
begin
  Result := V;
end;

function SingleToInt(V: Single): Cardinal;
begin
  // FTRC: truncation; out of range and NaN saturate.
  var Bits := SingleBits(V);
  if IsNaNBits(Bits) then
    Exit($80000000);
  if V >= 2147483648.0 then
    Exit($7FFFFFFF);
  if V <= -2147483648.0 then
    Exit($80000000);
  Result := Cardinal(Integer(Trunc(V)));
end;

function DoubleToInt(V: Double): Cardinal;
begin
  var Bits := PUInt64(@V)^;
  if IsNaN64(Bits) then
    Exit($80000000);
  if V >= 2147483648.0 then
    Exit($7FFFFFFF);
  if V <= -2147483648.0 then
    Exit($80000000);
  Result := Cardinal(Integer(Trunc(V)));
end;

function Sar32(V: Cardinal; Count: Integer): Cardinal; inline;
begin
  if (V and $80000000) <> 0 then
    Result := not ((not V) shr Count)
  else
    Result := V shr Count;
end;

function SwapHalves(V: UInt64): UInt64; inline;
begin
  Result := (V shr 32) or (V shl 32);
end;

{ Executor }

function TSH4.Execute(Insts: PSH4Inst; Count: Integer; out Next: Cardinal): Integer;
var
  I: PSH4Inst;
  N, M: Integer;
  A, B, V: Cardinal;
  V64: UInt64;
  P64: Int64;
  Jumped, Excepted: Boolean;
  JumpTarget: Cardinal;
  F: Single;
  DV: Double;
  DN: Boolean;
begin
  Result := 0;
  Jumped := False;
  Excepted := False;
  JumpTarget := 0;
  DN := (S.FPSCR and FPSCRDN) <> 0;
  I := Insts;
  while Result < Count do
  begin
    N := I.N;
    M := I.M;
    case TOp(I.Kind) of
      oNOP, oOCB:
        ;
      oMOV:
        S.R[N] := S.R[M];
      oMOVI:
        S.R[N] := I.Imm;
      oMOVWPC:
        begin
          V := Read16(I.Imm);
          if FFault then Break;
          S.R[N] := SignExtend16(V);
        end;
      oMOVLPC:
        begin
          V := Read32(I.Imm);
          if FFault then Break;
          S.R[N] := V;
        end;
      oMOVA:
        S.R[0] := I.Imm;
      oMOVBS:
        Write8(S.R[N], S.R[M]);
      oMOVWS:
        Write16(S.R[N], S.R[M]);
      oMOVLS:
        Write32(S.R[N], S.R[M]);
      oMOVBL:
        begin
          V := Read8(S.R[M]);
          if FFault then Break;
          S.R[N] := SignExtend8(V);
        end;
      oMOVWL:
        begin
          V := Read16(S.R[M]);
          if FFault then Break;
          S.R[N] := SignExtend16(V);
        end;
      oMOVLL:
        begin
          V := Read32(S.R[M]);
          if FFault then Break;
          S.R[N] := V;
        end;
      oMOVBM:
        begin
          A := S.R[N] - 1;
          Write8(A, S.R[M]);
          if FFault then Break;
          S.R[N] := A;
        end;
      oMOVWM:
        begin
          A := S.R[N] - 2;
          Write16(A, S.R[M]);
          if FFault then Break;
          S.R[N] := A;
        end;
      oMOVLM:
        begin
          A := S.R[N] - 4;
          Write32(A, S.R[M]);
          if FFault then Break;
          S.R[N] := A;
        end;
      oMOVBP:
        begin
          V := Read8(S.R[M]);
          if FFault then Break;
          if N <> M then
            S.R[M] := S.R[M] + 1;
          S.R[N] := SignExtend8(V);
        end;
      oMOVWP:
        begin
          V := Read16(S.R[M]);
          if FFault then Break;
          if N <> M then
            S.R[M] := S.R[M] + 2;
          S.R[N] := SignExtend16(V);
        end;
      oMOVLP:
        begin
          V := Read32(S.R[M]);
          if FFault then Break;
          if N <> M then
            S.R[M] := S.R[M] + 4;
          S.R[N] := V;
        end;
      oMOVBS0:
        Write8(S.R[N] + S.R[0], S.R[M]);
      oMOVWS0:
        Write16(S.R[N] + S.R[0], S.R[M]);
      oMOVLS0:
        Write32(S.R[N] + S.R[0], S.R[M]);
      oMOVBL0:
        begin
          V := Read8(S.R[M] + S.R[0]);
          if FFault then Break;
          S.R[N] := SignExtend8(V);
        end;
      oMOVWL0:
        begin
          V := Read16(S.R[M] + S.R[0]);
          if FFault then Break;
          S.R[N] := SignExtend16(V);
        end;
      oMOVLL0:
        begin
          V := Read32(S.R[M] + S.R[0]);
          if FFault then Break;
          S.R[N] := V;
        end;
      oMOVBS4:
        Write8(S.R[M] + I.Imm, S.R[0]);
      oMOVWS4:
        Write16(S.R[M] + I.Imm, S.R[0]);
      oMOVLS4:
        Write32(S.R[N] + I.Imm, S.R[M]);
      oMOVBL4:
        begin
          V := Read8(S.R[M] + I.Imm);
          if FFault then Break;
          S.R[0] := SignExtend8(V);
        end;
      oMOVWL4:
        begin
          V := Read16(S.R[M] + I.Imm);
          if FFault then Break;
          S.R[0] := SignExtend16(V);
        end;
      oMOVLL4:
        begin
          V := Read32(S.R[M] + I.Imm);
          if FFault then Break;
          S.R[N] := V;
        end;
      oMOVBSG:
        Write8(S.GBR + I.Imm, S.R[0]);
      oMOVWSG:
        Write16(S.GBR + I.Imm, S.R[0]);
      oMOVLSG:
        Write32(S.GBR + I.Imm, S.R[0]);
      oMOVBLG:
        begin
          V := Read8(S.GBR + I.Imm);
          if FFault then Break;
          S.R[0] := SignExtend8(V);
        end;
      oMOVWLG:
        begin
          V := Read16(S.GBR + I.Imm);
          if FFault then Break;
          S.R[0] := SignExtend16(V);
        end;
      oMOVLLG:
        begin
          V := Read32(S.GBR + I.Imm);
          if FFault then Break;
          S.R[0] := V;
        end;
      oMOVT:
        S.R[N] := S.T;
      oSWAPB:
        begin
          V := S.R[M];
          S.R[N] := (V and $FFFF0000) or ((V and $FF) shl 8) or ((V shr 8) and $FF);
        end;
      oSWAPW:
        begin
          V := S.R[M];
          S.R[N] := (V shl 16) or (V shr 16);
        end;
      oXTRCT:
        S.R[N] := (S.R[N] shr 16) or (S.R[M] shl 16);
      oADD:
        S.R[N] := S.R[N] + S.R[M];
      oADDI:
        S.R[N] := S.R[N] + I.Imm;
      oADDC:
        begin
          A := S.R[N];
          B := A + S.R[M];
          V := B + S.T;
          S.T := Cardinal(Ord((A > B) or (B > V)));
          S.R[N] := V;
        end;
      oADDV:
        begin
          A := S.R[N];
          B := S.R[M];
          V := A + B;
          S.T := ((not (A xor B)) and (A xor V)) shr 31;
          S.R[N] := V;
        end;
      oCMPEQ:
        S.T := Cardinal(Ord(S.R[N] = S.R[M]));
      oCMPEQI:
        S.T := Cardinal(Ord(S.R[0] = I.Imm));
      oCMPHS:
        S.T := Cardinal(Ord(S.R[N] >= S.R[M]));
      oCMPGE:
        S.T := Cardinal(Ord(Integer(S.R[N]) >= Integer(S.R[M])));
      oCMPHI:
        S.T := Cardinal(Ord(S.R[N] > S.R[M]));
      oCMPGT:
        S.T := Cardinal(Ord(Integer(S.R[N]) > Integer(S.R[M])));
      oCMPPZ:
        S.T := Cardinal(Ord(Integer(S.R[N]) >= 0));
      oCMPPL:
        S.T := Cardinal(Ord(Integer(S.R[N]) > 0));
      oCMPSTR:
        begin
          V := S.R[N] xor S.R[M];
          S.T := Cardinal(Ord(((V and $FF) = 0) or ((V and $FF00) = 0) or
            ((V and $FF0000) = 0) or ((V and $FF000000) = 0)));
        end;
      oDIV0S:
        begin
          var Q := S.R[N] shr 31;
          var MM := S.R[M] shr 31;
          S.SR := (S.SR and not Cardinal(SRQ or SRM)) or (Q shl 8) or (MM shl 9);
          S.T := Q xor MM;
        end;
      oDIV0U:
        begin
          S.SR := S.SR and not Cardinal(SRQ or SRM);
          S.T := 0;
        end;
      oDIV1:
        begin
          var OldQ := (S.SR shr 8) and 1;
          var MM := (S.SR shr 9) and 1;
          var Q := S.R[N] shr 31;
          A := (S.R[N] shl 1) or S.T;
          // DIV1 Rn,Rn divides by the shifted value (SingleStepTests).
          var Divisor := S.R[M];
          if N = M then
            Divisor := A;
          var Tmp0 := A;
          var Tmp1: Cardinal;
          if OldQ = MM then
          begin
            A := A - Divisor;
            Tmp1 := Cardinal(Ord(A > Tmp0));
          end
          else
          begin
            A := A + Divisor;
            Tmp1 := Cardinal(Ord(A < Tmp0));
          end;
          // The manual's case table for old Q / M reduces to Q xor carry xor M.
          Q := Q xor Tmp1 xor MM;
          S.R[N] := A;
          S.SR := (S.SR and not Cardinal(SRQ)) or (Q shl 8);
          S.T := Cardinal(Ord(Q = MM));
        end;
      oDMULS:
        begin
          P64 := Int64(Integer(S.R[N])) * Int64(Integer(S.R[M]));
          S.MACH := Cardinal(UInt64(P64) shr 32);
          S.MACL := Cardinal(P64);
        end;
      oDMULU:
        begin
          V64 := UInt64(S.R[N]) * UInt64(S.R[M]);
          S.MACH := Cardinal(V64 shr 32);
          S.MACL := Cardinal(V64);
        end;
      oDT:
        begin
          V := S.R[N] - 1;
          S.R[N] := V;
          S.T := Cardinal(Ord(V = 0));
        end;
      oEXTSB:
        S.R[N] := SignExtend8(S.R[M]);
      oEXTSW:
        S.R[N] := SignExtend16(S.R[M]);
      oEXTUB:
        S.R[N] := S.R[M] and $FF;
      oEXTUW:
        S.R[N] := S.R[M] and $FFFF;
      oMACL:
        begin
          A := Read32(S.R[N]);
          if FFault then Break;
          B := Read32(S.R[M] + Cardinal(Ord(N = M)) * 4);
          if FFault then Break;
          S.R[N] := S.R[N] + 4;
          S.R[M] := S.R[M] + 4;
          P64 := Int64(Integer(A)) * Int64(Integer(B));
          P64 := Int64((UInt64(S.MACH) shl 32) or S.MACL) + P64;
          if (S.SR and SRS) <> 0 then
          begin
            if P64 > Int64($00007FFFFFFFFFFF) then
              P64 := $00007FFFFFFFFFFF
            else if P64 < -Int64($0000800000000000) then
              P64 := -Int64($0000800000000000);
          end;
          S.MACH := Cardinal(UInt64(P64) shr 32);
          S.MACL := Cardinal(P64);
        end;
      oMACW:
        begin
          A := Read16(S.R[N]);
          if FFault then Break;
          B := Read16(S.R[M] + Cardinal(Ord(N = M)) * 2);
          if FFault then Break;
          S.R[N] := S.R[N] + 2;
          S.R[M] := S.R[M] + 2;
          var Product := Integer(SmallInt(Word(A))) * Integer(SmallInt(Word(B)));
          if (S.SR and SRS) <> 0 then
          begin
            P64 := Int64(Integer(S.MACL)) + Product;
            if P64 > MaxInt then
              S.MACL := $7FFFFFFF
            else if P64 < -Int64(2147483648) then
              S.MACL := $80000000
            else
              S.MACL := Cardinal(Integer(P64));
          end
          else
          begin
            P64 := Int64((UInt64(S.MACH) shl 32) or S.MACL) + Product;
            S.MACH := Cardinal(UInt64(P64) shr 32);
            S.MACL := Cardinal(P64);
          end;
        end;
      oMULL:
        S.MACL := S.R[N] * S.R[M];
      oMULSW:
        S.MACL := Cardinal(Integer(SmallInt(Word(S.R[N]))) * Integer(SmallInt(Word(S.R[M]))));
      oMULUW:
        S.MACL := (S.R[N] and $FFFF) * (S.R[M] and $FFFF);
      oNEG:
        S.R[N] := 0 - S.R[M];
      oNEGC:
        begin
          A := 0 - S.R[M];
          V := A - S.T;
          S.T := Cardinal(Ord((A <> 0) or (A < V)));
          S.R[N] := V;
        end;
      oSUB:
        S.R[N] := S.R[N] - S.R[M];
      oSUBC:
        begin
          A := S.R[N];
          B := A - S.R[M];
          V := B - S.T;
          S.T := Cardinal(Ord((A < B) or (B < V)));
          S.R[N] := V;
        end;
      oSUBV:
        begin
          A := S.R[N];
          B := S.R[M];
          V := A - B;
          S.T := ((A xor B) and (A xor V)) shr 31;
          S.R[N] := V;
        end;
      oAND:
        S.R[N] := S.R[N] and S.R[M];
      oANDI:
        S.R[0] := S.R[0] and I.Imm;
      oANDB, oORB, oXORB, oTSTB:
        begin
          A := S.GBR + S.R[0];
          V := Read8(A);
          if FFault then Break;
          case TOp(I.Kind) of
            oANDB: Write8(A, V and I.Imm);
            oORB: Write8(A, V or I.Imm);
            oXORB: Write8(A, V xor I.Imm);
          else
            S.T := Cardinal(Ord((V and I.Imm) = 0));
          end;
        end;
      oNOT:
        S.R[N] := not S.R[M];
      oOR:
        S.R[N] := S.R[N] or S.R[M];
      oORI:
        S.R[0] := S.R[0] or I.Imm;
      oTASB:
        begin
          A := S.R[N];
          V := Read8(A);
          if FFault then Break;
          Write8(A, V or $80);
          if FFault then Break;
          S.T := Cardinal(Ord(V = 0));
        end;
      oTST:
        S.T := Cardinal(Ord((S.R[N] and S.R[M]) = 0));
      oTSTI:
        S.T := Cardinal(Ord((S.R[0] and I.Imm) = 0));
      oXOR:
        S.R[N] := S.R[N] xor S.R[M];
      oXORI:
        S.R[0] := S.R[0] xor I.Imm;
      oROTL:
        begin
          V := S.R[N];
          S.T := V shr 31;
          S.R[N] := (V shl 1) or S.T;
        end;
      oROTR:
        begin
          V := S.R[N];
          S.T := V and 1;
          S.R[N] := (V shr 1) or (S.T shl 31);
        end;
      oROTCL:
        begin
          V := S.R[N];
          S.R[N] := (V shl 1) or S.T;
          S.T := V shr 31;
        end;
      oROTCR:
        begin
          V := S.R[N];
          S.R[N] := (V shr 1) or (S.T shl 31);
          S.T := V and 1;
        end;
      oSHAD:
        begin
          B := S.R[M];
          V := S.R[N];
          if Integer(B) >= 0 then
            S.R[N] := V shl (B and 31)
          else if (B and 31) = 0 then
            S.R[N] := Sar32(V, 31)
          else
            S.R[N] := Sar32(V, ((not B) and 31) + 1);
        end;
      oSHLD:
        begin
          B := S.R[M];
          V := S.R[N];
          if Integer(B) >= 0 then
            S.R[N] := V shl (B and 31)
          else if (B and 31) = 0 then
            S.R[N] := 0
          else
            S.R[N] := V shr (((not B) and 31) + 1);
        end;
      oSHAL, oSHLL:
        begin
          V := S.R[N];
          S.T := V shr 31;
          S.R[N] := V shl 1;
        end;
      oSHAR:
        begin
          V := S.R[N];
          S.T := V and 1;
          S.R[N] := Sar32(V, 1);
        end;
      oSHLL2:
        S.R[N] := S.R[N] shl 2;
      oSHLL8:
        S.R[N] := S.R[N] shl 8;
      oSHLL16:
        S.R[N] := S.R[N] shl 16;
      oSHLR:
        begin
          V := S.R[N];
          S.T := V and 1;
          S.R[N] := V shr 1;
        end;
      oSHLR2:
        S.R[N] := S.R[N] shr 2;
      oSHLR8:
        S.R[N] := S.R[N] shr 8;
      oSHLR16:
        S.R[N] := S.R[N] shr 16;
      oBF:
        if S.T = 0 then
        begin
          Jumped := True;
          JumpTarget := I.Imm;
        end;
      oBT:
        if S.T <> 0 then
        begin
          Jumped := True;
          JumpTarget := I.Imm;
        end;
      oBFS:
        begin
          S.DelaySlot := True;
          if S.T = 0 then
            S.DelayTarget := I.Imm
          else
            S.DelayTarget := I.Addr + 4;
        end;
      oBTS:
        begin
          S.DelaySlot := True;
          if S.T <> 0 then
            S.DelayTarget := I.Imm
          else
            S.DelayTarget := I.Addr + 4;
        end;
      oBRA:
        begin
          S.DelaySlot := True;
          S.DelayTarget := I.Imm;
        end;
      oBSR:
        begin
          S.PR := I.Addr + 4;
          S.DelaySlot := True;
          S.DelayTarget := I.Imm;
        end;
      oBRAF:
        begin
          S.DelaySlot := True;
          S.DelayTarget := I.Addr + 4 + S.R[N];
        end;
      oBSRF:
        begin
          S.DelaySlot := True;
          S.DelayTarget := I.Addr + 4 + S.R[N];
          S.PR := I.Addr + 4;
        end;
      oJMP:
        begin
          S.DelaySlot := True;
          S.DelayTarget := S.R[N];
        end;
      oJSR:
        begin
          S.DelaySlot := True;
          S.DelayTarget := S.R[N];
          S.PR := I.Addr + 4;
        end;
      oRTS:
        begin
          S.DelaySlot := True;
          S.DelayTarget := S.PR;
        end;
      oRTE:
        begin
          S.DelaySlot := True;
          S.DelayTarget := S.SPC;
          S.RTEPending := True;
          S.RTESR := S.SSR;
        end;
      oCLRMAC:
        begin
          S.MACH := 0;
          S.MACL := 0;
        end;
      oCLRS:
        S.SR := S.SR and not Cardinal(SRS);
      oCLRT:
        S.T := 0;
      oSETS:
        S.SR := S.SR or SRS;
      oSETT:
        S.T := 1;
      oLDTLB:
        begin
          var Index := (S.MMUCR shr 10) and 63;
          S.UTLB[Index].VPN := S.PTEH and $FFFFFC00;
          S.UTLB[Index].ASID := S.PTEH and $FF;
          S.UTLB[Index].PPN := S.PTEL and $1FFFFC00;
          S.UTLB[Index].Flags := S.PTEL and $1FF;
          S.UTLB[Index].PTEA := S.PTEA and $F;
          if (S.MMUCR and 1) <> 0 then
            InvalidateBlocks;
        end;
      oMOVCAL:
        Write32(S.R[N], S.R[0]);
      oPREF:
        if (S.R[N] and $FC000000) = $E0000000 then
          StoreQueueFlush(S.R[N]);
      oSLEEP:
        begin
          // PC stays on SLEEP; an accepted interrupt returns past it.
          S.Sleeping := True;
          Jumped := True;
          JumpTarget := I.Addr;
        end;
      oTRAPA:
        begin
          S.TRA := I.Imm shl 2;
          S.EXPEVT := SH4ExcTrap;
          EnterException(SH4ExcTrap, $100, I.Addr + 2);
          Inc(Result);
          Next := S.PC;
          Exit;
        end;
      oLDCSR:
        SetSRValue(S.R[N]);
      oLDCGBR:
        S.GBR := S.R[N];
      oLDCVBR:
        S.VBR := S.R[N];
      oLDCSSR:
        S.SSR := S.R[N];
      oLDCSPC:
        S.SPC := S.R[N];
      oLDCDBR:
        S.DBR := S.R[N];
      oLDCBANK:
        S.RBank[M] := S.R[N];
      oLDCMSR, oLDCMGBR, oLDCMVBR, oLDCMSSR, oLDCMSPC, oLDCMDBR, oLDCMBANK,
      oLDSMMACH, oLDSMMACL, oLDSMPR, oLDSMFPUL, oLDSMFPSCR:
        begin
          V := Read32(S.R[N]);
          if FFault then Break;
          S.R[N] := S.R[N] + 4;
          case TOp(I.Kind) of
            oLDCMSR: SetSRValue(V);
            oLDCMGBR: S.GBR := V;
            oLDCMVBR: S.VBR := V;
            oLDCMSSR: S.SSR := V;
            oLDCMSPC: S.SPC := V;
            oLDCMDBR: S.DBR := V;
            oLDCMBANK: S.RBank[M] := V;
            oLDSMMACH: S.MACH := V;
            oLDSMMACL: S.MACL := V;
            oLDSMPR: S.PR := V;
            oLDSMFPUL: S.FPUL := V;
          else
            begin
              SetFPSCRValue(V);
              DN := (S.FPSCR and FPSCRDN) <> 0;
            end;
          end;
        end;
      oLDSMACH:
        S.MACH := S.R[N];
      oLDSMACL:
        S.MACL := S.R[N];
      oLDSPR:
        S.PR := S.R[N];
      oSTCSR:
        S.R[N] := GetSRValue;
      oSTCGBR:
        S.R[N] := S.GBR;
      oSTCVBR:
        S.R[N] := S.VBR;
      oSTCSSR:
        S.R[N] := S.SSR;
      oSTCSPC:
        S.R[N] := S.SPC;
      oSTCSGR:
        S.R[N] := S.SGR;
      oSTCDBR:
        S.R[N] := S.DBR;
      oSTCBANK:
        S.R[N] := S.RBank[M];
      oSTCMSR, oSTCMGBR, oSTCMVBR, oSTCMSSR, oSTCMSPC, oSTCMSGR, oSTCMDBR, oSTCMBANK,
      oSTSMMACH, oSTSMMACL, oSTSMPR, oSTSMFPUL, oSTSMFPSCR:
        begin
          case TOp(I.Kind) of
            oSTCMSR: V := GetSRValue;
            oSTCMGBR: V := S.GBR;
            oSTCMVBR: V := S.VBR;
            oSTCMSSR: V := S.SSR;
            oSTCMSPC: V := S.SPC;
            oSTCMSGR: V := S.SGR;
            oSTCMDBR: V := S.DBR;
            oSTCMBANK: V := S.RBank[M];
            oSTSMMACH: V := S.MACH;
            oSTSMMACL: V := S.MACL;
            oSTSMPR: V := S.PR;
            oSTSMFPUL: V := S.FPUL;
          else
            V := S.FPSCR;
          end;
          A := S.R[N] - 4;
          Write32(A, V);
          if FFault then Break;
          S.R[N] := A;
        end;
      oSTSMACH:
        S.R[N] := S.MACH;
      oSTSMACL:
        S.R[N] := S.MACL;
      oSTSPR:
        S.R[N] := S.PR;
      oLDSFPSCR:
        begin
          SetFPSCRValue(S.R[N]);
          DN := (S.FPSCR and FPSCRDN) <> 0;
        end;
      oLDSFPUL:
        S.FPUL := S.R[N];
      oSTSFPSCR:
        S.R[N] := S.FPSCR;
      oSTSFPUL:
        S.R[N] := S.FPUL;
      // Single-precision moves; register numbers are pre-xored (see TSH4State).
      oFMOV:
        S.FR.U[N] := S.FR.U[M];
      oFMOVLD:
        begin
          V := Read32(S.R[M]);
          if FFault then Break;
          S.FR.U[N] := V;
        end;
      oFMOVLD0:
        begin
          V := Read32(S.R[M] + S.R[0]);
          if FFault then Break;
          S.FR.U[N] := V;
        end;
      oFMOVLDP:
        begin
          V := Read32(S.R[M]);
          if FFault then Break;
          S.R[M] := S.R[M] + 4;
          S.FR.U[N] := V;
        end;
      oFMOVST:
        Write32(S.R[N], S.FR.U[M]);
      oFMOVST0:
        Write32(S.R[N] + S.R[0], S.FR.U[M]);
      oFMOVSTM:
        begin
          A := S.R[N] - 4;
          Write32(A, S.FR.U[M]);
          if FFault then Break;
          S.R[N] := A;
        end;
      // Pair moves (SZ=1): odd register numbers select XD.
      oFMOVD:
        begin
          if (M and 1) = 0 then
            V64 := S.FR.Q[M shr 1]
          else
            V64 := S.XF.Q[M shr 1];
          if (N and 1) = 0 then
            S.FR.Q[N shr 1] := V64
          else
            S.XF.Q[N shr 1] := V64;
        end;
      oFMOVDLD, oFMOVDLD0, oFMOVDLDP:
        begin
          A := S.R[M];
          if TOp(I.Kind) = oFMOVDLD0 then
            A := A + S.R[0];
          V64 := Read64(A);
          if FFault then Break;
          if TOp(I.Kind) = oFMOVDLDP then
            S.R[M] := S.R[M] + 8;
          if (N and 1) = 0 then
            S.FR.Q[N shr 1] := SwapHalves(V64)
          else
            S.XF.Q[N shr 1] := SwapHalves(V64);
        end;
      oFMOVDST, oFMOVDST0, oFMOVDSTM:
        begin
          if (M and 1) = 0 then
            V64 := SwapHalves(S.FR.Q[M shr 1])
          else
            V64 := SwapHalves(S.XF.Q[M shr 1]);
          A := S.R[N];
          case TOp(I.Kind) of
            oFMOVDST0: A := A + S.R[0];
            oFMOVDSTM: A := A - 8;
          end;
          Write64(A, V64);
          if FFault then Break;
          if TOp(I.Kind) = oFMOVDSTM then
            S.R[N] := A;
        end;
      oFLDI0:
        S.FR.U[N] := 0;
      oFLDI1:
        S.FR.U[N] := $3F800000;
      oFLDS:
        S.FPUL := S.FR.U[N];
      oFSTS:
        S.FR.U[N] := S.FPUL;
      oFABS:
        S.FR.U[N] := S.FR.U[N] and $7FFFFFFF;
      oFNEG:
        S.FR.U[N] := S.FR.U[N] xor $80000000;
      oFADD, oFSUB, oFMUL, oFDIV:
        begin
          var X := S.FR.S[N];
          var Y := S.FR.S[M];
          if DN then
          begin
            X := FlushSingle(X);
            Y := FlushSingle(Y);
          end;
          case TOp(I.Kind) of
            oFADD: F := X + Y;
            oFSUB: F := X - Y;
            oFMUL: F := X * Y;
          else
            F := X / Y;
          end;
          if DN then
            F := FlushSingle(F);
          S.FR.S[N] := F;
        end;
      oFMAC:
        begin
          var X := S.FR.S[1];
          var Y := S.FR.S[M];
          var Z := S.FR.S[N];
          if DN then
          begin
            X := FlushSingle(X);
            Y := FlushSingle(Y);
            Z := FlushSingle(Z);
          end;
          DV := Double(X) * Double(Y) + Double(Z);
          F := RoundToSingle(DV);
          if DN then
            F := FlushSingle(F);
          S.FR.S[N] := F;
        end;
      oFSQRT:
        begin
          F := S.FR.S[N];
          if DN then
            F := FlushSingle(F);
          F := RoundToSingle(Sqrt(Double(F)));
          S.FR.S[N] := F;
        end;
      oFSRRA:
        begin
          F := S.FR.S[N];
          if DN then
            F := FlushSingle(F);
          F := RoundToSingle(1.0 / Sqrt(Double(F)));
          if DN then
            F := FlushSingle(F);
          S.FR.S[N] := F;
        end;
      oFCMPEQ:
        if IsNaNBits(S.FR.U[N]) or IsNaNBits(S.FR.U[M]) then
          S.T := 0
        else
          S.T := Cardinal(Ord(S.FR.S[N] = S.FR.S[M]));
      oFCMPGT:
        if IsNaNBits(S.FR.U[N]) or IsNaNBits(S.FR.U[M]) then
          S.T := 0
        else
          S.T := Cardinal(Ord(S.FR.S[N] > S.FR.S[M]));
      oFLOAT:
        begin
          F := Integer(S.FPUL);
          S.FR.S[N] := F;
        end;
      oFTRC:
        S.FPUL := SingleToInt(S.FR.S[N]);
      // FIPR/FTRV: a rounded first product, then fused multiply-adds with one
      // rounding each (the order matches SingleStepTests).
      oFIPR:
        begin
          F := SingleProduct(S.FR.S[N xor 1], S.FR.S[M xor 1]);
          F := FusedSingle(S.FR.S[(N + 1) xor 1], S.FR.S[(M + 1) xor 1], F);
          F := FusedSingle(S.FR.S[(N + 2) xor 1], S.FR.S[(M + 2) xor 1], F);
          F := FusedSingle(S.FR.S[(N + 3) xor 1], S.FR.S[(M + 3) xor 1], F);
          if DN then
            F := FlushSingle(F);
          S.FR.S[(N + 3) xor 1] := F;
        end;
      oFTRV:
        begin
          var X0 := S.FR.S[N xor 1];
          var X1 := S.FR.S[(N + 1) xor 1];
          var X2 := S.FR.S[(N + 2) xor 1];
          var X3 := S.FR.S[(N + 3) xor 1];
          for var Row := 0 to 3 do
          begin
            F := SingleProduct(S.XF.S[(Row + 4) xor 1], X1);
            F := FusedSingle(S.XF.S[Row xor 1], X0, F);
            F := FusedSingle(S.XF.S[(Row + 8) xor 1], X2, F);
            F := FusedSingle(S.XF.S[(Row + 12) xor 1], X3, F);
            if DN then
              F := FlushSingle(F);
            S.FR.S[(N + Row) xor 1] := F;
          end;
        end;
      oFSCA:
        begin
          DV := (S.FPUL and $FFFF) * (2 * Pi / 65536);
          S.FR.S[N + 1] := RoundToSingle(Sin(DV));
          S.FR.S[N] := RoundToSingle(Cos(DV));
        end;
      oFSCHG:
        S.FPSCR := S.FPSCR xor FPSCRSZ;
      oFRCHG:
        begin
          S.FPSCR := S.FPSCR xor FPSCRFR;
          SwapFPBanks;
        end;
      oDABS:
        S.FR.Q[N shr 1] := S.FR.Q[N shr 1] and $7FFFFFFFFFFFFFFF;
      oDNEG:
        S.FR.Q[N shr 1] := S.FR.Q[N shr 1] xor $8000000000000000;
      oDADD, oDSUB, oDMUL, oDDIV:
        begin
          var X := S.FR.D[N shr 1];
          var Y := S.FR.D[M shr 1];
          if DN then
          begin
            X := FlushDouble(X);
            Y := FlushDouble(Y);
          end;
          case TOp(I.Kind) of
            oDADD: DV := X + Y;
            oDSUB: DV := X - Y;
            oDMUL: DV := X * Y;
          else
            DV := X / Y;
          end;
          if DN then
            DV := FlushDouble(DV);
          S.FR.D[N shr 1] := DV;
        end;
      oDSQRT:
        S.FR.D[N shr 1] := Sqrt(S.FR.D[N shr 1]);
      oDCMPEQ:
        if IsNaN64(S.FR.Q[N shr 1]) or IsNaN64(S.FR.Q[M shr 1]) then
          S.T := 0
        else
          S.T := Cardinal(Ord(S.FR.D[N shr 1] = S.FR.D[M shr 1]));
      oDCMPGT:
        if IsNaN64(S.FR.Q[N shr 1]) or IsNaN64(S.FR.Q[M shr 1]) then
          S.T := 0
        else
          S.T := Cardinal(Ord(S.FR.D[N shr 1] > S.FR.D[M shr 1]));
      oDFLOAT:
        S.FR.D[N shr 1] := Integer(S.FPUL);
      oDFTRC:
        S.FPUL := DoubleToInt(S.FR.D[N shr 1]);
      oFCNVSD:
        S.FR.D[N shr 1] := BitsSingle(S.FPUL);
      oFCNVDS:
        begin
          F := RoundToSingle(S.FR.D[N shr 1]);
          if DN then
            F := FlushSingle(F);
          S.FPUL := SingleBits(F);
        end;
      oIllegal, oSlotIllegal, oFPUDisabled, oSlotFPUDisabled:
        begin
          if (TOp(I.Kind) = oIllegal) and Assigned(FIllegalHook) then
          begin
            S.PC := I.Addr;
            if FIllegalHook(FIllegalUser, I.Addr) then
            begin
              Jumped := True;
              JumpTarget := S.PC;
              Inc(Result);
              Inc(I);
              Break;
            end;
          end;
          case TOp(I.Kind) of
            oIllegal: S.EXPEVT := SH4ExcIllegal;
            oSlotIllegal: S.EXPEVT := SH4ExcSlotIllegal;
            oFPUDisabled: S.EXPEVT := SH4ExcFPUDisabled;
          else
            S.EXPEVT := SH4ExcSlotFPUDisabled;
          end;
          Excepted := True;
          Break;
        end;
    end;
    if FFault then
      Break;
    Inc(Result);
    Inc(I);
  end;

  if FFault or Excepted then
  begin
    FFault := False;
    Fault(S.EXPEVT, I^, (I.Flags and IFSlot) <> 0);
    Next := S.PC;
    Exit;
  end;

  Dec(I);
  if Jumped then
    Next := JumpTarget
  else if (I.Flags and IFDelayed) <> 0 then
    Next := I.Addr + 2
  else if S.DelaySlot then
  begin
    Next := S.DelayTarget;
    S.DelaySlot := False;
    if S.RTEPending then
    begin
      S.RTEPending := False;
      SetSRValue(S.RTESR);
    end;
  end
  else
    Next := I.Addr + 2;
end;

{ Blocks }

procedure TSH4.ClearBlocks;
begin
  FillChar(FBlockHead, SizeOf(FBlockHead), 0);
  FBlockCount := 0;
  FInstChunk := 0;
  FInstUsed := 0;
  FCodeChunk := 0;
  FCodeUsed := 0;
end;

procedure TSH4.InvalidateBlocks;
begin
  ClearBlocks;
end;

function TSH4.FetchWord(Address: Cardinal; out Op: Word): Boolean;
begin
  if Assigned(FFetch) then
  begin
    if ((Address and 1) <> 0) and not FLenient then
    begin
      S.TEA := Address;
      S.EXPEVT := SH4ExcAddressRead;
      Exit(False);
    end;
    Op := FFetch(FFetchUser, Address);
    Exit(True);
  end;
  var P := FReadMap[Address shr 16];
  if (P <> nil) and ((Address and 1) = 0) then
  begin
    Op := PWord(P + (Address and $FFFF))^;
    Exit(True);
  end;
  Op := Word(SlowRead(Address, 2));
  Result := not FFault;
  FFault := False;
end;

function TSH4.BlockValid(B: PSH4Block): Boolean;
begin
  if (B.GenPtr^ = B.Gen) and (B.GenPtr2^ = B.Gen2) then
    Exit(True);
  var Code := B.Code;
  var Address := B.PC;
  for var I := 0 to B.Words - 1 do
  begin
    var P := FReadMap[Address shr 16];
    if (P = nil) or (PWord(P + (Address and $FFFF))^ <> Code^) then
      Exit(False);
    Inc(Code);
    Inc(Address, 2);
  end;
  B.Gen := B.GenPtr^;
  B.Gen2 := B.GenPtr2^;
  Result := True;
end;

function TSH4.FindBlock(PC, AMode: Cardinal): PSH4Block;
begin
  Result := FBlockHead[(PC shr 1) and (BlockBuckets - 1)];
  while Result <> nil do
  begin
    if (Result.PC = PC) and (Result.Mode = AMode) then
    begin
      if BlockValid(Result) then
        Exit;
      // Stale code: unlink by marking an impossible mode; rebuilt below.
      Result.Mode := $FFFFFFFF;
      Exit(nil);
    end;
    Result := Result.Next;
  end;
end;

function TSH4.BuildBlock(PC, AMode: Cardinal): PSH4Block;
begin
  Result := nil;
  // Only directly mapped code is cached; device memory runs by steps.
  if (FReadMap[PC shr 16] = nil) or ((PC and 1) <> 0) then
    Exit;
  if FInstUsed + MaxBlockInsts + 1 > InstChunkSize then
  begin
    Inc(FInstChunk);
    FInstUsed := 0;
  end;
  if FCodeUsed + MaxBlockInsts + 1 > InstChunkSize then
  begin
    Inc(FCodeChunk);
    FCodeUsed := 0;
  end;
  if (FBlockCount >= MaxBlocks) or (FInstChunk >= MaxInstChunks) or (FCodeChunk >= MaxInstChunks) then
    ClearBlocks;
  if FInstChunk >= Length(FInstChunks) then
  begin
    SetLength(FInstChunks, FInstChunk + 1);
    SetLength(FInstChunks[FInstChunk], InstChunkSize);
  end;
  if FCodeChunk >= Length(FCodeChunks) then
  begin
    SetLength(FCodeChunks, FCodeChunk + 1);
    SetLength(FCodeChunks[FCodeChunk], InstChunkSize);
  end;
  var Chunk := FBlockCount div BlockChunkSize;
  if Chunk >= Length(FBlockChunks) then
  begin
    SetLength(FBlockChunks, Chunk + 1);
    SetLength(FBlockChunks[Chunk], BlockChunkSize);
  end;
  var B: PSH4Block := @FBlockChunks[Chunk][FBlockCount mod BlockChunkSize];
  var Insts: PSH4Inst := @FInstChunks[FInstChunk][FInstUsed];
  var Code: PWord := @FCodeChunks[FCodeChunk][FCodeUsed];
  var Count := 0;
  var Address := PC;
  var Slot := False;
  while Count < MaxBlockInsts + 1 do
  begin
    var Page := FReadMap[Address shr 16];
    if Page = nil then
      Break;
    var Op := PWord(Page + (Address and $FFFF))^;
    var Delayed := Decode(Op, Address, AMode, Slot, Insts[Count]);
    Code[Count] := Op;
    Inc(Count);
    Inc(Address, 2);
    if Slot or ((Insts[Count - 1].Flags and IFEnd) <> 0) then
      Break;
    Slot := Delayed;
    if Slot then
      Continue;
    if (Count >= MaxBlockInsts) or ((Address and $FFF) = 0) then
      Break;
  end;
  // A delayed branch whose slot could not be fetched runs by steps.
  if (Count > 0) and ((Insts[Count - 1].Flags and IFDelayed) <> 0) then
    Dec(Count);
  if Count = 0 then
    Exit;
  Inc(FBlockCount);
  Inc(FInstUsed, Count);
  Inc(FCodeUsed, Count);
  Inc(FBlocksBuilt);
  B.PC := PC;
  B.Mode := AMode;
  B.Count := Count;
  B.Words := Count;
  B.Insts := Insts;
  B.Code := Code;
  B.GenPtr := @FGenMap[PC shr 16][(PC shr 12) and 15];
  var Last := PC + Cardinal(Count - 1) * 2;
  B.GenPtr2 := @FGenMap[Last shr 16][(Last shr 12) and 15];
  B.Gen := B.GenPtr^;
  B.Gen2 := B.GenPtr2^;
  B.Idle := False;
  var Bucket := (PC shr 1) and (BlockBuckets - 1);
  B.Next := FBlockHead[Bucket];
  FBlockHead[Bucket] := B;
  Result := B;
end;

{ Control }

constructor TSH4.Create(const Bus: TSH4Bus; NowCounter, DeadlineCounter: PInt64);
begin
  inherited Create;
  if (Bus.ReadPages = nil) or (Bus.WritePages = nil) or (Bus.Gens = nil) or
    not Assigned(Bus.Read) or not Assigned(Bus.Write) or not Assigned(Bus.Burst) then
    raise EArgumentException.Create('SH-4 requires complete bus tables and callbacks');
  if (NowCounter = nil) or (DeadlineCounter = nil) then
    raise EArgumentException.Create('SH-4 requires time counters');
  FBus := Bus;
  Now := NowCounter;
  Deadline := DeadlineCounter;
  FBlocksEnabled := True;
  Reset;
end;

procedure TSH4.SetFetchHook(Fetch: TSH4Fetch; User: Pointer);
begin
  FFetch := Fetch;
  FFetchUser := User;
  ClearBlocks;
end;

procedure TSH4.SetIllegalHook(Hook: TSH4IllegalHook; User: Pointer);
begin
  FIllegalHook := Hook;
  FIllegalUser := User;
end;

procedure TSH4.Reset;
begin
  S := Default(TSH4State);
  S.PC := $A0000000;
  S.SR := $700000F0;
  S.T := 0;
  S.FPSCR := $00040001;
  FIRQLevel := 0;
  FIRQCode := 0;
  FFault := False;
  FExitRequest := False;
  BuildMaps;
  ClearBlocks;
end;

procedure TSH4.SetInterrupt(Level: Integer; Code: Cardinal);
begin
  FIRQLevel := Level;
  FIRQCode := Code;
  if Level > Integer((S.SR shr 4) and 15) then
    FExitRequest := True;
end;

procedure TSH4.RequestExit;
begin
  FExitRequest := True;
end;

procedure TSH4.Run;
begin
  FHostMaskSaved := GetExceptionMask;
  FHostRoundSaved := GetRoundMode;
  SetExceptionMask(exAllArithmeticExceptions);
  ApplyHostRounding;
  try
    FExitRequest := False;
    while Now^ < Deadline^ do
    begin
      if (FIRQLevel > Integer((S.SR shr 4) and 15)) and ((S.SR and SRBL) = 0) and not S.DelaySlot then
      begin
        S.INTEVT := FIRQCode;
        if S.Sleeping then
          S.PC := S.PC + 2;
        EnterException(0, $600, S.PC);
        Inc(Now^);
      end;
      if S.Sleeping then
      begin
        Now^ := Deadline^;
        Break;
      end;
      var Next: Cardinal;
      var Count: Integer;
      var B: PSH4Block := nil;
      if FBlocksEnabled and not S.DelaySlot and not Assigned(FFetch) then
      begin
        var AMode := Mode;
        B := FindBlock(S.PC, AMode);
        if B = nil then
          B := BuildBlock(S.PC, AMode);
      end;
      if B <> nil then
      begin
        Count := Execute(B.Insts, B.Count, Next);
        S.PC := Next;
        Inc(InstructionsExecuted, Count);
        if Count = 0 then
          Count := 1;
        Inc(Now^, Count);
      end
      else
        Step;
      if FExitRequest then
      begin
        FExitRequest := False;
        Break;
      end;
    end;
  finally
    ClearExceptions(False);
    SetExceptionMask(FHostMaskSaved);
    SetRoundMode(FHostRoundSaved);
  end;
end;

procedure TSH4.Step;
begin
  var SavedMask := GetExceptionMask;
  var SavedRound := GetRoundMode;
  SetExceptionMask(exAllArithmeticExceptions);
  ApplyHostRounding;
  try
    if (FIRQLevel > Integer((S.SR shr 4) and 15)) and ((S.SR and SRBL) = 0) and not S.DelaySlot then
    begin
      S.INTEVT := FIRQCode;
      if S.Sleeping then
        S.PC := S.PC + 2;
      EnterException(0, $600, S.PC);
    end;
    Inc(Now^);
    if S.Sleeping then
      Exit;
    var Op: Word;
    var Slot := S.DelaySlot;
    if not FetchWord(S.PC, Op) then
    begin
      FScratch[0].Addr := S.PC;
      FScratch[0].Flags := 0;
      if Slot then
        FScratch[0].Flags := IFSlot;
      Fault(S.EXPEVT, FScratch[0], Slot);
      Exit;
    end;
    Decode(Op, S.PC, Mode, Slot, FScratch[0]);
    var Next: Cardinal;
    var Count := Execute(@FScratch[0], 1, Next);
    S.PC := Next;
    Inc(InstructionsExecuted, Count);
  finally
    ClearExceptions(False);
    SetExceptionMask(SavedMask);
    SetRoundMode(SavedRound);
  end;
end;

procedure TSH4.SerializeState(Archive: TStateArchive);
begin
  Archive.Field(S, SizeOf(S));
  if Archive.Loading then
  begin
    S.T := S.T and 1;
    S.SR := S.SR and SH4SRWriteMask and not Cardinal(SRT);
    S.FPSCR := S.FPSCR and SH4FPSCRMask;
    FFault := False;
    BuildMaps;
    ClearBlocks;
  end;
end;

end.
