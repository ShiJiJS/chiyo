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
    $arguments = @('pub', 'get', '--enforce-lockfile')
    if ($Offline) { $arguments += '--offline' }
    Invoke-Checked $Executable $arguments
}

$lockSnapshots = @{}
foreach ($relative in @('packages/info_cli', 'packages/info_core', 'packages/info_remote', 'packages/info_storage', 'packages/info_workspace', 'apps/desktop')) {
    $lockPath = Join-Path $projectRoot "$relative/pubspec.lock"
    $lockSnapshots[$lockPath] = [IO.File]::ReadAllBytes($lockPath)
}
try {
    # Keep mirror URLs stable for the entire pipeline: tests can run Dart child
    # processes which also resolve packages. Never change versions or hashes.
    if ($env:PUB_HOSTED_URL -eq 'https://pub.flutter-io.cn') {
        foreach ($lockPath in $lockSnapshots.Keys) {
            $temporaryLock = [Text.Encoding]::UTF8.GetString($lockSnapshots[$lockPath]).Replace('https://pub.dev', 'https://pub.flutter-io.cn')
            [IO.File]::WriteAllText($lockPath, $temporaryLock, (New-Object Text.UTF8Encoding($false)))
        }
    }
foreach ($package in Get-ChildItem (Join-Path $projectRoot 'packages') -Directory | Sort-Object Name) {
    if (-not (Test-Path (Join-Path $package.FullName 'pubspec.yaml'))) { continue }
    Push-Location $package.FullName
    try {
        Write-Host "Checking $($package.Name)"
        Invoke-LockedGet $dartCommand
        Invoke-Checked $dartCommand @('analyze', '--fatal-infos')
        if (Test-Path -LiteralPath 'test' -PathType Container) {
            Invoke-Checked $dartCommand @('test')
        } else {
            Write-Host 'No standalone test directory; analysis completed. Contract consumers have their own tests.'
        }
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
        $nativeBuild = Join-Path $projectRoot 'apps/desktop/build/windows/x64'
        $cmakeEntry = Select-String -LiteralPath (Join-Path $nativeBuild 'CMakeCache.txt') -Pattern '^CMAKE_COMMAND:INTERNAL=(.+)$'
        if (-not $cmakeEntry) { throw 'Cannot locate the release build CMake executable.' }
        $cmake = $cmakeEntry.Matches.Groups[1].Value
        Invoke-Checked $cmake @('--build', $nativeBuild, '--config', 'Release', '--target', 'desktop_instance_test')
        Invoke-Checked (Join-Path $nativeBuild 'runner/instance-check/Release/desktop_instance_test.exe') @()
    }
    if ($MacosRelease) {
        $macFlutterSdk = Split-Path -Parent (Split-Path -Parent $flutterCommand)
        Invoke-Checked (Get-Command python3 -ErrorAction Stop).Source @(
            (Join-Path $PSScriptRoot 'build-macos-release.py'), $macFlutterSdk
        )
    }
} finally { Pop-Location }

} finally {
    $unexpectedLocks = @()
    foreach ($lockPath in $lockSnapshots.Keys) {
        $original = [Text.Encoding]::UTF8.GetString($lockSnapshots[$lockPath]).Replace('https://pub.flutter-io.cn', 'https://pub.dev').Replace("`r`n", "`n")
        if (-not (Test-Path -LiteralPath $lockPath)) {
            $unexpectedLocks += $lockPath
            continue
        }
        $current = [IO.File]::ReadAllText($lockPath).Replace('https://pub.flutter-io.cn', 'https://pub.dev').Replace("`r`n", "`n")
        if ($current -cne $original) {
            # Preserve unexpected edits for inspection rather than hiding an
            # upgrade or overwriting another editor's concurrent changes.
            $unexpectedLocks += $lockPath
        } else {
            [IO.File]::WriteAllBytes($lockPath, $lockSnapshots[$lockPath])
        }
    }
    if ($unexpectedLocks.Count -gt 0) {
        throw "Dependency locks changed beyond mirror URLs; preserved for inspection: $($unexpectedLocks -join ', ')"
    }
}

Write-Host 'Headless checks passed. No desktop application was launched.'
