program PSPDecryptRun;

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.IOUtils, System.Hash,
  PSP.Media, PSP.PRX;

procedure Inspect(const Image, Name: string; const Data: TBytes; const ExtractTo: string);
begin
  if (Length(Data) < $150) or (PSPLE32(Data, 0) <> $5053507E) then
    Exit;
  var Tag := PSPLE32(Data, $D0);
  try
    var Elf := DecryptPSPPRX(Data);
    var Hash := THashSHA2.Create;
    if Length(Elf) > 0 then Hash.Update(Elf[0], Length(Elf));
    Writeln(Format('OK %.8x %d %s | %s | %s', [Tag, Length(Elf), Hash.HashAsString, Image, Name]));
  except
    on E: Exception do
      Writeln(Format('FAIL %.8x %s | %s | %s', [Tag, E.Message, Image, Name]));
  end;
  if ExtractTo <> '' then
  begin
    var OutName := TPath.Combine(ExtractTo, ExtractFileName(Image) + '_' + Name.Replace('/', '_'));
    TFile.WriteAllBytes(OutName, Data);
  end;
end;

procedure Disc(const Image, ExtractTo: string);
var
  D: TPSPDisc;
  procedure Walk(const Path: string);
  begin
    for var E in D.ReadDirectory(Path) do
    begin
      if (E.Name = '.') or (E.Name = '..') then Continue;
      var N := Path + '/' + E.Name;
      if E.Directory then
        Walk(N)
      else if SameText(ExtractFileExt(N), '.prx') or SameText(E.Name, 'EBOOT.BIN') or SameText(E.Name, 'BOOT.BIN') then
        Inspect(Image, N, D.ReadFile(N), ExtractTo);
    end;
  end;
begin
  var S := TFileStream.Create(Image, fmOpenRead or fmShareDenyWrite);
  try
    D := TPSPDisc.Create(S);
    try
      Walk('/PSP_GAME');
    finally
      D.Free;
    end;
  finally
    S.Free;
  end;
end;

begin
  try
    var Input := ParamStr(1);
    var ExtractTo := ParamStr(2);
    if ExtractTo <> '' then ForceDirectories(ExtractTo);
    if TDirectory.Exists(Input) then
    begin
      for var N in TDirectory.GetFiles(Input, '*', TSearchOption.soAllDirectories) do
        if SameText(ExtractFileExt(N), '.iso') or SameText(ExtractFileExt(N), '.cso') then
          Disc(N, ExtractTo);
    end
    else if SameText(ExtractFileExt(Input), '.iso') or SameText(ExtractFileExt(Input), '.cso') then
      Disc(Input, ExtractTo)
    else
      Inspect(Input, 'module', TFile.ReadAllBytes(Input), ExtractTo);
  except
    on E: Exception do
    begin
      Writeln(E.ClassName + ': ' + E.Message);
      ExitCode := 1;
    end;
  end;
end.
