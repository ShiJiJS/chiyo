param(
    [ValidateSet('setup', 'doctor', 'analyze', 'smoke', 'test', 'build', 'run', 'flutter', 'dart')]
    [string]$Command = 'doctor'
)

$ToolArguments = @($args)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$sdkRoot = Join-Path $projectRoot '.tools/flutter'
$flutter = Join-Path $sdkRoot 'bin/flutter.bat'
$dart = Join-Path $sdkRoot 'bin/dart.bat'
$revision = 'abaf9c523780a608bd46686fd5e53740a07077f8'
$env:PUB_CACHE = Join-Path $projectRoot '.cache/pub'
$env:FLUTTER_SUPPRESS_ANALYTICS = 'true'
$env:DART_SUPPRESS_ANALYTICS = 'true'
$env:PATH = "$sdkRoot/bin;$env:PATH"
$env:UV_PYTHON_INSTALL_DIR = Join-Path $projectRoot '.tools/python'
$env:UV_CACHE_DIR = Join-Path $projectRoot '.cache/uv'
$pythonDirectory = Get-ChildItem $env:UV_PYTHON_INSTALL_DIR -Directory -Filter 'cpython-3.13*' -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
if ($pythonDirectory -and (Test-Path (Join-Path $pythonDirectory.FullName 'python.exe'))) {
    $env:PATH = "$($pythonDirectory.FullName);$env:PATH"
}

function Invoke-Checked {
    param([string]$Executable, [string[]]$Arguments)
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed ($LASTEXITCODE): $Executable $($Arguments -join ' ')"
    }
}

function Get-LockedDependencies {
    foreach ($package in Get-ChildItem (Join-Path $projectRoot 'packages') -Directory | Sort-Object Name) {
        if (-not (Test-Path (Join-Path $package.FullName 'pubspec.yaml'))) { continue }
        Push-Location $package.FullName
        try { Invoke-Checked $dart @('pub', 'get', '--enforce-lockfile') }
        finally { Pop-Location }
    }
    Push-Location (Join-Path $projectRoot 'apps/server')
    try { Invoke-Checked $dart @('pub', 'get', '--enforce-lockfile') }
    finally { Pop-Location }
    Push-Location (Join-Path $projectRoot 'apps/desktop')
    try { Invoke-Checked $flutter @('pub', 'get', '--enforce-lockfile') }
    finally { Pop-Location }
}

if ($Command -eq 'setup') {
    New-Item -ItemType Directory -Force (Join-Path $projectRoot '.downloads'), (Join-Path $projectRoot '.tools'), $env:PUB_CACHE | Out-Null
    $gitDirectory = & git -C $projectRoot rev-parse --absolute-git-dir
    if ($LASTEXITCODE -ne 0) { throw 'Run setup from a Git checkout.' }
    $excludeFile = Join-Path $gitDirectory 'info/exclude'
    foreach ($pattern in @('/.tools/', '/.cache/', '/.downloads/', '/local/development/')) {
        if (-not (Get-Content $excludeFile | Where-Object { $_ -eq $pattern })) { Add-Content $excludeFile $pattern }
    }
    if (-not (Test-Path $flutter)) {
        $base = if ($env:FLUTTER_STORAGE_BASE_URL) { $env:FLUTTER_STORAGE_BASE_URL.TrimEnd('/') } else { 'https://storage.googleapis.com' }
        $metadata = Invoke-RestMethod "$base/flutter_infra_release/releases/releases_windows.json"
        $release = $metadata.releases | Where-Object { $_.hash -eq $revision -and $_.dart_sdk_arch -eq 'x64' } | Select-Object -First 1
        if (-not $release) { throw 'Pinned Windows x64 Flutter release is missing from the release manifest.' }
        $archive = Join-Path $projectRoot '.downloads/flutter_windows_3.47.7-stable.zip'
        if (-not (Test-Path $archive) -or (Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $release.sha256) {
            Invoke-Checked 'curl.exe' @('--location', '--fail', '--retry', '3', '--output', $archive, "$base/flutter_infra_release/releases/$($release.archive)")
        }
        if ((Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $release.sha256) { throw 'Flutter archive SHA256 mismatch.' }
        Invoke-Checked 'tar.exe' @('-xf', $archive, '-C', (Join-Path $projectRoot '.tools'))
    }
}

if (-not (Test-Path $flutter)) { throw 'Run .\scripts\dev-windows.ps1 setup first.' }
$actualRevision = & git -C $sdkRoot rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $actualRevision -ne $revision) { throw "Flutter revision mismatch: expected $revision, got $actualRevision" }

. (Join-Path $PSScriptRoot 'windows-test-environment.ps1')
if ($Command -in @('setup', 'test', 'smoke') -or
    ($Command -in @('flutter', 'dart') -and $ToolArguments -contains 'test')) {
    Initialize-WindowsTestEnvironment
}

switch ($Command) {
    'setup' {
        Invoke-Checked $flutter @('--version')
        Invoke-Checked $flutter @('precache', '--windows')
        Get-LockedDependencies
    }
    'doctor' { Invoke-Checked $flutter @('doctor', '-v') }
    'flutter' { Invoke-Checked $flutter $ToolArguments }
    'dart' { Invoke-Checked $dart $ToolArguments }
    'smoke' {
        Push-Location (Join-Path $projectRoot 'packages/info_storage')
        try { Invoke-Checked $dart @('test', 'test/storage_test.dart', 'test/server_state_storage_test.dart') }
        finally { Pop-Location }
        Push-Location (Join-Path $projectRoot 'apps/desktop')
        try { Invoke-Checked $flutter @('test', '--no-pub', 'test/online_connection_location_test.dart', 'test/approvals_controller_test.dart', 'test/workspace_records_test.dart') }
        finally { Pop-Location }
    }
    { $_ -in 'analyze', 'test' } {
        foreach ($relative in @('packages/info_core', 'packages/info_cli', 'packages/info_storage', 'packages/info_remote', 'packages/info_workspace', 'apps/server', 'apps/desktop')) {
            Push-Location (Join-Path $projectRoot $relative)
            try {
                $tool = if ($relative -eq 'apps/desktop') { $flutter } else { $dart }
                $arguments = if ($Command -eq 'analyze') { @('analyze', '--fatal-infos') } else { @('test', 'test/') }
                if ($relative -eq 'apps/desktop') { $arguments += '--no-pub' }
                Invoke-Checked $tool ($arguments + $ToolArguments)
            } finally { Pop-Location }
        }
    }
    { $_ -in 'build', 'run' } {
        Push-Location (Join-Path $projectRoot 'apps/desktop')
        try {
            $arguments = if ($Command -eq 'build') { @('build', 'windows', '--release', '--no-pub') } else { @('run', '-d', 'windows', '--no-pub') }
            Invoke-Checked $flutter ($arguments + $ToolArguments)
            if ($Command -eq 'build') {
                Push-Location (Join-Path $projectRoot 'packages/info_cli')
                try {
                    Invoke-Checked $dart @('compile', 'exe', '--target-os', 'windows', '--target-arch', 'x64', 'bin/runtime_worker.dart', '-o', (Join-Path $projectRoot 'apps/desktop/build/windows/x64/runner/Release/info-runtime-worker.exe'))
                } finally { Pop-Location }
            }
        } finally { Pop-Location }
    }
}
