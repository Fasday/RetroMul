# Screen gamepad

NES also offers `TScreenGamepadLayout.Dendy`, drawn after the four-button clone
controller with black B/A and red Turbo B/Turbo A above them. Select
**Dendy · Turbo** in NES / Famicom → Controls for the desired player port,
apply settings, and reopen the ROM to connect the device. The standard NES
gamepad remains available. The settings and controls-help diagrams use the
selected layout, including independent keyboard or physical-pad assignments
for both turbo buttons. Four Score ports can also use this device.

The common input uses X for Turbo B and Y for Turbo A on a `paddendy` NES port.
These buttons remain held in `TScreenGamepad.Buttons`; the NES worker converts
them into ordinary serial A/B bits, with two frames pressed and two released
(about 15 repeats/s at NTSC and 12.5 at PAL). Each button, source and player has
its own phase; a fresh hold starts pressed, and repeated input updates preserve
the phase. Ordinary A/B holds take priority over the released turbo phase.
Pause freezes the phase. Releasing contacts, changing layouts, clearing input
or disconnecting a source stops its turbo. Standard NES ports ignore X/Y.

`TScreenGamepad` shares the touch tracking and painting implementation between
NES and the six-button SEGA Mega Drive / Genesis layout. Set `Layout` to
`TScreenGamepadLayout.Sega` for X/Y/Z above A/B/C, a D-pad, Start and Mode.
Its `Buttons` and `ButtonBounds` use `TEmulatorButton` from `Core.Emulation`.
Changing layouts releases all contacts, including stale pointer IDs.
`RM.Main` selects the layout from the loaded core's configuration and forwards
the complete button set through `IEmulationCore.SetGamepadInput`. The MD adapter
maps C/X/Y/Z/Mode directly; Select remains a legacy alias for C. NES, GB and GBC
ignore the additional SEGA buttons. The Android form still uses one native
touch listener for the active screen control.

`TNesGamepad` is a self-painted FMX control in `NES.Gamepad.pas`. It contains
the D-pad, A/B and Select/Start, without a dependency on the emulator thread.
It scales its geometry from its actual width and height. Extra width separates
the two hand areas; `PreferredHeight` provides a suitable height for a bottom
panel. Hit areas stay fixed while buttons animate. It now wraps `TScreenGamepad`
and preserves the existing `TNesButton` / `TNesButtons` API.

```pascal
Gamepad := TNesGamepad.Create(Self);
Gamepad.Parent := Self;
Gamepad.Align := TAlignLayout.Bottom;
Gamepad.Height := TNesGamepad.PreferredHeight(ClientWidth, ClientHeight);
Gamepad.OnChange := GamepadChanged;
```

Call `AttachToForm(Self)` after the form's native handle is available (for
example, from `OnActivate`). On Android the control installs a non-consuming
touch listener on the form view. Use one gamepad per form; this listener owns
that view's `OnTouchListener` slot. FMX continues to receive the events for other
controls. The adapter reads Android's pointer ID and action index directly:
Delphi 13's FMX `OnTouch` path assigns the global action to every pointer,
which cannot reliably identify a single finger being lifted.

`OnChange` is synchronous on the UI thread. `Buttons: TNesButtons` is the union
of all contacts. The application forwards it through
`TNesEmulationThread.SetButtons(INPUT_SCREEN_GAMEPAD, 1, Gamepad.Buttons)`;
keyboard and screen input remain independent sources.

- A contact stays assigned to the D-pad, action buttons or menu area until up.
- Direction slides support diagonals and a center dead zone. Opposing directions
  from multiple contacts cancel each other until one is released.
- A/B support separate fingers and sliding between the two buttons.
- Press/release animations use 75/140 ms easing with tint, scale and shadow changes.
  The animation timer stops when all transitions finish.
- Call `ReleaseAll` when pausing, opening a modal UI or losing focus. Disabling,
  hiding and resizing the control also clear contacts.
- Desktop mouse input supports captured dragging. The application currently
  displays the screen controller on Android only.

The host form updates the height on resize and applies all four safe-area
insets. It releases input on backgrounding, ROM replacement and emulation errors.

Local checks: `tests/GamepadTests.dpr` covers responsive geometry, three contact
IDs, diagonal sliding, independent release, duplicate contacts, cancellation and
rotation. It also renders normal/pressed states to PNG. Thread tests verify
that releasing screen input preserves a keyboard-held button.
The same tests cover all twelve SEGA controls at portrait/landscape sizes,
simultaneous touches across both action rows, independent release, sliding and
NES/SEGA layout changes. `GamepadFrontendTests` checks layout selection on ROM replacement;
`MultiCoreAdapterTests` verifies GB/GBC ignore the SEGA-only buttons.
