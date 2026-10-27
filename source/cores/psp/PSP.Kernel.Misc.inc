{ PSP.Kernel: time, interrupts, system memory, registration. }

type
  TPSPMemBlock = class(TPSPKernelObject)
  public
    PartitionId: Integer;
    Address, Size: Cardinal;
  end;

  // A kernel heap (SysMemForKernel): blocks carved from one partition block.
  TPSPHeap = class(TPSPKernelObject)
  public
    PartitionId: Integer;
    Block, Size: Cardinal;
    Area: TPSPPartition;
    destructor Destroy; override;
  end;

destructor TPSPHeap.Destroy;
begin
  Area.Free;
  inherited;
end;

procedure TPSPKernel.hGetSystemTime;
begin
  var P := FHLE.Arg(0);
  var T := UInt64(NowUs);
  FMemory.Write32(P, Cardinal(T));
  FMemory.Write32(P + 4, Cardinal(T shr 32));
  FHLE.Result(0);
end;

procedure TPSPKernel.hGetSystemTimeWide;
begin
  FHLE.Result64(UInt64(NowUs));
end;

procedure TPSPKernel.hGetSystemTimeLow;
begin
  FHLE.Result(Cardinal(NowUs));
end;

procedure TPSPKernel.hUSec2SysClock;
begin
  var P := FHLE.Arg(1);
  FMemory.Write32(P, FHLE.Arg(0));
  FMemory.Write32(P + 4, 0);
  FHLE.Result(0);
end;

procedure TPSPKernel.hUSec2SysClockWide;
begin
  FHLE.Result64(FHLE.Arg(0));
end;

procedure TPSPKernel.hSysClock2USec;
begin
  var P := FHLE.Arg(0);
  var Clock := UInt64(FMemory.Read32(P)) or (UInt64(FMemory.Read32(P + 4)) shl 32);
  var SecPtr := FHLE.Arg(1);
  var UsPtr := FHLE.Arg(2);
  if SecPtr <> 0 then
  begin
    FMemory.Write32(SecPtr, Cardinal(Clock div 1000000));
    if UsPtr <> 0 then
      FMemory.Write32(UsPtr, Cardinal(Clock mod 1000000));
  end
  else if UsPtr <> 0 then
    FMemory.Write32(UsPtr, Cardinal(Clock));
  FHLE.Result(0);
end;

procedure TPSPKernel.hSysClock2USecWide;
begin
  var Clock := FHLE.Arg64(0);
  var SecPtr := FHLE.Arg(2);
  var UsPtr := FHLE.Arg(3);
  if SecPtr <> 0 then
  begin
    FMemory.Write32(SecPtr, Cardinal(Clock div 1000000));
    if UsPtr <> 0 then
      FMemory.Write32(UsPtr, Cardinal(Clock mod 1000000));
  end
  else if UsPtr <> 0 then
    FMemory.Write32(UsPtr, Cardinal(Clock));
  FHLE.Result(0);
end;

{ Interrupts }

procedure TPSPKernel.hCpuSuspendIntr;
begin
  FHLE.Result(Ord(FCPU.InterruptsEnabled));
  FCPU.InterruptsEnabled := False;
end;

procedure TPSPKernel.hCpuResumeIntr;
begin
  FCPU.InterruptsEnabled := (FHLE.Arg(0) and 1) <> 0;
  FHLE.Result(0);
  if FCPU.InterruptsEnabled then
  begin
    if FPendingInts.Count > 0 then
      FCPU.Stop;
    // What became ready while dispatch was held gets the CPU now.
    RequestReschedule;
  end;
end;

procedure TPSPKernel.hIsCpuIntrEnable;
begin
  FHLE.Result(Ord(FCPU.InterruptsEnabled));
end;

procedure TPSPKernel.hIsCpuIntrSuspended;
begin
  FHLE.Result(Ord(FHLE.Arg(0) = 0));
end;

const
  // Interrupts with a sub-interrupt table user code may use.
  PSPSubIntrHosts = [25, 30];
  // Interrupts user code may not touch at all, and ones it may only release.
  PSPIntrUserDenied = [7, 10, 12, 15..20, 22..24, 26, 31, 36, 50, 56..61, 65];
  PSPIntrRegisterDenied = [4, 6, 21];
  // VBlank sub-interrupts the firmware's drivers hold.
  PSPVBlankFirmwareSubs = [18..20, 24..26];

// 0 when the interrupt has a sub-interrupt table this caller may use.
function SubIntrCheck(I, S: Integer; Registering: Boolean): Cardinal;
begin
  if (I < 0) or (I > 66) or (I in PSPIntrUserDenied) or (Registering and (I in PSPIntrRegisterDenied)) then
    Exit(SCE_KERNEL_ERROR_ILLEGAL_INTRCODE);
  if not (I in PSPSubIntrHosts) then
    Exit(SCE_KERNEL_ERROR_NOTFOUND_HANDLER);
  if (S < 0) or (S > 31) then
    Exit(SCE_KERNEL_ERROR_ILLEGAL_INTRCODE);
  Result := 0;
end;

procedure TPSPKernel.hRegisterSubIntrHandler;
begin
  var I := FHLE.ArgInt(0);
  var S := FHLE.ArgInt(1);
  var Err := SubIntrCheck(I, S, True);
  if Err <> 0 then
    begin FHLE.Result(Err); Exit; end;
  if (FSubIntr[I, S].Handler <> 0) or ((I = 30) and (S in PSPVBlankFirmwareSubs)) then
    begin FHLE.Result(SCE_KERNEL_ERROR_FOUND_HANDLER); Exit; end;
  // The upper half of the table is the firmware's.
  if S > 15 then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_INTRCODE); Exit; end;
  // A null handler is taken but leaves the slot free; an enable made before
  // the handler came stays.
  FSubIntr[I, S].Handler := FHLE.Arg(2);
  FSubIntr[I, S].Arg := FHLE.Arg(3);
  FSubIntr[I, S].GP := FCPU.Ctx.GPR[28];
  FHLE.Result(0);
end;

procedure TPSPKernel.hReleaseSubIntrHandler;
begin
  var I := FHLE.ArgInt(0);
  var S := FHLE.ArgInt(1);
  var Err := SubIntrCheck(I, S, False);
  if Err <> 0 then
    begin FHLE.Result(Err); Exit; end;
  if FSubIntr[I, S].Handler = 0 then
    begin FHLE.Result(SCE_KERNEL_ERROR_NOTFOUND_HANDLER); Exit; end;
  FSubIntr[I, S] := Default(TPSPInterruptHandler);
  FHLE.Result(0);
end;

procedure TPSPKernel.hEnableSubIntr;
begin
  var I := FHLE.ArgInt(0);
  var S := FHLE.ArgInt(1);
  var Err := SubIntrCheck(I, S, False);
  if Err <> 0 then
    begin FHLE.Result(Err); Exit; end;
  FSubIntr[I, S].Enabled := True;
  FHLE.Result(0);
end;

procedure TPSPKernel.hDisableSubIntr;
begin
  var I := FHLE.ArgInt(0);
  var S := FHLE.ArgInt(1);
  var Err := SubIntrCheck(I, S, False);
  if Err <> 0 then
    begin FHLE.Result(Err); Exit; end;
  FSubIntr[I, S].Enabled := False;
  FHLE.Result(0);
end;

procedure TPSPKernel.hSuspendSubIntr;
begin
  var I := FHLE.ArgInt(0);
  var S := FHLE.ArgInt(1);
  var Err := SubIntrCheck(I, S, False);
  if Err <> 0 then
    begin FHLE.Result(Err); Exit; end;
  if FHLE.Arg(2) <> 0 then
    FMemory.Write32(FHLE.Arg(2), Ord(FSubIntr[I, S].Enabled));
  FSubIntr[I, S].Enabled := False;
  FHLE.Result(0);
end;

procedure TPSPKernel.hResumeSubIntr;
begin
  var I := FHLE.ArgInt(0);
  var S := FHLE.ArgInt(1);
  var Err := SubIntrCheck(I, S, False);
  if Err <> 0 then
    begin FHLE.Result(Err); Exit; end;
  FSubIntr[I, S].Enabled := FHLE.Arg(2) <> 0;
  FHLE.Result(0);
end;

procedure TPSPKernel.hIsSubInterruptOccurred;
begin
  FHLE.Result(0);
end;

procedure TPSPKernel.hRegisterUserSpaceIntrStack;
begin
  FHLE.Result(0);
end;

procedure TPSPKernel.hQueryIntrHandlerInfo;
begin
  FHLE.Result(0);
end;

// Checks an interrupt number and that something handles it; 0 when it does.
function TPSPKernel.IntrHandlerCheck(I: Integer): Cardinal;
begin
  if (I < 0) or (I > High(FIntrHandlers)) then
    Result := SCE_KERNEL_ERROR_ILLEGAL_INTRCODE
  else if FIntrHandlers[I].Handler = 0 then
    Result := SCE_KERNEL_ERROR_NOTFOUND_HANDLER
  else
    Result := 0;
end;

procedure TPSPKernel.hEnableIntr;
begin
  var I := FHLE.ArgInt(0);
  var Err := IntrHandlerCheck(I);
  if Err <> 0 then
    begin FHLE.Result(Err); Exit; end;
  FIntrHandlers[I].Enabled := True;
  FHLE.Result(0);
end;

procedure TPSPKernel.hDisableIntr;
begin
  var I := FHLE.ArgInt(0);
  var Err := IntrHandlerCheck(I);
  if Err <> 0 then
    begin FHLE.Result(Err); Exit; end;
  FIntrHandlers[I].Enabled := False;
  FHLE.Result(0);
end;

procedure TPSPKernel.hRegisterIntrHandler;
begin
  // (intno, no, handler, arg1, arg2)
  var I := FHLE.ArgInt(0);
  if (I < 0) or (I > High(FIntrHandlers)) or (FHLE.Arg(2) = 0) then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_INTRCODE); Exit; end;
  if FIntrHandlers[I].Handler <> 0 then
    begin FHLE.Result(SCE_KERNEL_ERROR_FOUND_HANDLER); Exit; end;
  FIntrHandlers[I].Handler := FHLE.Arg(2);
  FIntrHandlers[I].Arg := FHLE.Arg(3);
  FIntrHandlers[I].GP := FCPU.Ctx.GPR[28];
  FIntrHandlers[I].Enabled := False;
  FHLE.Result(0);
end;

procedure TPSPKernel.hReleaseIntrHandler;
begin
  var I := FHLE.ArgInt(0);
  var Err := IntrHandlerCheck(I);
  if Err <> 0 then
    begin FHLE.Result(Err); Exit; end;
  FIntrHandlers[I] := Default(TPSPInterruptHandler);
  FHLE.Result(0);
end;

{ System memory }

function TPSPKernel.AllocPartitionBlock(PartId: Integer; const Name: string; Kind: Integer; Size, Addr: Cardinal; out Err: Cardinal): Cardinal;
begin
  Result := 0;
  Err := 0;
  var P := Partition(PartId);
  if P = nil then
    begin Err := SCE_KERNEL_ERROR_ILLEGAL_PARTITION; Exit; end;
  if (Kind < 0) or (Kind > 4) then
    begin Err := SCE_KERNEL_ERROR_ILLEGAL_MEMBLOCKTYPE; Exit; end;
  if (Size = 0) or (Size > $7FFFFFFF) then
    begin Err := SCE_KERNEL_ERROR_MEMBLOCK_ALLOC_FAILED; Exit; end;
  case Kind of
    0: Result := P.Alloc(Size, akLow, 0, 256, Name);
    1: Result := P.Alloc(Size, akHigh, 0, 256, Name);
    2:
      begin
        if (Addr < P.Base) or (Addr - P.Base >= P.Size) then
          begin Err := SCE_KERNEL_ERROR_MEMBLOCK_ALLOC_FAILED; Exit; end;
        Result := P.Alloc(Size, akAddress, Addr, 256, Name);
      end;
    3, 4:
      begin
        if (Addr = 0) or ((Addr and (Addr - 1)) <> 0) then
          begin Err := SCE_KERNEL_ERROR_ILLEGAL_ALIGNMENT_SIZE; Exit; end;
        if Kind = 3 then
          Result := P.Alloc(Size, akLow, 0, Addr, Name)
        else
          Result := P.Alloc(Size, akHigh, 0, Addr, Name);
      end;
  end;
  if Result = 0 then
    Err := SCE_KERNEL_ERROR_MEMBLOCK_ALLOC_FAILED;
end;

procedure TPSPKernel.hAllocPartitionMemory;
begin
  var PartId := FHLE.ArgInt(0);
  var NamePtr := FHLE.Arg(1);
  var Kind := FHLE.ArgInt(2);
  var Size := FHLE.Arg(3);
  var Addr := FHLE.Arg(4);
  var KernelCaller := (FCurrent <> nil) and FCurrent.IsKernel;
  if (PartId < 1) or (PartId > 6) then
  begin
    if KernelCaller then
      FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_PARTITION)
    else
      FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ARGUMENT);
    Exit;
  end;
  if not KernelCaller and (PartId in [1, 3, 4]) then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_PARTITION); Exit; end;
  if (Kind < 0) or (Kind > 4) then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_MEMBLOCKTYPE); Exit; end;
  var Name: string;
  if not ReadName(NamePtr, Name) then
    begin FHLE.Result(SCE_KERNEL_ERROR_ERROR); Exit; end;
  var Err: Cardinal;
  var A := AllocPartitionBlock(PartId, Name, Kind, Size, Addr, Err);
  if A = 0 then
    begin FHLE.Result(Err); Exit; end;
  var B := TPSPMemBlock.Create;
  B.Name := Name;
  B.PartitionId := PartId;
  B.Address := A;
  B.Size := Size;
  FHLE.Result(AddObject(B));
end;

procedure TPSPKernel.hFreePartitionMemory;
begin
  var B := TPSPMemBlock(GetObject(FHLE.Arg(0), TPSPMemBlock));
  if B = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_UID); Exit; end;
  Partition(B.PartitionId).FreeBlock(B.Address);
  DeleteObject(B);
  FHLE.Result(0);
end;

procedure TPSPKernel.hGetBlockHeadAddr;
begin
  var B := TPSPMemBlock(GetObject(FHLE.Arg(0), TPSPMemBlock));
  if B = nil then
    begin FHLE.Result(0); Exit; end;
  FHLE.Result(B.Address);
end;

procedure TPSPKernel.hMaxFreeMemSize;
begin
  FHLE.Result(FUserPartition.LargestFree);
end;

procedure TPSPKernel.hTotalFreeMemSize;
begin
  FHLE.Result(FUserPartition.FreeTotal);
end;

procedure TPSPKernel.hTotalMemSize;
begin
  FHLE.Result(FUserPartition.Size);
end;

procedure TPSPKernel.hPartitionTotalFreeMemSize;
begin
  var P := Partition(FHLE.ArgInt(0));
  if P = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_PARTITION); Exit; end;
  FHLE.Result(P.FreeTotal);
end;

procedure TPSPKernel.hQueryMemoryInfo;
begin
  // (address, partition id out, block id out)
  var Addr := FHLE.Arg(0);
  for var O in FObjects.Values do
    if (O is TPSPMemBlock) and (Addr >= TPSPMemBlock(O).Address) and (Addr - TPSPMemBlock(O).Address < TPSPMemBlock(O).Size) then
    begin
      if FHLE.Arg(1) <> 0 then
        FMemory.Write32(FHLE.Arg(1), Cardinal(TPSPMemBlock(O).PartitionId));
      if FHLE.Arg(2) <> 0 then
        FMemory.Write32(FHLE.Arg(2), O.UID);
      FHLE.Result(0);
      Exit;
    end;
  FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ADDR);
end;

procedure TPSPKernel.hAllocMemoryBlock;
begin
  // (name, type, size, options): type 0 low, 1 high, in the user partition.
  var Name: string;
  if not ReadName(FHLE.Arg(0), Name) then
    begin FHLE.Result(SCE_KERNEL_ERROR_ERROR); Exit; end;
  var Kind := FHLE.ArgInt(1);
  if (Kind < 0) or (Kind > 1) then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_MEMBLOCKTYPE); Exit; end;
  if (FHLE.Arg(3) <> 0) and (FMemory.Read32(FHLE.Arg(3)) <> 4) then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ARGUMENT); Exit; end;
  var Err: Cardinal;
  var A := AllocPartitionBlock(2, Name, Kind, FHLE.Arg(2), 0, Err);
  if A = 0 then
    begin FHLE.Result(Err); Exit; end;
  var B := TPSPMemBlock.Create;
  B.Name := Name;
  B.PartitionId := 2;
  B.Address := A;
  B.Size := FHLE.Arg(2);
  FHLE.Result(AddObject(B));
end;

procedure TPSPKernel.hFreeMemoryBlock;
begin
  hFreePartitionMemory;
end;

procedure TPSPKernel.hGetMemoryBlockPtr;
begin
  var B := TPSPMemBlock(GetObject(FHLE.Arg(0), TPSPMemBlock));
  // An unknown block is not reported.
  if B = nil then
    begin FHLE.Result(0); Exit; end;
  if FHLE.Arg(1) <> 0 then
    FMemory.Write32(FHLE.Arg(1), B.Address);
  FHLE.Result(0);
end;

procedure TPSPKernel.hCreateHeap;
begin
  // (partition, size, attr, name)
  var PartId := FHLE.ArgInt(0);
  var Size := FHLE.Arg(1);
  var P := Partition(PartId);
  if P = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_PARTITION); Exit; end;
  if Integer(Size) <= 0 then
    begin FHLE.Result($800200DC); Exit; end;
  var Name: string;
  if not ReadName(FHLE.Arg(3), Name) then
    begin FHLE.Result(SCE_KERNEL_ERROR_ERROR); Exit; end;
  var Block := P.Alloc(Size, akLow, 0, 256, 'heap:' + Name);
  if Block = 0 then
    begin FHLE.Result(SCE_KERNEL_ERROR_NO_MEMORY); Exit; end;
  var H := TPSPHeap.Create;
  H.Name := Name;
  H.PartitionId := PartId;
  H.Block := Block;
  H.Size := AlignUp(Size, 256);
  H.Area := TPSPPartition.Create(PartId, Block, H.Size);
  FHLE.Result(AddObject(H));
end;

procedure TPSPKernel.hDeleteHeap;
begin
  var H := TPSPHeap(GetObject(FHLE.Arg(0), TPSPHeap));
  if H = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_UID); Exit; end;
  Partition(H.PartitionId).FreeBlock(H.Block);
  DeleteObject(H);
  FHLE.Result(0);
end;

procedure TPSPKernel.hAllocHeapMemory;
begin
  var H := TPSPHeap(GetObject(FHLE.Arg(0), TPSPHeap));
  if H = nil then
    begin FHLE.Result(0); Exit; end;
  var Size := FHLE.Arg(1);
  if Size > $7FFFFFF0 then
    begin FHLE.Result(0); Exit; end;
  // Even nothing gets a block.
  if Size = 0 then
    Size := 1;
  var A := H.Area.Alloc(Size, akLow, 0, 8, '');
  // The heap grows with more of its partition.
  if A = 0 then
    A := Partition(H.PartitionId).Alloc(Size, akLow, 0, 256, 'heap ext:' + H.Name);
  FHLE.Result(A);
end;

procedure TPSPKernel.hAllocHeapMemoryWithOption;
begin
  // The option is (size, alignment); the alignment is 0 or a power of two
  // from 4 to 128.
  var Opt := FHLE.Arg(2);
  if Opt <> 0 then
  begin
    var Align := FMemory.Read32(Opt + 4);
    if (Align <> 0) and ((Align < 4) or (Align > $80) or ((Align and (Align - 1)) <> 0)) then
      begin FHLE.Result(0); Exit; end;
  end;
  hAllocHeapMemory;
end;

procedure TPSPKernel.hFreeHeapMemory;
begin
  var H := TPSPHeap(GetObject(FHLE.Arg(0), TPSPHeap));
  if H = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_UID); Exit; end;
  var A := FHLE.Arg(1);
  if H.Area.FreeBlock(A) or Partition(H.PartitionId).FreeBlock(A) then
    FHLE.Result(0)
  else
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_MEMBLOCK);
end;

procedure TPSPKernel.hDevkitVersion;
begin
  FHLE.Result($06060010);
end;

procedure TPSPKernel.hSetCompiledSdkVersion;
begin
  FCompiledSdkVersion := FHLE.Arg(0);
  FSdkVersionSet := True;
  FHLE.Result(0);
end;

procedure TPSPKernel.hGetCompiledSdkVersion;
begin
  FHLE.Result(FCompiledSdkVersion);
end;

procedure TPSPKernel.hSetCompilerVersion;
begin
  FCompilerVersion := FHLE.Arg(0);
  FHLE.Result(0);
end;

// A small printf: %d %i %u %x %X %p %s %c %%, flags 0 - +, width, l/ll ignored.
function GuestFormat(K: TPSPKernel; Fmt: RawByteString; FirstArg: Integer): RawByteString;
begin
  Result := '';
  var ArgIndex := FirstArg;
  var NextArg := function: Cardinal
    begin
      if ArgIndex < 8 then
        Result := K.CPU.Ctx.GPR[4 + ArgIndex]
      else
        Result := K.Memory.Read32(K.CPU.Ctx.GPR[29] + Cardinal(ArgIndex - 8) * 4);
      Inc(ArgIndex);
    end;
  var I := 1;
  while I <= Length(Fmt) do
  begin
    var Ch := Fmt[I];
    if (Ch <> '%') or (I = Length(Fmt)) then
    begin
      Result := Result + Ch;
      Inc(I);
      Continue;
    end;
    Inc(I);
    var Flags: RawByteString := '';
    while (I <= Length(Fmt)) and (Fmt[I] in ['-', '0', '+', ' ', '#']) do
    begin
      Flags := Flags + Fmt[I];
      Inc(I);
    end;
    var Width := 0;
    while (I <= Length(Fmt)) and (Fmt[I] in ['0'..'9']) do
    begin
      Width := Width * 10 + Ord(Fmt[I]) - Ord('0');
      Inc(I);
    end;
    if (I <= Length(Fmt)) and (Fmt[I] = '.') then
    begin
      Inc(I);
      while (I <= Length(Fmt)) and (Fmt[I] in ['0'..'9']) do
        Inc(I);
    end;
    while (I <= Length(Fmt)) and (Fmt[I] in ['l', 'h', 'z']) do
      Inc(I);
    if I > Length(Fmt) then
      Break;
    var Conv := Fmt[I];
    Inc(I);
    var S: RawByteString;
    case Conv of
      'd', 'i': S := RawByteString(IntToStr(Integer(NextArg())));
      'u': S := RawByteString(UIntToStr(NextArg()));
      'x': S := RawByteString(LowerCase(IntToHex(NextArg(), 1)));
      'X': S := RawByteString(IntToHex(NextArg(), 1));
      'p': S := RawByteString(LowerCase(IntToHex(NextArg(), 8)));
      'c': S := AnsiChar(Byte(NextArg()));
      's': S := K.Memory.ReadAnsi(NextArg(), 4096);
      '%': S := '%';
    else
      S := '%' + Conv;
    end;
    var Pad: AnsiChar := ' ';
    if (Pos('0', string(Flags)) > 0) and (Pos('-', string(Flags)) = 0) then
      Pad := '0';
    while Length(S) < Width do
      if Pos('-', string(Flags)) > 0 then
        S := S + ' '
      else
        S := Pad + S;
    Result := Result + S;
  end;
end;

procedure TPSPKernel.hPrintf;
begin
  DebugWrite(GuestFormat(Self, FMemory.ReadAnsi(FHLE.Arg(0), 4096), 1));
  FHLE.Result(0);
end;

procedure TPSPKernel.hExitGame;
begin
  FExited := True;
  if Assigned(FOnExit) then
    FOnExit(0);
  // Nothing else of the game runs.
  for var T in FThreads do
    if T <> FCurrent then
    begin
      RemoveReady(T);
      T.Status := PSPThreadDormant;
    end;
  if FCurrent <> nil then
    FCurrent.Status := PSPThreadDormant;
  FCurrent := nil;
  FIdle := True;
  FCPU.Stop;
  FHLE.Result(0);
end;

procedure TPSPKernel.hRegisterExitCallback;
begin
  var Id := FHLE.Arg(0);
  if (FCompiledSdkVersion >= $03950000) and (GetObject(Id, TPSPCallback) = nil) then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ARGUMENT); Exit; end;
  FExitCallback := Id;
  FHLE.Result(0);
end;

{ Volatile memory }

function TPSPKernel.VolatileRetry(T: TPSPThread): Boolean;
begin
  Result := not FVolatileLocked;
  if Result then
  begin
    FVolatileLocked := True;
    if T.Wait.Data[0] <> 0 then
      FMemory.Write32(T.Wait.Data[0], $08400000);
    if T.Wait.Data[1] <> 0 then
      FMemory.Write32(T.Wait.Data[1], $00400000);
    T.SetResult(0);
  end;
end;

procedure TPSPKernel.hVolatileMemLock;
begin
  if FHLE.Arg(0) <> 0 then
    begin FHLE.Result(SCE_KERNEL_ERROR_INVALID_MODE); Exit; end;
  if RefuseWait then
    Exit;
  if not FVolatileLocked then
  begin
    FVolatileLocked := True;
    if FHLE.Arg(1) <> 0 then
      FMemory.Write32(FHLE.Arg(1), $08400000);
    if FHLE.Arg(2) <> 0 then
      FMemory.Write32(FHLE.Arg(2), $00400000);
    FHLE.Result(0);
    Exit;
  end;
  if not CanWait then
    begin FHLE.Result(SCE_KERNEL_ERROR_CAN_NOT_WAIT); Exit; end;
  FHLE.Result(0);
  FVolatileWaiters.Add(FCurrent);
  BeginWaitData(PSPWaitEventFlag, nil, 0, 0, False, VolatileRetry, [FHLE.Arg(1), FHLE.Arg(2)], nil, 'volatile');
end;

procedure TPSPKernel.hVolatileMemTryLock;
begin
  if FHLE.Arg(0) <> 0 then
    begin FHLE.Result(SCE_KERNEL_ERROR_INVALID_MODE); Exit; end;
  if FVolatileLocked then
    begin FHLE.Result(Cardinal($802B0200)); Exit; end;
  FVolatileLocked := True;
  if FHLE.Arg(1) <> 0 then
    FMemory.Write32(FHLE.Arg(1), $08400000);
  if FHLE.Arg(2) <> 0 then
    FMemory.Write32(FHLE.Arg(2), $00400000);
  FHLE.Result(0);
end;

procedure TPSPKernel.hVolatileMemUnlock;
begin
  if FHLE.Arg(0) <> 0 then
    begin FHLE.Result(SCE_KERNEL_ERROR_INVALID_MODE); Exit; end;
  if not FVolatileLocked then
    begin FHLE.Result(Cardinal($802B0201)); Exit; end;
  FVolatileLocked := False;
  FHLE.Result(0);
  while FVolatileWaiters.Count > 0 do
  begin
    var T := FVolatileWaiters[0];
    FVolatileWaiters.Delete(0);
    if T.IsWaiting and (T.Wait.HLETag = 'volatile') then
    begin
      VolatileRetry(T);
      EndWait(T, 0);
      Break;
    end;
  end;
end;

procedure TPSPKernel.hReturnZero;
begin
  FHLE.Result(0);
end;

procedure TPSPKernel.hMemcpy;
begin
  var Dst := FHLE.Arg(0);
  var Src := FHLE.Arg(1);
  var N := FHLE.Arg(2);
  if N > 0 then
    FMemory.Copy(Dst, Src, N);
  FHLE.Result(Dst);
end;

procedure TPSPKernel.hMemset;
begin
  var Dst := FHLE.Arg(0);
  var N := FHLE.Arg(2);
  if N > 0 then
    FMemory.Fill(Dst, Byte(FHLE.Arg(1)), N);
  FHLE.Result(Dst);
end;

procedure TPSPKernel.RegisterAll;
const
  T = 'ThreadManForUser';
  K = 'Kernel_Library';
  S = 'SysMemUserForUser';
  I = 'InterruptManager';
begin
  var H := FHLE;
  H.Register(T, $446D8DE6, 'sceKernelCreateThread', hCreateThread);
  H.Register(T, $F475845D, 'sceKernelStartThread', hStartThread);
  H.Register(T, $AA73C935, 'sceKernelExitThread', hExitThread);
  H.Register(T, $532A522E, '_sceKernelExitThread', hExitThread);
  H.Register(T, $809CE29B, 'sceKernelExitDeleteThread', hExitDeleteThread);
  H.Register(T, $9FA03CD3, 'sceKernelDeleteThread', hDeleteThread);
  H.Register(T, $616403BA, 'sceKernelTerminateThread', hTerminateThread);
  H.Register(T, $383F7BCC, 'sceKernelTerminateDeleteThread', hTerminateDeleteThread);
  H.Register(T, $293B45B8, 'sceKernelGetThreadId', hGetThreadId);
  H.Register(T, $94AA61EE, 'sceKernelGetThreadCurrentPriority', hGetThreadCurrentPriority);
  H.Register(T, $71BC9871, 'sceKernelChangeThreadPriority', hChangeThreadPriority);
  H.Register(T, $912354A7, 'sceKernelRotateThreadReadyQueue', hRotateThreadReadyQueue);
  H.Register(T, $17C1684E, 'sceKernelReferThreadStatus', hReferThreadStatus);
  H.Register(T, $FFC36A14, 'sceKernelReferThreadRunStatus', hReferThreadRunStatus);
  H.Register(T, $3B183E26, 'sceKernelGetThreadExitStatus', hGetThreadExitStatus);
  H.Register(T, $9ACE131E, 'sceKernelSleepThread', hSleepThread);
  H.Register(T, $82826F70, 'sceKernelSleepThreadCB', hSleepThreadCB);
  H.Register(T, $D59EAD2F, 'sceKernelWakeupThread', hWakeupThread);
  H.Register(T, $FCCFAD26, 'sceKernelCancelWakeupThread', hCancelWakeupThread);
  H.Register(T, $1AF94D03, 'sceKernelDonateWakeupThread', hDonateWakeupThread);
  H.Register(T, $9944F31F, 'sceKernelSuspendThread', hSuspendThread);
  H.Register(T, $75156E8F, 'sceKernelResumeThread', hResumeThread);
  H.Register(T, $278C0DF5, 'sceKernelWaitThreadEnd', hWaitThreadEnd);
  H.Register(T, $840E8133, 'sceKernelWaitThreadEndCB', hWaitThreadEndCB);
  H.Register(T, $CEADEB47, 'sceKernelDelayThread', hDelayThread);
  H.Register(T, $68DA9E36, 'sceKernelDelayThreadCB', hDelayThreadCB);
  H.Register(T, $BD123D9E, 'sceKernelDelaySysClockThread', hDelaySysClockThread);
  H.Register(T, $1181E963, 'sceKernelDelaySysClockThreadCB', hDelaySysClockThreadCB);
  H.Register(T, $2C34E053, 'sceKernelReleaseWaitThread', hReleaseWaitThread);
  H.Register(T, $52089CA1, 'sceKernelGetThreadStackFreeSize', hGetThreadStackFreeSize);
  H.Register(T, $D13BDE95, 'sceKernelCheckThreadStack', hCheckThreadStack);
  H.Register(T, $BC80EC7C, 'sceKernelExtendThreadStack', hExtendThreadStack);
  H.Register(T, $EA748E31, 'sceKernelChangeCurrentThreadAttr', hChangeCurrentThreadAttr);
  H.Register(T, $57CF62DD, 'sceKernelGetThreadmanIdType', hGetThreadmanIdType);
  H.Register(T, $94416130, 'sceKernelGetThreadmanIdList', hGetThreadmanIdList);
  H.Register(T, $3AD58B8C, 'sceKernelSuspendDispatchThread', hSuspendDispatchThread);
  H.Register(T, $27E22EC2, 'sceKernelResumeDispatchThread', hResumeDispatchThread);
  H.Register(T, $627E6F3A, 'sceKernelReferSystemStatus', hReferSystemStatus);
  H.Register(T, $64D4540E, 'sceKernelReferThreadProfiler', hReferThreadProfiler);
  H.Register(T, $8218B4DD, 'sceKernelReferGlobalProfiler', hReferThreadProfiler);
  H.Register(T, $E81CAF8F, 'sceKernelCreateCallback', hCreateCallback);
  H.Register(T, $EDBA5844, 'sceKernelDeleteCallback', hDeleteCallback);
  H.Register(T, $C11BA8C4, 'sceKernelNotifyCallback', hNotifyCallback);
  H.Register(T, $BA4051D6, 'sceKernelCancelCallback', hCancelCallback);
  H.Register(T, $2A3D44FF, 'sceKernelGetCallbackCount', hGetCallbackCount);
  H.Register(T, $349D6D6C, 'sceKernelCheckCallback', hCheckCallback);
  H.Register(T, $730ED8BC, 'sceKernelReferCallbackStatus', hReferCallbackStatus);
  H.Register(T, $D6DA4BA1, 'sceKernelCreateSema', hCreateSema);
  H.Register(T, $28B6489C, 'sceKernelDeleteSema', hDeleteSema);
  H.Register(T, $3F53E640, 'sceKernelSignalSema', hSignalSema);
  H.Register(T, $4E3A1105, 'sceKernelWaitSema', hWaitSema);
  H.Register(T, $6D212BAC, 'sceKernelWaitSemaCB', hWaitSemaCB);
  H.Register(T, $58B1F937, 'sceKernelPollSema', hPollSema);
  H.Register(T, $8FFDF9A2, 'sceKernelCancelSema', hCancelSema);
  H.Register(T, $BC6FEBC5, 'sceKernelReferSemaStatus', hReferSemaStatus);
  H.Register(T, $55C20A00, 'sceKernelCreateEventFlag', hCreateEventFlag);
  H.Register(T, $EF9E4C70, 'sceKernelDeleteEventFlag', hDeleteEventFlag);
  H.Register(T, $1FB15A32, 'sceKernelSetEventFlag', hSetEventFlag);
  H.Register(T, $812346E4, 'sceKernelClearEventFlag', hClearEventFlag);
  H.Register(T, $402FCF22, 'sceKernelWaitEventFlag', hWaitEventFlag);
  H.Register(T, $328C546A, 'sceKernelWaitEventFlagCB', hWaitEventFlagCB);
  H.Register(T, $30FD48F0, 'sceKernelPollEventFlag', hPollEventFlag);
  H.Register(T, $CD203292, 'sceKernelCancelEventFlag', hCancelEventFlag);
  H.Register(T, $A66B0120, 'sceKernelReferEventFlagStatus', hReferEventFlagStatus);
  H.Register(T, $B7D098C6, 'sceKernelCreateMutex', hCreateMutex);
  H.Register(T, $F8170FBE, 'sceKernelDeleteMutex', hDeleteMutex);
  H.Register(T, $B011B11F, 'sceKernelLockMutex', hLockMutex);
  H.Register(T, $5BF4DD27, 'sceKernelLockMutexCB', hLockMutexCB);
  H.Register(T, $0DDCD2C9, 'sceKernelTryLockMutex', hTryLockMutex);
  H.Register(T, $6B30100F, 'sceKernelUnlockMutex', hUnlockMutex);
  H.Register(T, $87D9223C, 'sceKernelCancelMutex', hCancelMutex);
  H.Register(T, $A9C2CB9A, 'sceKernelReferMutexStatus', hReferMutexStatus);
  H.Register(T, $19CFF145, 'sceKernelCreateLwMutex', hCreateLwMutex);
  H.Register(T, $60107536, 'sceKernelDeleteLwMutex', hDeleteLwMutex);
  H.Register(T, $4C145944, 'sceKernelReferLwMutexStatusByID', hReferLwMutexStatusByID);
  H.Register(T, $7CFF8CF3, '_sceKernelLockLwMutex', hLockLwMutex);
  H.Register(T, $31327F19, '_sceKernelLockLwMutexCB', hLockLwMutexCB);
  H.Register(T, $71040D5C, '_sceKernelTryLockLwMutex', hTryLockLwMutex600);
  H.Register(T, $BEED3A47, '_sceKernelUnlockLwMutex', hUnlockLwMutex);
  H.Register(K, $BEA46419, 'sceKernelLockLwMutex', hLockLwMutex);
  H.Register(K, $1FC64E09, 'sceKernelLockLwMutexCB', hLockLwMutexCB);
  H.Register(K, $DC692EE3, 'sceKernelTryLockLwMutex', hTryLockLwMutex);
  H.Register(K, $37431849, 'sceKernelTryLockLwMutex_600', hTryLockLwMutex600);
  H.Register(K, $15B6446B, 'sceKernelUnlockLwMutex', hUnlockLwMutex);
  H.Register(K, $C1734599, 'sceKernelReferLwMutexStatus', hReferLwMutexStatus);
  H.Register(T, $8125221D, 'sceKernelCreateMbx', hCreateMbx);
  H.Register(T, $86255ADA, 'sceKernelDeleteMbx', hDeleteMbx);
  H.Register(T, $E9B3061E, 'sceKernelSendMbx', hSendMbx);
  H.Register(T, $18260574, 'sceKernelReceiveMbx', hReceiveMbx);
  H.Register(T, $F3986382, 'sceKernelReceiveMbxCB', hReceiveMbxCB);
  H.Register(T, $0D81716A, 'sceKernelPollMbx', hPollMbx);
  H.Register(T, $87D4DD36, 'sceKernelCancelReceiveMbx', hCancelReceiveMbx);
  H.Register(T, $A8E8C846, 'sceKernelReferMbxStatus', hReferMbxStatus);
  H.Register(T, $7C0DC2A0, 'sceKernelCreateMsgPipe', hCreateMsgPipe);
  H.Register(T, $F0B7DA1C, 'sceKernelDeleteMsgPipe', hDeleteMsgPipe);
  H.Register(T, $876DBFAD, 'sceKernelSendMsgPipe', hSendMsgPipe);
  H.Register(T, $7C41F2C2, 'sceKernelSendMsgPipeCB', hSendMsgPipeCB);
  H.Register(T, $884C9F90, 'sceKernelTrySendMsgPipe', hTrySendMsgPipe);
  H.Register(T, $74829B76, 'sceKernelReceiveMsgPipe', hReceiveMsgPipe);
  H.Register(T, $FBFA697D, 'sceKernelReceiveMsgPipeCB', hReceiveMsgPipeCB);
  H.Register(T, $DF52098F, 'sceKernelTryReceiveMsgPipe', hTryReceiveMsgPipe);
  H.Register(T, $349B864D, 'sceKernelCancelMsgPipe', hCancelMsgPipe);
  H.Register(T, $33BE4024, 'sceKernelReferMsgPipeStatus', hReferMsgPipeStatus);
  H.Register(T, $56C039B5, 'sceKernelCreateVpl', hCreateVpl);
  H.Register(T, $89B3D48C, 'sceKernelDeleteVpl', hDeleteVpl);
  H.Register(T, $BED27435, 'sceKernelAllocateVpl', hAllocateVpl);
  H.Register(T, $EC0A693F, 'sceKernelAllocateVplCB', hAllocateVplCB);
  H.Register(T, $AF36D708, 'sceKernelTryAllocateVpl', hTryAllocateVpl);
  H.Register(T, $B736E9FF, 'sceKernelFreeVpl', hFreeVpl);
  H.Register(T, $1D371B8A, 'sceKernelCancelVpl', hCancelVpl);
  H.Register(T, $39810265, 'sceKernelReferVplStatus', hReferVplStatus);
  H.Register(T, $C07BB470, 'sceKernelCreateFpl', hCreateFpl);
  H.Register(T, $ED1410E0, 'sceKernelDeleteFpl', hDeleteFpl);
  H.Register(T, $D979E9BF, 'sceKernelAllocateFpl', hAllocateFpl);
  H.Register(T, $E7282CB6, 'sceKernelAllocateFplCB', hAllocateFplCB);
  H.Register(T, $623AE665, 'sceKernelTryAllocateFpl', hTryAllocateFpl);
  H.Register(T, $F6414A71, 'sceKernelFreeFpl', hFreeFpl);
  H.Register(T, $A8AA591F, 'sceKernelCancelFpl', hCancelFpl);
  H.Register(T, $D8199E4C, 'sceKernelReferFplStatus', hReferFplStatus);
  H.Register(T, $8DAFF657, 'sceKernelCreateTlspl', hCreateTlspl);
  H.Register(T, $32BF938E, 'sceKernelDeleteTlspl', hDeleteTlspl);
  H.Register(T, $65F54FFB, '_sceKernelAllocateTlspl', hAllocateTlspl);
  H.Register(T, $4A719FB2, 'sceKernelFreeTlspl', hFreeTlspl);
  H.Register(T, $721067F3, 'sceKernelReferTlsplStatus', hReferTlsplStatus);
  H.Register(K, $FA835CDE, 'sceKernelGetTlsAddr', hGetTlsAddr);
  H.Register(T, $6652B8CA, 'sceKernelSetAlarm', hSetAlarm);
  H.Register(T, $B2C25152, 'sceKernelSetSysClockAlarm', hSetSysClockAlarm);
  H.Register(T, $7E65B999, 'sceKernelCancelAlarm', hCancelAlarm);
  H.Register(T, $DAA3F564, 'sceKernelReferAlarmStatus', hReferAlarmStatus);
  H.Register(T, $20FFF560, 'sceKernelCreateVTimer', hCreateVTimer);
  H.Register(T, $328F9E52, 'sceKernelDeleteVTimer', hDeleteVTimer);
  H.Register(T, $B3A59970, 'sceKernelGetVTimerBase', hGetVTimerBase);
  H.Register(T, $B7C18B77, 'sceKernelGetVTimerBaseWide', hGetVTimerBaseWide);
  H.Register(T, $034A921F, 'sceKernelGetVTimerTime', hGetVTimerTime);
  H.Register(T, $C0B3FFD2, 'sceKernelGetVTimerTimeWide', hGetVTimerTimeWide);
  H.Register(T, $542AD630, 'sceKernelSetVTimerTime', hSetVTimerTime);
  H.Register(T, $FB6425C3, 'sceKernelSetVTimerTimeWide', hSetVTimerTimeWide);
  H.Register(T, $C68D9437, 'sceKernelStartVTimer', hStartVTimer);
  H.Register(T, $D0AEEE87, 'sceKernelStopVTimer', hStopVTimer);
  H.Register(T, $D8B299AE, 'sceKernelSetVTimerHandler', hSetVTimerHandler);
  H.Register(T, $53B00E9A, 'sceKernelSetVTimerHandlerWide', hSetVTimerHandlerWide);
  H.Register(T, $D2D615EF, 'sceKernelCancelVTimerHandler', hCancelVTimerHandler);
  H.Register(T, $5F32BEAA, 'sceKernelReferVTimerStatus', hReferVTimerStatus);
  H.Register(T, $0C106E53, 'sceKernelRegisterThreadEventHandler', hRegisterThreadEventHandler);
  H.Register(T, $72F3C145, 'sceKernelReleaseThreadEventHandler', hReleaseThreadEventHandler);
  H.Register(T, $369EEB6B, 'sceKernelReferThreadEventHandlerStatus', hReferThreadEventHandlerStatus);
  H.Register(T, $DB738F35, 'sceKernelGetSystemTime', hGetSystemTime);
  H.Register(T, $82BC5777, 'sceKernelGetSystemTimeWide', hGetSystemTimeWide);
  H.Register(T, $369ED59D, 'sceKernelGetSystemTimeLow', hGetSystemTimeLow);
  H.Register(T, $110DEC9A, 'sceKernelUSec2SysClock', hUSec2SysClock);
  H.Register(T, $C8CD158C, 'sceKernelUSec2SysClockWide', hUSec2SysClockWide);
  H.Register(T, $BA6B92E2, 'sceKernelSysClock2USec', hSysClock2USec);
  H.Register(T, $E1619D7C, 'sceKernelSysClock2USecWide', hSysClock2USecWide);
  H.Register(K, $092968F4, 'sceKernelCpuSuspendIntr', hCpuSuspendIntr);
  H.Register(K, $5F10D406, 'sceKernelCpuResumeIntr', hCpuResumeIntr);
  H.Register(K, $3B84732D, 'sceKernelCpuResumeIntrWithSync', hCpuResumeIntr);
  H.Register(K, $B55249D2, 'sceKernelIsCpuIntrEnable', hIsCpuIntrEnable);
  H.Register(K, $47A0B729, 'sceKernelIsCpuIntrSuspended', hIsCpuIntrSuspended);
  H.Register(K, $293B45B8, 'sceKernelGetThreadId', hGetThreadId);
  H.Register(K, $D13BDE95, 'sceKernelCheckThreadStack', hCheckThreadStack);
  H.Register(K, $1839852A, 'sceKernelMemcpy', hMemcpy);
  H.Register(K, $A089ECA4, 'sceKernelMemset', hMemset);
  H.Register(I, $CA04A2B9, 'sceKernelRegisterSubIntrHandler', hRegisterSubIntrHandler);
  H.Register(I, $D61E6961, 'sceKernelReleaseSubIntrHandler', hReleaseSubIntrHandler);
  H.Register(I, $FB8E22EC, 'sceKernelEnableSubIntr', hEnableSubIntr);
  H.Register(I, $8A389411, 'sceKernelDisableSubIntr', hDisableSubIntr);
  H.Register(I, $5CB5A78B, 'sceKernelSuspendSubIntr', hSuspendSubIntr);
  H.Register(I, $7860E0DC, 'sceKernelResumeSubIntr', hResumeSubIntr);
  H.Register(I, $FC4374B8, 'sceKernelIsSubInterruptOccurred', hIsSubInterruptOccurred);
  H.Register(I, $EEE43F47, 'sceKernelRegisterUserSpaceIntrStack', hRegisterUserSpaceIntrStack);
  H.Register(I, $D2E8363F, 'QueryIntrHandlerInfo', hQueryIntrHandlerInfo);
  H.Register(S, $237DBD4F, 'sceKernelAllocPartitionMemory', hAllocPartitionMemory);
  H.Register(S, $B6D61D02, 'sceKernelFreePartitionMemory', hFreePartitionMemory);
  H.Register(S, $9D9A5BA1, 'sceKernelGetBlockHeadAddr', hGetBlockHeadAddr);
  H.Register(S, $A291F107, 'sceKernelMaxFreeMemSize', hMaxFreeMemSize);
  H.Register(S, $F919F628, 'sceKernelTotalFreeMemSize', hTotalFreeMemSize);
  H.Register(S, $ACBD88CA, 'sceKernelTotalMemSize', hTotalMemSize);
  H.Register(S, $2A3E5280, 'sceKernelQueryMemoryInfo', hQueryMemoryInfo);
  H.Register(S, $FE707FDF, 'sceKernelAllocMemoryBlock', hAllocMemoryBlock);
  H.Register(S, $50F61D8A, 'sceKernelFreeMemoryBlock', hFreeMemoryBlock);
  H.Register(S, $DB83A952, 'sceKernelGetMemoryBlockPtr', hGetMemoryBlockPtr);
  H.Register(S, $3FC9AE6A, 'sceKernelDevkitVersion', hDevkitVersion);
  H.Register(S, $7591C7DB, 'sceKernelSetCompiledSdkVersion', hSetCompiledSdkVersion);
  H.Register(S, $FC114573, 'sceKernelGetCompiledSdkVersion', hGetCompiledSdkVersion);
  H.Register(S, $F77D77CB, 'sceKernelSetCompilerVersion', hSetCompilerVersion);
  H.Register(S, $13A5ABEF, 'sceKernelPrintf', hPrintf);
  for var NID in [Cardinal($342061E5), $315AD3A0, $EBD5C3E6, $057E7380, $91DE343C, $7893F79A, $35669D4C,
    $1B4217BC, $358CA1BB] do
    H.Register(S, NID, Format('sceKernelSetCompiledSdkVersion_%.8X', [NID]), hSetCompiledSdkVersion);
  H.Register('LoadExecForUser', $05572A5F, 'sceKernelExitGame', hExitGame);
  H.Register('LoadExecForUser', $2AC9954B, 'sceKernelExitGameWithStatus', hExitGame);
  H.Register('LoadExecForUser', $4AC57943, 'sceKernelRegisterExitCallback', hRegisterExitCallback);
  H.Register('LoadExecForKernel', $05572A5F, 'sceKernelExitGame', hExitGame);
  H.Register('sceSuspendForUser', $3E0271D3, 'sceKernelVolatileMemLock', hVolatileMemLock);
  H.Register('sceSuspendForUser', $A14F40B2, 'sceKernelVolatileMemTryLock', hVolatileMemTryLock);
  H.Register('sceSuspendForUser', $A569E425, 'sceKernelVolatileMemUnlock', hVolatileMemUnlock);
  H.Register('sceSuspendForUser', $EADB1BD7, 'sceKernelPowerLock', hReturnZero);
  H.Register('sceSuspendForUser', $3AEE7261, 'sceKernelPowerUnlock', hReturnZero);
  H.Register('sceSuspendForUser', $090CCB3F, 'sceKernelPowerTick', hReturnZero);
  RegisterKernelAliases;
end;

const
  PSPIoForwardNids: array[0..16] of Cardinal = ($109F50BC, $810C4BC3, $6A638D83, $42EC03AC, $27EB27B8, $68963324,
    $63632449, $54F5FB11, $B29DDF9C, $E3EB004C, $EB092469, $F27A9C51, $06A70004, $1117C65F, $779103A0, $ACE946E8,
    $B8A740F4);
  PSPIoForwardNames: array[0..16] of string = ('sceIoOpen', 'sceIoClose', 'sceIoRead', 'sceIoWrite', 'sceIoLseek',
    'sceIoLseek32', 'sceIoIoctl', 'sceIoDevctl', 'sceIoDopen', 'sceIoDread', 'sceIoDclose', 'sceIoRemove',
    'sceIoMkdir', 'sceIoRmdir', 'sceIoRename', 'sceIoGetstat', 'sceIoChstat');

// Kernel modules reach the file calls through IoFileMgrForKernel: the same
// calls as the user library, looked up when made.
procedure TPSPKernel.hIoForKernel;
begin
  var Name := FHLE.CurrentName;
  for var I := 0 to High(PSPIoForwardNames) do
    if PSPIoForwardNames[I] = Name then
    begin
      var F := FHLE.FunctionInfo(FHLE.Find('IoFileMgrForUser', PSPIoForwardNids[I]));
      if (F <> nil) and Assigned(F.Handler) then
        F.Handler()
      else
        FHLE.Unimplemented('IoFileMgrForKernel ' + Name);
      Exit;
    end;
  FHLE.Unimplemented('IoFileMgrForKernel ' + Name);
end;

procedure TPSPKernel.RegisterKernelAliases;
const
  TK = 'ThreadManForKernel';
  SK = 'SysMemForKernel';
  IK = 'InterruptManagerForKernel';
begin
  for var I := 0 to High(PSPIoForwardNids) do
    FHLE.Register('IoFileMgrForKernel', PSPIoForwardNids[I], PSPIoForwardNames[I], hIoForKernel);
  // Kernel modules import the same calls from the *ForKernel libraries.
  var H := FHLE;
  for var N in [Cardinal($446D8DE6), $F475845D, $AA73C935, $809CE29B, $9FA03CD3, $616403BA, $383F7BCC, $293B45B8,
    $94AA61EE, $71BC9871, $912354A7, $17C1684E, $FFC36A14, $3B183E26, $9ACE131E, $82826F70, $D59EAD2F, $FCCFAD26,
    $9944F31F, $75156E8F, $278C0DF5, $840E8133, $CEADEB47, $68DA9E36, $2C34E053, $52089CA1, $D13BDE95, $57CF62DD,
    $94416130, $3AD58B8C, $27E22EC2, $E81CAF8F, $EDBA5844, $C11BA8C4, $BA4051D6, $2A3D44FF, $349D6D6C, $D6DA4BA1,
    $28B6489C, $3F53E640, $4E3A1105, $6D212BAC, $58B1F937, $8FFDF9A2, $BC6FEBC5, $55C20A00, $EF9E4C70, $1FB15A32,
    $812346E4, $402FCF22, $328C546A, $30FD48F0, $CD203292, $A66B0120, $B7D098C6, $F8170FBE, $B011B11F, $5BF4DD27,
    $0DDCD2C9, $6B30100F, $87D9223C, $A9C2CB9A, $DB738F35, $82BC5777, $369ED59D, $110DEC9A, $C8CD158C, $BA6B92E2,
    $E1619D7C, $6652B8CA, $7E65B999, $8DAFF657, $32BF938E, $65F54FFB, $4A719FB2, $721067F3, $56C039B5, $89B3D48C,
    $BED27435, $AF36D708, $B736E9FF, $C07BB470, $ED1410E0, $D979E9BF, $623AE665, $F6414A71] do
  begin
    var Index := H.Find('ThreadManForUser', N);
    if Index >= 0 then
    begin
      var F := H.FunctionInfo(Index);
      H.Register(TK, N, F.Name, F.Handler);
    end;
  end;
  H.Register(TK, $FA835CDE, 'sceKernelGetTlsAddr', hGetTlsAddr);
  H.Register(SK, $237DBD4F, 'sceKernelAllocPartitionMemory', hAllocPartitionMemory);
  H.Register(SK, $B6D61D02, 'sceKernelFreePartitionMemory', hFreePartitionMemory);
  H.Register(SK, $9D9A5BA1, 'sceKernelGetBlockHeadAddr', hGetBlockHeadAddr);
  H.Register(SK, $9697CD32, 'sceKernelPartitionTotalFreeMemSize', hPartitionTotalFreeMemSize);
  H.Register(SK, $1C1FBFE7, 'sceKernelCreateHeap', hCreateHeap);
  H.Register(SK, $C9805775, 'sceKernelDeleteHeap', hDeleteHeap);
  H.Register(SK, $636C953B, 'sceKernelAllocHeapMemory', hAllocHeapMemory);
  H.Register(SK, $EB7A74DB, 'sceKernelAllocHeapMemoryWithOption', hAllocHeapMemoryWithOption);
  H.Register(SK, $7B749390, 'sceKernelFreeHeapMemory', hFreeHeapMemory);
  H.Register(IK, $092968F4, 'sceKernelCpuSuspendIntr', hCpuSuspendIntr);
  H.Register(IK, $5F10D406, 'sceKernelCpuResumeIntr', hCpuResumeIntr);
  H.Register(IK, $4D6E7305, 'sceKernelEnableIntr', hEnableIntr);
  H.Register(IK, $D774BA45, 'sceKernelDisableIntr', hDisableIntr);
  H.Register(IK, $58DD8978, 'sceKernelRegisterIntrHandler', hRegisterIntrHandler);
  H.Register(IK, $F987B1F0, 'sceKernelReleaseIntrHandler', hReleaseIntrHandler);
end;
