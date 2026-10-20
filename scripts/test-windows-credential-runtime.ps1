param([Parameter(Mandatory=$true)][string]$FlutterBin, [Parameter(Mandatory=$true)][string]$GhExecutable, [string]$CliExecutable='')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if($env:OS -ne 'Windows_NT'){throw 'Windows is required.'}
$projectRoot=Split-Path -Parent $PSScriptRoot
$flutter=(Get-Item -LiteralPath (Join-Path $FlutterBin 'flutter.bat')).FullName
$dart=(Get-Item -LiteralPath (Join-Path $FlutterBin 'cache/dart-sdk/bin/dart.exe')).FullName
$gh=(Get-Item -LiteralPath $GhExecutable).FullName
$cliDirectory=(Get-Item -LiteralPath (Join-Path $projectRoot 'packages/info_cli')).FullName
Push-Location (Join-Path $projectRoot 'apps/desktop')
try {
  & $flutter test integration_test/credential_runtime_native_test.dart -d windows --no-pub "--dart-define=DART_EXECUTABLE=$dart" "--dart-define=CLI_DIRECTORY=$cliDirectory" "--dart-define=GH_EXECUTABLE=$gh" "--dart-define=CLI_EXECUTABLE=$CliExecutable"
  if($LASTEXITCODE -ne 0){throw 'Isolated Windows runtime acceptance failed.'}
} finally {Pop-Location}
