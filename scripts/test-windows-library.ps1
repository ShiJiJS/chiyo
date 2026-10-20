param([Parameter(Mandatory=$true)][string]$FlutterBin)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if($env:OS -ne 'Windows_NT'){throw 'This check requires Windows.'}
$projectRoot=Split-Path -Parent $PSScriptRoot
$flutter=(Get-Item -LiteralPath (Join-Path $FlutterBin 'flutter.bat')).FullName
$dart=(Get-Item -LiteralPath (Join-Path $FlutterBin 'cache/dart-sdk/bin/dart.exe')).FullName
$cliDirectory=(Get-Item -LiteralPath (Join-Path $projectRoot 'packages/info_cli')).FullName
Push-Location (Join-Path $projectRoot 'apps/desktop')
try{
  & $flutter test integration_test/library_native_test.dart -d windows "--dart-define=DART_EXECUTABLE=$dart" "--dart-define=CLI_DIRECTORY=$cliDirectory"
  if($LASTEXITCODE -ne 0){throw 'Isolated Windows library acceptance failed.'}
}finally{Pop-Location}
