unit PSP.MpegVideo;

// The Media Engine's H.264 decoder as sceMpeg sees it: access units in,
// pictures out after the delay the hardware applies (the picture timing SEI's
// dpb_output_delay when the stream has HRD parameters, otherwise a bumping
// buffer three pictures deep), and the colour conversion into the guest's
// pixel formats.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, System.Generics.Collections, Core.Bitstream, Video.AVC.Types, Video.AVC.H264;

const
  PSPPixel5650 = 0;
  PSPPixel5551 = 1;
  PSPPixel4444 = 2;
  PSPPixel8888 = 3;

type
  TPSPPicture = record
    Width, Height: Integer;
    Y, Cb, Cr: TBytes;
    Poc: Integer;
    Index: Integer;
    OutAt: Int64;
  end;

  TPSPAvcSps = record
    Valid: Boolean;
    Profile, Level, MaxRefs: Integer;
    LogFrameNum, PocType, LogPocLsb: Integer;
    DeltaPocAlwaysZero: Boolean;
    MBWidth, MBHeight: Integer;
    Width, Height: Integer;
    CropLeft, CropRight, CropTop, CropBottom: Integer;
    Timing: Boolean;
    UnitsInTick, TimeScale: Cardinal;
    Hrd: Boolean;
    CpbDelayLength, DpbDelayLength, TimeOffsetLength: Integer;
    CpbCount: Integer;
    PicStruct: Boolean;
    FullRange: Boolean;
    MaxDecFrameBuffering: Integer;
  end;

  TPSPAvcSei = record
    HasBuffering, HasTiming: Boolean;
    CpbRemovalDelay, DpbOutputDelay: Cardinal;
    PicStruct: Integer;
  end;

  TPSPAvc = class
  private
    FDecoder: TH264Decoder;
    FSps: array[0..31] of TPSPAvcSps;
    FPpsSps: array[0..255] of Integer;
    FPpsBottom: array[0..255] of Boolean;
    FActive: Integer;
    FHeld: TList<TPSPPicture>;
    FCount: Int64;
    FPrevPocMsb, FPrevPocLsb, FPrevFrameNum, FPrevFrameNumOffset: Integer;
    FConfigured: Boolean;
    FLastSei: TPSPAvcSei;
    FLastPicture: TPSPPicture;
    FHasPicture: Boolean;
    procedure ParseSps(const Rbsp: TBytes);
    procedure ParsePps(const Rbsp: TBytes);
    procedure ParseSei(const Rbsp: TBytes; var Sei: TPSPAvcSei);
    function SlicePoc(const Rbsp: TBytes; NalType, RefIdc: Integer): Integer;
    function TakeDue(out Pictures: TArray<TPSPPicture>): Integer;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Reset;
    // Decodes one access unit. Returns 0 or an error; Pictures are those
    // the call completes (the first one lands in the frame buffer).
    function Decode(const Au: TBytes; out Pictures: TArray<TPSPPicture>): Cardinal;
    // End of stream: every held picture.
    function Drain(out Pictures: TArray<TPSPPicture>): Integer;
    function ActiveSps: TPSPAvcSps;
    property LastSei: TPSPAvcSei read FLastSei;
    property HasPicture: Boolean read FHasPicture;
    property LastPicture: TPSPPicture read FLastPicture;
    property Decoded: Int64 read FCount;
  end;

// Video colour conversion (BT.601, studio range) as the ME does it.
procedure PSPYCbCrToRGB(Y, Cb, Cr: Integer; out R, G, B: Integer); inline;
// JPEG colour conversion (full range).
procedure PSPJpegYCbCrToRGB(Y, Cb, Cr: Integer; out R, G, B: Integer); inline;
function PSPPackPixel(R, G, B, Format: Integer): Cardinal; inline;
function PSPPixelBytes(Format: Integer): Integer; inline;
// Writes a picture as RGB into a frame buffer of Stride pixels.
procedure PSPWritePicture(const Pic: TPSPPicture; Dest: PByte; Stride, Format: Integer; MaxRows: Integer = -1);

implementation

uses
  System.Math;

function Clamp255(V: Integer): Integer; inline;
begin
  if V < 0 then
    Result := 0
  else if V > 255 then
    Result := 255
  else
    Result := V;
end;

function SarFloor(V: Integer): Integer; inline;
begin
  if V >= 0 then
    Result := V shr 8
  else
    Result := -((-V + 255) shr 8);
end;

procedure PSPYCbCrToRGB(Y, Cb, Cr: Integer; out R, G, B: Integer);
begin
  var L := 298 * (Y - 16) + 128;
  var U := Cb - 128;
  var V := Cr - 128;
  R := Clamp255(SarFloor(L + 409 * V));
  G := Clamp255(SarFloor(L - 100 * U - 208 * V));
  B := Clamp255(SarFloor(L + 516 * U));
end;

procedure PSPJpegYCbCrToRGB(Y, Cb, Cr: Integer; out R, G, B: Integer);
begin
  var U := Cb - 128;
  var V := Cr - 128;
  R := Clamp255(Y + SarFloor(359 * V + 128));
  G := Clamp255(Y - SarFloor(88 * U + 183 * V + 128));
  B := Clamp255(Y + SarFloor(454 * U + 128));
end;

function PSPPackPixel(R, G, B, Format: Integer): Cardinal;
begin
  case Format of
    PSPPixel5650: Result := Cardinal(R shr 3) or (Cardinal(G shr 2) shl 5) or (Cardinal(B shr 3) shl 11);
    PSPPixel5551: Result := Cardinal(R shr 3) or (Cardinal(G shr 3) shl 5) or (Cardinal(B shr 3) shl 10);
    PSPPixel4444: Result := Cardinal(R shr 4) or (Cardinal(G shr 4) shl 4) or (Cardinal(B shr 4) shl 8);
  else
    Result := Cardinal(R) or (Cardinal(G) shl 8) or (Cardinal(B) shl 16);
  end;
end;

function PSPPixelBytes(Format: Integer): Integer;
begin
  if Format = PSPPixel8888 then
    Result := 4
  else
    Result := 2;
end;

procedure PSPWritePicture(const Pic: TPSPPicture; Dest: PByte; Stride, Format: Integer; MaxRows: Integer);
begin
  var Rows := Pic.Height;
  if (MaxRows >= 0) and (MaxRows < Rows) then
    Rows := MaxRows;
  var Bpp := PSPPixelBytes(Format);
  var CW := (Pic.Width + 1) div 2;
  for var Y := 0 to Rows - 1 do
  begin
    var Line := Dest + NativeInt(Y) * Stride * Bpp;
    for var X := 0 to Pic.Width - 1 do
    begin
      var R, G, B: Integer;
      var C := (Y div 2) * CW + (X div 2);
      PSPYCbCrToRGB(Pic.Y[Y * Pic.Width + X], Pic.Cb[C], Pic.Cr[C], R, G, B);
      var P := PSPPackPixel(R, G, B, Format);
      if Bpp = 4 then
        PCardinal(Line + X * 4)^ := P
      else
        PWord(Line + X * 2)^ := Word(P);
    end;
  end;
end;

function SplitAnnexB(const Data: TBytes): TArray<TBytes>;
begin
  Result := nil;
  var Start := -1;
  var P := 0;
  var N := Length(Data);
  while P + 3 <= N do
  begin
    if (Data[P] = 0) and (Data[P + 1] = 0) and (Data[P + 2] = 1) then
    begin
      if Start >= 0 then
      begin
        var Last := P;
        while (Last > Start) and (Data[Last - 1] = 0) do
          Dec(Last);
        if Last > Start then
          Result := Result + [Copy(Data, Start, Last - Start)];
      end;
      Start := P + 3;
      Inc(P, 3);
    end
    else
      Inc(P);
  end;
  if (Start >= 0) and (Start < N) then
    Result := Result + [Copy(Data, Start, N - Start)];
end;

{ TPSPAvc }

constructor TPSPAvc.Create;
begin
  inherited Create;
  FHeld := TList<TPSPPicture>.Create;
  Reset;
end;

destructor TPSPAvc.Destroy;
begin
  FreeAndNil(FDecoder);
  FHeld.Free;
  inherited;
end;

procedure TPSPAvc.Reset;
begin
  FreeAndNil(FDecoder);
  FDecoder := TH264Decoder.Create;
  FDecoder.ConfigureAnnexB(True);
  for var I := 0 to High(FSps) do
    FSps[I] := Default(TPSPAvcSps);
  for var I := 0 to High(FPpsSps) do
  begin
    FPpsSps[I] := -1;
    FPpsBottom[I] := False;
  end;
  FActive := -1;
  FHeld.Clear;
  FCount := 0;
  FPrevPocMsb := 0;
  FPrevPocLsb := 0;
  FPrevFrameNum := 0;
  FPrevFrameNumOffset := 0;
  FConfigured := True;
  FLastSei := Default(TPSPAvcSei);
  FHasPicture := False;
end;

function TPSPAvc.ActiveSps: TPSPAvcSps;
begin
  if FActive >= 0 then
    Result := FSps[FActive]
  else
    Result := Default(TPSPAvcSps);
end;

procedure TPSPAvc.ParseSps(const Rbsp: TBytes);
var
  B: TBitReader;
  S: TPSPAvcSps;

  procedure Hrd;
  begin
    var Count := B.ReadUE + 1;
    S.CpbCount := Count;
    B.Skip(8);
    for var J := 1 to Count do
    begin
      B.ReadUE;
      B.ReadUE;
      B.Skip(1);
    end;
    B.Skip(5);
    S.CpbDelayLength := B.ReadBits(5) + 1;
    S.DpbDelayLength := B.ReadBits(5) + 1;
    S.TimeOffsetLength := B.ReadBits(5);
  end;

begin
  S := Default(TPSPAvcSps);
  B.Init(Rbsp);
  var Id: Cardinal := 0;
  try
    S.Profile := B.ReadBits(8);
    B.Skip(8);
    S.Level := B.ReadBits(8);
    Id := B.ReadUE;
    if Id > 31 then
      Exit;
    if S.Profile in [100, 110, 122, 244, 44, 83, 86, 118, 128] then
    begin
      var Chroma := B.ReadUE;
      if Chroma = 3 then
        B.Skip(1);
      B.ReadUE;
      B.ReadUE;
      B.Skip(1);
      if B.ReadBit then
        for var I := 0 to 7 do
          if B.ReadBit then
          begin
            var Size := 16;
            if I >= 6 then
              Size := 64;
            var Last := 8;
            var Next := 8;
            for var J := 0 to Size - 1 do
            begin
              if Next <> 0 then
                Next := (Last + B.ReadSE + 256) mod 256;
              if Next <> 0 then
                Last := Next;
            end;
          end;
    end;
    S.LogFrameNum := B.ReadUE + 4;
    S.PocType := B.ReadUE;
    if S.PocType = 0 then
      S.LogPocLsb := B.ReadUE + 4
    else if S.PocType = 1 then
    begin
      S.DeltaPocAlwaysZero := B.ReadBit;
      B.ReadSE;
      B.ReadSE;
      var N := B.ReadUE;
      for var I := 1 to N do
        B.ReadSE;
    end;
    S.MaxRefs := B.ReadUE;
    B.Skip(1);
    S.MBWidth := B.ReadUE + 1;
    S.MBHeight := B.ReadUE + 1;
    var FrameOnly := B.ReadBit;
    if not FrameOnly then
      B.Skip(1);
    B.Skip(1);
    if B.ReadBit then
    begin
      S.CropLeft := B.ReadUE;
      S.CropRight := B.ReadUE;
      S.CropTop := B.ReadUE;
      S.CropBottom := B.ReadUE;
    end;
    S.Width := S.MBWidth * 16 - (S.CropLeft + S.CropRight) * 2;
    S.Height := S.MBHeight * 16 - (S.CropTop + S.CropBottom) * 2;
    S.MaxDecFrameBuffering := -1;
    if B.ReadBit then
    begin
      if B.ReadBit then
        if B.ReadBits(8) = 255 then
          B.Skip(32);
      if B.ReadBit then
        B.Skip(1);
      if B.ReadBit then
      begin
        B.Skip(3);
        S.FullRange := B.ReadBit;
        if B.ReadBit then
          B.Skip(24);
      end;
      if B.ReadBit then
      begin
        B.ReadUE;
        B.ReadUE;
      end;
      S.Timing := B.ReadBit;
      if S.Timing then
      begin
        S.UnitsInTick := B.ReadBits(32);
        S.TimeScale := B.ReadBits(32);
        B.Skip(1);
      end;
      var NalHrd := B.ReadBit;
      if NalHrd then
        Hrd;
      var VclHrd := B.ReadBit;
      if VclHrd then
        Hrd;
      S.Hrd := NalHrd or VclHrd;
      if S.Hrd then
        B.Skip(1);
      S.PicStruct := B.ReadBit;
      if B.ReadBit then
      begin
        B.Skip(1);
        for var J := 1 to 4 do
          B.ReadUE;
        B.ReadUE;
        S.MaxDecFrameBuffering := B.ReadUE;
      end;
    end;
    S.Valid := True;
    FSps[Id] := S;
  except
    on EBitstreamError do
      if S.MBWidth > 0 then
      begin
        S.Valid := True;
        FSps[Id] := S;
      end;
  end;
end;

procedure TPSPAvc.ParsePps(const Rbsp: TBytes);
var
  B: TBitReader;
begin
  B.Init(Rbsp);
  try
    var Id := B.ReadUE;
    var SpsId := B.ReadUE;
    if (Id > 255) or (SpsId > 31) then
      Exit;
    B.Skip(1);
    FPpsBottom[Id] := B.ReadBit;
    FPpsSps[Id] := SpsId;
  except
    on EBitstreamError do ;
  end;
end;

procedure TPSPAvc.ParseSei(const Rbsp: TBytes; var Sei: TPSPAvcSei);
begin
  var P := 0;
  var N := Length(Rbsp);
  while P < N do
  begin
    if (P = N - 1) and (Rbsp[P] = $80) then
      Break;
    var PayloadType := 0;
    while (P < N) and (Rbsp[P] = $FF) do
    begin
      Inc(PayloadType, 255);
      Inc(P);
    end;
    if P >= N then
      Break;
    Inc(PayloadType, Rbsp[P]);
    Inc(P);
    var Size := 0;
    while (P < N) and (Rbsp[P] = $FF) do
    begin
      Inc(Size, 255);
      Inc(P);
    end;
    if P >= N then
      Break;
    Inc(Size, Rbsp[P]);
    Inc(P);
    if P + Size > N then
      Size := N - P;
    var Payload := Copy(Rbsp, P, Size);
    var S := FActive;
    if S < 0 then
      for var I := 0 to 31 do
        if FSps[I].Valid then
        begin
          S := I;
          Break;
        end;
    if (S >= 0) and FSps[S].Valid then
    begin
      var B: TBitReader;
      B.Init(Payload);
      try
        case PayloadType of
          0: Sei.HasBuffering := True;
          1:
            if FSps[S].Hrd then
            begin
              Sei.HasTiming := True;
              Sei.CpbRemovalDelay := B.ReadBits(FSps[S].CpbDelayLength);
              Sei.DpbOutputDelay := B.ReadBits(FSps[S].DpbDelayLength);
              if FSps[S].PicStruct then
                Sei.PicStruct := B.ReadBits(4);
            end
            else if FSps[S].PicStruct then
              Sei.PicStruct := B.ReadBits(4);
        end;
      except
        on EBitstreamError do ;
      end;
    end;
    Inc(P, Size);
  end;
end;

function TPSPAvc.SlicePoc(const Rbsp: TBytes; NalType, RefIdc: Integer): Integer;
var
  B: TBitReader;
begin
  Result := Integer(FCount) * 2;
  B.Init(Rbsp);
  try
    B.ReadUE;
    B.ReadUE;
    var PpsId := B.ReadUE;
    if (PpsId > 255) or (FPpsSps[PpsId] < 0) then
      Exit;
    FActive := FPpsSps[PpsId];
    var S := FSps[FActive];
    if not S.Valid then
      Exit;
    var FrameNum := Integer(B.ReadBits(S.LogFrameNum));
    var Idr := NalType = 5;
    if Idr then
      B.ReadUE;
    case S.PocType of
      0:
        begin
          var Lsb := Integer(B.ReadBits(S.LogPocLsb));
          if Idr then
          begin
            FPrevPocMsb := 0;
            FPrevPocLsb := 0;
          end;
          var MaxLsb := 1 shl S.LogPocLsb;
          var Msb: Integer;
          if (Lsb < FPrevPocLsb) and (FPrevPocLsb - Lsb >= MaxLsb div 2) then
            Msb := FPrevPocMsb + MaxLsb
          else if (Lsb > FPrevPocLsb) and (Lsb - FPrevPocLsb > MaxLsb div 2) then
            Msb := FPrevPocMsb - MaxLsb
          else
            Msb := FPrevPocMsb;
          Result := Msb + Lsb;
          if RefIdc <> 0 then
          begin
            FPrevPocMsb := Msb;
            FPrevPocLsb := Lsb;
          end;
        end;
      2:
        begin
          var MaxFrameNum := 1 shl S.LogFrameNum;
          var Offset: Integer;
          if Idr then
            Offset := 0
          else if FPrevFrameNum > FrameNum then
            Offset := FPrevFrameNumOffset + MaxFrameNum
          else
            Offset := FPrevFrameNumOffset;
          if Idr then
            Result := 0
          else if RefIdc = 0 then
            Result := 2 * (Offset + FrameNum) - 1
          else
            Result := 2 * (Offset + FrameNum);
          FPrevFrameNumOffset := Offset;
          FPrevFrameNum := FrameNum;
        end;
    end;
  except
    on EBitstreamError do ;
  end;
end;

function TPSPAvc.TakeDue(out Pictures: TArray<TPSPPicture>): Integer;
begin
  Pictures := nil;
  var S := ActiveSps;
  if S.Hrd then
  begin
    while True do
    begin
      var Best := -1;
      for var I := 0 to FHeld.Count - 1 do
        if FHeld[I].OutAt <= FCount then
          if (Best < 0) or (FHeld[I].OutAt < FHeld[Best].OutAt) or
            ((FHeld[I].OutAt = FHeld[Best].OutAt) and (FHeld[I].Index < FHeld[Best].Index)) then
            Best := I;
      if Best < 0 then
        Break;
      Pictures := Pictures + [FHeld[Best]];
      FHeld.Delete(Best);
    end;
  end
  else
  begin
    while FHeld.Count > 3 do
    begin
      var Best := 0;
      for var I := 1 to FHeld.Count - 1 do
        if FHeld[I].Poc < FHeld[Best].Poc then
          Best := I;
      Pictures := Pictures + [FHeld[Best]];
      FHeld.Delete(Best);
    end;
  end;
  Result := Length(Pictures);
end;

function TPSPAvc.Decode(const Au: TBytes; out Pictures: TArray<TPSPPicture>): Cardinal;
begin
  Pictures := nil;
  Result := 0;
  var Nals := SplitAnnexB(Au);
  var Sei := Default(TPSPAvcSei);
  var Poc := Integer(FCount) * 2;
  var HasSlice := False;
  var Idr := False;
  for var Nal in Nals do
  begin
    if Length(Nal) < 1 then
      Continue;
    var T := Nal[0] and $1F;
    var RefIdc := (Nal[0] shr 5) and 3;
    case T of
      7: ParseSps(UnescapeNAL(Copy(Nal, 1, Length(Nal) - 1), True));
      8: ParsePps(UnescapeNAL(Copy(Nal, 1, Length(Nal) - 1), True));
      6: ParseSei(UnescapeNAL(Copy(Nal, 1, Length(Nal) - 1), True), Sei);
      1, 5:
        if not HasSlice then
        begin
          HasSlice := True;
          Idr := T = 5;
          Poc := SlicePoc(UnescapeNAL(Copy(Nal, 1, Min(Length(Nal) - 1, 64)), True), T, RefIdc);
        end;
    end;
  end;
  if not HasSlice then
    Exit;
  var S := ActiveSps;
  if S.Valid and (S.MaxRefs > 3) then
    Exit(Cardinal($80628002));
  FLastSei := Sei;
  var Packet := Default(TMediaPacket);
  Packet.Data := Au;
  Packet.PTS := FCount;
  try
    FDecoder.SendAnnexB(Packet);
    FDecoder.Flush;
  except
    on E: Exception do
    begin
      FDecoder.Reset;
      Exit(Cardinal($80628002));
    end;
  end;
  var Frame: TVideoFrame;
  while FDecoder.Receive(Frame) do
  begin
    var Pic := Default(TPSPPicture);
    Pic.Width := Frame.Width;
    Pic.Height := Frame.Height;
    Pic.Y := Frame.Planes[0];
    Pic.Cb := Frame.Planes[1];
    Pic.Cr := Frame.Planes[2];
    Pic.Poc := Poc;
    Pic.Index := FCount;
    if S.Hrd and Sei.HasTiming then
    begin
      var Frames := Int64(Sei.DpbOutputDelay) div 2;
      Pic.OutAt := FCount + Frames;
    end
    else
      Pic.OutAt := FCount;
    FHeld.Add(Pic);
    FLastPicture := Pic;
    FHasPicture := True;
  end;
  TakeDue(Pictures);
  Inc(FCount);
end;

function TPSPAvc.Drain(out Pictures: TArray<TPSPPicture>): Integer;
begin
  Pictures := nil;
  while FHeld.Count > 0 do
  begin
    var Best := 0;
    for var I := 1 to FHeld.Count - 1 do
      if ActiveSps.Hrd then
      begin
        if (FHeld[I].OutAt < FHeld[Best].OutAt) or ((FHeld[I].OutAt = FHeld[Best].OutAt) and (FHeld[I].Index < FHeld[Best].Index)) then
          Best := I;
      end
      else if FHeld[I].Poc < FHeld[Best].Poc then
        Best := I;
    Pictures := Pictures + [FHeld[Best]];
    FHeld.Delete(Best);
  end;
  Result := Length(Pictures);
end;

end.
