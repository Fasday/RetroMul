program PSPFontFileTest;

{$APPTYPE CONSOLE}

uses System.SysUtils, System.IOUtils, PSP.Font;

begin
  try
    var F := TPGFFile.Parse(TFile.ReadAllBytes(ParamStr(1)));
    if F = nil then raise Exception.Create('PGF rejected');
    try
      Writeln(Format('PGF: %d glyphs, U+%.4x..U+%.4x', [F.GlyphCount, F.FirstCode, F.LastCode]));
      for var C in [Ord('N'), Ord('e'), Ord('w'), Ord('G'), Ord('a'), Ord('m'), $0410, $0430, $3042] do
      begin
        var I := F.Lookup(C);
        var G := F.Glyph(I);
        if G = nil then raise Exception.CreateFmt('Missing glyph U+%.4x', [C]);
        var Ink := 0;
        for var P in G.Pixels do if P <> 0 then Inc(Ink);
        Writeln(Format('U+%.4x: %dx%d, advance %d, ink %d', [C, G.W, G.H, G.Advance.X, Ink]));
        if (G.Advance.X <= 0) or (Ink = 0) then raise Exception.Create('Empty glyph');
      end;
    finally
      F.Free;
    end;
  except
    on E: Exception do begin Writeln(E.ClassName + ': ' + E.Message); ExitCode := 1; end;
  end;
end.
