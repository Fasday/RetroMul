# Fetches the hardware test suite (pspautotests, results recorded on a PSP) and
# pspsdk (NID names and structure layouts used by nids.py).
$ErrorActionPreference = 'Stop'
Push-Location $PSScriptRoot
try {
  if (-not (Test-Path 'pspautotests')) { git clone --depth 1 https://github.com/hrydgard/pspautotests.git pspautotests }
  if (-not (Test-Path 'pspsdk')) { git clone --depth 1 https://github.com/pspdev/pspsdk.git pspsdk }
} finally {
  Pop-Location
}
