{ PSP.Kernel: time, interrupts, system memory, registration. }

type
  TPSPMemBlock = class(TPSPKernelObject)
  public
    PartitionId: Integer;
    Address, Size: Cardinal;
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
  FCPU.InterruptsEnabled := FHLE.Arg(0) <> 0;
  FHLE.Result(0);
  if FCPU.InterruptsEnabled and (FPendingInts.Count > 0) then
    FCPU.Stop;
end;

procedure TPSPKernel.hIsCpuIntrEnable;
begin
  FHLE.Result(Ord(FCPU.InterruptsEnabled));
end;

procedure TPSPKernel.hIsCpuIntrSuspended;
begin
  FHLE.Result(Ord(FHLE.Arg(0) = 0));
end;

procedure TPSPKernel.hRegisterSubIntrHandler;
begin
  var I := FHLE.ArgInt(0);
  var S := FHLE.ArgInt(1);
  if (I < 0) or (I > High(FSubIntr)) then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_INTRCODE); Exit; end;
  if (S < 0) or (S > 31) then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_INTRCODE); Exit; end;
  if FSubIntr[I, S].Handler <> 0 then
    begin FHLE.Result(SCE_KERNEL_ERROR_FOUND_HANDLER); Exit; end;
  FSubIntr[I, S].Handler := FHLE.Arg(2);
  FSubIntr[I, S].Arg := FHLE.Arg(3);
  FSubIntr[I, S].GP := FCPU.Ctx.GPR[28];
  FSubIntr[I, S].Enabled := False;
  FHLE.Result(0);
end;

procedure TPSPKernel.hReleaseSubIntrHandler;
begin
  var I := FHLE.ArgInt(0);
  var S := FHLE.ArgInt(1);
  if (I < 0) or (I > High(FSubIntr)) or (S < 0) or (S > 31) then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_INTRCODE); Exit; end;
  if FSubIntr[I, S].Handler = 0 then
    begin FHLE.Result(SCE_KERNEL_ERROR_NOTFOUND_HANDLER); Exit; end;
  FSubIntr[I, S] := Default(TPSPInterruptHandler);
  FHLE.Result(0);
end;

procedure TPSPKernel.hEnableSubIntr;
begin
  var I := FHLE.ArgInt(0);
  var S := FHLE.ArgInt(1);
  if (I < 0) or (I > High(FSubIntr)) or (S < 0) or (S > 31) then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_INTRCODE); Exit; end;
  if FSubIntr[I, S].Handler = 0 then
    begin FHLE.Result(SCE_KERNEL_ERROR_NOTFOUND_HANDLER); Exit; end;
  FSubIntr[I, S].Enabled := True;
  FHLE.Result(0);
end;

procedure TPSPKernel.hDisableSubIntr;
begin
  var I := FHLE.ArgInt(0);
  var S := FHLE.ArgInt(1);
  if (I < 0) or (I > High(FSubIntr)) or (S < 0) or (S > 31) then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_INTRCODE); Exit; end;
  FSubIntr[I, S].Enabled := False;
  FHLE.Result(0);
end;

procedure TPSPKernel.hSuspendSubIntr;
begin
  var I := FHLE.ArgInt(0);
  var S := FHLE.ArgInt(1);
  if (I < 0) or (I > High(FSubIntr)) or (S < 0) or (S > 31) then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_INTRCODE); Exit; end;
  if FHLE.Arg(2) <> 0 then
    FMemory.Write32(FHLE.Arg(2), Ord(FSubIntr[I, S].Enabled));
  FSubIntr[I, S].Enabled := False;
  FHLE.Result(0);
end;

procedure TPSPKernel.hResumeSubIntr;
begin
  var I := FHLE.ArgInt(0);
  var S := FHLE.ArgInt(1);
  if (I < 0) or (I > High(FSubIntr)) or (S < 0) or (S > 31) then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_INTRCODE); Exit; end;
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

{ System memory }

procedure TPSPKernel.hAllocPartitionMemory;
begin
  var PartId := FHLE.ArgInt(0);
  var NamePtr := FHLE.Arg(1);
  var Kind := FHLE.ArgInt(2);
  var Size := FHLE.Arg(3);
  var Addr := FHLE.Arg(4);
  var P := Partition(PartId);
  if (P = nil) or (PartId = 1) then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_PARTITION); Exit; end;
  if (Kind < 0) or (Kind > 4) then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_MEMBLOCKTYPE); Exit; end;
  if NamePtr = 0 then
    begin FHLE.Result(SCE_KERNEL_ERROR_ERROR); Exit; end;
  if (Size = 0) or (Size > $7FFFFFFF) then
    begin FHLE.Result(SCE_KERNEL_ERROR_MEMBLOCK_ALLOC_FAILED); Exit; end;
  var Name := FMemory.ReadString(NamePtr, 31);
  var A: Cardinal := 0;
  case Kind of
    0: A := P.Alloc(Size, akLow, 0, 256, Name);
    1: A := P.Alloc(Size, akHigh, 0, 256, Name);
    2: A := P.Alloc(Size, akAddress, Addr, 256, Name);
    3, 4:
      begin
        if (Addr = 0) or ((Addr and (Addr - 1)) <> 0) then
          begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ALIGNMENT_SIZE); Exit; end;
        if Kind = 3 then
          A := P.Alloc(Size, akLow, 0, Addr, Name)
        else
          A := P.Alloc(Size, akHigh, 0, Addr, Name);
      end;
  end;
  if A = 0 then
    begin FHLE.Result(SCE_KERNEL_ERROR_MEMBLOCK_ALLOC_FAILED); Exit; end;
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
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_MEMBLOCK); Exit; end;
  Partition(B.PartitionId).FreeBlock(B.Address);
  DeleteObject(B);
  FHLE.Result(0);
end;

procedure TPSPKernel.hGetBlockHeadAddr;
begin
  var B := TPSPMemBlock(GetObject(FHLE.Arg(0), TPSPMemBlock));
  if B = nil then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_MEMBLOCK); Exit; end;
  FHLE.Result(B.Address);
end;

procedure TPSPKernel.hMaxFreeMemSize;
begin
  var N := FUserPartition.LargestFree;
  if N > 256 then
    Dec(N, 256);
  FHLE.Result(N);
end;

procedure TPSPKernel.hTotalFreeMemSize;
begin
  var N := FUserPartition.FreeTotal;
  if N > 256 then
    Dec(N, 256);
  FHLE.Result(N);
end;

procedure TPSPKernel.hDevkitVersion;
begin
  FHLE.Result($06060010);
end;

procedure TPSPKernel.hSetCompiledSdkVersion;
begin
  FCompiledSdkVersion := FHLE.Arg(0);
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
  FExitCallback := FHLE.Arg(0);
  FHLE.Result(0);
end;

procedure TPSPKernel.hVolatileMemLock;
begin
  if FHLE.Arg(1) <> 0 then
    FMemory.Write32(FHLE.Arg(1), $08400000);
  if FHLE.Arg(2) <> 0 then
    FMemory.Write32(FHLE.Arg(2), $00400000);
  FHLE.Result(0);
end;

procedure TPSPKernel.hVolatileMemTryLock;
begin
  hVolatileMemLock;
end;

procedure TPSPKernel.hVolatileMemUnlock;
begin
  FHLE.Result(0);
end;

procedure TPSPKernel.hReturnZero;
begin
  FHLE.Result(0);
end;

procedure TPSPKernel.RegisterAll;
const
  T = 'ThreadManForUser';
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
  H.Register(T, $EA748E31, 'sceKernelChangeCurrentThreadAttr', hChangeCurrentThreadAttr);
  H.Register(T, $57CF62DD, 'sceKernelGetThreadmanIdType', hGetThreadmanIdType);
  H.Register(T, $94416130, 'sceKernelGetThreadmanIdList', hGetThreadmanIdList);
  H.Register(T, $3AD58B8C, 'sceKernelSuspendDispatchThread', hSuspendDispatchThread);
  H.Register(T, $27E22EC2, 'sceKernelResumeDispatchThread', hResumeDispatchThread);
  H.Register(T, $627E6F3A, 'sceKernelReferSystemStatus', hReferSystemStatus);
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
  H.Register(T, $DB738F35, 'sceKernelGetSystemTime', hGetSystemTime);
  H.Register(T, $82BC5777, 'sceKernelGetSystemTimeWide', hGetSystemTimeWide);
  H.Register(T, $369ED59D, 'sceKernelGetSystemTimeLow', hGetSystemTimeLow);
  H.Register(T, $110DEC9A, 'sceKernelUSec2SysClock', hUSec2SysClock);
  H.Register(T, $C8CD158C, 'sceKernelUSec2SysClockWide', hUSec2SysClockWide);
  H.Register(T, $BA6B92E2, 'sceKernelSysClock2USec', hSysClock2USec);
  H.Register(T, $E1619D7C, 'sceKernelSysClock2USecWide', hSysClock2USecWide);
  H.Register('Kernel_Library', $092968F4, 'sceKernelCpuSuspendIntr', hCpuSuspendIntr);
  H.Register('Kernel_Library', $5F10D406, 'sceKernelCpuResumeIntr', hCpuResumeIntr);
  H.Register('Kernel_Library', $3B84732D, 'sceKernelCpuResumeIntrWithSync', hCpuResumeIntr);
  H.Register('Kernel_Library', $B55249D2, 'sceKernelIsCpuIntrEnable', hIsCpuIntrEnable);
  H.Register('Kernel_Library', $47A0B729, 'sceKernelIsCpuIntrSuspended', hIsCpuIntrSuspended);
  H.Register('InterruptManager', $CA04A2B9, 'sceKernelRegisterSubIntrHandler', hRegisterSubIntrHandler);
  H.Register('InterruptManager', $D61E6961, 'sceKernelReleaseSubIntrHandler', hReleaseSubIntrHandler);
  H.Register('InterruptManager', $FB8E22EC, 'sceKernelEnableSubIntr', hEnableSubIntr);
  H.Register('InterruptManager', $8A389411, 'sceKernelDisableSubIntr', hDisableSubIntr);
  H.Register('InterruptManager', $5CB5A78B, 'sceKernelSuspendSubIntr', hSuspendSubIntr);
  H.Register('InterruptManager', $7860E0DC, 'sceKernelResumeSubIntr', hResumeSubIntr);
  H.Register('InterruptManager', $FC4374B8, 'sceKernelIsSubInterruptOccurred', hIsSubInterruptOccurred);
  H.Register('InterruptManager', $EEE43F47, 'sceKernelRegisterUserSpaceIntrStack', hRegisterUserSpaceIntrStack);
  H.Register('SysMemUserForUser', $237DBD4F, 'sceKernelAllocPartitionMemory', hAllocPartitionMemory);
  H.Register('SysMemUserForUser', $B6D61D02, 'sceKernelFreePartitionMemory', hFreePartitionMemory);
  H.Register('SysMemUserForUser', $9D9A5BA1, 'sceKernelGetBlockHeadAddr', hGetBlockHeadAddr);
  H.Register('SysMemUserForUser', $A291F107, 'sceKernelMaxFreeMemSize', hMaxFreeMemSize);
  H.Register('SysMemUserForUser', $F919F628, 'sceKernelTotalFreeMemSize', hTotalFreeMemSize);
  H.Register('SysMemUserForUser', $3FC9AE6A, 'sceKernelDevkitVersion', hDevkitVersion);
  H.Register('SysMemUserForUser', $7591C7DB, 'sceKernelSetCompiledSdkVersion', hSetCompiledSdkVersion);
  H.Register('SysMemUserForUser', $FC114573, 'sceKernelGetCompiledSdkVersion', hGetCompiledSdkVersion);
  H.Register('SysMemUserForUser', $F77D77CB, 'sceKernelSetCompilerVersion', hSetCompilerVersion);
  H.Register('SysMemUserForUser', $13A5ABEF, 'sceKernelPrintf', hPrintf);
  for var NID in [Cardinal($342061E5), $315AD3A0, $EBD5C3E6, $057E7380, $91DE343C, $7893F79A, $35669D4C,
    $1B4217BC, $358CA1BB] do
    H.Register('SysMemUserForUser', NID, Format('sceKernelSetCompiledSdkVersion_%.8X', [NID]), hSetCompiledSdkVersion);
  H.Register('LoadExecForUser', $05572A5F, 'sceKernelExitGame', hExitGame);
  H.Register('LoadExecForUser', $2AC9954B, 'sceKernelExitGameWithStatus', hExitGame);
  H.Register('LoadExecForUser', $4AC57943, 'sceKernelRegisterExitCallback', hRegisterExitCallback);
  H.Register('sceSuspendForUser', $3E0271D3, 'sceKernelVolatileMemLock', hVolatileMemLock);
  H.Register('sceSuspendForUser', $A14F40B2, 'sceKernelVolatileMemTryLock', hVolatileMemTryLock);
  H.Register('sceSuspendForUser', $A569E425, 'sceKernelVolatileMemUnlock', hVolatileMemUnlock);
  H.Register('sceSuspendForUser', $EADB1BD7, 'sceKernelPowerLock', hReturnZero);
  H.Register('sceSuspendForUser', $3AEE7261, 'sceKernelPowerUnlock', hReturnZero);
  H.Register('sceSuspendForUser', $090CCB3F, 'sceKernelPowerTick', hReturnZero);
end;
