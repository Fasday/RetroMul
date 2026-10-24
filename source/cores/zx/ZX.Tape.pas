unit ZX.Tape;

interface

uses
  System.Classes, System.SysUtils, System.Generics.Collections, Core.Snapshots;

type
  TZXSignal = record
    Duration: Int64;
    Level: Boolean;
  end;

  TZXTapeBlock = record
    ID: Byte;
    Offset, Size: Integer;
  end;

  TZXTapeLoop = record
    BlockIndex, Remaining: Integer;
  end;

  TZXTapeCall = record
    BlockIndex, NextCall: Integer;
  end;

  TZXTape = class
  private
    FData: TBytes;
    FBlocks: TArray<TZXTapeBlock>;
    FSignals: TArray<TZXSignal>;
    FLoops: TArray<TZXTapeLoop>;
    FCalls: TArray<TZXTapeCall>;
    FBlock, FSignalBlock, FPosition, FSelectionBlock: Integer;
    FRemaining, FMessageTicks: Int64;
    FLevel, FNextLevel, FStartLevel, FStopped, FIs128: Boolean;
    FChoices: TArray<string>;
    FTargets: TArray<Integer>;
    FMessage: string;
    FSnapshot: TBytes;
    FSnapshotType: Byte;
    function U(Offset, Bytes: Integer): Cardinal;
    function Text(Offset, Count: Integer): string;
    function RelativeTarget(BlockIndex, Offset: Integer): Integer;
    procedure DecodePause(BlockIndex: Integer);
    procedure DecodeWave(BlockIndex: Integer);
    function NextBlock: Boolean;
  public
    procedure Load(const Data: TBytes; TZX: Boolean; Is128: Boolean = False);
    procedure Rewind;
    procedure Play;
    procedure Stop;
    procedure Select(Index: Integer);
    procedure Tick;
    function TakeSnapshot(out Data: TBytes; out Kind: Byte): Boolean;
    procedure SerializeState(State: TStateArchive);
    property Model128: Boolean read FIs128 write FIs128;
    property Level: Boolean read FLevel;
    property Position: Integer read FBlock;
    property Stopped: Boolean read FStopped;
    property Choices: TArray<string> read FChoices;
    property MessageText: string read FMessage;
  end;

implementation

uses
  System.Math, System.ZLib;

const
  MaxSignals = 16 * 1024 * 1024;

function TZXTape.U(Offset, Bytes: Integer): Cardinal;
begin
  if (Offset < 0) or (Bytes < 1) or (Bytes > 4) or (Offset > Length(FData) - Bytes) then
    raise EReadError.Create('Truncated TZX block');
  Result := 0;
  for var I := 0 to Bytes - 1 do
    Result := Result or (Cardinal(FData[Offset + I]) shl (8 * I));
end;

function TZXTape.Text(Offset, Count: Integer): string;
begin
  SetLength(Result, Count);
  for var I := 1 to Count do
    Result[I] := Char(FData[Offset + I - 1]);
end;

function TZXTape.RelativeTarget(BlockIndex, Offset: Integer): Integer;
begin
  var Delta := Integer(U(Offset, 2));
  if Delta >= $8000 then
    Dec(Delta, $10000);
  Result := BlockIndex + Delta;
  if (Result < 0) or (Result > Length(FBlocks)) then
    raise EReadError.Create('TZX jump outside tape');
end;

procedure TZXTape.Load(const Data: TBytes; TZX, Is128: Boolean);
begin
  FIs128 := Is128;
  if Length(Data) > 8 * 1024 * 1024 then
    raise EReadError.Create('TZX image exceeds 8 MiB');
  if not TZX then
  begin
    var Stream := TBytesStream.Create;
    try
      var Header: TBytes := [90, 88, 84, 97, 112, 101, 33, 26, 1, 20];
      Stream.WriteBuffer(Header[0], Length(Header));
      var P := 0;
      while P < Length(Data) do
      begin
        if P > Length(Data) - 2 then
          raise EReadError.Create('Truncated TAP length');
        var N := Integer(Data[P]) or (Integer(Data[P + 1]) shl 8);
        if (N < 2) or (N > Length(Data) - P - 2) then
          raise EReadError.Create('Truncated TAP payload');
        var Prefix: TBytes := [$10, $E8, 3];
        Stream.WriteBuffer(Prefix[0], 3);
        Stream.WriteBuffer(Data[P], N + 2);
        Inc(P, N + 2);
      end;
      FData := Copy(Stream.Bytes, 0, Stream.Size);
    finally
      Stream.Free;
    end;
  end
  else
    FData := Copy(Data);
  if (Length(FData) < 10) or (TEncoding.ASCII.GetString(FData, 0, 8) <> 'ZXTape!'#26) or
    (FData[8] <> 1) then
    raise EReadError.Create('Invalid or unsupported TZX header');
  var Blocks := TList<TZXTapeBlock>.Create;
  try
    var P := 10;
    while P < Length(FData) do
    begin
      var B: TZXTapeBlock;
      B.ID := FData[P];
      Inc(P);
      B.Offset := P;
      var N: Int64;
      case B.ID of
        $10:
          N := 4 + Int64(U(P + 2, 2));
        $11:
          N := 18 + Int64(U(P + 15, 3));
        $12:
          N := 4;
        $13:
          N := 1 + U(P, 1) * 2;
        $14:
          N := 10 + Int64(U(P + 7, 3));
        $15:
          N := 8 + Int64(U(P + 5, 3));
        $16:
          N := 40 + Int64(U(P + 37, 3));
        $17:
          N := 22 + Int64(U(P + 19, 3));
        $18, $19, $2A, $2B:
          N := 4 + Int64(U(P, 4));
        $20, $23, $24:
          N := 2;
        $21, $30:
          N := 1 + U(P, 1);
        $22, $25, $27:
          N := 0;
        $26:
          N := 2 + U(P, 2) * 2;
        $28, $32:
          N := 2 + U(P, 2);
        $31:
          N := 2 + U(P + 1, 1);
        $33:
          N := 1 + U(P, 1) * 3;
        $34:
          N := 8;
        $35:
          N := 20 + Int64(U(P + 16, 4));
        $40:
          N := 4 + Int64(U(P + 1, 3));
        $5A:
          N := 9;
      else
        N := 4 + Int64(U(P, 4)); // General extension rule for future blocks.
      end;
      if (N < 0) or (N > Length(FData) - P) then
        raise EReadError.Create('Truncated TZX payload');
      B.Size := N;
      Blocks.Add(B);
      Inc(P, B.Size);
      if Blocks.Count > 100000 then
        raise EReadError.Create('Too many TZX blocks');
    end;
    FBlocks := Blocks.ToArray;
  finally
    Blocks.Free;
  end;
  if Length(FBlocks) = 0 then
    raise EReadError.Create('Empty Spectrum tape');
  FNextLevel := False;
  for var I := 0 to High(FBlocks) do
  begin
    if FBlocks[I].ID in [$10..$19] then
      DecodeWave(I);
    var P := FBlocks[I].Offset;
    case FBlocks[I].ID of
      $16, $17:
        if (U(P, 4) <> Cardinal(FBlocks[I].Size)) and
          (U(P, 4) <> Cardinal(FBlocks[I].Size - 4)) then
          raise EReadError.Create('Invalid legacy TZX length');
      $23:
        RelativeTarget(I, P);
      $28:
        begin
          var EndPos := P + FBlocks[I].Size;
          var Count := Integer(U(P + 2, 1));
          Inc(P, 3);
          if Count = 0 then
            raise EReadError.Create('Empty TZX selection');
          for var J := 1 to Count do
          begin
            if P > EndPos - 3 then
              raise EReadError.Create('Truncated TZX selection');
            RelativeTarget(I, P);
            Inc(P, 3 + Integer(U(P + 2, 1)));
            if P > EndPos then
              raise EReadError.Create('Truncated TZX selection text');
          end;
          if P <> EndPos then
            raise EReadError.Create('Invalid TZX selection length');
        end;
      $26:
        for var J := 0 to Integer(U(P, 2)) - 1 do
          RelativeTarget(I, P + 2 + J * 2);
      $2A:
        if FBlocks[I].Size <> 4 then
          raise EReadError.Create('Invalid TZX 48K stop');
      $2B:
        if (FBlocks[I].Size <> 5) or (U(P + 4, 1) > 1) then
          raise EReadError.Create('Invalid TZX signal level');
      $40:
        if (U(P, 1) > 1) or (FBlocks[I].Size = 4) then
          raise EReadError.Create('Invalid embedded TZX snapshot');
    end;
  end;
  Rewind;
end;

procedure TZXTape.DecodePause(BlockIndex: Integer);
begin
  var MS := U(FBlocks[BlockIndex].Offset, 2);
  SetLength(FSignals, 1 + Ord(MS > 1));
  FSignals[0].Duration := 3500;
  FSignals[0].Level := FStartLevel;
  if MS > 1 then
  begin
    FSignals[1].Duration := Int64(MS - 1) * 3500;
    FSignals[1].Level := False;
  end;
  FNextLevel := False;
end;

procedure TZXTape.DecodeWave(BlockIndex: Integer);
type
  TSymbol = record
    Flags: Byte;
    Pulses: TArray<Word>;
  end;
var
  P, Finish, Pause, Bits, N, Pilot, Sync1, Sync2, Zero, One, Count: Integer;
  Signals: TList<TZXSignal>;

  function ReadN(Bytes: Integer): Cardinal;
  begin
    if P > Finish - Bytes then
      raise EReadError.Create('Truncated TZX wave data');
    Result := U(P, Bytes);
    Inc(P, Bytes);
  end;

  procedure Signal(Duration: Int64; Value: Boolean);
  begin
    if Duration = 0 then
      Exit;
    if (Duration < 0) or (Signals.Count >= MaxSignals) then
      raise EReadError.Create('TZX waveform exceeds limit');
    var S: TZXSignal;
    S.Duration := Duration;
    S.Level := Value;
    Signals.Add(S);
  end;

  procedure Pulse(Duration: Integer);
  begin
    if Duration <= 0 then
      raise EReadError.Create('Zero TZX pulse');
    Signal(Duration, FNextLevel);
    FNextLevel := not FNextLevel;
  end;

  procedure Silence(MS: Integer);
  begin
    if MS = 0 then
      Exit;
    Signal(3500, FNextLevel);
    FNextLevel := False;
    if MS > 1 then
      Signal(Int64(MS - 1) * 3500, False);
  end;

  procedure Payload;
  begin
    if (N < 1) or (N > Finish - P) or (Bits < 1) or (Bits > 8) then
      raise EReadError.Create('Invalid TZX data');
    for var I := 1 to Count do
      Pulse(Pilot);
    if Sync1 > 0 then
      Pulse(Sync1);
    if Sync2 > 0 then
      Pulse(Sync2);
    for var I := 1 to N do
    begin
      var V := ReadN(1);
      var Used := 8;
      if I = N then
        Used := Bits;
      for var B := 7 downto 8 - Used do
      begin
        var T := Zero;
        if (V and (1 shl B)) <> 0 then
          T := One;
        Pulse(T);
        Pulse(T);
      end;
    end;
    Silence(Pause);
  end;

  procedure CSW;
  begin
    Pause := ReadN(2);
    var Rate := ReadN(3);
    var Compression := ReadN(1);
    var Expected := ReadN(4);
    if (Rate = 0) or not (Compression in [1, 2]) or (Expected > MaxSignals) then
      raise EReadError.Create('Invalid TZX CSW header');
    var Bytes := Copy(FData, P, Finish - P);
    if Compression = 2 then
    begin
      var Input := TBytesStream.Create(Bytes);
      try
        var Decoder := TDecompressionStream.Create(Input);
        try
          var Output := TBytesStream.Create;
          try
            var Buffer: array[0..8191] of Byte;
            repeat
              var Got := Decoder.Read(Buffer, SizeOf(Buffer));
              if Got = 0 then
                Break;
              if Output.Size > 64 * 1024 * 1024 - Got then
                raise EReadError.Create('TZX CSW inflation limit');
              Output.WriteBuffer(Buffer, Got);
            until False;
            Bytes := Copy(Output.Bytes, 0, Output.Size);
          finally
            Output.Free;
          end;
        finally
          Decoder.Free;
        end;
      finally
        Input.Free;
      end;
    end;
    var Pos := 0;
    var Seen: Cardinal := 0;
    var Fraction: Int64 := 0;
    while Pos < Length(Bytes) do
    begin
      var Samples: Cardinal := Bytes[Pos];
      Inc(Pos);
      if Samples = 0 then
      begin
        if Pos > Length(Bytes) - 4 then
          raise EReadError.Create('Truncated CSW long pulse');
        Samples := Cardinal(Bytes[Pos]) or (Cardinal(Bytes[Pos + 1]) shl 8) or
          (Cardinal(Bytes[Pos + 2]) shl 16) or (Cardinal(Bytes[Pos + 3]) shl 24);
        Inc(Pos, 4);
        if Samples = 0 then
          raise EReadError.Create('Zero CSW pulse');
      end;
      Inc(Seen);
      if Seen > Expected then
        raise EReadError.Create('CSW pulse count mismatch');
      Fraction := Fraction + Int64(Samples) * 3500000;
      Signal(Fraction div Rate, FNextLevel);
      Fraction := Fraction mod Rate;
      FNextLevel := not FNextLevel;
    end;
    if Seen <> Expected then
      raise EReadError.Create('CSW pulse count mismatch');
    if Seen <> 0 then
      FNextLevel := not FNextLevel;
    P := Finish;
    Silence(Pause);
  end;

  function Alphabet(Count, Pulses: Integer): TArray<TSymbol>;
  begin
    if Count = 0 then
      Count := 256;
    SetLength(Result, Count);
    for var I := 0 to Count - 1 do
    begin
      Result[I].Flags := ReadN(1);
      if Result[I].Flags > 3 then
        raise EReadError.Create('Invalid generalized symbol flags');
      SetLength(Result[I].Pulses, Pulses);
      for var J := 0 to Pulses - 1 do
        Result[I].Pulses[J] := ReadN(2);
    end;
  end;

  procedure Symbol(const S: TSymbol);
  begin
    case S.Flags of
      1:
        FNextLevel := not FNextLevel;
      2:
        FNextLevel := False;
      3:
        FNextLevel := True;
    end;
    for var T in S.Pulses do
    begin
      if T = 0 then
        Break;
      Pulse(T);
    end;
  end;

  procedure Generalized;
  begin
    Pause := ReadN(2);
    var PilotCount := ReadN(4);
    var PilotPulses := ReadN(1);
    var PilotAlphabet := ReadN(1);
    var DataCount := ReadN(4);
    var DataPulses := ReadN(1);
    var DataAlphabet := ReadN(1);
    if (PilotCount > MaxSignals) or (DataCount > MaxSignals) then
      raise EReadError.Create('Generalized TZX symbol limit');
    if PilotCount <> 0 then
    begin
      var Symbols := Alphabet(PilotAlphabet, PilotPulses);
      for var I := 1 to PilotCount do
      begin
        var Index := ReadN(1);
        var RepeatCount := ReadN(2);
        if (Index >= Cardinal(Length(Symbols))) or (RepeatCount = 0) then
          raise EReadError.Create('Invalid generalized pilot symbol');
        for var J := 1 to RepeatCount do
          Symbol(Symbols[Index]);
      end;
    end;
    if DataCount <> 0 then
    begin
      var Symbols := Alphabet(DataAlphabet, DataPulses);
      var Width := 0;
      while (1 shl Width) < Length(Symbols) do
        Inc(Width);
      var BitIndex: Int64 := 0;
      var Start := P;
      if (Int64(DataCount) * Width + 7) div 8 > Finish - P then
        raise EReadError.Create('Truncated generalized bitstream');
      for var I := 1 to DataCount do
      begin
        var Index := 0;
        for var J := 1 to Width do
        begin
          Index := (Index shl 1) or ((FData[Start + BitIndex div 8] shr (7 - BitIndex mod 8)) and 1);
          Inc(BitIndex);
        end;
        if Index >= Length(Symbols) then
          raise EReadError.Create('Invalid generalized data symbol');
        Symbol(Symbols[Index]);
      end;
      Inc(P, (BitIndex + 7) div 8);
    end;
    Silence(Pause);
  end;

  procedure Wave(T: Integer);
  begin
    if T <> 0 then
    begin
      FNextLevel := False;
      Pulse(T);
      Pulse(T);
    end;
  end;

  procedure Legacy;
  begin
    var B := FBlocks[BlockIndex];
    var O := B.Offset;
    if B.ID = $16 then
    begin
      var Extra := U(O + 20, 1);
      Bits := U(O + 33, 1);
      N := U(O + 37, 3);
      if not (Extra in [0, 1, 255]) or (Bits < 1) or (Bits > 8) then
        raise EReadError.Create('Invalid C64 ROM block');
      for var I := 1 to U(O + 6, 2) do
        Wave(U(O + 4, 2));
      Wave(U(O + 8, 2));
      Wave(U(O + 10, 2));
      P := O + 40;
      for var I := 1 to N do
      begin
        var V := ReadN(1);
        var Used := 8;
        if I = N then
          Used := Bits;
        var Checksum := Extra;
        for var J := 0 to Used - 1 do
        begin
          var Bit := J;
          if (U(O + 34, 1) and 1) <> 0 then
            Bit := 7 - J;
          var OneBit := (V shr Bit) and 1;
          Checksum := Checksum xor OneBit;
          Wave(U(O + 12 + Integer(OneBit) * 4, 2));
          Wave(U(O + 14 + Integer(OneBit) * 4, 2));
        end;
        if Extra <> 255 then
        begin
          Wave(U(O + 12 + Integer(Checksum) * 4, 2));
          Wave(U(O + 14 + Integer(Checksum) * 4, 2));
        end;
        if I < N then
        begin
          Wave(U(O + 21, 2));
          Wave(U(O + 23, 2));
        end;
      end;
      Wave(U(O + 25, 2));
      Wave(U(O + 27, 2));
      for var I := 1 to U(O + 31, 2) do
        Wave(U(O + 29, 2));
      Silence(U(O + 35, 2));
    end
    else
    begin
      Bits := U(O + 12, 1);
      N := U(O + 19, 3);
      if (Bits < 1) or (Bits > 8) then
        raise EReadError.Create('Invalid C64 turbo last bits');
      var Extra := U(O + 8, 1);
      var Total := U(O + 9, 2) + Cardinal(N) + U(O + 14, 2);
      for var I := 0 to Integer(Total) - 1 do
      begin
        var V := U(O + 11, 1);
        var Used := 8;
        if I >= Integer(U(O + 9, 2)) + N then
          V := U(O + 16, 1)
        else if I >= Integer(U(O + 9, 2)) then
        begin
          V := U(O + 22 + I - Integer(U(O + 9, 2)), 1);
          if I = Integer(U(O + 9, 2)) + N - 1 then
            Used := Bits;
        end;
        if (Extra and 4) = 0 then
          for var J := 1 to (Extra and 3) do
            Wave(U(O + 4 + Integer((Extra shr 3) and 1) * 2, 2));
        for var J := 0 to Used - 1 do
        begin
          var Bit := J;
          if (U(O + 13, 1) and 1) <> 0 then
            Bit := 7 - J;
          Wave(U(O + 4 + Integer((V shr Bit) and 1) * 2, 2));
        end;
        if (Extra and 4) <> 0 then
          for var J := 1 to (Extra and 3) do
            Wave(U(O + 4 + Integer((Extra shr 3) and 1) * 2, 2));
      end;
      P := Finish;
      Silence(U(O + 17, 2));
    end;
  end;

begin
  P := FBlocks[BlockIndex].Offset;
  Finish := P + FBlocks[BlockIndex].Size;
  Signals := TList<TZXSignal>.Create;
  try
    Pilot := 2168;
    Sync1 := 667;
    Sync2 := 735;
    Zero := 855;
    One := 1710;
    Count := 0;
    Bits := 8;
    case FBlocks[BlockIndex].ID of
      $10:
        begin
          Pause := ReadN(2);
          N := ReadN(2);
          if P >= Finish then
            raise EReadError.Create('Empty standard TZX block');
          if U(P, 1) < 128 then
            Count := 8063
          else
            Count := 3223;
          Payload;
        end;
      $11:
        begin
          Pilot := ReadN(2);
          Sync1 := ReadN(2);
          Sync2 := ReadN(2);
          Zero := ReadN(2);
          One := ReadN(2);
          Count := ReadN(2);
          Bits := ReadN(1);
          Pause := ReadN(2);
          N := ReadN(3);
          Payload;
        end;
      $12:
        begin
          Pilot := ReadN(2);
          Count := ReadN(2);
          for var I := 1 to Count do
            Pulse(Pilot);
        end;
      $13:
        begin
          Count := ReadN(1);
          for var I := 1 to Count do
            Pulse(ReadN(2));
        end;
      $14:
        begin
          Zero := ReadN(2);
          One := ReadN(2);
          Bits := ReadN(1);
          Pause := ReadN(2);
          N := ReadN(3);
          Sync1 := 0;
          Sync2 := 0;
          Payload;
        end;
      $15:
        begin
          var Duration := ReadN(2);
          Pause := ReadN(2);
          Bits := ReadN(1);
          N := ReadN(3);
          if (Duration = 0) or (Bits < 1) or (Bits > 8) then
            raise EReadError.Create('Invalid TZX direct recording');
          for var I := 1 to N do
          begin
            var V := ReadN(1);
            var Used := 8;
            if I = N then
              Used := Bits;
            for var J := 7 downto 8 - Used do
            begin
              FNextLevel := (V and (1 shl J)) <> 0;
              Signal(Duration, FNextLevel);
            end;
          end;
          Silence(Pause);
        end;
      $16, $17:
        Legacy;
      $18:
        begin
          ReadN(4);
          CSW;
        end;
      $19:
        begin
          ReadN(4);
          Generalized;
        end;
    end;
    if P <> Finish then
      raise EReadError.Create('TZX waveform length mismatch');
    FSignals := Signals.ToArray;
  finally
    Signals.Free;
  end;
end;

function TZXTape.NextBlock: Boolean;
begin
  Result := False;
  for var Step := 1 to 100000 do
  begin
    if (FBlock < 0) or (FBlock >= Length(FBlocks)) then
    begin
      FStopped := True;
      Exit;
    end;
    var Index := FBlock;
    var B := FBlocks[Index];
    var P := B.Offset;
    var Finish := P + B.Size;
    Inc(FBlock);
    FSignalBlock := -1;
    case B.ID of
      $10..$19:
        begin
          FStartLevel := FNextLevel;
          DecodeWave(Index);
          FSignalBlock := Index;
          FPosition := 0;
          if Length(FSignals) > 0 then
            Exit(True);
        end;
      $20:
        begin
          var MS := U(P, 2);
          if MS = 0 then
          begin
            FStopped := True;
            FMessageTicks := 0;
            FMessage := 'Tape stopped. F7: play';
            Exit;
          end;
          FStartLevel := FNextLevel;
          DecodePause(Index);
          FSignalBlock := Index;
          FPosition := 0;
          Exit(True);
        end;
      $23:
        FBlock := RelativeTarget(Index, P);
      $24:
        begin
          if Length(FLoops) >= 64 then
            raise EReadError.Create('TZX loop nesting limit');
          var L: TZXTapeLoop;
          L.BlockIndex := FBlock;
          L.Remaining := U(P, 2);
          if L.Remaining = 0 then
            raise EReadError.Create('Zero TZX loop count');
          FLoops := FLoops + [L];
        end;
      $25:
        begin
          var I := High(FLoops);
          if I < 0 then
            raise EReadError.Create('TZX return without loop');
          Dec(FLoops[I].Remaining);
          if FLoops[I].Remaining > 0 then
            FBlock := FLoops[I].BlockIndex
          else
            SetLength(FLoops, I);
        end;
      $26:
        begin
          if U(P, 2) = 0 then
            Continue;
          if Length(FCalls) >= 64 then
            raise EReadError.Create('TZX call nesting limit');
          var C: TZXTapeCall;
          C.BlockIndex := Index;
          C.NextCall := 1;
          FCalls := FCalls + [C];
          FBlock := RelativeTarget(Index, P + 2);
        end;
      $27:
        begin
          var I := High(FCalls);
          if I < 0 then
            raise EReadError.Create('TZX return without call');
          var C := FCalls[I];
          var Origin := FBlocks[C.BlockIndex].Offset;
          if C.NextCall < Integer(U(Origin, 2)) then
          begin
            FBlock := RelativeTarget(C.BlockIndex, Origin + 2 + C.NextCall * 2);
            Inc(FCalls[I].NextCall);
          end
          else
          begin
            FBlock := C.BlockIndex + 1;
            SetLength(FCalls, I);
          end;
        end;
      $28:
        begin
          var N := Integer(U(P + 2, 1));
          Inc(P, 3);
          FChoices := nil;
          FTargets := nil;
          for var I := 0 to N - 1 do
          begin
            if P > Finish - 3 then
              raise EReadError.Create('Truncated TZX selection');
            var Target := RelativeTarget(Index, P);
            var Size := Integer(U(P + 2, 1));
            Inc(P, 3);
            if Size > Finish - P then
              raise EReadError.Create('Truncated TZX selection text');
            FChoices := FChoices + [Text(P, Size)];
            FTargets := FTargets + [Target];
            Inc(P, Size);
          end;
          if (P <> Finish) or (N = 0) then
            raise EReadError.Create('Invalid TZX selection block');
          FSelectionBlock := Index;
          FStopped := True;
          FMessageTicks := 0;
          FMessage := 'Select tape part (1..9): ' + string.Join(' | ', FChoices);
          Exit;
        end;
      $2A:
        if not FIs128 then
        begin
          FStopped := True;
          FMessageTicks := 0;
          FMessage := '48K tape stop. F7: continue';
          Exit;
        end;
      $2B:
        begin
          FNextLevel := U(P + 4, 1) <> 0;
          FLevel := FNextLevel;
        end;
      $30:
        begin
          FMessage := Text(P + 1, U(P, 1));
          FMessageTicks := 0;
        end;
      $31:
        begin
          FMessage := Text(P + 2, U(P + 1, 1));
          FMessageTicks := Int64(U(P, 1)) * 3500000;
          if U(P, 1) = 0 then
          begin
            FStopped := True;
            Exit;
          end;
        end;
      $40:
        begin
          FSnapshotType := U(P, 1);
          FSnapshot := Copy(FData, P + 4, B.Size - 4);
          FStopped := True;
          Exit;
        end;
    end;
  end;
  raise EReadError.Create('TZX control flow makes no progress');
end;

procedure TZXTape.Rewind;
begin
  FBlock := 0;
  FPosition := 0;
  FRemaining := 0;
  FSignalBlock := -1;
  FSelectionBlock := -1;
  FLevel := False;
  FNextLevel := False;
  FStopped := False;
  FSignals := nil;
  FChoices := nil;
  FMessageTicks := 0;
  FLoops := nil;
  FCalls := nil;
  FTargets := nil;
  FMessage := '';
  FSnapshot := nil;
end;

procedure TZXTape.Play;
begin
  if Length(FChoices) = 0 then
  begin
    FStopped := False;
    FMessage := '';
  end;
end;

procedure TZXTape.Stop;
begin
  FStopped := True;
  FMessageTicks := 0;
  FMessage := 'Tape paused. F7: play';
end;

procedure TZXTape.Select(Index: Integer);
begin
  if (Index < 0) or (Index >= Length(FChoices)) then
    raise EArgumentOutOfRangeException.Create('TZX selection');
  FBlock := FTargets[Index];
  FChoices := nil;
  FTargets := nil;
  FSelectionBlock := -1;
  FStopped := False;
  FRemaining := 0;
  FPosition := 0;
  FSignalBlock := -1;
  FSignals := nil;
  FMessage := '';
  FLevel := False;
  FNextLevel := False;
end;

procedure TZXTape.Tick;
begin
  if FMessageTicks > 0 then
  begin
    Dec(FMessageTicks);
    if FMessageTicks = 0 then
      FMessage := '';
  end;
  if FStopped then
    Exit;
  if FRemaining = 0 then
  begin
    if FPosition >= Length(FSignals) then
    begin
      FLevel := FNextLevel;
      if not NextBlock then
        Exit;
    end;
    FRemaining := FSignals[FPosition].Duration;
    FLevel := FSignals[FPosition].Level;
    Inc(FPosition);
  end;
  Dec(FRemaining);
end;

function TZXTape.TakeSnapshot(out Data: TBytes; out Kind: Byte): Boolean;
begin
  Result := Length(FSnapshot) <> 0;
  Data := FSnapshot;
  Kind := FSnapshotType;
  FSnapshot := nil;
  if Result then
    Play;
end;

procedure TZXTape.SerializeState(State: TStateArchive);
begin
  State.Field(FBlock, SizeOf(FBlock));
  State.Field(FSignalBlock, SizeOf(FSignalBlock));
  State.Field(FPosition, SizeOf(FPosition));
  State.Field(FRemaining, SizeOf(FRemaining));
  State.Field(FLevel, SizeOf(FLevel));
  State.Field(FNextLevel, SizeOf(FNextLevel));
  State.Field(FStartLevel, SizeOf(FStartLevel));
  State.Field(FStopped, SizeOf(FStopped));
  var Selection := FSelectionBlock;
  State.Field(Selection, SizeOf(Selection));
  var N := Length(FLoops);
  State.Field(N, SizeOf(N));
  if (N < 0) or (N > 64) then
    raise EReadError.Create('Invalid TZX loop state');
  if State.Loading then
    SetLength(FLoops, N);
  for var I := 0 to N - 1 do
    State.Field(FLoops[I], SizeOf(TZXTapeLoop));
  N := Length(FCalls);
  State.Field(N, SizeOf(N));
  if (N < 0) or (N > 64) then
    raise EReadError.Create('Invalid TZX call state');
  if State.Loading then
    SetLength(FCalls, N);
  for var I := 0 to N - 1 do
    State.Field(FCalls[I], SizeOf(TZXTapeCall));
  State.Field(FMessageTicks, SizeOf(FMessageTicks));
  var MessageBytes := TEncoding.UTF8.GetBytes(FMessage);
  N := Length(MessageBytes);
  State.Field(N, SizeOf(N));
  if (N < 0) or (N > 65536) then
    raise EReadError.Create('Invalid TZX message state');
  if State.Loading then
    SetLength(MessageBytes, N);
  if N > 0 then
    State.Field(MessageBytes[0], N);
  if State.Loading then
  begin
    FMessage := TEncoding.UTF8.GetString(MessageBytes);
    for var L in FLoops do
      if (L.BlockIndex < 1) or (L.BlockIndex >= Length(FBlocks)) or (L.Remaining < 1) or
        (L.Remaining > 65535) or (FBlocks[L.BlockIndex - 1].ID <> $24) then
        raise EReadError.Create('Invalid TZX loop state');
    for var C in FCalls do
    begin
      if (C.BlockIndex < 0) or (C.BlockIndex >= Length(FBlocks)) or
        (FBlocks[C.BlockIndex].ID <> $26) then
        raise EReadError.Create('Invalid TZX call state');
      if (C.NextCall < 1) or (C.NextCall > Integer(U(FBlocks[C.BlockIndex].Offset, 2))) then
        raise EReadError.Create('Invalid TZX call position');
    end;
    if (FBlock < 0) or (FBlock > Length(FBlocks)) or (FSignalBlock < -1) or
      (FSignalBlock >= Length(FBlocks)) or (FRemaining < 0) or (Selection < -1) or
      (Selection >= Length(FBlocks)) then
      raise EReadError.Create('Invalid TZX state');
    var NextLevel := FNextLevel;
    FSignals := nil;
    if FSignalBlock >= 0 then
    begin
      FNextLevel := FStartLevel;
      if FBlocks[FSignalBlock].ID = $20 then
        DecodePause(FSignalBlock)
      else
        DecodeWave(FSignalBlock);
    end;
    FNextLevel := NextLevel;
    if (FPosition < 0) or (FPosition > Length(FSignals)) then
      raise EReadError.Create('Invalid TZX pulse position');
    FChoices := nil;
    FTargets := nil;
    FSnapshot := nil;
    FSelectionBlock := Selection;
    if (FRemaining > 0) and ((FPosition = 0) or (FRemaining > FSignals[FPosition - 1].Duration)) then
      raise EReadError.Create('Invalid TZX remaining pulse');
    if Selection >= 0 then
    begin
      if FBlocks[Selection].ID <> $28 then
        raise EReadError.Create('Invalid TZX selection state');
      var Resume := FBlock;
      FBlock := Selection;
      NextBlock;
      FBlock := Resume;
    end;
  end;
end;

end.

