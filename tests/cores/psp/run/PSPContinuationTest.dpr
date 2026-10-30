program PSPContinuationTest;

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.IOUtils, System.Hash,
  Core.Emulation.Types, PSP.Console, PSP.Media, PSP.GE, PSP.Kernel, PSP.Scheduler, PSP.Types;

const
  Entry = $08804000;
  Code = $09F00000;
  Globals = $09F10000;
  Params = $09F10100;
  ErrWord = $09F10200;
  Image = $09F10300;
  Pixels = $09F11000;
  Heap = $09000000;
  FileData = $09400000;

procedure Require(OK: Boolean; const Text: string);
begin if not OK then raise Exception.Create(Text); end;

function OpI(Op, RS, RT: Cardinal; Imm: Integer): Cardinal;
begin Result := (Op shl 26) or (RS shl 21) or (RT shl 16) or (Cardinal(Imm) and $FFFF); end;

function OpR(RS, RT, RD, Func: Cardinal): Cardinal;
begin Result := (RS shl 21) or (RT shl 16) or (RD shl 11) or Func; end;

function ProgramData: TPSPProgram;
  procedure W16(P: Integer; V: Word);
  begin Move(V, Result.Executable[P], 2); end;
  procedure W32(P: Integer; V: Cardinal);
  begin Move(V, Result.Executable[P], 4); end;
begin
  Result := Default(TPSPProgram);
  SetLength(Result.Executable, $110);
  W32(0, $464C457F); Result.Executable[4] := 1; Result.Executable[5] := 1; Result.Executable[6] := 1;
  W16(16, 2); W16(18, 8); W32(20, 1); W32(24, Entry); W32(28, 52);
  W16(40, 52); W16(42, 32); W16(44, 1);
  W32(52, 1); W32(56, $100); W32(60, Entry); W32(68, 16); W32(72, 16); W32(76, 5); W32(80, $1000);
  W32($100, (2 shl 26) or ((Entry shr 2) and $03FFFFFF));
end;

procedure Emit(C: TPSPConsole; Address: Cardinal; const Words: array of Cardinal);
begin
  for var I := 0 to High(Words) do C.Memory.Write32(Address + Cardinal(I * 4), Words[I]);
end;

procedure CopyRoutine(C: TPSPConsole; Address: Cardinal; FontRead: Boolean);
begin
  var W: TArray<Cardinal> := nil;
  if FontRead then
    W := [OpR(7, 8, 0, $19), OpR(0, 0, 11, $12), OpR(8, 0, 2, $21), OpR(6, 0, 13, $21), OpI($2B, 9, 0, 0)]
  else W := [OpR(6, 0, 11, $21), OpR(6, 0, 2, $21), OpR(5, 0, 13, $21)];
  W := W + [OpI($23, 4, 10, 4), OpI($23, 4, 12, 8), OpR(12, 10, 12, $21),
    OpR(10, 11, 10, $21), OpI($2B, 4, 10, 4)];
  var Loop := Length(W);
  W := W + [OpI(4, 11, 0, 8), 0, OpI($24, 12, 14, 0), OpI($28, 13, 14, 0),
    OpI(9, 12, 12, 1), OpI(9, 13, 13, 1), OpI(9, 11, 11, -1)];
  W := W + [OpI(4, 0, 0, Loop - (Length(W) + 1)), 0, $03E00008, 0];
  Emit(C, Address, W);
end;

function CreateConsole(const P: TPSPProgram; const Root: string): TPSPConsole;
begin
  Result := TPSPConsole.Create(P, nil, Root, TPath.Combine(Root, 'ms'));
  Result.Memory.Write32(Globals, Heap);
  Emit(Result, Code, [OpI($23, 4, 2, 0), OpI(9, 5, 8, 15), OpI(9, 0, 9, -16),
    OpR(8, 9, 8, $24), OpR(2, 8, 8, $21), OpI($2B, 4, 8, 0), $03E00008, 0]);
  Emit(Result, Code + $40, [OpI($23, 4, 8, 28), OpI(9, 8, 8, 1), OpI($2B, 4, 8, 28),
    OpR(0, 0, 2, $21), $03E00008, 0]);
  Emit(Result, Code + $80, [OpI($2B, 6, 0, 0), OpI($2B, 4, 0, 4), OpI(9, 0, 2, 1), $03E00008, 0]);
  Emit(Result, Code + $C0, [OpI($2B, 4, 6, 4), OpR(0, 0, 2, $21), $03E00008, 0]);
  CopyRoutine(Result, Code + $100, True);
  Emit(Result, Code + $180, [OpR(5, 0, 2, $21), $03E00008, 0]);
  // MP4 seek(0, END) reads the size; seek(0, SET) resets the cursor.
  Emit(Result, Code + $1C0, [OpI(4, 8, 0, 4), 0, OpI($23, 4, 2, 12), $03E00008, 0,
    OpI($2B, 4, 0, 4), OpR(0, 0, 2, $21), $03E00008, 0]);
  CopyRoutine(Result, Code + $200, False);
  // A one-shot allocator fault on the second request, for rollback coverage.
  Emit(Result, Code + $300, [OpI($23, 4, 8, 24), OpI(9, 8, 8, 1), OpI($2B, 4, 8, 24),
    OpI(9, 0, 9, 2), OpI(4, 8, 9, 3), 0, (2 shl 26) or ((Code shr 2) and $03FFFFFF), 0,
    OpR(0, 0, 2, $21), $03E00008, 0]);
end;

function Call(C: TPSPConsole; const Name: string; const Args: array of Cardinal): Cardinal;
begin
  for var I := 0 to High(Args) do C.CPU.Ctx.GPR[4 + I] := Args[I];
  var Found := False;
  for var I := 0 to C.HLE.Count - 1 do
    if C.HLE.FunctionInfo(I).Name = Name then
    begin C.HLE.Call(I); Found := True; Break; end;
  Require(Found, 'Missing HLE ' + Name);
  Result := C.CPU.Ctx.GPR[2];
end;

function Digest(C: TPSPConsole): string;
begin
  TPSPGE(C.System.Find(TPSPGE)).Engine.Synchronize;
  var H := THashSHA2.Create;
  H.Update(C.Memory.RAM); H.Update(C.Memory.VRAM); H.Update(C.Memory.Scratch);
  H.Update(C.CPU.Ctx, SizeOf(C.CPU.Ctx)); H.Update(C.Scheduler.Now, SizeOf(C.Scheduler.Now));
  var Samples := C.AudioSamples;
  if Length(Samples) > 0 then H.Update(Samples[0], Length(Samples) * 2);
  Result := H.HashAsString;
end;

procedure Checkpoint(C: TPSPConsole; const Root, Name: string; Frames: Integer = 4);
begin
  var Before := Digest(C);
  var Path := TPath.Combine(Root, 'callback.snapshot');
  C.SaveSnapshot(Path);
  Require(C.LastSnapshotFormat = 'direct', 'Not a direct callback state');
  var Cancelled := False;
  try
    var Aborted := C.RestoreSnapshot(Path,
      function(Done, Total: UInt64): Boolean begin Result := Done < 3; end);
    Aborted.Free;
  except on EAbort do Cancelled := True; end;
  Require(Cancelled and (Digest(C) = Before), 'Cancellation changed active callback: ' + Name);
  var D := C.RestoreSnapshot(Path);
  try
    Require(Digest(D) = Before, 'Callback state differs before continuation: ' + Name);
    var F: TEmulatorFrame;
    for var I := 1 to Frames do
    begin
      C.RunFrame(F); D.RunFrame(F);
      Require(Digest(C) = Digest(D), 'Callback continuation differs: ' + Name);
    end;
  finally D.Free; end;
  Writeln('PASS active ', Name);
end;

procedure AdvanceTo(C: TPSPConsole; PC: Cardinal);
begin
  for var I := 0 to 200000 do
  begin
    if C.CPU.Ctx.PC = PC then Exit;
    C.RunUntil(C.Scheduler.Now + 1);
  end;
  raise Exception.CreateFmt('Callback PC %.8x was not reached', [PC]);
end;

procedure FontCases(const P: TPSPProgram; const Root: string);
begin
  var C := CreateConsole(P, Root);
  try
    C.Memory.Fill(Params, 0, $2C);
    C.Memory.Write32(Params, Globals); C.Memory.Write32(Params + 4, 4);
    C.Memory.Write32(Params + $0C, Code); C.Memory.Write32(Params + $10, Code + $40);
    C.Memory.Write32(Params + $14, Code + $80); C.Memory.Write32(Params + $18, Code + $40);
    C.Memory.Write32(Params + $1C, Code + $100); C.Memory.Write32(Params + $20, Code + $C0);
    Call(C, 'sceFontNewLib', [Params, ErrWord]);
    Require(C.Kernel.Current.Frames.Count > 0, 'Allocator callback is not active');
    Checkpoint(C, Root, 'font library allocator');
    var Lib := C.CPU.Ctx.GPR[2]; Require(Lib = Heap, 'Wrong library address');
    Call(C, 'sceFontOpen', [Lib, 0, 0, ErrWord]);
    Checkpoint(C, Root, 'font table allocations');
    var Font := C.CPU.Ctx.GPR[2];
    C.Memory.Fill(Image, 0, 24); C.Memory.Write32(Image, 2);
    C.Memory.Write16(Image + 12, 64); C.Memory.Write16(Image + 14, 64);
    C.Memory.Write16(Image + 16, 64); C.Memory.Write32(Image + 20, Pixels);
    Call(C, 'sceFontGetCharGlyphImage', [Font, Ord('H'), Image]);
    Checkpoint(C, Root, 'font glyph cache allocation');
    Call(C, 'sceFontGetCharGlyphImage', [Font, Ord('W'), Image]);
    Checkpoint(C, Root, 'font glyph cache free/reallocation');
    Call(C, 'sceFontClose', [Font]); Checkpoint(C, Root, 'font close free callback');
    C.Memory.Write32(Lib + $0C, Code + $300); C.Memory.Write32(Globals + 24, 0);
    var Freed := C.Memory.Read32(Globals + 28);
    Call(C, 'sceFontOpen', [Lib, 1, 0, ErrWord]);
    Checkpoint(C, Root, 'font allocation failure rollback');
    Require((C.Memory.Read32(ErrWord) <> 0) and (C.Memory.Read32(Globals + 28) > Freed),
      'Partial font allocations were not freed');
    C.Memory.Write32(Lib + $0C, Code);
    if ParamCount > 0 then
    begin
      var Data := TFile.ReadAllBytes(ParamStr(1));
      TFile.WriteAllBytes(TPath.Combine(Root, 'font.pgf'), Data);
      C.Memory.WriteBytes(FileData, Data[0], Length(Data));
      C.Memory.Write32(Globals + 8, FileData); C.Memory.Write32(Globals + 12, Length(Data));
      C.Memory.WriteString(Params + $80, 'host0:/font.pgf', 128);
      Call(C, 'sceFontOpenUserFile', [Lib, Params + $80, 0, ErrWord]);
      Checkpoint(C, Root, 'font streamed open callback', 0);
      AdvanceTo(C, Code + $100); Checkpoint(C, Root, 'font prefix read callback', 0);
      C.RunUntil(C.Scheduler.Now + 1);
      AdvanceTo(C, Code + $100); Checkpoint(C, Root, 'font header body read callback', 0);
      C.RunUntil(C.Scheduler.Now + 1);
      AdvanceTo(C, Code + $100);
      Checkpoint(C, Root, 'font allocated table read/close chain', 12);
      Require(C.Memory.Read32(ErrWord) = 0, 'Streamed PGF open failed');
      Call(C, 'sceFontOpenUserMemory', [Lib, FileData, Cardinal(Length(Data)), ErrWord]);
      Checkpoint(C, Root, 'owned PGF pending allocation');
      Require(C.Memory.Read32(ErrWord) = 0, 'Memory PGF open failed');
      C.Memory.WriteBytes(FileData + $200000, Data[0], Length(Data));
      C.Memory.Write32(Lib + $0C, Code + $40);
      Call(C, 'sceFontOpenUserMemory', [Lib, FileData + $200000, Cardinal(Length(Data)), ErrWord]);
      Checkpoint(C, Root, 'owned PGF allocation failure/cancel cleanup');
      Require(C.Memory.Read32(ErrWord) <> 0, 'Faulting allocator did not reject memory font');
      C.Memory.Write32(Lib + $0C, Code);
    end;
    Call(C, 'sceFontDoneLib', [Lib]); Checkpoint(C, Root, 'font library cleanup');
  finally C.Free; end;
end;

procedure LoaderAndDriverCases(const P: TPSPProgram; const Root: string);
begin
  var C := CreateConsole(P, Root);
  try
    // A local second ELF with a returning entry, never a patched game image.
    var Module := Copy(P.Executable);
    PCardinal(@Module[24])^ := Entry + $10000;
    PCardinal(@Module[60])^ := Entry + $10000;
    PCardinal(@Module[$100])^ := $03E00008;
    PCardinal(@Module[$104])^ := OpR(0, 0, 2, $21);
    TFile.WriteAllBytes(TPath.Combine(Root, 'module.elf'), Module);
    C.Memory.WriteString(Params, 'host0:/module.elf', 128);
    Call(C, 'sceKernelLoadModule', [Params, 0, 0]);
    Checkpoint(C, Root, 'delayed module loader');
    var Id := C.CPU.Ctx.GPR[2];
    Require(Id < $80000000, 'Fixture module did not load');
    Call(C, 'sceKernelStartModule', [Id, 0, 0, ErrWord, 0]);
    Checkpoint(C, Root, 'module start/exit/delete/wake chain');
    Require(C.Memory.Read32(ErrWord) = 0, 'Fixture module returned an error');
    Call(C, 'sceKernelStopModule', [Id, 0, 0, ErrWord, 0]);
    for var I := 0 to 1 do
      Emit(C, Code + $500 + Cardinal(I * $40), [OpI($0F, 0, 8, Globals shr 16),
        OpI($0D, 8, 8, Globals and $FFFF), OpI(9, 0, 9, 1), OpI($2B, 8, 9, 36 + I * 4),
        OpR(0, 0, 2, $21), $03E00008, 0]);
    C.Memory.Write32(Globals + 36, 0); C.Memory.Write32(Globals + 40, 0);
    var Lower := C.Kernel.CreateThread('unload lower', Code + $500,
      C.Kernel.Current.Priority + 1, $1000, $80000000, 0);
    var Equal := C.Kernel.CreateThread('unload equal', Code + $540,
      C.Kernel.Current.Priority, $1000, $80000000, 0);
    Require((Lower <> nil) and (Equal <> nil), 'Unload probe thread allocation failed');
    Equal.DeleteOnExit := True;
    C.Kernel.StartThread(Lower, 0, 0); C.Kernel.StartThread(Equal, 0, 0);
    Call(C, 'sceKernelUnloadModule', [Id]);
    Require((C.Kernel.Current.BusyNs > 0) and not C.Kernel.Current.IsWaiting,
      'Module unload was modeled as a wait instead of preemptible CPU work');
    Checkpoint(C, Root, 'preemptible module-unload CPU tail');
    Require((C.Memory.Read32(Globals + 36) = 0) and (C.Memory.Read32(Globals + 40) = 1),
      'Unload completion lost its equal-priority handoff or donated time to a lower thread');
    C.Kernel.TerminateThread(Lower, 0); C.Kernel.DeleteThread(Lower);
    C.Memory.Fill(Params, 0, $80);
    C.Memory.WriteString(Params + $80, 'state', 16);
    C.Memory.Write32(Params, Params + $80); C.Memory.Write32(Params + 16, Params + $20);
    C.Memory.Write32(Params + $24, Code + $40); // exit
    C.Memory.Write32(Params + $28, Code + $40); // open
    C.Memory.Write32(Params + $2C, Code + $40); // close
    Call(C, 'sceIoAddDrv', [Params]);
    C.Memory.WriteString(Params + $A0, 'state0:/data', 32);
    Call(C, 'sceIoOpen', [Params + $A0, 1, 0]);
    Require(C.Kernel.Current.Frames.Count > 0, 'Guest driver open callback is not active');
    Checkpoint(C, Root, 'guest IO driver open');
    var Fd := C.CPU.Ctx.GPR[2];
    Call(C, 'sceIoClose', [Fd]);
    Require(C.Kernel.Current.Frames.Count > 0, 'Guest driver close callback is not active');
    Checkpoint(C, Root, 'guest IO driver close');
    Call(C, 'sceIoDelDrv', [Params + $80]);
    Require(C.Kernel.Current.Frames.Count > 0, 'Guest driver exit callback is not active');
    Checkpoint(C, Root, 'guest IO driver exit');
  finally C.Free; end;
end;

procedure NetworkAndUtilityCases(const P: TPSPProgram; const Root: string);
begin
  var C := CreateConsole(P, Root);
  try
    Call(C, 'sceNetInetInit', []);
    var Fd := Call(C, 'sceNetInetSocket', [2, 2, 0]);
    C.Memory.Write32(Params, 100000);
    Call(C, 'sceNetInetSetsockopt', [Fd, $FFFF, $1006, Params, 4]);
    Call(C, 'sceNetInetRecv', [Fd, Pixels, 16, 0]);
    Require(C.Kernel.Current.IsWaiting, 'Socket waiter is not active');
    Checkpoint(C, Root, 'socket receive attempt/timeout', 12);
    Call(C, 'sceNetApctlInit', [$1000, 20]);
    Call(C, 'sceNetApctlScanUser', []);
    Checkpoint(C, Root, 'network library queued job and scan timer');
    C.Memory.Fill(Params, 0, $300); C.Memory.Write32(Params, $244);
    Call(C, 'sceUtilityMsgDialogInitStart', [Params]);
    Checkpoint(C, Root, 'utility initialization timer');
  finally C.Free; end;
end;

procedure MediaCases(const P: TPSPProgram; const Root: string);
begin
  var C := CreateConsole(P, Root);
  try
    Call(C, 'sceMpegRingbufferConstruct', [Params, 4, FileData, $10000, Code + $180, 0]);
    C.Memory.Write32(Params + 8, 3);
    Call(C, 'sceMpegRingbufferPut', [Params, 2, 4]);
    Checkpoint(C, Root, 'MPEG ringbuffer wrap callbacks');
    Require(C.Memory.Read32(Params + 8) = 1, 'Ringbuffer wrap failed');
    C.Memory.Write32(FileData, $10000000); C.Memory.Write32(FileData + 4, $65657266);
    C.Memory.Write32(Globals + 8, FileData); C.Memory.Write32(Globals + 12, 16);
    C.Memory.Write32(Params + $80, Globals); C.Memory.Write32(Params + $88, Code + $1C0);
    C.Memory.Write32(Params + $8C, Code + $200);
    Call(C, 'sceMp4Create', [Params + $40, Params + $80, Pixels, 7]);
    Checkpoint(C, Root, 'MP4 seek/end/start and chunk reads');
    Require(C.Memory.Read32(Globals + 4) = 16, 'MP4 did not finish chunked reading');
  finally C.Free; end;
end;

procedure FatCases(const P: TPSPProgram; const Root: string);
  function FileCall(C: TPSPConsole; const Name: string; const Args: array of Cardinal): Cardinal;
  begin
    Call(C, Name, Args);
    C.Kernel.AfterSyscall;
    C.RunUntil(C.Scheduler.Now + 100000);
    Result := C.CPU.Ctx.GPR[2];
  end;
  procedure OpenClose(C: TPSPConsole; const Path: RawByteString; Flags: Cardinal);
  begin
    C.Memory.WriteString(Params, Path, 256);
    var Fd := FileCall(C, 'sceIoOpen', [Params, Flags, $1FF]);
    Require(Fd < $80000000, 'FAT open failed: ' + string(Path) + ' ' + IntToHex(Fd, 8));
    Require(FileCall(C, 'sceIoClose', [Fd]) = 0, 'FAT close failed');
  end;
begin
  var C := CreateConsole(P, Root);
  var D: TPSPConsole := nil;
  try
    C.RunUntil(C.Scheduler.Now + 10000000);
    OpenClose(C, 'ms0:/LongFileName.txt', $602);
    OpenClose(C, 'ms0:/LongFileName2.txt', $602);
    TDirectory.SetLastWriteTime(Root, EncodeDate(2009, 1, 1));
    TDirectory.SetLastWriteTime(TPath.Combine(Root, 'ms'), EncodeDate(2011, 2, 3));
    C.Memory.WriteString(Params, 'ms0:/', 256);
    var Fd := FileCall(C, 'sceIoDopen', [Params]);
    C.Memory.Fill(Pixels, 0, $1000);
    C.Memory.Write32(Pixels + $158, Pixels + $400);
    C.Memory.Write32(Pixels + $400, 1044);
    Require(FileCall(C, 'sceIoDread', [Fd, Pixels]) = 1, 'FAT directory read failed');
    Require(C.Memory.ReadString(Pixels + $400, 13) = '.', 'Old FAT private layout failed');
    Require(C.Memory.Read16(Pixels + 16) = 2011, 'Dot directory timestamp was not populated');
    var Path := TPath.Combine(Root, 'fat.snapshot');
    C.SaveSnapshot(Path);
    D := C.RestoreSnapshot(Path);
    OpenClose(D, 'ms0:/LONGFI~1.TXT', 1);
    OpenClose(D, 'ms0:/longfi~2.txt', 1);
    D.Memory.Fill(Pixels, 0, $1000);
    D.Memory.Write32(Pixels + $158, Pixels + $400);
    D.Memory.Write32(Pixels + $400, 1044);
    Call(D, 'sceKernelSetCompiledSdkVersion', [$06060010]);
    Require(FileCall(D, 'sceIoDread', [Fd, Pixels]) = 1, 'Restored FAT enumeration failed');
    Require((D.Memory.Read32(Pixels + $400) = 1044) and
      (D.Memory.ReadString(Pixels + $404, 16) = '..') and
      (D.Memory.ReadString(Pixels + $414, 1024) = '..'), 'Modern FAT private layout failed');
    Require(D.Memory.Read16(Pixels + 16) = 2011, 'Parent timestamp escaped the mounted root');
    FileCall(D, 'sceIoDclose', [Fd]);
    D.Memory.WriteString(Params, 'ms0:/LONGFI~1.TXT', 256);
    Require(FileCall(D, 'sceIoRemove', [Params]) = 0, 'FAT alias deletion failed');
    OpenClose(D, 'ms0:/LongFileName3.txt', $602);
    OpenClose(D, 'ms0:/LONGFI~1.TXT', 1);
    D.Memory.WriteString(Params, 'ms0:/LongDirectoryName', 256);
    Require(FileCall(D, 'sceIoMkdir', [Params, $1FF]) = 0, 'FAT directory creation failed');
    OpenClose(D, 'ms0:/LongDirectoryName/LongFileName.txt', $602);
    D.Memory.WriteString(Params, 'ms0:/LongDirectoryName', 256);
    D.Memory.WriteString(Params + $100, 'RenamedDirectory', 256);
    Require(FileCall(D, 'sceIoRename', [Params, Params + $100]) = 0, 'FAT directory rename failed');
    OpenClose(D, 'ms0:/RENAME~1/LONGFI~1.TXT', 1);
    Writeln('PASS FAT aliases/private layouts, pending enumeration state, reuse and directory rename');
  finally D.Free; C.Free; end;
end;

procedure AsyncIOCases(const P: TPSPProgram; const Root: string);
  function ReadShared(const Name: string): string;
  begin
    var S := TFileStream.Create(Name, fmOpenRead or fmShareDenyNone);
    try
      var Bytes: TBytes;
      SetLength(Bytes, S.Size);
      if Length(Bytes) <> 0 then S.ReadBuffer(Bytes[0], Length(Bytes));
      Result := TEncoding.ASCII.GetString(Bytes);
    finally S.Free; end;
  end;
  procedure Await(C: TPSPConsole; Fd: Cardinal);
  begin
    Call(C, 'sceIoWaitAsync', [Fd, ErrWord]);
    C.Kernel.AfterSyscall;
    C.RunUntil(C.Scheduler.Now + 1000000);
    Require(C.CPU.Ctx.GPR[2] = 0, 'Asynchronous IO wait failed');
  end;
  function WorkerCount(C: TPSPConsole): Integer;
  begin
    Result := 0;
    for var T in C.Kernel.Threads do if T.Name = 'SceIofileAsync' then Inc(Result);
  end;
begin
  var Host := TPath.Combine(Root, 'async-host');
  TDirectory.CreateDirectory(Host);
  var Source := TPath.Combine(Host, 'data.bin');
  TFile.WriteAllText(Source, 'DATA', TEncoding.ASCII);
  var C := CreateConsole(P, Host);
  try
    C.RunUntil(C.Scheduler.Now + 10000000);
    C.Memory.WriteString(Params, 'host0:/data.bin', 128);
    var Fd := Call(C, 'sceIoOpenAsync', [Params, 3, 0]);
    Require((Fd < $80000000) and (WorkerCount(C) = 1), 'Asynchronous file worker was not created');
    Require(Call(C, 'sceIoPollAsync', [Fd, ErrWord]) = 1, 'Queued open completed without its worker');
    Checkpoint(C, Root, 'queued asynchronous file open', 0);
    Await(C, Fd);
    Require(C.Memory.Read32(ErrWord) = Fd, 'Async open did not return its descriptor');
    Require(Call(C, 'sceIoPollAsync', [Fd, ErrWord]) = $8002032A, 'A waited result was not consumed');

    for var Priority in [0, 7, 120, 126, 127] do
      Require(Call(C, 'sceIoChangeAsyncPriority', [Fd, Cardinal(Priority)]) = $80020193,
        'User async priority boundary was accepted');
    for var Priority in [8, 119] do
      Require(Call(C, 'sceIoChangeAsyncPriority', [Fd, Cardinal(Priority)]) = 0,
        'Valid user async priority was rejected');
    var CallerThread := C.Kernel.Current;
    var Attr := CallerThread.Attr;
    CallerThread.Attr := 0;
    try
      for var Priority in [1, 126] do
        Require(Call(C, 'sceIoChangeAsyncPriority', [Fd, Cardinal(Priority)]) = 0,
          'Valid kernel async priority was rejected');
      Require(Call(C, 'sceIoChangeAsyncPriority', [Fd, 127]) = $80020193,
        'Kernel async priority 127 was accepted');
    finally CallerThread.Attr := Attr; end;

    Require(Call(C, 'sceIoChangeAsyncPriority', [Fd, $10]) = 0, 'Async priority change failed');
    C.Memory.Fill(Pixels, $CC, 16);
    Require(Call(C, 'sceIoReadAsync', [Fd, Pixels, 4]) = 0, 'Async read submission failed');
    Require(C.Memory.Read32(Pixels) = $CCCCCCCC, 'Read data changed before its worker ran');
    C.Kernel.AfterSyscall;
    C.RunUntil(C.Scheduler.Now + 10000);
    Require(C.Memory.Read32(Pixels) = $CCCCCCCC, 'Read data changed before transfer completion');
    Checkpoint(C, Root, 'asynchronous read worker in transfer wait');
    Require(C.Memory.Read32(Pixels) = $41544144, 'Async read did not transfer the requested bytes');
    Checkpoint(C, Root, 'completed asynchronous result before collection', 0);
    Require(Call(C, 'sceIoPollAsync', [Fd, ErrWord]) = 0, 'Ready async read result could not be collected');
    Require(C.Memory.Read32(ErrWord) = 4, 'Async read returned the wrong count');
    Require(Call(C, 'sceIoPollAsync', [Fd, ErrWord]) = $8002032A, 'Polled async result was not consumed');

    Require(Call(C, 'sceIoLseek32Async', [Fd, 1, 0]) = 0, 'Async seek submission failed');
    Await(C, Fd);
    Require(C.Memory.Read32(ErrWord) = 1, 'Async seek returned the wrong offset');
    C.Memory.WriteString(Pixels, 'XY', 3);
    Require(Call(C, 'sceIoWriteAsync', [Fd, Pixels, 2]) = 0, 'Async write submission failed');
    Checkpoint(C, Root, 'queued asynchronous write and cancellation', 0);
    Require(ReadShared(Source) = 'DATA', 'Queued/restored write touched live data');
    Await(C, Fd);
    Require((C.Memory.Read32(ErrWord) = 2) and
      (ReadShared(Source) = 'DXYA'), 'Deferred async write failed');
    Require(Call(C, 'sceIoWriteAsync', [Fd, Pixels, $FFFFFFFF]) = 0, 'Bad-buffer async submission failed');
    Await(C, Fd);
    Require((C.Memory.Read32(ErrWord) = $800200D3) and
      (ReadShared(Source) = 'DXYA'), 'Invalid async buffer allocated or wrote host data');

    Require(Call(C, 'sceIoLseek32Async', [Fd, 0, 0]) = 0, 'Callback-case seek failed');
    Await(C, Fd);
    var DelayIndex := C.HLE.Find('ThreadManForUser', $CEADEB47);
    Require(DelayIndex >= 0, 'Missing callback delay syscall');
    Emit(C, Code + $400, [OpI(9, 0, 4, 500), (Cardinal(DelayIndex) shl 6) or $0C,
      OpI($0F, 0, 8, Globals shr 16), OpI($0D, 8, 8, Globals and $FFFF),
      OpI(9, 0, 9, 1), OpI($2B, 8, 9, 32), OpR(0, 0, 2, $21), $03E00008, 0]);
    C.Memory.Write32(Globals + 32, 0);
    C.Memory.WriteString(Params, 'async result callback', 128);
    var CB := Call(C, 'sceKernelCreateCallback', [Params, Code + $400, Globals]);
    Require(CB < $80000000, 'IO callback creation failed');
    Require(Call(C, 'sceIoReadAsync', [Fd, Pixels, 4]) = 0, 'Callback-case read failed');
    Call(C, 'sceKernelNotifyCallback', [CB, 0]);
    var Caller := C.Kernel.Current.UID;
    Call(C, 'sceIoWaitAsyncCB', [Fd, ErrWord]);
    C.Kernel.AfterSyscall;
    C.RunUntil(C.Scheduler.Now + 20000);
    Require(C.Kernel.ThreadById(Caller).Frames.Count > 0, 'IO callback wait frame was not retained');
    Checkpoint(C, Root, 'async result completing while its caller waits inside a callback');
    Require((C.Memory.Read32(Globals + 32) = 1) and (C.Memory.Read32(ErrWord) = 4),
      'Callback return did not collect the completed IO result');
    Require(Call(C, 'sceIoPollAsync', [Fd, ErrWord]) = $8002032A,
      'Callback completion did not consume its result');
    Call(C, 'sceKernelDeleteCallback', [CB]);

    Require(Call(C, 'sceIoCloseAsync', [Fd]) = 0, 'Async close submission failed');
    Checkpoint(C, Root, 'pending asynchronous close', 0);
    Await(C, Fd);
    Require((C.Memory.Read32(ErrWord) = 0) and (WorkerCount(C) = 0), 'Async close leaked its worker');
    Require(Call(C, 'sceIoPollAsync', [Fd, ErrWord]) = $80020323, 'Collected close retained its descriptor');

    C.Memory.WriteString(Params, 'host0:/data.bin', 128);
    Fd := Call(C, 'sceIoOpenAsync', [Params, 3, 0]);
    Await(C, Fd);
    Call(C, 'sceIoChangeAsyncPriority', [Fd, $10]);
    C.Memory.WriteString(Params, 'async close callback', 128);
    CB := Call(C, 'sceKernelCreateCallback', [Params, Code + $400, Globals]);
    C.Memory.Write32(Globals + 32, 0);
    Require(Call(C, 'sceIoCloseAsync', [Fd]) = 0, 'Callback-case close failed');
    Call(C, 'sceKernelNotifyCallback', [CB, 0]);
    Call(C, 'sceIoWaitAsyncCB', [Fd, ErrWord]);
    C.Kernel.AfterSyscall;
    C.RunUntil(C.Scheduler.Now + 20000);
    Checkpoint(C, Root, 'closed descriptor collected on callback return');
    Require((C.Memory.Read32(Globals + 32) = 1) and (C.Memory.Read32(ErrWord) = 0) and
      (WorkerCount(C) = 0), 'Callback return leaked its closed IO worker/descriptor');
    Require(Call(C, 'sceIoPollAsync', [Fd, ErrWord]) = $80020323, 'Callback close retained its descriptor');
    Call(C, 'sceKernelDeleteCallback', [CB]);

    C.Memory.WriteString(Params, 'host0:/missing.bin', 128);
    Fd := Call(C, 'sceIoOpenAsync', [Params, 1, 0]);
    Checkpoint(C, Root, 'asynchronous open failure before completion', 0);
    Await(C, Fd);
    Require((C.Memory.Read32(ErrWord) = $80010002) and
      (C.Memory.Read32(ErrWord + 4) = $FFFFFFFF) and (WorkerCount(C) = 0),
      'Async open failure did not preserve its signed result/cleanup');
    Writeln('PASS async worker priority, deferred transfers, result consumption and failure/close cleanup');
  finally C.Free; end;
end;

procedure SRCContextCases(const P: TPSPProgram; const Root: string);
begin
  var Host := TPath.Combine(Root, 'src-host');
  TDirectory.CreateDirectory(Host);
  var C := CreateConsole(P, Host);
  try
    C.RunUntil(C.Scheduler.Now + 10000000);
    C.Memory.Fill(Pixels, 0, 512);
    Require(Call(C, 'sceAudioSRCChReserve', [64, 44100, 2]) = 0, 'SRC reserve failed');
    C.CPU.InterruptsEnabled := False;
    Require(Call(C, 'sceAudioSRCOutputBlocking', [0, Pixels]) = $800201A7,
      'SRC did not reject its first disabled-interrupt wait');
    Checkpoint(C, Root, 'SRC descriptor retained after refused wait', 0);
    Require(Call(C, 'sceAudioSRCOutputBlocking', [0, Pixels]) = $800201A7,
      'SRC did not retain its second submitted descriptor');
    Checkpoint(C, Root, 'SRC full descriptor queue after refused waits', 0);
    C.CPU.InterruptsEnabled := True;
    Require(Call(C, 'sceAudioSRCOutputBlocking', [0, 0]) = $80260002,
      'SRC failed-wait lock did not protect the active DMA');
    Require(Call(C, 'sceAudioSRCChRelease', []) = $80268002, 'SRC released active DMA ownership');
    C.RunUntil(C.Scheduler.Now + 10000000);
    Require(Call(C, 'sceAudioSRCChRelease', []) = 0, 'Drained SRC retained failed-wait state');
    Writeln('PASS SRC refused waits preserve DMA ownership without retaining a thread pointer');
  finally C.Free; end;
end;

procedure ScanClockCases(const P: TPSPProgram; const Root: string);
const
  Late: array[0..3] of Int64 = (10000, 100000, 1000000, 2000000);
begin
  var Host := TPath.Combine(Root, 'clock-host');
  TDirectory.CreateDirectory(Host);
  var C := CreateConsole(P, Host);
  try
    var FirstEdge := C.Scheduler.Due(TPSPEvent.VBlank);
    for var I := 0 to High(Late) do
    begin
      var Edge := FirstEdge + Int64(I) * PSPFrameNs;
      // Simulate an atomic CPU section which notices a hardware edge late.
      C.Scheduler.AdvanceTo(Edge + Late[I]);
      C.RunUntil(C.Scheduler.Now);
      Require(Call(C, 'sceDisplayGetVcount', []) = Cardinal(I + 1), 'Late scan edge was not delivered');
      var H := Call(C, 'sceDisplayGetCurrentHcount', []);
      var Expected := Cardinal((C.Scheduler.Now - Edge) * PSPLinesPerFrame div PSPFrameNs);
      Require(H = Expected, 'Hcount restarted at interrupt delivery instead of the physical edge');
      if I = 0 then Checkpoint(C, Root, 'late display edge before interrupt tail', 0);
      C.RunUntil(C.Scheduler.Now + 1000000);
      Require(C.Scheduler.Due(TPSPEvent.VBlank) = Edge + PSPFrameNs,
        'Late interrupt delivery permanently shifted the display scan clock');
    end;
    Checkpoint(C, Root, 'display scan clock after differing interrupt delivery delays');
    Writeln('PASS display scan clock retains its hardware phase across late interrupt delivery');
  finally C.Free; end;
end;

procedure SyncWriteCases(const P: TPSPProgram; const Root: string);
begin
  var Host := TPath.Combine(Root, 'sync-write-host');
  TDirectory.CreateDirectory(Host);
  var C := CreateConsole(P, Host);
  try
    C.RunUntil(C.Scheduler.Now + 10000000);
    C.Memory.WriteString(Params, 'host0:/output.bin', 128);
    Call(C, 'sceIoOpen', [Params, $602, $1FF]);
    C.Kernel.AfterSyscall;
    C.RunUntil(C.Scheduler.Now + 1000000);
    var Fd := C.CPU.Ctx.GPR[2];
    Require(Fd < $80000000, 'Sync-write fixture open failed');
    Emit(C, Code + $600, [OpI($0F, 0, 8, Globals shr 16), OpI($0D, 8, 8, Globals and $FFFF),
      OpI(9, 0, 9, 1), OpI($2B, 8, 9, 48), OpR(0, 0, 2, $21), $03E00008, 0]);
    C.Memory.Write32(Globals + 48, 0);
    var Lower := C.Kernel.CreateThread('write lower', Code + $600,
      C.Kernel.Current.Priority + 1, $800, $80000000, 0);
    Require(Lower <> nil, 'Sync-write probe allocation failed');
    Lower.DeleteOnExit := True;
    C.Kernel.StartThread(Lower, 0, 0);
    C.Memory.WriteString(Pixels, 'sync', 5);
    Call(C, 'sceIoWrite', [Fd, Pixels, 4]);
    Require(C.Kernel.Current.IsWaiting and (C.Kernel.Current.Wait.HLETag = 'iodev'),
      'Synchronous host write did not wait for its drive transfer');
    C.Kernel.AfterSyscall;
    Checkpoint(C, Root, 'synchronous host write transfer and lower-priority progress');
    Require((C.CPU.Ctx.GPR[2] = 4) and (C.Memory.Read32(Globals + 48) = 1),
      'Sync-write completion lost its result or starved the lower-priority probe');
    Call(C, 'sceIoClose', [Fd]);
    C.Kernel.AfterSyscall;
    C.RunUntil(C.Scheduler.Now + 1000000);
    Require(Call(C, 'sceIoWrite', [1, Pixels, 4]) = 4, 'Stdout write failed');
    Require(not C.Kernel.Current.IsWaiting, 'Stdout was incorrectly treated as a host disk transfer');
    Writeln('PASS sync disk writes yield through transfer waits; stdout stays independent');
  finally C.Free; end;
end;

procedure MemstickCases(const P: TPSPProgram; const Root: string);
  procedure Callbacks(C: TPSPConsole);
  begin
    Call(C, 'sceKernelCheckCallback', []);
    C.Kernel.AfterSyscall;
    C.RunUntil(C.Scheduler.Now + 1000000);
  end;
begin
  var Host := TPath.Combine(Root, 'card-host');
  TDirectory.CreateDirectory(Host);
  var C := CreateConsole(P, Host);
  var D: TPSPConsole := nil;
  try
    C.RunUntil(C.Scheduler.Now + 10000000);
    var Source := TPath.Combine(Host, 'ms' + PathDelim + 'kept.bin');
    TFile.WriteAllText(Source, 'card', TEncoding.ASCII);
    Emit(C, Code + $700, [OpI($23, 6, 8, 52), OpI(9, 8, 8, 1), OpI($2B, 6, 8, 52),
      OpI($2B, 6, 5, 56), OpR(0, 0, 2, $21), $03E00008, 0]);
    C.Memory.Write32(Globals + 52, 0);
    C.Memory.WriteString(Params, 'card state', 128);
    var CB := Call(C, 'sceKernelCreateCallback', [Params, Code + $700, Globals]);
    C.Memory.WriteString(Params, 'fatms0:', 32); C.Memory.Write32(Params + $40, CB);
    Require(Call(C, 'sceIoDevctl', [Params, $02415821, Params + $40, 4, 0, 0]) = 0,
      'Card callback registration failed');
    Callbacks(C);
    Require((C.Memory.Read32(Globals + 52) = 1) and (C.Memory.Read32(Globals + 56) = 1),
      'Initial inserted-card callback was not delivered');
    C.IO.MemstickInserted := False;
    C.Memory.WriteString(Params, 'ms0:/kept.bin', 128);
    Require(Call(C, 'sceIoGetstat', [Params, Pixels]) = $80020321, 'Ejected card getstat touched host storage');
    Require(Call(C, 'sceIoDopen', [Params]) = $80020321, 'Ejected card directory access was allowed');
    var Data: TBytes;
    Require(C.IO.ReadAll('ms0:/kept.bin', Data) = $80020321, 'Ejected native IO helper read the card');
    var Path := TPath.Combine(Root, 'card.snapshot');
    C.SaveSnapshot(Path);
    D := C.RestoreSnapshot(Path);
    Require(not D.IO.MemstickInserted, 'Direct restore reinserted an ejected card');
    Callbacks(D);
    Require((D.Memory.Read32(Globals + 52) = 2) and (D.Memory.Read32(Globals + 56) = 0),
      'Restored card callback was lost or duplicated');
    D.IO.MemstickInserted := True;
    Callbacks(D);
    Require((D.Memory.Read32(Globals + 52) = 3) and (D.Memory.Read32(Globals + 56) = 1),
      'Reinserted-card callback was not delivered');
    Require((D.IO.ReadAll('ms0:/kept.bin', Data) = 0) and
      (TEncoding.ASCII.GetString(Data) = 'card'), 'Card data did not survive ejection/restore/reinsertion');
    Require(TFile.ReadAllText(Source, TEncoding.ASCII) = 'card', 'Media state change modified live card data');

    D.Memory.WriteString(Params, 'ms0:/kept.bin', 128);
    var Fd := Call(D, 'sceIoOpenAsync', [Params, 1, 0]);
    Call(D, 'sceIoWaitAsync', [Fd, ErrWord]); D.Kernel.AfterSyscall;
    D.RunUntil(D.Scheduler.Now + 1000000);
    D.Memory.Fill(Pixels, $CC, 4);
    Require(Call(D, 'sceIoReadAsync', [Fd, Pixels, 4]) = 0, 'Card async read submission failed');
    D.IO.MemstickInserted := False;
    Call(D, 'sceIoWaitAsync', [Fd, ErrWord]); D.Kernel.AfterSyscall;
    D.RunUntil(D.Scheduler.Now + 1000000);
    Require((D.Memory.Read32(ErrWord) = $80020321) and (D.Memory.Read32(Pixels) = $CCCCCCCC),
      'Pending transfer read an ejected card');
    Call(D, 'sceIoCloseAsync', [Fd]); Call(D, 'sceIoWaitAsync', [Fd, ErrWord]);
    D.Kernel.AfterSyscall; D.RunUntil(D.Scheduler.Now + 1000000);
    Require(D.Memory.Read32(ErrWord) = 0, 'Ejected descriptor could not be closed');
    Callbacks(D);
    var Notifications := D.Memory.Read32(Globals + 52);
    D.Memory.WriteString(Params, 'fatms0:', 32); D.Memory.Write32(Params + $40, CB);
    Call(D, 'sceIoDevctl', [Params, $02415822, Params + $40, 4, 0, 0]);
    D.IO.MemstickInserted := True;
    Callbacks(D);
    Require(D.Memory.Read32(Globals + 52) = Notifications, 'Unregistered card callback still fired');
    Writeln('PASS card ejection/callback state, data-preserving restore/reinsertion and pending IO rejection');
  finally D.Free; C.Free; end;
end;

begin
  try
    var Root := TPath.Combine(TPath.GetTempPath, 'RetroMul-continuation-test-' + TGUID.NewGuid.ToString);
    TDirectory.CreateDirectory(Root);
    try
      var P := ProgramData;
      FontCases(P, Root); MediaCases(P, Root);
      LoaderAndDriverCases(P, Root); NetworkAndUtilityCases(P, Root);
      FatCases(P, Root);
      AsyncIOCases(P, Root);
      SRCContextCases(P, Root);
      ScanClockCases(P, Root);
      SyncWriteCases(P, Root);
      MemstickCases(P, Root);
    finally TDirectory.Delete(Root, True); end;
  except
    on E: Exception do begin Writeln(E.ClassName, ': ', E.Message); ExitCode := 1; end;
  end;
end.
