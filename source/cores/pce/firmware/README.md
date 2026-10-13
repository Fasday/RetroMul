# System Card firmware

The original, unmodified System Card images are embedded by `PCE.Firmware.rc`.
Each is 262144 bytes. Resource loading validates size and CRC32. Acquisition
verified MD5 as well; `manifest.json` records URLs, CRC32, MD5, SHA-1 and SHA-256.

| File | Revision | Region | MD5 |
| --- | --- | --- | --- |
| syscard1.pce | System Card 1.0 | Japan | 2b7ccb3d86baa18f6402c176f3065082 |
| syscard2.pce | System Card 2.0 | Japan | 3cdd6614a918616bfc41c862e889dd79 |
| syscard2u.pce | System Card 2.0 | USA | 94279f315e8b52904f65ab3108542afe |
| syscard3.pce | Super System Card 3.0 | Japan | 38179df8f4ac870017db21ebcbf53114 |
| syscard3u.pce | Super System Card 3.0 | USA | 0754f903b52e3b3342202bdafb13efa5 |

Retrieved from the [retroarch_system firmware archive](https://github.com/interface/retroarch_system/tree/libretro/NEC%20-%20PC%20Engine%20-%20TurboGrafx%2016%20-%20SuperGrafx).
The Japanese 3.0 checksum also matches [RetroPie documentation](https://github.com/RetroPie/RetroPie-Docs/blob/master/docs/PC-Engine.md).
These are NEC/Hudson firmware images, not RetroMul source code or an external
host library. Their inclusion does not change their original ownership or
grant a new license to redistribute them.

Rebuild the resource from this directory using RAD Studio's
`brcc32.exe PCE.Firmware.rc`. Preserve the original firmware bytes; rebuild the `.res`
when the `.rc` changes. No separate BIOS deployment is required.
