param(
    [string]$FlutterBin,
    [switch]$WindowsRelease,
    [switch]$MacosRelease,
    [switch]$Offline
)

$ErrorActionPreference = 'Stop'
if ($WindowsRelease -and $MacosRelease) {
    throw 'Choose the release target matching this host.'
}
$projectRoot = Split-Path -Parent $PSScriptRoot
if ($FlutterBin) {
    $env:PATH = "$FlutterBin;$env:PATH"
}
$flutterCommand = (Get-Command flutter -ErrorAction Stop).Source
$dartCommand = (Get-Command dart -ErrorAction Stop).Source

function Invoke-Checked {
    param([string]$Executable, [string[]]$Arguments)
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Check failed: $Executable $($Arguments -join ' ')"
    }
}

$getArguments = @('pub', 'get')
if ($Offline) { $getArguments += '--offline' }

foreach ($package in Get-ChildItem (Join-Path $projectRoot 'packages') -Directory | Sort-Object Name) {
    if (-not (Test-Path (Join-Path $package.FullName 'pubspec.yaml'))) { continue }
    Push-Location $package.FullName
    try {
        Write-Host "Checking $($package.Name)"
        Invoke-Checked $dartCommand $getArguments
        Invoke-Checked $dartCommand @('analyze', '--fatal-infos')
        Invoke-Checked $dartCommand @('test')
    } finally { Pop-Location }
}

Push-Location (Join-Path $projectRoot 'apps/desktop')
try {
    Invoke-Checked $flutterCommand $getArguments
    Invoke-Checked $flutterCommand @('analyze', '--fatal-infos')
    # The explicit test/ path excludes native integration_test/ runners.
    Invoke-Checked $flutterCommand @('test', 'test/')
    if ($WindowsRelease) {
        Invoke-Checked $flutterCommand @('build', 'windows', '--release')
    }
    if ($MacosRelease) {
        Invoke-Checked $flutterCommand @('build', 'macos', '--release')
    }
} finally { Pop-Location }

Write-Host 'Headless checks passed. No desktop application was launched.'
