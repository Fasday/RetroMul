// Uncomment to preview the mobile UI on a desktop target, then rebuild (Build).
// Alternatively, add ISMOBILE to the project's conditional defines.
{.$DEFINE ISMOBILE}

// Native mobile targets always use the mobile UI.
{$IF Defined(ANDROID) or Defined(IOS)}
  {$DEFINE ISMOBILE}
{$ENDIF}
