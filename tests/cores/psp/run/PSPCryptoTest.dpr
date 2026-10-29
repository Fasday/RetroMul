program PSPCryptoTest;

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, PSP.AES, PSP.PRX, PSP.Crypto.Kirk, PSP.Crypto.ECDSA,
  PSP.Types, PSP.Memory, PSP.CPU, PSP.HLE, PSP.Service, PSP.Crypto, PSP.Crypto.Keys;

{$I PSPCryptoFixtures.inc}

procedure Check(Ok: Boolean; const What: string);
begin
  if not Ok then raise Exception.Create(What);
end;

procedure Same(const A, B: TBytes; const What: string);
begin
  Check(PSPDigestEqual(A, B), What);
end;

procedure Primitives;
begin
  var A: TPSPAES;
  A.Init(PSPHex('000102030405060708090A0B0C0D0E0F'));
  var D := PSPHex('00112233445566778899AABBCCDDEEFF');
  var B: TPSPAESBlock;
  Move(D[0], B, 16);
  A.Encrypt(B);
  var Expected := PSPHex('69C4E0D86A7B0430D8CDB78070B4C55A');
  Check(CompareMem(@B[0], @Expected[0], 16), 'FIPS 197 encryption');
  A.Decrypt(B);
  Check(CompareMem(@B[0], @D[0], 16), 'FIPS 197 decryption');
  SetLength(D, 64);
  for var I := 0 to 63 do D[I] := I;
  Same(A.CBC(D, False), PSPHex(FixtureCBCZero), 'CBC independent oracle');
  Same(A.CBC(PSPHex(FixtureCBCZero), True), D, 'CBC inverse');
  A.Init(PSPHex('2B7E151628AED2A6ABF7158809CF4F3C'));
  Same(A.CMAC(nil), PSPHex('BB1D6929E95937287FA37D129B756746'), 'CMAC empty');
  D := PSPHex('6BC1BEE22E409F96E93D7E117393172A' + 'AE2D8A571E03AC9C9EB76FAC45AF8E51' +
    '30C81C46A35CE411E5FBC1191A0A52EF' + 'F69F2445DF4F9B17AD2B417BE66C3710');
  Same(A.CMAC(Copy(D, 0, 16)), PSPHex('070A16B46B4D4144F79BDD9DD04A287C'), 'CMAC 16');
  Same(A.CMAC(Copy(D, 0, 40)), PSPHex('DFA66747DE9AE63030CA32611497C827'), 'CMAC 40');
  Same(A.CMAC(D), PSPHex('51F0BEBF7E3B9D92FC49741779363CFE'), 'CMAC 64');
  var Bad := False;
  try A.Init(nil); except on EArgumentException do Bad := True; end;
  Check(Bad, 'AES rejects invalid key');
  Bad := False;
  try A.CBC(Copy(D, 0, 17), True); except on EArgumentException do Bad := True; end;
  Check(Bad, 'CBC rejects partial block');
  Writeln('PASS: AES-128 FIPS 197, independent CBC, all four SP 800-38B CMAC vectors');
end;

procedure RejectPRX(const Data: TBytes; const What: string);
begin
  var Bad := False;
  try DecryptPSPPRX(Data); except on E: EReadError do Bad := True; end;
  Check(Bad, What);
end;

procedure Envelopes;
begin
  var Expected := PSPHex(FixturePlainElf);
  for var Hex in [FixtureLegacy00000000, FixtureLegacy02000000, FixtureLegacy03000000,
    FixtureLegacy08000000, FixtureLegacyC0CB167C, FixtureModernD91605F0,
    FixtureModernD91680F0, FixtureModernD91681F0] do
  begin
    var D := PSPHex(Hex);
    var Before := Copy(D);
    Same(DecryptPSPPRX(D), Expected, 'PRX plaintext');
    Same(D, Before, 'PRX input immutable');
    for var At in [$28, $80, $12C, $150] do
    begin
      var Bad := Copy(D);
      Bad[At] := Bad[At] xor 1;
      RejectPRX(Bad, 'PRX rejects modified metadata/ciphertext');
    end;
    for var Size in [0, 1, 3, 8, 52, $14F] do RejectPRX(Copy(D, 0, Size), 'PRX truncation');
    RejectPRX(Copy(D, 0, Length(D) - 1), 'PRX truncated ciphertext');
  end;
  var K := PSPHex(FixtureSignedKirk);
  RejectPRX(PSPHex(FixtureGzipOversize), 'bounded gzip rejects oversized expansion');
  RejectPRX(PSPHex(FixtureGzipBroken), 'malformed authenticated gzip rejected as module error');
  var Wrapped := PSPHex('7E53434508000000') + PSPHex(FixtureModernD91681F0);
  Same(DecryptPSPPRX(Wrapped), Expected, 'SCE wrapper');
  for var I := 4 to 7 do Wrapped[I] := $FF;
  RejectPRX(Wrapped, 'truncated SCE wrapper extent');
  Same(PSPKirk1(K), PSPHex(FixtureZippedElf), 'signed KIRK1 fixture');
  var Hash := PSPSHA1(K, $60, $30);
  Check(PSPVerifyKirkSignature(Hash, Copy(K, $10, 40)), 'ECDSA independent signature');
  Check(not PSPVerifyKirkSignature(Hash, nil), 'ECDSA signature length');
  var Sig := Copy(K, $10, 40);
  FillChar(Sig[0], 20, 0);
  Check(not PSPVerifyKirkSignature(Hash, Sig), 'ECDSA r=0');
  Sig := Copy(K, $10, 40);
  FillChar(Sig[20], 20, $FF);
  Check(not PSPVerifyKirkSignature(Hash, Sig), 'ECDSA s out of range');
  for var At in [$10, $24, $38, $4C, $60, $70, $110] do
  begin
    var Bad := Copy(K);
    Bad[At] := Bad[At] xor 1;
    var Rejected := False;
    try PSPKirk1(Bad); except on EReadError do Rejected := True; end;
    Check(Rejected, 'KIRK rejects signature/body modification');
  end;
  for var Hex in [FixturePauth2FD311F0, FixturePauth2FD312F0, FixturePauth2FD313F0] do
  begin
    var D := PSPHex(Hex);
    var Second := D[$D1] = $13;
    Same(DecryptPSPPauth(D, PSPHex(FixtureCallerKey), Second), Expected, 'Pauth fixture');
    var Key := PSPHex(FixtureCallerKey);
    Key[0] := Key[0] xor 1;
    var Rejected := False;
    try DecryptPSPPauth(D, Key, Second); except on EReadError do Rejected := True; end;
    Check(Rejected, 'Pauth wrong caller key rejected');
  end;
  Writeln('PASS: five legacy PRX layouts, game CMAC/ECDSA, gzip, Pauth, mutation/truncation rejection');
end;

procedure GuestService;
begin
  var M := TPSPMemory.Create;
  var C := TPSPCPU.Create(M);
  var H := TPSPHLE.Create(C, M);
  var S := TPSPSystem.Create;
  S.Memory := M; S.CPU := C; S.HLE := H;
  var Service := TPSPCrypto.Create(S);
  try
    Service.Register;
    var D := PSPHex(FixturePauth2FD313F0);
    var Key := PSPHex(FixtureCallerKey);
    const Buffer = $08800000;
    const KeyAt = $08900000;
    const SizeAt = $08900100;
    M.WriteBytes(Buffer, D[0], Length(D));
    M.WriteBytes(KeyAt, Key[0], 16);
    C.Ctx.GPR[4] := Buffer; C.Ctx.GPR[5] := Length(D); C.Ctx.GPR[6] := SizeAt; C.Ctx.GPR[7] := KeyAt;
    H.Call(H.Find('scePauth', $98B83B5D));
    Check(C.Ctx.GPR[2] = 0, 'Pauth guest result');
    Check(M.Read32(SizeAt) = 128, 'Pauth guest size');
    var Plain := PSPHex(FixturePlainElf);
    Check(CompareMem(M.Ptr(Buffer, 128), @Plain[0], 128), 'Pauth guest plaintext');
    D[$80] := D[$80] xor 1;
    M.WriteBytes(Buffer, D[0], Length(D));
    C.Ctx.GPR[4] := Buffer; C.Ctx.GPR[5] := Length(D); C.Ctx.GPR[6] := SizeAt; C.Ctx.GPR[7] := KeyAt;
    H.Call(H.Find('scePauth', $98B83B5D));
    Check(C.Ctx.GPR[2] <> 0, 'Pauth guest error');
    Check(M.Read32(SizeAt) = 0, 'Pauth guest error size');
    Check(CompareMem(M.Ptr(Buffer, Length(D)), @D[0], Length(D)), 'Pauth failure leaves ciphertext unchanged');
    Writeln('PASS: Pauth HLE output/size, error handling and no unauthenticated plaintext');
  finally
    Service.Free; S.Free; H.Free; C.Free; M.Free;
  end;
end;

begin
  try
    Primitives;
    Envelopes;
    GuestService;
  except
    on E: Exception do
    begin
      Writeln(E.ClassName + ': ' + E.Message);
      ExitCode := 1;
    end;
  end;
end.
