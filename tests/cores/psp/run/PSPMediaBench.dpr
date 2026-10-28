program PSPMediaBench;

// PSPMediaBench <movie.pmf>: decode every AVC picture and ATRAC3+ frame,
// fingerprint planar YUV, RGB and PCM output, and time the pipeline.
{$APPTYPE CONSOLE}
{$Q-}{$R-}

uses
  System.SysUtils, System.Math, System.Classes, System.IOUtils, System.Diagnostics,
  PSP.MpegDemux, PSP.MpegVideo, Audio.ATRAC3Plus;

procedure Fingerprint(var Hash: UInt64; Data: PByte; Size: Integer);
begin
  for var I := 0 to Size - 1 do
    Hash := (Hash xor Data[I]) * 1099511628211;
end;

procedure Run(const Name: string);
begin
  var Data := TFile.ReadAllBytes(Name);
  var Header: TPSPPsmfHeader;
  if Header.Parse(Copy(Data, 0, PSMFPacketSize)) <> 0 then
    raise Exception.Create('Invalid PSMF header');
  var Demux := TPSPPsDemux.Create;
  var Avc := TPSPAvc.Create;
  var Atrac: TATRAC3PlusDecoder := nil;
  try
    var Video := Demux.AddStream(PSMFKindAvc, $E0, 0);
    var Audio: TPSPEsQueue := nil;
    if Header.Count(PSMFKindAtrac) > 0 then
      Audio := Demux.AddStream(PSMFKindAtrac, $BD, 0);
    var Pos := Integer(Header.HeaderSize);
    var Pictures := 0;
    var AudioFrames := 0;
    var VideoErrors := 0;
    var AudioErrors := 0;
    var VideoTime := TStopwatch.Create;
    var AudioTime := TStopwatch.Create;
    var CscTime := TStopwatch.Create;
    var VideoHash: UInt64 := 14695981039346656037;
    var AudioHash: UInt64 := 14695981039346656037;
    var Rgb: TBytes;
    var Total := TStopwatch.StartNew;
    while True do
    begin
      while not Demux.HasAu(Video) and (Pos + PSMFPacketSize <= Length(Data)) do
      begin
        Demux.FeedPack(@Data[Pos]);
        Inc(Pos, PSMFPacketSize);
      end;
      if Audio <> nil then
        while Demux.HasAu(Audio) do
        begin
          var Au: TPSPAccessUnit;
          Demux.NextAu(Audio, Au);
          var Pcm: TArray<SmallInt> := nil;
          AudioTime.Start;
          try
            if Atrac = nil then
            begin
              var Channels := (Au.Data[2] shr 2) and 7;
              if Channels <> 1 then
                Channels := 2;
              Atrac := TATRAC3PlusDecoder.Create(Channels, 2);
            end;
            Pcm := Atrac.Decode(Copy(Au.Data, 8, Length(Au.Data) - 8));
          except
            on E: Exception do
            begin
              Inc(AudioErrors);
              if AudioErrors = 1 then
                Writeln('Audio error: ', E.ClassName, ': ', E.Message);
            end;
          end;
          AudioTime.Stop;
          if Length(Pcm) > 0 then
            Fingerprint(AudioHash, @Pcm[0], Length(Pcm) * SizeOf(SmallInt));
          Inc(AudioFrames);
        end;
      var Au: TPSPAccessUnit;
      var Frames: TArray<TPSPPicture>;
      var More := Demux.NextAu(Video, Au, Pos + PSMFPacketSize > Length(Data));
      VideoTime.Start;
      if More then
      begin
        var Err := Avc.Decode(Au.Data, Frames);
        if Err <> 0 then
        begin
          Inc(VideoErrors);
          if VideoErrors = 1 then
            Writeln(Format('Video error: %.8x', [Err]));
        end;
      end
      else
        Avc.Drain(Frames);
      VideoTime.Stop;
      for var P in Frames do
      begin
        Fingerprint(VideoHash, @P.Width, 4);
        Fingerprint(VideoHash, @P.Height, 4);
        Fingerprint(VideoHash, @P.Y[0], Length(P.Y));
        Fingerprint(VideoHash, @P.Cb[0], Length(P.Cb));
        Fingerprint(VideoHash, @P.Cr[0], Length(P.Cr));
        CscTime.Start;
        SetLength(Rgb, P.Width * P.Height * 4);
        PSPWritePicture(P, @Rgb[0], P.Width, PSPPixel8888);
        CscTime.Stop;
        Fingerprint(VideoHash, @Rgb[0], Length(Rgb));
      end;
      Inc(Pictures, Length(Frames));
      Demux.TakeFreed;
      if not More then
        Break;
    end;
    var DecodeSeconds := VideoTime.Elapsed.TotalSeconds + AudioTime.Elapsed.TotalSeconds + CscTime.Elapsed.TotalSeconds;
    Writeln(Format('%s: pictures %d, audio frames %d, video/audio errors %d/%d',
      [ExtractFileName(Name), Pictures, AudioFrames, VideoErrors, AudioErrors]));
    Writeln(Format('video %.3fs, csc %.3fs, audio %.3fs; decode %.1f fps; total incl fingerprints %.3fs (%.1f fps)',
      [VideoTime.Elapsed.TotalSeconds, CscTime.Elapsed.TotalSeconds, AudioTime.Elapsed.TotalSeconds,
       Pictures / Max(0.001, DecodeSeconds), Total.Elapsed.TotalSeconds, Pictures / Max(0.001, Total.Elapsed.TotalSeconds)]));
    Writeln(Format('video+rgb %.16x pcm %.16x', [VideoHash, AudioHash]));
    if (VideoErrors <> 0) or (AudioErrors <> 0) then
      ExitCode := 1;
  finally
    Atrac.Free;
    Avc.Free;
    Demux.Free;
  end;
end;

begin
  try
    if ParamCount <> 1 then
      raise Exception.Create('Usage: PSPMediaBench <movie.pmf>');
    Run(ParamStr(1));
  except
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
