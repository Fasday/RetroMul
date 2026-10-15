# Neo Geo Pocket / Pocket Color

Native Pascal implementation integrated with RetroMul's platform registry,
storage, input, settings, emulation worker, audio backend and snapshots.

- TLCS-900/H instruction set, banked registers, exceptions and micro-DMA.
- Existing RetroMul Z80 core, shared sound RAM, mailbox and interrupt signals.
- K1GE monochrome / K2GE colour planes, sprites, palettes and display window.
- T6W28 stereo attenuation, shared tone/noise generators and stereo DAC.
- Four 8-bit timers, timer chaining, ADC battery input, RTC and power NMI.
- Two cartridge flash windows, programming, identification and boot-block erase.
- Atomic cartridge saves and battery-backed system RAM; firmware-driven power-off.

Cartridges are identified by their headers. Supported containers are raw `.ngp`
and `.ngc` images, ZIPs containing one cartridge, and native Pascal decoded 7z.
For multi-image 7z collections, verified, unmodified English/world variants are
preferred, with filename order breaking ties. Unpacked archives are limited to 256 MiB. No external emulator core or native binary library is
loaded.

Both original 64 KiB BIOS images are embedded in `NGP.Firmware.res`. The optional
BIOS setting overrides the embedded image. The initial language/date setup is
the original firmware interface. Settings persist after orderly Stop or Reset;
the firmware warm-start path is used when system RAM is available. Cartridge
saves belong to each game; system RAM belongs to the console model and BIOS.

The TLCS-900/H ISA was translated from Wilbert Pol's BSD-3-Clause MAME
implementation. Its notice is in `source/hardware/cpu/TLCS900H.LICENSE`.
The bus, devices, worker and frontend integration are RetroMul components.

Validation materials are in `codex-work/neo-platforms`: 74,898 instruction
comparisons against a stand-alone MAME ISA oracle, native hardware/adapter/UI
tests, the Judge_ CPU diagnostic, and short runs of twelve commercial games.
These checks establish startup and exercised behavior, not complete playthroughs.

Known accuracy limits include cartridge bus wait states, serial/link cable,
watchdog reset, RTC alarms and the remaining on-chip 16-bit timer modes. Flash
operations complete synchronously. Full game compatibility and cycle accuracy
are not claimed.
