{$DEFINE GEPIX_565}
{$UNDEF GEPIX_TEXTURE}
{$UNDEF GEPIX_BLEND}
{$UNDEF GEPIX_DEPTH}
procedure Pixel565_0(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$DEFINE GEPIX_TEXTURE}
{$UNDEF GEPIX_BLEND}
{$UNDEF GEPIX_DEPTH}
procedure Pixel565_1(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$UNDEF GEPIX_TEXTURE}
{$DEFINE GEPIX_BLEND}
{$UNDEF GEPIX_DEPTH}
procedure Pixel565_2(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$DEFINE GEPIX_TEXTURE}
{$DEFINE GEPIX_BLEND}
{$UNDEF GEPIX_DEPTH}
procedure Pixel565_3(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$UNDEF GEPIX_TEXTURE}
{$UNDEF GEPIX_BLEND}
{$DEFINE GEPIX_DEPTH}
procedure Pixel565_4(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$DEFINE GEPIX_TEXTURE}
{$UNDEF GEPIX_BLEND}
{$DEFINE GEPIX_DEPTH}
procedure Pixel565_5(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$UNDEF GEPIX_TEXTURE}
{$DEFINE GEPIX_BLEND}
{$DEFINE GEPIX_DEPTH}
procedure Pixel565_6(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$DEFINE GEPIX_TEXTURE}
{$DEFINE GEPIX_BLEND}
{$DEFINE GEPIX_DEPTH}
procedure Pixel565_7(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$UNDEF GEPIX_565}
{$DEFINE GEPIX_5551}
{$UNDEF GEPIX_TEXTURE}
{$UNDEF GEPIX_BLEND}
{$UNDEF GEPIX_DEPTH}
procedure Pixel5551_0(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$DEFINE GEPIX_TEXTURE}
{$UNDEF GEPIX_BLEND}
{$UNDEF GEPIX_DEPTH}
procedure Pixel5551_1(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$UNDEF GEPIX_TEXTURE}
{$DEFINE GEPIX_BLEND}
{$UNDEF GEPIX_DEPTH}
procedure Pixel5551_2(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$DEFINE GEPIX_TEXTURE}
{$DEFINE GEPIX_BLEND}
{$UNDEF GEPIX_DEPTH}
procedure Pixel5551_3(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$UNDEF GEPIX_TEXTURE}
{$UNDEF GEPIX_BLEND}
{$DEFINE GEPIX_DEPTH}
procedure Pixel5551_4(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$DEFINE GEPIX_TEXTURE}
{$UNDEF GEPIX_BLEND}
{$DEFINE GEPIX_DEPTH}
procedure Pixel5551_5(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$UNDEF GEPIX_TEXTURE}
{$DEFINE GEPIX_BLEND}
{$DEFINE GEPIX_DEPTH}
procedure Pixel5551_6(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$DEFINE GEPIX_TEXTURE}
{$DEFINE GEPIX_BLEND}
{$DEFINE GEPIX_DEPTH}
procedure Pixel5551_7(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$UNDEF GEPIX_5551}
{$DEFINE GEPIX_4444}
{$UNDEF GEPIX_TEXTURE}
{$UNDEF GEPIX_BLEND}
{$UNDEF GEPIX_DEPTH}
procedure Pixel4444_0(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$DEFINE GEPIX_TEXTURE}
{$UNDEF GEPIX_BLEND}
{$UNDEF GEPIX_DEPTH}
procedure Pixel4444_1(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$UNDEF GEPIX_TEXTURE}
{$DEFINE GEPIX_BLEND}
{$UNDEF GEPIX_DEPTH}
procedure Pixel4444_2(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$DEFINE GEPIX_TEXTURE}
{$DEFINE GEPIX_BLEND}
{$UNDEF GEPIX_DEPTH}
procedure Pixel4444_3(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$UNDEF GEPIX_TEXTURE}
{$UNDEF GEPIX_BLEND}
{$DEFINE GEPIX_DEPTH}
procedure Pixel4444_4(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$DEFINE GEPIX_TEXTURE}
{$UNDEF GEPIX_BLEND}
{$DEFINE GEPIX_DEPTH}
procedure Pixel4444_5(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$UNDEF GEPIX_TEXTURE}
{$DEFINE GEPIX_BLEND}
{$DEFINE GEPIX_DEPTH}
procedure Pixel4444_6(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$DEFINE GEPIX_TEXTURE}
{$DEFINE GEPIX_BLEND}
{$DEFINE GEPIX_DEPTH}
procedure Pixel4444_7(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$UNDEF GEPIX_4444}
{$DEFINE GEPIX_8888}
{$UNDEF GEPIX_TEXTURE}
{$UNDEF GEPIX_BLEND}
{$UNDEF GEPIX_DEPTH}
procedure Pixel8888_0(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$DEFINE GEPIX_TEXTURE}
{$UNDEF GEPIX_BLEND}
{$UNDEF GEPIX_DEPTH}
procedure Pixel8888_1(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$UNDEF GEPIX_TEXTURE}
{$DEFINE GEPIX_BLEND}
{$UNDEF GEPIX_DEPTH}
procedure Pixel8888_2(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$DEFINE GEPIX_TEXTURE}
{$DEFINE GEPIX_BLEND}
{$UNDEF GEPIX_DEPTH}
procedure Pixel8888_3(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$UNDEF GEPIX_TEXTURE}
{$UNDEF GEPIX_BLEND}
{$DEFINE GEPIX_DEPTH}
procedure Pixel8888_4(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$DEFINE GEPIX_TEXTURE}
{$UNDEF GEPIX_BLEND}
{$DEFINE GEPIX_DEPTH}
procedure Pixel8888_5(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$UNDEF GEPIX_TEXTURE}
{$DEFINE GEPIX_BLEND}
{$DEFINE GEPIX_DEPTH}
procedure Pixel8888_6(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$DEFINE GEPIX_TEXTURE}
{$DEFINE GEPIX_BLEND}
{$DEFINE GEPIX_DEPTH}
procedure Pixel8888_7(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$UNDEF GEPIX_8888}
{$UNDEF GEPIX_TEXTURE}
{$UNDEF GEPIX_BLEND}
{$UNDEF GEPIX_DEPTH}
type
  TGEPlotProc = procedure(const S: TGERaster; X, Y: Integer; var F: TGEFragment);

const
  PixelProcs: array[0..3, 0..7] of TGEPlotProc = (
    (Pixel565_0, Pixel565_1, Pixel565_2, Pixel565_3, Pixel565_4, Pixel565_5, Pixel565_6, Pixel565_7),
    (Pixel5551_0, Pixel5551_1, Pixel5551_2, Pixel5551_3, Pixel5551_4, Pixel5551_5, Pixel5551_6, Pixel5551_7),
    (Pixel4444_0, Pixel4444_1, Pixel4444_2, Pixel4444_3, Pixel4444_4, Pixel4444_5, Pixel4444_6, Pixel4444_7),
    (Pixel8888_0, Pixel8888_1, Pixel8888_2, Pixel8888_3, Pixel8888_4, Pixel8888_5, Pixel8888_6, Pixel8888_7));

// Specialise once per primitive. The generic path handles uncommon tests,
// secondary colour, fog, stencil and logic operations.
function SelectPixel(const S: TGERaster; Secondary: Boolean): TGEPlotProc;
begin
  if S.ClearMode or S.FogEnabled or S.StencilTest or S.ColorTest or S.LogicOp or Secondary then
  begin
    Result := PlotPixel;
    Exit;
  end;
  Result := PixelProcs[S.FBFormat, Ord(S.Textured) or (Ord(S.Blend) shl 1) or (Ord(S.DepthTest) shl 2)];
end;
