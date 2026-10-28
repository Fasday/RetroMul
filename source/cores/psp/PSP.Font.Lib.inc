// Libraries, opening and closing fonts.

type
  TPSPInternalFont = record
    Name, FileName: string;
    Family, Style, Language, Country: Word;
    Points: Single;
    // What opening it takes on hardware: mode 0, and the file for mode 1.
    Mode0Size, FileSize: Cardinal;
  end;

const
  // The firmware's font list, in its order.
  InternalFonts: array[0..17] of TPSPInternalFont = (
    (Name: 'FTT-NewRodin Pro DB'; FileName: 'jpn0.pgf'; Family: 1; Style: 103; Language: 1; Country: 1;
      Points: 10.125; Mode0Size: 145844; FileSize: 1581700),
    (Name: 'FTT-NewRodin Pro Latin'; FileName: 'ltn0.pgf'; Family: 1; Style: 1; Language: 2; Country: 1;
      Points: 10.125; Mode0Size: 16680; FileSize: 67660),
    (Name: 'FTT-Matisse Pro Latin'; FileName: 'ltn1.pgf'; Family: 2; Style: 1; Language: 2; Country: 1;
      Points: 10.125; Mode0Size: 16920; FileSize: 0),
    (Name: 'FTT-NewRodin Pro Latin'; FileName: 'ltn2.pgf'; Family: 1; Style: 2; Language: 2; Country: 1;
      Points: 10.125; Mode0Size: 16872; FileSize: 0),
    (Name: 'FTT-Matisse Pro Latin'; FileName: 'ltn3.pgf'; Family: 2; Style: 2; Language: 2; Country: 1;
      Points: 10.125; Mode0Size: 17112; FileSize: 0),
    (Name: 'FTT-NewRodin Pro Latin'; FileName: 'ltn4.pgf'; Family: 1; Style: 5; Language: 2; Country: 1;
      Points: 10.125; Mode0Size: 16648; FileSize: 0),
    (Name: 'FTT-Matisse Pro Latin'; FileName: 'ltn5.pgf'; Family: 2; Style: 5; Language: 2; Country: 1;
      Points: 10.125; Mode0Size: 16928; FileSize: 0),
    (Name: 'FTT-NewRodin Pro Latin'; FileName: 'ltn6.pgf'; Family: 1; Style: 6; Language: 2; Country: 1;
      Points: 10.125; Mode0Size: 16792; FileSize: 0),
    (Name: 'FTT-Matisse Pro Latin'; FileName: 'ltn7.pgf'; Family: 2; Style: 6; Language: 2; Country: 1;
      Points: 10.125; Mode0Size: 17160; FileSize: 0),
    (Name: 'FTT-NewRodin Pro Latin'; FileName: 'ltn8.pgf'; Family: 1; Style: 1; Language: 2; Country: 1;
      Points: 7; Mode0Size: 16192; FileSize: 0),
    (Name: 'FTT-Matisse Pro Latin'; FileName: 'ltn9.pgf'; Family: 2; Style: 1; Language: 2; Country: 1;
      Points: 7; Mode0Size: 16476; FileSize: 0),
    (Name: 'FTT-NewRodin Pro Latin'; FileName: 'ltn10.pgf'; Family: 1; Style: 2; Language: 2; Country: 1;
      Points: 7; Mode0Size: 16300; FileSize: 0),
    (Name: 'FTT-Matisse Pro Latin'; FileName: 'ltn11.pgf'; Family: 2; Style: 2; Language: 2; Country: 1;
      Points: 7; Mode0Size: 16656; FileSize: 0),
    (Name: 'FTT-NewRodin Pro Latin'; FileName: 'ltn12.pgf'; Family: 1; Style: 5; Language: 2; Country: 1;
      Points: 7; Mode0Size: 16176; FileSize: 0),
    (Name: 'FTT-Matisse Pro Latin'; FileName: 'ltn13.pgf'; Family: 2; Style: 5; Language: 2; Country: 1;
      Points: 7; Mode0Size: 16436; FileSize: 0),
    (Name: 'FTT-NewRodin Pro Latin'; FileName: 'ltn14.pgf'; Family: 1; Style: 6; Language: 2; Country: 1;
      Points: 7; Mode0Size: 16272; FileSize: 0),
    (Name: 'FTT-Matisse Pro Latin'; FileName: 'ltn15.pgf'; Family: 2; Style: 6; Language: 2; Country: 1;
      Points: 7; Mode0Size: 16704; FileSize: 0),
    (Name: 'AsiaNHH(512Johab)'; FileName: 'kr0.pgf'; Family: 1; Style: 1; Language: 3; Country: 3;
      Points: 10.125; Mode0Size: 51856; FileSize: 0));

  // How the two fonts the tests open break their mode 0 size down.
  Jpn0Parts: array[0..8] of Cardinal = (2040, 2040, 2040, 848, 1020, 0, 0, 114632, 23224);
  Ltn0Parts: array[0..8] of Cardinal = (2040, 1760, 648, 1144, 648, 0, 0, 9872, 568);

  MaxFontsPerLib = 9;
  LibStructSize = 76;
  FontHandleSize = 76;
  FontRecordSize = 560;
  FontStyleSize = 168;
  FontListSize = Length(InternalFonts) * FontStyleSize;
  MemoryFontSize = 12;
  // Inside a font record: where a mode 0 open reads the header and the
  // error word it hands the file callbacks.
  RecordErrorWord = $220;
  // The free order of the nine mode 0 blocks.
  PartFreeOrder: array[0..8] of Integer = (8, 7, 5, 6, 4, 0, 1, 2, 3);
  // Time the library's own file and kernel calls give other threads.
  NewLibYieldUs = 60;
  FileYieldUs = 120;
  ListYieldUs = 20;

{ TPSPFontData }

destructor TPSPFontData.Destroy;
begin
  if OwnsFont then
    Font.Free;
  Seen.Free;
  inherited;
end;

function TPSPFontData.FirstLook(Index: Integer): Boolean;
begin
  if not Streamed or (Index < 0) then
    Exit(False);
  if Seen = nil then
    Seen := TDictionary<Integer, Boolean>.Create;
  Result := not Seen.ContainsKey(Index);
  if Result then
    Seen.Add(Index, True);
end;

{ TPSPFontLib }

constructor TPSPFontLib.Create;
begin
  inherited Create;
  Slots := TObjectList<TPSPFontSlot>.Create;
  Datas := TObjectList<TPSPFontData>.Create;
end;

destructor TPSPFontLib.Destroy;
begin
  Slots.Free;
  Datas.Free;
  inherited;
end;

{ TPSPFont }

constructor TPSPFont.Create(System: TPSPSystem);
begin
  inherited Create(System);
  FLibs := TObjectDictionary<Cardinal, TPSPFontLib>.Create([doOwnsValues]);
  FSlots := TDictionary<Cardinal, TPSPFontSlot>.Create;
  FFonts := TObjectDictionary<Integer, TPGFFont>.Create([doOwnsValues]);
end;

destructor TPSPFont.Destroy;
begin
  FSlots.Free;
  FLibs.Free;
  FFonts.Free;
  inherited;
end;

procedure TPSPFont.Reset;
begin
  FSlots.Clear;
  FLibs.Clear;
end;

function TPSPFont.FontOf(Handle: Cardinal): TPGFFont;
begin
  var S := SlotOf(Handle);
  if (S = nil) or (S.Data = nil) then
    Result := nil
  else
    Result := S.Data.Font;
end;

function TPSPFont.LibOf(Addr: Cardinal): TPSPFontLib;
begin
  if (Addr = 0) or not FLibs.TryGetValue(Addr, Result) then
    Result := nil;
end;

function TPSPFont.SlotOf(Handle: Cardinal): TPSPFontSlot;
begin
  if (Handle = 0) or not FSlots.TryGetValue(Handle, Result) then
    Result := nil;
end;

procedure TPSPFont.SetError(Ptr, Code: Cardinal);
begin
  if (Ptr <> 0) and FMemory.Valid(Ptr, 4) then
    FMemory.Write32(Ptr, Code);
end;

procedure TPSPFont.Finish(Value: Cardinal; YieldUs: Integer);
begin
  FHLE.Result(Value);
  if (YieldUs <= 0) or not FKernel.CanWait then
    Exit;
  // The library's own kernel calls let other threads run meanwhile.
  var T := FKernel.Current;
  FKernel.BeginWait(PSPWaitEventFlag, nil, 0, 0, False, nil, nil, 'font');
  FKernel.AddTimer(FKernel.Scheduler.Now + Int64(YieldUs) * 1000, T,
    procedure
    begin
      if T.IsWaiting and (T.Wait.HLETag = 'font') then
        FKernel.EndWait(T, Value);
    end);
end;

{ Guest calls }

procedure TPSPFont.AllocStep(AllocF, FreeF, UserData: Cardinal; const Sizes, Addrs: TArray<Cardinal>; I: Integer;
  const Done: TFontAllocDone);
begin
  if I > High(Sizes) then
  begin
    Done(Addrs, True);
    Exit;
  end;
  FKernel.CallGuest(AllocF, [UserData, Sizes[I]],
    procedure(Ret: Cardinal)
    begin
      if (Ret = 0) and (Sizes[I] <> 0) then
      begin
        // What was allocated goes back, newest first.
        var Back: TArray<Cardinal>;
        SetLength(Back, I);
        for var K := 0 to I - 1 do
          Back[K] := Addrs[I - 1 - K];
        FreeStep(FreeF, UserData, Back, 0,
          procedure
          begin
            Done(nil, False);
          end);
        Exit;
      end;
      Addrs[I] := Ret;
      AllocStep(AllocF, FreeF, UserData, Sizes, Addrs, I + 1, Done);
    end);
end;

procedure TPSPFont.AllocBlocks(Lib: TPSPFontLib; const Sizes: TArray<Cardinal>; const Done: TFontAllocDone);
begin
  var Addrs: TArray<Cardinal>;
  SetLength(Addrs, Length(Sizes));
  var AllocF := FMemory.Read32(Lib.Addr + $0C);
  var FreeF := FMemory.Read32(Lib.Addr + $10);
  if AllocF = 0 then
  begin
    Done(nil, False);
    Exit;
  end;
  AllocStep(AllocF, FreeF, FMemory.Read32(Lib.Addr), Sizes, Addrs, 0, Done);
end;

procedure TPSPFont.FreeStep(FreeF, UserData: Cardinal; const Addrs: TArray<Cardinal>; I: Integer; const Done: TProc);
begin
  while (I <= High(Addrs)) and (Addrs[I] = 0) do
    Inc(I);
  if (I > High(Addrs)) or (FreeF = 0) then
  begin
    Done();
    Exit;
  end;
  FKernel.CallGuest(FreeF, [UserData, Addrs[I]],
    procedure(Ret: Cardinal)
    begin
      FreeStep(FreeF, UserData, Addrs, I + 1, Done);
    end);
end;

procedure TPSPFont.FreeBlocks(Lib: TPSPFontLib; const Addrs: TArray<Cardinal>; const Done: TProc);
begin
  FreeStep(FMemory.Read32(Lib.Addr + $10), FMemory.Read32(Lib.Addr), Addrs, 0, Done);
end;

procedure TPSPFont.RunIO(const IO: TFontIO; const Ops: TArray<TFontIOOp>; I: Integer; const Done: TProc;
  const Fail: TFontFail);
begin
  if I > High(Ops) then
  begin
    Done();
    Exit;
  end;
  var Op := Ops[I];
  case Op.Kind of
    fiSeek:
      FKernel.CallGuest(IO.SeekF, [IO.UserData, IO.FH, Op.A],
        procedure(Ret: Cardinal)
        begin
          if Ret <> 0 then
            Fail(SCE_FONT_ERROR_FILESEEK)
          else
            RunIO(IO, Ops, I + 1, Done, Fail);
        end);
    fiRead:
      begin
        FMemory.Write32(IO.ErrAddr, 0);
        FKernel.CallGuest(IO.ReadF, [IO.UserData, IO.FH, Op.A, Op.B, Op.C, IO.ErrAddr],
          procedure(Ret: Cardinal)
          begin
            if (Ret <> Op.C) or (FMemory.Read32(IO.ErrAddr) <> 0) then
              Fail(SCE_FONT_ERROR_FILEREAD)
            else
              RunIO(IO, Ops, I + 1, Done, Fail);
          end);
      end;
    fiClose:
      FKernel.CallGuest(IO.CloseF, [IO.UserData, IO.FH],
        procedure(Ret: Cardinal)
        begin
          RunIO(IO, Ops, I + 1, Done, Fail);
        end);
  end;
end;

function IOOp(Kind: TFontIOKind; A: Cardinal = 0; B: Cardinal = 0; C: Cardinal = 0): TFontIOOp;
begin
  Result.Kind := Kind;
  Result.A := A;
  Result.B := B;
  Result.C := C;
end;

{ Libraries }

procedure TPSPFont.RemoveLib(Addr: Cardinal);
begin
  var Lib := LibOf(Addr);
  if Lib = nil then
    Exit;
  for var S in Lib.Slots do
  begin
    var Cur: TPSPFontSlot;
    if FSlots.TryGetValue(S.Handle, Cur) and (Cur = S) then
      FSlots.Remove(S.Handle);
  end;
  FLibs.Remove(Addr);
end;

procedure TPSPFont.WriteStyle(Addr: Cardinal; Index: Integer);
begin
  var E := InternalFonts[Index];
  FMemory.Fill(Addr, 0, FontStyleSize);
  FMemory.WriteFloat(Addr, E.Points);
  FMemory.WriteFloat(Addr + 4, E.Points);
  FMemory.WriteFloat(Addr + 8, 128);
  FMemory.WriteFloat(Addr + 12, 128);
  FMemory.Write16(Addr + 20, E.Family);
  FMemory.Write16(Addr + 22, E.Style);
  FMemory.Write16(Addr + 26, E.Language);
  FMemory.Write16(Addr + 30, E.Country);
  FMemory.WriteString(Addr + 32, RawByteString(E.Name), 64);
  FMemory.WriteString(Addr + 96, RawByteString(E.FileName), 64);
end;

function TPSPFont.CreateLib(const Addrs: TArray<Cardinal>; Count: Integer; const Params: TBytes): TPSPFontLib;
begin
  var A := Addrs[0];
  // Memory freed by a library that is done can come back for a new one.
  RemoveLib(A);
  FMemory.Fill(A, 0, LibStructSize);
  FMemory.WriteBytes(A, Params[0], Length(Params));
  FMemory.Write32(A + $2C, Addrs[1]);
  FMemory.Write32(A + $30, Addrs[2]);
  FMemory.WriteFloat(A + $38, 128);
  FMemory.WriteFloat(A + $3C, 128);
  FMemory.Write32(A + $40, Length(InternalFonts));
  FMemory.Write32(A + $44, Addrs[3]);
  FMemory.Write16(A + $48, Ord('_'));
  FMemory.Fill(Addrs[1], 0, FontHandleSize * Count);
  FMemory.Fill(Addrs[2], 0, FontRecordSize * Count);
  for var I := 0 to High(InternalFonts) do
    WriteStyle(Addrs[3] + Cardinal(I * FontStyleSize), I);
  Result := TPSPFontLib.Create;
  Result.Addr := A;
  Result.Blocks := Copy(Addrs);
  for var I := 0 to Count - 1 do
  begin
    var S := TPSPFontSlot.Create;
    S.Lib := Result;
    S.Handle := Addrs[1] + Cardinal(I * FontHandleSize);
    S.Memory := Addrs[2] + Cardinal(I * FontRecordSize);
    FMemory.Write32(S.Handle, A);
    FMemory.Write32(S.Handle + 4, S.Memory);
    Result.Slots.Add(S);
    FSlots.AddOrSetValue(S.Handle, S);
  end;
  FLibs.Add(A, Result);
end;

procedure TPSPFont.hNewLib;
begin
  var Params := FHLE.Arg(0);
  var ErrPtr := FHLE.Arg(1);
  if (Params = 0) or not FMemory.Valid(Params, $2C) then
  begin
    SetError(ErrPtr, SCE_FONT_ERROR_ARG);
    FHLE.Result(0);
    Exit;
  end;
  var UserData := FMemory.Read32(Params);
  var AllocF := FMemory.Read32(Params + $0C);
  var FreeF := FMemory.Read32(Params + $10);
  if (AllocF = 0) or (FreeF = 0) then
  begin
    SetError(ErrPtr, SCE_FONT_ERROR_ARG);
    FHLE.Result(0);
    Exit;
  end;
  var Count := Integer(Min(FMemory.Read32(Params + 4), Cardinal(MaxFontsPerLib)));
  var Copied: TBytes;
  SetLength(Copied, $2C);
  FMemory.ReadBytes(Params, Copied[0], $2C);
  var Sizes: TArray<Cardinal> := [LibStructSize, FontHandleSize * Count, FontRecordSize * Count, FontListSize];
  var Addrs: TArray<Cardinal>;
  SetLength(Addrs, Length(Sizes));
  AllocStep(AllocF, FreeF, UserData, Sizes, Addrs, 0,
    procedure(const Got: TArray<Cardinal>; Ok: Boolean)
    begin
      if not Ok then
      begin
        SetError(ErrPtr, SCE_FONT_ERROR_NOMEMORY);
        FHLE.Result(0);
        Exit;
      end;
      var Lib := CreateLib(Got, Count, Copied);
      SetError(ErrPtr, 0);
      Finish(Lib.Addr, NewLibYieldUs);
    end);
end;

procedure TPSPFont.hDoneLib;
begin
  var Lib := LibOf(FHLE.Arg(0));
  if (Lib = nil) or Lib.Done then
  begin
    FHLE.Result(SCE_FONT_ERROR_LIBID);
    Exit;
  end;
  Lib.Done := True;
  // Fonts still open go first, then the library's own blocks.
  var Addrs: TArray<Cardinal> := nil;
  for var D in Lib.Datas do
    if D.Refs > 0 then
    begin
      D.Refs := 0;
      Addrs := Addrs + D.Blocks + D.Cache;
      D.Cache := nil;
    end;
  for var S in Lib.Slots do
    S.Busy := False;
  Addrs := Addrs + [Lib.Blocks[3], Lib.Blocks[1], Lib.Blocks[2], Lib.Blocks[0]];
  FHLE.Result(0);
  FreeBlocks(Lib, Addrs,
    procedure
    begin
      FHLE.Result(0);
    end);
end;

{ Opening }

function TPSPFont.FreeSlot(Lib: TPSPFontLib): TPSPFontSlot;
begin
  for var S in Lib.Slots do
    if not S.Busy then
      Exit(S);
  Result := nil;
end;

function TPSPFont.SharedData(Lib: TPSPFontLib; const Key: string): TPSPFontData;
begin
  for var D in Lib.Datas do
    if (D.Refs > 0) and (D.Key = Key) then
      Exit(D);
  Result := nil;
end;

function TPSPFont.AddData(Lib: TPSPFontLib; const Key: string; Font: TPGFFont; Owns: Boolean;
  const Blocks: TArray<Cardinal>): TPSPFontData;
begin
  Result := TPSPFontData.Create;
  Result.Key := Key;
  Result.Font := Font;
  Result.OwnsFont := Owns;
  Result.Blocks := Blocks;
  Result.CacheKey := -1;
  Lib.Datas.Add(Result);
end;

procedure TPSPFont.Attach(Slot: TPSPFontSlot; Data: TPSPFontData);
begin
  Slot.Busy := True;
  Slot.Data := Data;
  Inc(Data.Refs);
end;

function PartsFreeOrder(const Parts: TArray<Cardinal>): TArray<Cardinal>;
begin
  SetLength(Result, Length(Parts));
  if Length(Parts) = 9 then
    for var K := 0 to 8 do
      Result[K] := Parts[PartFreeOrder[K]]
  else
    for var K := 0 to High(Parts) do
      Result[K] := Parts[High(Parts) - K];
end;

function TPSPFont.InternalFont(Index: Integer): TPGFFont;
begin
  if FFonts.TryGetValue(Index, Result) then
    Exit;
  var E := InternalFonts[Index];
  Result := nil;
  var Data: TBytes;
  if (FSystem.FlashRoot <> '') and (FSystem.IO.ReadAll('flash0:/font/' + E.FileName, Data) = 0) then
    Result := TPGFFile.Parse(Data);
  if Result = nil then
  begin
    var Bold := E.Style in [5, 6, 103];
    var Italic := E.Style in [2, 6];
    Result := TPGFBuiltin.Create(E.Points, Bold, Italic);
    Result.FileSize := E.FileSize;
    case Index of
      0: Result.Parts := TArray<Cardinal>.Create(Jpn0Parts[0], Jpn0Parts[1], Jpn0Parts[2], Jpn0Parts[3],
        Jpn0Parts[4], Jpn0Parts[5], Jpn0Parts[6], Jpn0Parts[7], Jpn0Parts[8]);
      1: Result.Parts := TArray<Cardinal>.Create(Ltn0Parts[0], Ltn0Parts[1], Ltn0Parts[2], Ltn0Parts[3],
        Ltn0Parts[4], Ltn0Parts[5], Ltn0Parts[6], Ltn0Parts[7], Ltn0Parts[8]);
    else
      Result.Parts := [E.Mode0Size];
    end;
  end;
  FFonts.Add(Index, Result);
end;

procedure TPSPFont.hOpen;
begin
  var Lib := LibOf(FHLE.Arg(0));
  var Index := FHLE.ArgInt(1);
  var Mode := FHLE.ArgInt(2);
  var ErrPtr := FHLE.Arg(3);
  if (Lib = nil) or Lib.Done then
  begin
    SetError(ErrPtr, SCE_FONT_ERROR_LIBID);
    FHLE.Result(0);
    Exit;
  end;
  if (Index < 0) or (Index > High(InternalFonts)) then
  begin
    SetError(ErrPtr, SCE_FONT_ERROR_ARG);
    FHLE.Result(0);
    Exit;
  end;
  var Slot := FreeSlot(Lib);
  if Slot = nil then
  begin
    SetError(ErrPtr, SCE_FONT_ERROR_TOOMANYOPENED);
    FHLE.Result(0);
    Exit;
  end;
  var Whole := Mode = 1;
  var Key := Format('font%d:%d', [Ord(Whole), Index]);
  var Shared := SharedData(Lib, Key);
  if Shared <> nil then
  begin
    Attach(Slot, Shared);
    SetError(ErrPtr, 0);
    FHLE.Result(Slot.Handle);
    Exit;
  end;
  var Font := InternalFont(Index);
  var Sizes: TArray<Cardinal>;
  if Whole and (Font.FileSize <> 0) then
    Sizes := [Font.FileSize, MemoryFontSize]
  else
  begin
    Sizes := Copy(Font.Parts);
    Whole := False;
  end;
  Slot.Busy := True;
  AllocBlocks(Lib, Sizes,
    procedure(const Addrs: TArray<Cardinal>; Ok: Boolean)
    begin
      if not Ok then
      begin
        Slot.Busy := False;
        SetError(ErrPtr, SCE_FONT_ERROR_NOMEMORY);
        FHLE.Result(0);
        Exit;
      end;
      var D := AddData(Lib, Key, Font, False, PartsFreeOrder(Addrs));
      D.Streamed := not Whole;
      Attach(Slot, D);
      SetError(ErrPtr, 0);
      Finish(Slot.Handle, FileYieldUs);
    end);
end;

function TPSPFont.GuestBytes(Addr, Size: Cardinal): TBytes;
const
  Cap = 64 * 1024 * 1024;
begin
  // As much of the image as is mapped: a size past the font's end is fine.
  var N := Min(Size, Cardinal(Cap));
  if not FMemory.Valid(Addr, N) then
  begin
    var Lo: Cardinal := 0;
    var Hi := N;
    while Lo + 1 < Hi do
    begin
      var Mid := Lo + (Hi - Lo) div 2;
      if FMemory.Valid(Addr, Mid) then
        Lo := Mid
      else
        Hi := Mid;
    end;
    N := Lo;
  end;
  SetLength(Result, N);
  if N > 0 then
    FMemory.ReadBytes(Addr, Result[0], N);
end;

procedure TPSPFont.hOpenUserMemory;
begin
  var Lib := LibOf(FHLE.Arg(0));
  var Addr := FHLE.Arg(1);
  var Size := FHLE.Arg(2);
  var ErrPtr := FHLE.Arg(3);
  if (Lib = nil) or Lib.Done then
  begin
    SetError(ErrPtr, SCE_FONT_ERROR_LIBID);
    FHLE.Result(0);
    Exit;
  end;
  if (Addr = 0) or (Size = 0) then
  begin
    SetError(ErrPtr, SCE_FONT_ERROR_ARG);
    FHLE.Result(0);
    Exit;
  end;
  var Slot := FreeSlot(Lib);
  if Slot = nil then
  begin
    SetError(ErrPtr, SCE_FONT_ERROR_TOOMANYOPENED);
    FHLE.Result(0);
    Exit;
  end;
  var Key := 'memory:' + IntToHex(Addr, 8);
  var Shared := SharedData(Lib, Key);
  if Shared <> nil then
  begin
    Attach(Slot, Shared);
    SetError(ErrPtr, 0);
    FHLE.Result(Slot.Handle);
    Exit;
  end;
  var Font := TPGFFile.Parse(GuestBytes(Addr, Size));
  if Font = nil then
  begin
    SetError(ErrPtr, SCE_FONT_ERROR_DATAINCONSISTENT);
    FHLE.Result(0);
    Exit;
  end;
  Slot.Busy := True;
  AllocBlocks(Lib, [MemoryFontSize],
    procedure(const Addrs: TArray<Cardinal>; Ok: Boolean)
    begin
      if not Ok then
      begin
        Font.Free;
        Slot.Busy := False;
        SetError(ErrPtr, SCE_FONT_ERROR_NOMEMORY);
        FHLE.Result(0);
        Exit;
      end;
      Attach(Slot, AddData(Lib, Key, Font, True, Addrs));
      SetError(ErrPtr, 0);
      FHLE.Result(Slot.Handle);
    end);
end;

procedure TPSPFont.hOpenUserFile;
begin
  var Lib := LibOf(FHLE.Arg(0));
  var NamePtr := FHLE.Arg(1);
  var Mode := FHLE.ArgInt(2);
  var ErrPtr := FHLE.Arg(3);
  if (Lib = nil) or Lib.Done then
  begin
    SetError(ErrPtr, SCE_FONT_ERROR_LIBID);
    FHLE.Result(0);
    Exit;
  end;
  if NamePtr = 0 then
  begin
    SetError(ErrPtr, SCE_FONT_ERROR_ARG);
    FHLE.Result(0);
    Exit;
  end;
  var Name := FMemory.ReadString(NamePtr, 256);
  if Mode = 1 then
    OpenWhole(Lib, Name, ErrPtr)
  else
    OpenStreamed(Lib, NamePtr, Name, ErrPtr);
end;

procedure TPSPFont.OpenWhole(Lib: TPSPFontLib; const Name: string; ErrPtr: Cardinal);
begin
  // Mode 1: the library reads the whole file itself.
  var Slot := FreeSlot(Lib);
  if Slot = nil then
  begin
    SetError(ErrPtr, SCE_FONT_ERROR_TOOMANYOPENED);
    FHLE.Result(0);
    Exit;
  end;
  var Key := 'file1:' + Name;
  var Shared := SharedData(Lib, Key);
  if Shared <> nil then
  begin
    Attach(Slot, Shared);
    SetError(ErrPtr, 0);
    FHLE.Result(Slot.Handle);
    Exit;
  end;
  var Data: TBytes;
  if FSystem.IO.ReadAll(Name, Data) <> 0 then
  begin
    SetError(ErrPtr, SCE_FONT_ERROR_FILEOPEN);
    Finish(0, FileYieldUs);
    Exit;
  end;
  var Font := TPGFFile.Parse(Data);
  if Font = nil then
  begin
    SetError(ErrPtr, SCE_FONT_ERROR_DATAINCONSISTENT);
    Finish(0, FileYieldUs);
    Exit;
  end;
  Slot.Busy := True;
  AllocBlocks(Lib, [Font.FileSize, MemoryFontSize],
    procedure(const Addrs: TArray<Cardinal>; Ok: Boolean)
    begin
      if not Ok then
      begin
        Font.Free;
        Slot.Busy := False;
        SetError(ErrPtr, SCE_FONT_ERROR_NOMEMORY);
        FHLE.Result(0);
        Exit;
      end;
      Attach(Slot, AddData(Lib, Key, Font, True, [Addrs[1], Addrs[0]]));
      SetError(ErrPtr, 0);
      Finish(Slot.Handle, FileYieldUs);
    end);
end;

procedure TPSPFont.OpenStreamed(Lib: TPSPFontLib; NamePtr: Cardinal; const Name: string; ErrPtr: Cardinal);
begin
  // Mode 0: header and tables come through the program's file callbacks,
  // the glyphs as they are drawn.
  var IO: TFontIO;
  IO.UserData := FMemory.Read32(Lib.Addr);
  IO.OpenF := FMemory.Read32(Lib.Addr + $14);
  IO.CloseF := FMemory.Read32(Lib.Addr + $18);
  IO.ReadF := FMemory.Read32(Lib.Addr + $1C);
  IO.SeekF := FMemory.Read32(Lib.Addr + $20);
  if (IO.OpenF = 0) or (IO.CloseF = 0) or (IO.ReadF = 0) or (IO.SeekF = 0) then
  begin
    SetError(ErrPtr, SCE_FONT_ERROR_ARG);
    FHLE.Result(0);
    Exit;
  end;
  var Slot := FreeSlot(Lib);
  if Slot = nil then
  begin
    SetError(ErrPtr, SCE_FONT_ERROR_TOOMANYOPENED);
    FHLE.Result(0);
    Exit;
  end;
  var Key := 'file0:' + Name;
  var Shared := SharedData(Lib, Key);
  if Shared <> nil then
  begin
    Attach(Slot, Shared);
    SetError(ErrPtr, 0);
    FHLE.Result(Slot.Handle);
    Exit;
  end;
  Slot.Busy := True;
  var Mem := Slot.Memory;
  IO.ErrAddr := Mem + RecordErrorWord;
  var Fail: TFontFail :=
    procedure(Error: Cardinal)
    begin
      Slot.Busy := False;
      SetError(ErrPtr, Error);
      FHLE.Result(0);
    end;
  var FailClose: TFontFail :=
    procedure(Error: Cardinal)
    begin
      RunIO(IO, [IOOp(fiClose)], 0,
        procedure
        begin
          Fail(Error);
        end, Fail);
    end;
  FMemory.Write32(IO.ErrAddr, 0);
  FKernel.CallGuest(IO.OpenF, [IO.UserData, NamePtr, IO.ErrAddr],
    procedure(FH: Cardinal)
    begin
      if FMemory.Read32(IO.ErrAddr) <> 0 then
      begin
        Fail(SCE_FONT_ERROR_FILEOPEN);
        Exit;
      end;
      IO.FH := FH;
      RunIO(IO, [IOOp(fiSeek, 0), IOOp(fiRead, Mem, $C, 1)], 0,
        procedure
        begin
          var HeaderSize := FMemory.Read16(Mem + 2);
          if (HeaderSize < $188) or (HeaderSize > RecordErrorWord) then
          begin
            FailClose(SCE_FONT_ERROR_DATAINCONSISTENT);
            Exit;
          end;
          RunIO(IO, [IOOp(fiRead, Mem + $C, HeaderSize - $C, 1)], 0,
            procedure
            begin
              var Header: TBytes;
              SetLength(Header, HeaderSize);
              FMemory.ReadBytes(Mem, Header[0], HeaderSize);
              var L: TPGFLayout;
              if not L.Read(Header) then
              begin
                FailClose(SCE_FONT_ERROR_DATAINCONSISTENT);
                Exit;
              end;
              var Sizes: TArray<Cardinal>;
              SetLength(Sizes, 9);
              for var K := 0 to 8 do
                Sizes[K] := L.Parts[K];
              AllocBlocks(Lib, Sizes,
                procedure(const Addrs: TArray<Cardinal>; Ok: Boolean)
                begin
                  if not Ok then
                  begin
                    FailClose(SCE_FONT_ERROR_NOMEMORY);
                    Exit;
                  end;
                  var Ops: TArray<TFontIOOp> := [IOOp(fiSeek, L.HeaderSize), IOOp(fiSeek, L.HeaderSize)];
                  for var K := 0 to 3 do
                    if L.TableLength[K] > 0 then
                      Ops := Ops + [IOOp(fiRead, Addrs[K], 8, L.TableLength[K])];
                  Ops := Ops + [IOOp(fiSeek, Cardinal(L.ShadowMapPos))];
                  for var K := 4 to 8 do
                    if L.Parts[K] > 0 then
                      Ops := Ops + [IOOp(fiRead, Addrs[K], L.Parts[K], 1)];
                  Ops := Ops + [IOOp(fiClose)];
                  RunIO(IO, Ops, 0,
                    procedure
                    begin
                      // The glyphs are read from the same file as they are drawn.
                      var Font: TPGFFile := nil;
                      var Data: TBytes;
                      if FSystem.IO.ReadAll(Name, Data) = 0 then
                        Font := TPGFFile.Parse(Data);
                      if Font = nil then
                      begin
                        // Only what came through the callbacks: metrics without bitmaps.
                        SetLength(Data, L.GlyphPos);
                        FillChar(Data[0], Length(Data), 0);
                        Move(Header[0], Data[0], HeaderSize);
                        var Pos := L.HeaderSize;
                        for var K := 0 to 3 do
                        begin
                          FMemory.ReadBytes(Addrs[K], Data[Pos], L.Parts[K]);
                          Inc(Pos, L.Parts[K]);
                        end;
                        FMemory.ReadBytes(Addrs[4], Data[L.ShadowMapPos], L.Parts[4]);
                        FMemory.ReadBytes(Addrs[7], Data[L.CharMapPos], L.Parts[7]);
                        FMemory.ReadBytes(Addrs[8], Data[L.CharPtrPos], L.Parts[8]);
                        Font := TPGFFile.Parse(Data);
                      end;
                      if Font = nil then
                      begin
                        FreeBlocks(Lib, PartsFreeOrder(Addrs),
                          procedure
                          begin
                            Fail(SCE_FONT_ERROR_DATAINCONSISTENT);
                          end);
                        Exit;
                      end;
                      var D := AddData(Lib, Key, Font, True, PartsFreeOrder(Addrs));
                      D.Streamed := True;
                      Attach(Slot, D);
                      SetError(ErrPtr, 0);
                      FHLE.Result(Slot.Handle);
                    end,
                    procedure(Error: Cardinal)
                    begin
                      FreeBlocks(Lib, PartsFreeOrder(Addrs),
                        procedure
                        begin
                          FailClose(Error);
                        end);
                    end);
                end);
            end, FailClose);
        end, FailClose);
    end);
end;

procedure TPSPFont.hClose;
begin
  var Slot := SlotOf(FHLE.Arg(0));
  if Slot = nil then
  begin
    FHLE.Result(SCE_FONT_ERROR_ARG);
    Exit;
  end;
  FHLE.Result(0);
  if not Slot.Busy or (Slot.Data = nil) then
    Exit;
  Slot.Busy := False;
  var D := Slot.Data;
  Dec(D.Refs);
  if D.Refs > 0 then
    Exit;
  var Addrs := D.Blocks + D.Cache;
  D.Cache := nil;
  D.CacheKey := -1;
  FreeBlocks(Slot.Lib, Addrs,
    procedure
    begin
      FHLE.Result(0);
    end);
end;
