unit DC.Boot;

// High-level boot firmware: the console state the boot ROM leaves for a
// program, the system call vectors at 8C0000B0..8C0000E0 and their services
// (system information, ROM font, flash ROM, GD-ROM, menu). Each vector points
// to a stub in low RAM whose illegal opcode reaches TDCBoot.Syscall.
// References: Marcus Comstedt's "Dreamcast system calls" and boot pages,
// KallistiOS syscall/flashrom/cdrom sources (as usage examples).
{$IFDEF DC_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$POINTERMATH ON}

interface

uses
  System.SysUtils, System.Classes, Core.Snapshots, HW.SH4, HW.SH4.Periph, DC.Types, DC.Memory, DC.PVR, DC.Disc;

const
  DCStubBase = $8C000800;
  DCStubSysinfo = DCStubBase;
  DCStubFont = DCStubBase + $10;
  DCStubFlash = DCStubBase + $20;
  DCStubGDROM = DCStubBase + $30;
  DCStubGDROM2 = DCStubBase + $40;
  DCStubMisc = DCStubBase + $50;
  DCStubEnd = DCStubBase + $60;
  DCFontAddress = $A0100020;
  DCSystemIDAddress = $8C000068;
  DCHLEOpcode = $FFFF;

type
  // Requests the console cannot satisfy inside a system call.
  TDCBootRequest = (None, ExitToMenu);

  TDCGDROMSyscalls = class
  public
    function Call(CPU: TSH4; Memory: TDCMemory): Boolean; virtual; abstract;
    procedure Reset; virtual; abstract;
    procedure SerializeState(Archive: TStateArchive); virtual; abstract;
  end;

  TDCBoot = class
  private
    FCPU: TSH4;
    FMemory: TDCMemory;
    FPeriph: TSH4Periph;
    FPVR: TDCPVR;
    FRequest: TDCBootRequest;
    procedure Flashrom;
    procedure Sysinfo;
    function FlashPartition(Index: Integer; out Offset, Size: Integer): Boolean;
  public
    GDROM: TDCGDROMSyscalls;
    // Optional diagnostics: one line per system call.
    Trace: TStrings;
    // Video output: True for VGA (31 kHz progressive), else NTSC/PAL 480i.
    VGA, PAL: Boolean;
    constructor Create(CPU: TSH4; Memory: TDCMemory; Periph: TSH4Periph; PVR: TDCPVR);
    // System call vectors, stubs and the hardware state at program entry.
    procedure Install;
    procedure EnterProgram(Entry: Cardinal);
    // Loads IP.BIN (8C008000) and the boot file (8C010000), descrambled on CD
    // media, and starts the IP.BIN bootstrap at 8C008300.
    procedure BootDisc(Disc: TDCDisc);
    function Syscall(Address: Cardinal): Boolean;
    function TakeRequest: TDCBootRequest;
  end;

function DCBootIllegalHook(User: Pointer; Address: Cardinal): Boolean;

implementation

function DCBootIllegalHook(User: Pointer; Address: Cardinal): Boolean;
begin
  Result := TDCBoot(User).Syscall(Address);
end;

constructor TDCBoot.Create(CPU: TSH4; Memory: TDCMemory; Periph: TSH4Periph; PVR: TDCPVR);
begin
  inherited Create;
  FCPU := CPU;
  FMemory := Memory;
  FPeriph := Periph;
  FPVR := PVR;
end;

procedure TDCBoot.Install;
begin
  var RAM := FMemory.RAM;
  // Vector table.
  PCardinal(RAM + $B0)^ := DCStubSysinfo;
  PCardinal(RAM + $B4)^ := DCStubFont;
  PCardinal(RAM + $B8)^ := DCStubFlash;
  PCardinal(RAM + $BC)^ := DCStubGDROM;
  PCardinal(RAM + $C0)^ := DCStubGDROM2;
  PCardinal(RAM + $E0)^ := DCStubMisc;
  // Stubs: the HLE opcode, then RTS/NOP should a handler decline.
  var Stub := DCStubBase;
  while Stub < DCStubEnd do
  begin
    var P := PWord(RAM + (Stub and $FFFFFF));
    P[0] := DCHLEOpcode;
    P[1] := $000B;
    P[2] := $0009;
    Inc(Stub, $10);
  end;
  FMemory.TouchRAM(0, $1000);
  Sysinfo;
end;

procedure TDCBoot.EnterProgram(Entry: Cardinal);
begin
  // The state the boot ROM leaves: privileged with interrupts masked, single
  // precision with denormals flushed, stack at the top of RAM.
  FCPU.SetSR($600000F0);
  FCPU.SetFPSCR($00040001);
  FCPU.S.R[15] := $8D000000;
  FCPU.S.VBR := $8C000000;
  FCPU.S.GBR := $8C000000;
  FCPU.S.PR := $8C000000;
  FCPU.S.PC := Entry;
  // Caches enabled with half the operand cache as RAM (IP.BIN keeps its stack
  // there), as the boot ROM leaves CCR.
  FCPU.S.CCR := $00000125;
  FCPU.RemapMemory;
  // Video: 640x480, 16 bpp RGB565, NTSC/PAL interlaced or VGA.
  var R: ^TDCPVRRegs := @FPVR.R;
  if VGA then
  begin
    R[PVRFBRCtrl shr 2] := $00800005;
    R[PVRSPGControl shr 2] := $00000100;
    R[PVRSPGLoad shr 2] := $020C0359;
    R[PVRSPGVBlankInt shr 2] := $00150208;
    R[PVRSPGVBlank shr 2] := $00280208;
    R[PVRFBRSize shr 2] := (1 shl 20) or (479 shl 10) or 319;
    R[PVRVOControl shr 2] := $00160000;
  end
  else
  begin
    R[PVRFBRCtrl shr 2] := $00000005;
    if PAL then
    begin
      R[PVRSPGControl shr 2] := $00000190;
      R[PVRSPGLoad shr 2] := $0270035F;
      R[PVRSPGVBlankInt shr 2] := $00150136;
      R[PVRSPGVBlank shr 2] := $002D026C;
    end
    else
    begin
      R[PVRSPGControl shr 2] := $00000150;
      R[PVRSPGLoad shr 2] := $020C0359;
      R[PVRSPGVBlankInt shr 2] := $00150104;
      R[PVRSPGVBlank shr 2] := $00240204;
    end;
    // Fields of 240 lines; each skips the other field's line.
    R[PVRFBRSize shr 2] := (321 shl 20) or (239 shl 10) or 319;
    R[PVRVOControl shr 2] := $00160000;
  end;
  R[PVRFBRSOF1 shr 2] := $00200000;
  R[PVRFBRSOF2 shr 2] := $00200000 + 640 * 2;
  // Enable the DMAC master switch as the boot ROM does.
  FPeriph.S.DMAOR := $8201;
end;

procedure TDCBoot.BootDisc(Disc: TDCDisc);
begin
  if not Disc.HasBootTrack then
    raise EReadError.Create('Disc has no Dreamcast boot track');
  var RAM := FMemory.RAM;
  for var I := 0 to 15 do
  begin
    var Sector := Disc.ReadBootSector(I);
    Move(Sector[0], (RAM + $8000 + Cardinal(I) * 2048)^, 2048);
  end;
  if not CompareMem(RAM + $8000, PAnsiChar(AnsiString('SEGA SEGAKATANA ')), 16) then
    raise EReadError.Create('Disc boot area has no Dreamcast IP.BIN');
  // Boot file name at IP.BIN offset 60h, space padded.
  var Name := '';
  for var I := 0 to 15 do
    if (RAM + $8060 + Cardinal(I))^ > 32 then
      Name := Name + Char((RAM + $8060 + Cardinal(I))^);
  if Name = '' then
    Name := '1ST_READ.BIN';
  var Data := Disc.ReadFile(Name, DCRAMSize - $20000);
  if Length(Data) = 0 then
    raise EReadError.CreateFmt('Boot file %s not found on the disc', [Name]);
  // The boot ROM descrambles boot files read from CD media (MIL-CD, CD-R).
  if not Disc.IsGDROM then
    DCDescramble(Data);
  Move(Data[0], (RAM + $10000)^, Length(Data));
  FMemory.TouchRAM($8000, $8000 + Cardinal(Length(Data)));
  EnterProgram($AC008300);
end;

procedure TDCBoot.Sysinfo;
begin
  // 8C000068: an eight-byte console ID followed by zeroed fields.
  var RAM := FMemory.RAM;
  for var I := 0 to 7 do
    (RAM + (DCSystemIDAddress and $FFFFFF) + Cardinal(I))^ := FMemory.Flash[$1A056 + I];
  FMemory.TouchRAM(DCSystemIDAddress, 8);
end;

function TDCBoot.FlashPartition(Index: Integer; out Offset, Size: Integer): Boolean;
begin
  Result := True;
  case Index of
    0: begin Offset := $1A000; Size := $2000; end;
    1: begin Offset := $18000; Size := $2000; end;
    2: begin Offset := $1C000; Size := $4000; end;
    3: begin Offset := $10000; Size := $8000; end;
    4: begin Offset := $00000; Size := $10000; end;
  else
    Offset := 0;
    Size := 0;
    Result := False;
  end;
end;

procedure TDCBoot.Flashrom;
begin
  var S: ^TSH4State := @FCPU.S;
  case S.R[7] of
    0:
      begin
        var Offset, Size: Integer;
        if FlashPartition(Integer(S.R[4]), Offset, Size) then
        begin
          FCPU.WriteVirtual32(S.R[5], Cardinal(Offset));
          FCPU.WriteVirtual32(S.R[5] + 4, Cardinal(Size));
          S.R[0] := 0;
        end
        else
          S.R[0] := $FFFFFFFF;
      end;
    1:
      begin
        var Offset := S.R[4] and (DCFlashSize - 1);
        for var I := 0 to Integer(S.R[6]) - 1 do
        begin
          var Dest := FCPU.PhysicalAddress(S.R[5] + Cardinal(I));
          if (Dest >= $0C000000) and (Dest < $10000000) then
            FMemory.RAM[Dest and (DCRAMSize - 1)] := FMemory.Flash[(Offset + Cardinal(I)) and (DCFlashSize - 1)];
        end;
        FMemory.TouchRAM(FCPU.PhysicalAddress(S.R[5]), S.R[6]);
        S.R[0] := 0;
      end;
    2:
      begin
        // Programming can only clear bits.
        var Offset := S.R[4] and (DCFlashSize - 1);
        for var I := 0 to Integer(S.R[6]) - 1 do
        begin
          var Source := FCPU.PhysicalAddress(S.R[5] + Cardinal(I));
          var Value: Byte := $FF;
          if (Source >= $0C000000) and (Source < $10000000) then
            Value := FMemory.RAM[Source and (DCRAMSize - 1)];
          var F := (Offset + Cardinal(I)) and (DCFlashSize - 1);
          FMemory.Flash[F] := FMemory.Flash[F] and Value;
        end;
        S.R[0] := S.R[6];
      end;
    3:
      begin
        S.R[0] := $FFFFFFFF;
        for var P := 0 to 4 do
        begin
          var Offset, Size: Integer;
          FlashPartition(P, Offset, Size);
          if Cardinal(Offset) = S.R[4] then
          begin
            FillChar(FMemory.Flash[Offset], Size, $FF);
            S.R[0] := 0;
            Break;
          end;
        end;
      end;
  else
    S.R[0] := $FFFFFFFF;
  end;
end;

function TDCBoot.Syscall(Address: Cardinal): Boolean;
begin
  // Stubs are reached through P1 or P2.
  Address := (Address and $1FFFFFFF) or $80000000;
  if (Address < DCStubBase) or (Address >= DCStubEnd) or ((Address and $F) <> 0) then
    Exit(False);
  var S: ^TSH4State := @FCPU.S;
  if Trace <> nil then
    Trace.Add(Format('syscall %.8x r4=%.8x r5=%.8x r6=%.8x r7=%.8x r1=%.8x pr=%.8x', [Address, S.R[4], S.R[5], S.R[6], S.R[7], S.R[1], S.PR]));
  case Address of
    DCStubSysinfo:
      case S.R[7] of
        0:
          begin
            Sysinfo;
            S.R[0] := 0;
          end;
        3:
          S.R[0] := DCSystemIDAddress;
      else
        S.R[0] := 0;
      end;
    DCStubFont:
      case S.R[1] of
        0: S.R[0] := DCFontAddress;
      else
        S.R[0] := 0;
      end;
    DCStubFlash:
      Flashrom;
    DCStubGDROM, DCStubGDROM2:
      if (GDROM = nil) or not GDROM.Call(FCPU, FMemory) then
        S.R[0] := $FFFFFFFF;
    DCStubMisc:
      if S.R[4] = 1 then
        FRequest := TDCBootRequest.ExitToMenu
      else
        S.R[0] := 0;
  end;
  // Return to the caller.
  S.PC := S.PR;
  Result := True;
end;

function TDCBoot.TakeRequest: TDCBootRequest;
begin
  Result := FRequest;
  FRequest := TDCBootRequest.None;
end;

end.
