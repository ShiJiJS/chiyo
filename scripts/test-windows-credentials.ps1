param([Parameter(Mandatory=$true)][string]$FlutterBin,[switch]$WithNativePicker)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if($env:OS -ne 'Windows_NT'){throw 'This check requires Windows.'}
$projectRoot=Split-Path -Parent $PSScriptRoot
$flutter=(Get-Item -LiteralPath (Join-Path $FlutterBin 'flutter.bat')).FullName
$dart=(Get-Item -LiteralPath (Join-Path $FlutterBin 'cache/dart-sdk/bin/dart.exe')).FullName
$cliDirectory=(Get-Item -LiteralPath (Join-Path $projectRoot 'packages/info_cli')).FullName
Push-Location (Join-Path $projectRoot 'apps/desktop')
try {
  # WithNativePicker requires the operator to cancel the first dialog, then
  # choose the printed, synthetic fixture path in the second real OS dialog.
  $nativePicker=if($WithNativePicker){'true'}else{'false'}
  & $flutter test integration_test/credentials_native_test.dart -d windows "--dart-define=DART_EXECUTABLE=$dart" "--dart-define=CLI_DIRECTORY=$cliDirectory" "--dart-define=NATIVE_CREDENTIAL_PICKER=$nativePicker"
  if($LASTEXITCODE -ne 0){throw 'Isolated Windows credential acceptance failed.'}
}finally {Pop-Location}
