# PSP executable and Pauth decryption

The former `PSP.PRX.pas` and `PSP.AES.pas` have been replaced, not wrapped or
retained as fallback implementations. The new Pascal implementation comprises:

- `PSP.AES`: AES-128, zero-IV CBC without padding and CMAC.
- `PSP.Crypto.ECDSA`: 160-bit integer arithmetic and KIRK1 ECDSA verification.
- `PSP.Crypto.Kirk`: KIRK7 slot-key CBC and authenticated KIRK1 decryption.
- `PSP.PRX`: PRX metadata normalization, authentication and bounded gzip/ELF output.
- `PSP.Crypto`: the guest `scePauth` service.
- `PSP.Crypto.Keys.inc`: numeric device data only, separate from the implementation.

## Sources and provenance

1. **FIPS 197**, **NIST SP 800-38A / 800-38B**: AES, CBC and CMAC definitions
   and known-answer tests. The S-box and multiplication tables are generated
   from GF(2^8); they are not imported from an emulator or crypto library.
2. **PSP Developer Wiki [Keys](https://www.psdevwiki.com/psp/Keys)** and
   **[Kirk](https://www.psdevwiki.com/psp/Kirk)**, saved HTML supplied by the user:
   KIRK slot values, PRX seeds, the Pauth whitening constant, curve parameters
   and authenticated-envelope layout. `import_crypto_keys.py` extracts numeric
   values, not routines; the generated include records the source HTML SHA-256.
   These values are existing published device facts, **not newly discovered keys**.
   The pages credit multiple PSP researchers/tools; rediscovery or independent
   origin of each individual numeric constant is not claimed.
3. **uOFW**, a PSP firmware reverse-engineering project, not an emulator:
   [`src/kd/mesg_led/mesg_led.c`](https://github.com/uofw/uofw/blob/master/src/kd/mesg_led/mesg_led.c)
   (git blob `86ab9d31fa443763838eb0f3ae843f3bdbb26148`, file SHA-256
   `2773a9645c5ec607d1ee3dd55f3c5ce23ea5b1dadb0a0f0337f9ded75d05e7fb`),
   consulted to understand PRX/Pauth field routing. The Pascal decoder uses
   immutable input and separate normalized/authenticated stages, not the
   firmware's in-place scratch buffers or a line-by-line translation.
   The reverse-engineered listing has suspect offsets: the 16 bytes following
   `0x80..0xAF` come from `0xC0`, not `0xD0`. This was resolved by matching the
   header SHA-1 and KIRK authentication on real samples, not by skipping checks.
   uOFW's permissive notice is preserved in `PSP.PRX-LICENSE.md`.

No PPSSPP, JPCSP or other emulator implementation was used as the implementation
reference for this replacement. The previous executable was used only as a
black-box compatibility oracle: all **97** modules it successfully decoded from
the user's image collection have identical SHA-256 output with the new decoder.
The new decoder also authenticates/decrypts MHP3rd's D91681F0 main executable
and three ECDSA updater modules that the previous decoder rejected (**101/101**
encrypted module samples inspected in that collection).

This is independently authored code using published reverse-engineering work,
**not** a claim of a formally separated legal clean-room process. Removing old
source does not erase its provenance from git history.

## Envelope processing

All lengths and offsets are validated before copying or allocating. The caller's
input is not modified. Unknown formats fail explicitly; there is no "try keys
until plaintext looks like ELF" or unauthenticated-output fallback.

Legacy tags `00000000`, `02000000`, `03000000`, `08000000`, `C0CB167C` use the
published 144-byte schedules and their respective KIRK slots. The last tag also
has CBC-wrapped metadata. The outer SHA-1 is checked before KIRK1 authentication.

Game tags `D916xxF0` use nine CBC-derived blocks from a 16-byte seed. Ordinary
supported game envelopes reconstruct the CMAC variant of KIRK1; `D91680F0` and
`D91681F0` preserve the additional signature tail and reconstruct the ECDSA
variant. Both header and payload authentication are mandatory in either mode.

`scePauth` tags `2FD311F0`, `2FD312F0`, `2FD313F0` additionally weave the header
using the published whitening constant and the caller-provided 16-byte key.
Their authenticated plaintext is arbitrary data, not necessarily an ELF.
Guest memory is written only after successful verification; failure clears the
returned length and leaves the original ciphertext untouched.

The wiki prose interchanges the KIRK curve's p/n values; its executable example
and the curve equation agree with the values used here. This was independently
checked by curve membership and the published test scalar's public point.
That scalar is used **only by the synthetic test-fixture generator**, not by
the runtime, which implements verification only.

## Verification

```powershell
.\tests\cores\psp\run\build.ps1 -Project PSPCryptoTest.dpr -Checked
.\tests\cores\psp\run\bin\PSPCryptoTest_win64_checked.exe
.\tests\cores\psp\run\build.ps1 -Project PSPDecryptRun.dpr
.\tests\cores\psp\run\bin\PSPDecryptRun_win64.exe D:\Soft\PSP
```

`PSPCryptoTest` checks FIPS AES, all four NIST CMAC vectors, independently
generated CBC/PRX/KIRK/Pauth fixtures, immutable inputs, corrupt signatures,
wrong caller keys, truncation, bounded decompression and the actual guest HLE
entry point. Fixture generation uses PyCryptodome for AES/CMAC and a separate
Python-integer ECDSA implementation; no game code is committed in fixtures.

`monster_smoke.py` uses controller input to create a six-letter character,
save it, pass the opening movie and reach Yukumo's opening bath scene. At
22,500 frames the script stands the character up and moves him with analogue
input. The JIT and interpreter runs match all 37 captured frames, guest time,
final frame hash and guest cycle totals; a 6,000-frame GPU per-batch check also
has zero differences. A separate restart loads the saved character from an
explicit test memory stick (`PSPRun -memstick`), without changing the save file.
MHP3rd uses **Circle** to confirm its own menus; the utility OSK follows the
configured system confirm button. The `<>` savedata suffix marker now resolves
to the game directory, rather than becoming illegal host pathname characters.

## Limits

- This is not every PRX/DRM variation: unknown kernel/module tags and KL3E/KL4E
  compression remain unsupported. Firmware libraries can still be served by HLE.
- PGD/NPDRM content encryption, fuse-derived per-console operations and the whole
  KIRK instruction set are not implemented by this executable decoder.
- In-game saves still use RetroMul's existing local save representation; this
  work does **not** make secure saves interchangeable with a real PSP.
- Booting/creating a character is not proof of full-game completion. Monster
  Hunter's long sessions, quests, multiplayer and DLC need further validation;
  some menu text is incomplete with the current font fallback.
