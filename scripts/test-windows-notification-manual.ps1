param(
    [Parameter(Mandatory = $true)][string]$FlutterBin,
    [switch]$Run
)

# Explicit operator opt-in. Opens ONLY the isolated temporary-library runner,
# sends one real Shell balloon and waits at most 60 seconds for a real click.
# Does not request/change notification permission or open a default profile.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $Run) { throw 'Manual probe is disabled. Coordinate an operator, then explicitly pass -Run.' }
if ($env:OS -ne 'Windows_NT') { throw 'This probe requires Windows.' }
$projectRoot = Split-Path -Parent $PSScriptRoot
$flutter = (Get-Item -LiteralPath (Join-Path $FlutterBin 'flutter.bat')).FullName
Push-Location (Join-Path $projectRoot 'apps/desktop')
try {
    & $flutter test integration_test/manual_notification_test.dart -d windows --no-pub '--dart-define=D1_MANUAL_NOTIFICATION=true'
    if ($LASTEXITCODE -ne 0) { throw 'Real Windows notification click was NOT verified; inspect the probe output.' }
} finally { Pop-Location }
