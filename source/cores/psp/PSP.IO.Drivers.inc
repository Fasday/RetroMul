{ PSP.IO: guest file drivers (IoFileMgrForKernel). }

procedure TPSPIO.hAddDrv;
begin
  if FKernel.InInterrupt then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_CONTEXT); Exit; end;
  var Table := FHLE.Arg(0);
  var Name := FMemory.ReadString(FMemory.Read32(Table), 32).ToLower;
  if (Name = '') or FDrivers.ContainsKey(Name) then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ARGUMENT); Exit; end;
  var Arg := FKernel.AllocKernel(8, 'io driver:' + Name);
  if Arg = 0 then
    begin FHLE.Result(SCE_KERNEL_ERROR_NO_MEMORY); Exit; end;
  var D := Default(TPSPIoDriver);
  D.Arg := Arg;
  D.Funcs := FMemory.Read32(Table + 16);
  D.GP := FHLE.CPU.Ctx.GPR[28];
  FMemory.Write32(Arg, Table);
  FMemory.Write32(Arg + 4, 0);
  FDrivers.Add(Name, D);
  FHLE.Result(0);
  var Init := FMemory.Read32(D.Funcs);
  if Init <> 0 then
    // Even an init returning -1 leaves the driver installed (io/iodrv).
    FKernel.CallGuest(Init, [Arg], nil, D.GP);
end;

procedure TPSPIO.hDelDrv;
begin
  if FKernel.InInterrupt then
    begin FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_CONTEXT); Exit; end;
  var Name := FMemory.ReadString(FHLE.Arg(0), 32).ToLower;
  var D: TPSPIoDriver;
  if not FDrivers.TryGetValue(Name, D) then
    begin FHLE.Result(SCE_KERNEL_ERROR_NODEV); Exit; end;
  for var F in FFiles.Values do
    if (F.GuestArg <> 0) and (FMemory.Read32(F.GuestArg + 8) = D.Arg) then
      begin FHLE.Result(SCE_KERNEL_ERROR_ASYNC_BUSY); Exit; end;
  FDrivers.Remove(Name);
  var K := FKernel;
  var ExitFunc := FMemory.Read32(D.Funcs + 4);
  FHLE.Result(0);
  if ExitFunc <> 0 then
    K.CallGuest(ExitFunc, [D.Arg],
      procedure(Ret: Cardinal)
      begin
        K.KernelPartition.FreeBlock(D.Arg);
      end, D.GP)
  else
    K.KernelPartition.FreeBlock(D.Arg);
end;

function TPSPIO.OpenGuestDriver(const Path: string; Flags, Mode: Cardinal): Boolean;
begin
  Result := False;
  if FDrivers.Count = 0 then
    Exit;
  var Device, Rest: string;
  if not Split(Resolve(Path), Device, Rest) then
    Exit;
  var Number: Cardinal := 0;
  var P := Length(Device);
  while (P > 0) and CharInSet(Device[P], ['0'..'9']) do
    Dec(P);
  if P < Length(Device) then
  begin
    Number := Cardinal(StrToIntDef(Device.Substring(P), 0));
    Device := Device.Substring(0, P);
  end;
  var D: TPSPIoDriver;
  if not FDrivers.TryGetValue(Device, D) then
    Exit;
  Result := True;
  if FKernel.RefuseWait then
    Exit;
  var OpenFunc := FMemory.Read32(D.Funcs + 8);
  if OpenFunc = 0 then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNSUP); Exit; end;
  var FileName := RawByteString(Rest.TrimStart(['/']));
  var Arg := FKernel.AllocKernel($20 + Cardinal(Length(FileName)) + 1, 'io file:' + Device);
  if Arg = 0 then
    begin FHLE.Result(SCE_KERNEL_ERROR_NO_MEMORY); Exit; end;
  FMemory.Fill(Arg, 0, $20);
  FMemory.Write32(Arg, Flags);
  FMemory.Write32(Arg + 4, Number);
  FMemory.Write32(Arg + 8, D.Arg);
  FMemory.Write32(Arg + 12, FMemory.Read32(FMemory.Read32(D.Arg) + 4));
  FMemory.WriteString(Arg + $20, FileName, Length(FileName) + 1);
  var F := TPSPOpenFile.Create;
  F.Id := AllocFd;
  F.Path := Path;
  F.Flags := Flags;
  F.GuestArg := Arg;
  F.GuestFuncs := D.Funcs;
  F.GuestGP := D.GP;
  FFiles.Add(F.Id, F);
  var IO := Self;
  // IoOpen sees the access mask, with create granting read/write access.
  var Access := Flags and 3;
  if (Flags and PSP_O_CREAT) <> 0 then
    Access := Access or 5;
  FKernel.CallGuest(OpenFunc, [Arg, Arg + $20, Access, Mode],
    procedure(Ret: Cardinal)
    begin
      if Integer(Ret) < 0 then
      begin
        IO.FFiles.Remove(F.Id);
        IO.FKernel.KernelPartition.FreeBlock(Arg);
        F.Free;
        IO.FHLE.Result(Ret);
      end
      else
        IO.FHLE.Result(Cardinal(F.Id));
    end, D.GP);
end;

function TPSPIO.CallFileDriver(F: TPSPOpenFile; Slot: Integer; const Args: array of Cardinal): Boolean;
begin
  Result := F.GuestArg <> 0;
  if not Result then
    Exit;
  var Func := FMemory.Read32(F.GuestFuncs + Cardinal(Slot) * 4);
  if Func = 0 then
    begin FHLE.Result(SCE_KERNEL_ERROR_UNSUP); Exit; end;
  if FKernel.RefuseWait then
    Exit;
  var Data: TArray<Cardinal>;
  SetLength(Data, Length(Args) + 1);
  Data[0] := F.GuestArg;
  for var I := 0 to High(Args) do
    Data[I + 1] := Args[I];
  var IO := Self;
  FKernel.CallGuest(Func, Data,
    procedure(Ret: Cardinal)
    begin
      IO.FHLE.Result(Ret);
      if (Slot = 3) and (Ret = 0) then
      begin
        IO.FFiles.Remove(F.Id);
        IO.FKernel.KernelPartition.FreeBlock(F.GuestArg);
        F.Free;
      end;
    end, F.GuestGP);
end;
