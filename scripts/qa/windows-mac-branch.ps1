param(
    [Parameter(Mandatory=$true)][string]$FlutterBin,
    [string]$Output = 'build/windows-mac-branch-ci'
)

# Disposable Windows runner only. No install, profile migration or Codex trust.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:OS -ne 'Windows_NT') { throw 'This regression requires Windows.' }
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$destination = [IO.Path]::GetFullPath((Join-Path $root $Output))
$build = [IO.Path]::GetFullPath((Join-Path $root 'build')) + [IO.Path]::DirectorySeparatorChar
if (-not $destination.StartsWith($build, [StringComparison]::OrdinalIgnoreCase)) { throw 'Output must be inside build/.' }
if (Test-Path -LiteralPath $destination) { throw 'Choose a new output directory.' }
New-Item -ItemType Directory -Path (Join-Path $destination 'logs') -Force | Out-Null
$flutter = (Get-Item -LiteralPath (Join-Path $FlutterBin 'flutter.bat')).FullName
$dart = (Get-Item -LiteralPath (Join-Path $FlutterBin 'cache/dart-sdk/bin/dart.exe')).FullName
$cli = Join-Path $root 'packages/info_cli'
$desktop = Join-Path $root 'apps/desktop'
$state = [ordered]@{
    complete = $false
    sourceCommit = (& git -C $root rev-parse HEAD)
    branch = (& git -C $root branch --show-current)
    runner = $env:RUNNER_OS
    stages = @()
    scope = 'Disposable native Windows regression for the Mac branch; synthetic libraries, picker fixture; no user Windows machine, install, hook trust or production data.'
}
function Save-State {
    $state | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $destination 'manifest.json') -Encoding utf8
}
function Invoke-Stage {
    param([string]$Name, [string]$Executable, [string[]]$Arguments, [string]$Directory)
    Push-Location $Directory
    $code = $null
    try {
        & $Executable @Arguments 2>&1 | Tee-Object -FilePath (Join-Path $destination "logs/$Name.txt")
        $code = $LASTEXITCODE
        if ($code -ne 0) { throw "Stage $Name failed with exit $code." }
    } finally {
        Pop-Location
        $state.stages += [ordered]@{ name=$Name; exitCode=$code }
        Save-State
    }
}
Save-State
try {
    Invoke-Stage 'four-package-and-windows-release' 'pwsh' @('-NoProfile','-File',(Join-Path $root 'scripts/check.ps1'),'-FlutterBin',$FlutterBin,'-WindowsRelease') $root
    Invoke-Stage 'codex-bundle' $dart @('run','tool/prepare_codex.dart',(Join-Path $root 'build/codex-ci')) $cli
    $env:INFO_TEST_BUNDLE = Join-Path $root 'build/codex-ci'
    Invoke-Stage 'aot-codex-subprocesses' $dart @('test','test/codex_process_test.dart') $cli
    Invoke-Stage 'compile-info-cli' $dart @('compile','exe','bin/info.dart','-o',(Join-Path $destination 'info.exe')) $cli
    foreach ($entry in @(
        @('desktop-cli','desktop_cli_test.dart'),
        @('library','library_native_test.dart'),
        @('proposals','proposals_native_test.dart')
    )) {
        $arguments = @('test','--no-pub',"integration_test/$($entry[1])",'-d','windows',"--dart-define=DART_EXECUTABLE=$dart","--dart-define=CLI_DIRECTORY=$cli")
        Invoke-Stage "native-$($entry[0])" $flutter $arguments $desktop
    }
    $files = Join-Path $destination 'files-ui'
    $arguments = @('test','--no-pub','integration_test/ordinary_files_native_test.dart','-d','windows',"--dart-define=CLI_EXECUTABLE=$(Join-Path $destination 'info.exe')","--dart-define=NATIVE_FILES_QA_DIRECTORY=$files",'--dart-define=NATIVE_FILES_SYNTHETIC_PICKER=true','--dart-define=NATIVE_FILES_BROWSER_CONSUMER=false')
    Invoke-Stage 'native-ordinary-files' $flutter $arguments $desktop
    $fileResult = Get-Content -LiteralPath (Join-Path $files 'result.json') -Raw | ConvertFrom-Json
    if (-not $fileResult.completed -or -not $fileResult.syntheticPicker -or $fileResult.browserConsumer) { throw 'Unexpected file-flow fixture evidence.' }
    $state.complete = $true
} finally {
    Save-State
}
if (-not $state.complete) { throw 'Windows regression incomplete; inspect retained logs.' }
