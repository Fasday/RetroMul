# NES Zapper core API

`TNesConsole.Zapper` supports the NES/Famicom and Vs. System protocols.
For NES/Famicom it occupies port 2 and is disabled by default. When enabled it replaces the second controller, Power Pad,
Four Score port-2 output and Subor keyboard output. Port 1 is unchanged.
Disabling it restores the existing port-2 configuration.

For Vs. System the cartridge selects `VsMode`: the gun occupies port 1
(`$4016` D0), while the controller on port 2 remains usable. The host uses
exactly the same `TriggerPressed` and `OnReadLight` properties. NES 2.0
expansion device 7 and the known legacy Vs. Duck Hunt payloads connect the
gun automatically. The existing Zapper connection setting also selects this
protocol when a Vs. cartridge is loaded; an explicit pad/none setting can
disconnect it. Four Score and Miracle Piano cannot share the gun.
The logical gun selection remains in the existing port-2 connection setting;
`VsMode` determines its physical wiring, without changing saved host settings.

```pascal
Core.Zapper.OnReadLight :=
  function(const Mask: TNesZapperMask): Boolean
  begin
    // External photosensor implementation goes here.
    // True = light detected; False = darkness / aim outside the screen.
    Result := ReadExternalPhotoSensor(Mask);
  end;
Core.Zapper.Enabled := True;
Core.Zapper.TriggerPressed := True;  // release with False
```

`TNesZapperMask` and `TNesZapperLightCallback` are declared in `NES.Types`.
The callback runs synchronously on each emulated CPU read of `$4017`,
on the emulation thread, independently of `$4016` strobing and the trigger.
In Vs. mode it is sampled when the serial report is latched by `$4016`
strobing (and reads while strobe is high). The eight bits are
`0,0,0,0,1,0,light,trigger`, in that order; 1 means light detected.
The latched packet remains stable until the next strobe.
It must be fast, must not reenter the emulator, and must not retain the
borrowed mask. Change the callback, connection and trigger from that thread
or while emulation is stopped. No callback means darkness.

The mask is a 256 x 240 byte array indexed `[X, Y]`, with top-left origin:
0 is dark, 1 is a bright area still visible to the sensor. It comes from
the actual PPU output (including the game's white target flashes), not
from object recognition or the displayed/scaled frontend image.
It includes recently rendered scanlines instead of waiting for frame
publication. Pixels use a weighted RGB luminance threshold of 128/255
and expire after 26 scanlines. The PPU renders whole scanlines, so this
is an approximation; brightness-dependent analog decay and dot-level
CRT timing are not modeled. No mouse or display-coordinate mapping is
implemented here.

The device returns bit 3 clear for light, set for darkness, and bit 4 set
while `TriggerPressed` is true, following the
[NESdev Zapper protocol](https://www.nesdev.org/wiki/Zapper).
The trigger property represents the electrical switch state; mechanical
half-pull/release timing is the host's responsibility.

Reset releases the trigger and clears the optical image, retaining the
connection and callback. Snapshot format 4 saves the connection and trigger;
format 22 also saves the Vs. strobe and partially read serial packet. The
host callback and cartridge-selected protocol are retained, never serialized. Formats 2 and 3 remain
readable, retaining the configured connection and releasing the trigger.
The optical mask is rebuilt from restored PPU state.

Regression coverage: `codex-work/tests/ZapperTests.dpr`, plus the existing input and
snapshot suites. Build with the NES and NES mapper directories in the
Delphi unit search path and range/overflow checking enabled.
