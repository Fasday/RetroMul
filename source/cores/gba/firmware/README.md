# Built-in GBA firmware

RetroMul executes the unmodified emibios 0.1.6 firmware when no external BIOS is configured.
The emulator remains separately licensed; this firmware is LGPL-3.0-or-later.
The complete upstream source archive and license accompany the firmware here.
Copyright and attribution notices are retained in the archive.

Source: https://github.com/coolbho3k/emibios/tree/0.1.6
Release: https://github.com/coolbho3k/emibios/releases/tag/0.1.6
SHA-256: ca56efafc53af12f6ba2eec722302dd2cb725f65dd2ed8afdeb5d27bc14e2d08

To rebuild: extract emibios-0.1.6-source.zip and run `zig build` with Zig 0.16.
To replace at runtime: select your rebuilt 16384-byte file in GBA settings, Boot/File.
To replace the embedded copy: replace emibios-0.1.6.bin and recompile GBA.Firmware.rc using brcc32.
The compatibility tests can explicitly request the legacy HLE path; normal ROMs use
emibios, entering the cartridge after boot initialization and executing every SWI on ARM.
External BIOS files execute the full boot from address zero.

GBA.Firmware.res embeds the binary (16 KiB), complete corresponding source archive (236 KiB),
and license (43 KiB). LoadBuiltinGBABIOSSource/LoadBuiltinGBABIOSLicense expose exact copies
for extraction. The included license also contains the incorporated GPL terms.
Distributions retain these resources and the attribution notices.
