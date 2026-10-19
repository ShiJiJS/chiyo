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

function Invoke-LockedGet {
    param([string]$Executable)
    $lockPath = Join-Path (Get-Location) 'pubspec.lock'
    $originalLock = [IO.File]::ReadAllBytes($lockPath)
    try {
        # The configured mirror needs its own cache URL. Change only that URL
        # for resolution, enforce every pinned version/hash, then restore bytes.
        if ($env:PUB_HOSTED_URL -eq 'https://pub.flutter-io.cn') {
            $temporaryLock = [Text.Encoding]::UTF8.GetString($originalLock).Replace('https://pub.dev', 'https://pub.flutter-io.cn')
            [IO.File]::WriteAllText($lockPath, $temporaryLock, (New-Object Text.UTF8Encoding($false)))
        }
        $arguments = @('pub', 'get', '--enforce-lockfile')
        if ($Offline) { $arguments += '--offline' }
        Invoke-Checked $Executable $arguments
    } finally {
        [IO.File]::WriteAllBytes($lockPath, $originalLock)
    }
}

foreach ($package in Get-ChildItem (Join-Path $projectRoot 'packages') -Directory | Sort-Object Name) {
    if (-not (Test-Path (Join-Path $package.FullName 'pubspec.yaml'))) { continue }
    Push-Location $package.FullName
    try {
        Write-Host "Checking $($package.Name)"
        Invoke-LockedGet $dartCommand
        Invoke-Checked $dartCommand @('analyze', '--fatal-infos')
        Invoke-Checked $dartCommand @('test')
    } finally { Pop-Location }
}

Push-Location (Join-Path $projectRoot 'apps/desktop')
try {
    Invoke-LockedGet $flutterCommand
    Invoke-Checked $flutterCommand @('analyze', '--fatal-infos', '--no-pub')
    # The explicit test/ path excludes native integration_test/ runners.
    Invoke-Checked $flutterCommand @('test', '--no-pub', 'test/')
    if ($WindowsRelease) {
        Invoke-Checked $flutterCommand @('build', 'windows', '--release', '--no-pub')
    }
    if ($MacosRelease) {
        Invoke-Checked $flutterCommand @('build', 'macos', '--release', '--no-pub')
    }
} finally { Pop-Location }

Write-Host 'Headless checks passed. No desktop application was launched.'
