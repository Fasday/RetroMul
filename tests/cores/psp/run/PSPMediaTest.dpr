program PSPMediaTest;

{$APPTYPE CONSOLE}

uses
  System.SysUtils, PSP.Types, PSP.Memory, PSP.CPU, PSP.HLE, PSP.Service, PSP.Mpeg, PSP.MpegDemux, PSP.MpegVideo;

procedure Check(Condition: Boolean; const What: string);
begin
  if not Condition then
    raise Exception.Create(What);
end;

procedure LargeAccessUnit;
const
  Size = 70681;
var
  Pack: array[0..PSMFPacketSize - 1] of Byte;
begin
  var D := TPSPPsDemux.Create;
  try
    var Q := D.AddStream(PSMFKindAvc, $E0, 0);
    FillChar(Pack, SizeOf(Pack), 0);
    Pack[2] := 1;
    Pack[3] := $BF;
    Pack[5] := 26;
    Pack[6] := 1;
    Pack[7] := $E0;
    Pack[23] := 2;
    // A table entry has the AU attribute at bit 23 and the length below it.
    Pack[25] := $81;
    Pack[26] := (Size shr 8) and $FF;
    Pack[27] := Size and $FF;
    Pack[31] := 37;
    D.FeedPack(@Pack[0]);
    var Data: TBytes;
    SetLength(Data, Size + 37);
    for var I := 0 to High(Data) do
      Data[I] := Byte(I and $FF);
    Q.Append(Data[0], 65535);
    Check(not D.HasAu(Q), 'large AU must wait for bytes beyond 64 KB');
    Q.Append(Data[65535], Length(Data) - 65535);
    var Au: TPSPAccessUnit;
    Check(D.NextAu(Q, Au), 'large AU available');
    Check(Length(Au.Data) = Size, 'large AU length');
    Check((Au.Flags and $80) <> 0, 'AU attribute preserved');
    Check(CompareMem(@Au.Data[0], @Data[0], Size), 'large AU data');
    Check(D.NextAu(Q, Au), 'next AU available');
    Check(Length(Au.Data) = 37, 'next AU length');
    Check(CompareMem(@Au.Data[0], @Data[Size], 37), 'next AU remains aligned');
    Check(Q.Length = 0, 'all ES bytes consumed');
  finally
    D.Free;
  end;
  Writeln('PASS large PSMF access unit');
end;

procedure CopyAndConvert;
const
  Src = $08800000;
  Dst = $08800100;
  Range = $08800200;
  SrcData = $08810000;
  DstData = $08910000;
  Rgb = $08A10000;
  W = 480;
  H = 272;
begin
  var S := TPSPSystem.Create;
  S.Memory := TPSPMemory.Create;
  S.CPU := TPSPCPU.Create(S.Memory);
  S.HLE := TPSPHLE.Create(S.CPU, S.Memory);
  var M := TPSPMpeg.Create(S);
  try
    M.Register;
    var Mem := S.Memory;
    var Sizes: TArray<Cardinal>;
    var Total := PSPMePlaneSizes(W div 16, H div 16, Sizes);
    Mem.Write32(Src, H);
    Mem.Write32(Src + 4, W);
    Mem.Write32(Dst, H div 16);
    Mem.Write32(Dst + 4, W div 16);
    var A: Cardinal := SrcData;
    var B: Cardinal := DstData;
    for var I := 0 to 7 do
    begin
      Mem.Write32(Src + 16 + Cardinal(I) * 4, A);
      Mem.Write32(Dst + 16 + Cardinal(I) * 4, B);
      var P := Mem.Ptr(A, Sizes[I]);
      for var K := 0 to Integer(Sizes[I]) - 1 do
        P[K] := Byte((K * 17 + I * 31) and $FF);
      Inc(A, Sizes[I]);
      Inc(B, Sizes[I]);
    end;
    var CopyFn := S.HLE.FunctionInfo(S.HLE.Find('sceMpegbase', $7AC0321A)).Handler;
    for var Flags := 1 to 3 do
    begin
      Mem.Fill(DstData, $5A, Total);
      S.CPU.Ctx.GPR[4] := Dst;
      S.CPU.Ctx.GPR[5] := Src;
      S.CPU.Ctx.GPR[6] := Cardinal(Flags);
      CopyFn();
      Check(S.CPU.Ctx.GPR[2] = 0, 'base copy succeeds with pixel dimensions');
      for var I := 0 to 7 do
      begin
        A := Mem.Read32(Src + 16 + Cardinal(I) * 4);
        B := Mem.Read32(Dst + 16 + Cardinal(I) * 4);
        var P := Mem.Ptr(B, Sizes[I]);
        if (Flags and (1 shl ((I shr 1) and 1))) <> 0 then
          Check(CompareMem(Mem.Ptr(A), P, Sizes[I]), 'selected plane copied')
        else
          for var K := 0 to Integer(Sizes[I]) - 1 do
            Check(P[K] = $5A, 'unselected plane unchanged');
      end;
    end;
    Writeln('PASS sceMpegBaseYCrCbCopy pixel dimensions and field selection');
    Mem.Write32(Range, 0);
    Mem.Write32(Range + 4, 0);
    Mem.Write32(Range + 8, W div 16);
    Mem.Write32(Range + 12, H div 16);
    S.CPU.Ctx.GPR[4] := Rgb;
    S.CPU.Ctx.GPR[5] := 0;
    S.CPU.Ctx.GPR[6] := Range;
    S.CPU.Ctx.GPR[7] := W;
    S.CPU.Ctx.GPR[8] := Dst;
    S.HLE.FunctionInfo(S.HLE.Find('sceMpegbase', $304882E1)).Handler();
    for var Y := 0 to H - 1 do
      for var X := 0 to W - 1 do
      begin
        var F := Y and 1;
        var Row := Y div 2;
        var Mb := X div 16;
        var Ya := Mem.Read32(Dst + 16 + Cardinal(F * 2 + (Mb and 1)) * 4);
        var U := Mem.Read32(Dst + 16 + Cardinal(4 + F * 2) * 4);
        var V := Mem.Read32(Dst + 16 + Cardinal(5 + F * 2) * 4);
        var C := Cardinal((Row div 2) * (W div 2) + X div 2);
        var R, G, Bv: Integer;
        PSPYCbCrToRGB(Mem.Read8(Ya + Cardinal(((Mb div 2) * (H div 2) + Row) * 16 + (X and 15))),
          Mem.Read8(U + C), Mem.Read8(V + C), R, G, Bv);
        Check(Mem.Read32(Rgb + Cardinal((Y * W + X) * 4)) = PSPPackPixel(R, G, Bv, PSPPixel8888),
          'CSC matches scalar conversion');
      end;
    Writeln('PASS ME picture CSC matches scalar conversion');
  finally
    M.Free;
    S.HLE.Free;
    S.CPU.Free;
    S.Memory.Free;
    S.Free;
  end;
end;

begin
  try
    LargeAccessUnit;
    CopyAndConvert;
  except
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
