# Embedded SMS firmware

Original Sega Master System BIOS dumps downloaded from SMS Power's technical archive:

- US/Europe v1.3: BIOS13FX.zip, 8192 bytes, CRC32 0072ed54.
- Japan v2.1 (MPR-11124, dumped by Hiroshi): MPR11124.zip, 8192 bytes, CRC32 48d44a13.

The binaries are unmodified; sizes, SHA-1, SHA-256 and source URLs are in manifest.json. Original Sega firmware is not relicensed by RetroMul's source license.

The adapter uses the export BIOS for export cartridge headers, and the Japanese BIOS for Japanese/headerless ROMs when BIOS is enabled and no custom file is configured. Custom paths take precedence. Disabling BIOS selects direct cartridge boot. Mark III has no automatic internal BIOS.

See https://www.smspower.org/Development/BIOSes for behavior and provenance. The export BIOS checks cartridge header, region and checksum; invalid homebrew/hacks can be rejected, as on hardware.
