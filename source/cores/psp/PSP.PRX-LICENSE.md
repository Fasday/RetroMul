# PSP PRX reference notices

`PSP.PRX.pas` implements the PRX wrapping protocol with reference to the PPSSPP
PRX decrypter. Protocol key data in `PSP.Keys.inc` is extracted from the pinned
PPSSPP tables and libkirk key vault, with the following upstream notices retained.
These files are supplied under GPL version 3 or later. The surrounding original
RetroMul code retains its existing notices; this file does not relicense it.

PPSSPP Project, copyright 2012 and contributors. Originally released under the
GNU General Public License version 2 or later.

libkirk, copyright 2010-2011 Proxima. This program is free software: you can
redistribute it and/or modify it under the terms of the GNU General Public
License as published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
PARTICULAR PURPOSE. See the GNU General Public License for more details.

The full license text is included at
`../../hardware/audio/atrac3plus/COPYING.GPL3.txt`.
Key-table acknowledgements in PPSSPP: PSARDUMPER and JPCSP.

`PSP.AES.pas` is an original implementation of AES-128 and CMAC, under the
repository's original license; it does not copy libkirk's AES implementation.

`PSP.Reverb.inc` retains PPSSPP's SAS reverb preset data (copyright 2015 and
PPSSPP contributors, GPL-2.0-or-later). `PSP.SAS.pas` uses that reference for
envelope and synthesis behavior and is supplied under GPL-3.0-or-later.
The native ATRAC3+ translation has separate notices under
`../../hardware/audio/atrac3plus/LICENSE.ATRAC3Plus.md`.
Distributed executables linking these components must comply with GPL-3.0-or-later.

`PSP.VFPUMath.pas` ports PPSSPP's hardware-verified quadratic VFPU
interpolator and coefficient tables from `Core/MIPS/MIPSVFPUUtils.cpp`
(copyright 2012- PPSSPP Project and contributors, GPL-2.0-or-later).
The port is supplied under GPL-3.0-or-later.

The native ATRAC3 translation has separate notices under
`../../hardware/audio/atrac3/LICENSE.ATRAC3.md`.
The AVC and AAC/MP3/transform source subsets retain their upstream notices in
`../../hardware/video/avc/ORIGIN.md` and
`../../hardware/audio/codecs/ORIGIN.md`, together with the applicable license texts.

`PSP.YCbCr.pas` implements the eight-buffer PSP image layout with reference to
PPSSPP's `sceVideocodec.cpp` and Jpcsp's `sceMpeg.java`. The port is supplied
under GPL-3.0-or-later with the upstream project attributions retained in source.

`PSP.RegistryData.inc` derives firmware registry defaults and font metadata from
PPSSPP's `Core/HLE/sceReg.cpp` (PPSSPP Project and contributors,
GPL-2.0-or-later). The derived tables are supplied under GPL-3.0-or-later;
virtual owner and first-boot defaults are replaced with RetroMul values.

The RCX recurrence in `PSP.VFPU.pas` ports PPSSPP's `vrnd_init` and
`vrnd_generate` from `Core/MIPS/MIPSVFPUUtils.cpp` (PPSSPP Project and
contributors, GPL-2.0-or-later). The port is supplied under GPL-3.0-or-later.
