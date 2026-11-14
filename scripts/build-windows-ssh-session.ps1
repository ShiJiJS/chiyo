param(
    [string]$OutputDirectory = 'build/ssh-session/native',
    [string]$CMake = '',
    [switch]$BuildTests
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
if (-not $CMake) {
    $found = Get-Command cmake.exe -ErrorAction SilentlyContinue
    $CMake = if ($found) { $found.Source } else {
        'C:/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools/Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe'
    }
}
if (-not [IO.Path]::IsPathRooted($OutputDirectory)) { $OutputDirectory = Join-Path $projectRoot $OutputDirectory }
$testOption = if ($BuildTests) { 'ON' } else { 'OFF' }
& $CMake -S (Join-Path $projectRoot 'packages/info_cli/windows/ssh_session') -B $OutputDirectory -G 'Visual Studio 17 2022' -A x64 "-DCHIYO_SSH_BUILD_TESTS=$testOption"
if ($LASTEXITCODE -ne 0) { throw 'SSH transport CMake configuration failed.' }
& $CMake --build $OutputDirectory --config Release
if ($LASTEXITCODE -ne 0) { throw 'SSH transport build failed.' }
$helper = Join-Path $OutputDirectory 'Release/info-ssh-session.exe'
if (-not (Test-Path -LiteralPath $helper)) { throw 'SSH transport output is missing.' }
Write-Output $helper
