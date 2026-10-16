param([Parameter(Mandatory=$true)][string]$FlutterBin)
$ErrorActionPreference='Stop'
$projectRoot=Split-Path -Parent $PSScriptRoot
Push-Location (Join-Path $projectRoot 'apps/desktop')
try {
  & (Join-Path $FlutterBin 'flutter.bat') test integration_test/history_settings_native_test.dart -d windows
  if($LASTEXITCODE -ne 0) {throw 'Isolated history/settings native acceptance failed.'}
} finally {Pop-Location}
