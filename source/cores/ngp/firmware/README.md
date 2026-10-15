# Embedded SNK system ROMs

Added at the user's explicit request on 2026-10-15.

| File | Size | CRC32 | SHA-1 |
| --- | ---: | --- | --- |
| ngp_bios.bin | 65536 | 6232df8d | 2f6429b68446536d8b03f35d02f1e98beb6460a0 |
| ngpc_bios.bin | 65536 | 6eeb6f40 | edc13192054a59be49c6d55f83b70e2510968e86 |

The hashes match the NGP/NGPC firmware declarations in
[MAME's SNK driver](https://github.com/mamedev/mame/blob/master/src/mame/snk/ngp.cpp).
The embedded resource loader verifies SHA-1 and size before use.

Download sources:

- [Neo Geo Pocket BIOS](https://github.com/Abdess/retrobios/blob/main/bios/SNK/Neo%20Geo%20Pocket/SNK%20Neo-Geo%20Pocket%20BIOS%20%281998%29%28SNK%29%28en-ja%29.bin)
- [Neo Geo Pocket Color BIOS](https://github.com/Abdess/retrobios/blob/main/bios/SNK/Neo%20Geo%20Pocket/SNK%20Neo-Geo%20Pocket%20Color%20BIOS%20%281999%29%28SNK%29%28en-ja%29.bin)

These are SNK firmware data, separate from the BSD-licensed CPU implementation.
To regenerate the resource, run `brcc32 NGP.Firmware.rc` from the parent directory.
