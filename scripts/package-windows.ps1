param(
    [Parameter(Mandatory = $true)][string]$FlutterBin,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [switch]$Offline,
    [switch]$PackageOnly,
    [string]$Python = ''
)

# Developer build only. The resulting ZIP needs neither Dart nor Flutter.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitProcess) {
    throw 'Build this x64 preview on 64-bit Windows.'
}
$projectRoot = Split-Path -Parent $PSScriptRoot
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $output) { throw 'Output directory already exists.' }
$env:PATH = "$FlutterBin;$env:PATH"
$flutter = (Get-Command flutter -ErrorAction Stop).Source
# Flutter's dart.bat wrapper needs Git on PATH even for `dart test`. The
# extracted-package check deliberately removes SDK/Git entries from PATH, so
# invoke the specified SDK's executable directly rather than its wrapper.
$dartPath = Join-Path $FlutterBin 'cache/dart-sdk/bin/dart.exe'
if (-not (Test-Path -LiteralPath $dartPath -PathType Leaf)) {
    throw 'The specified FlutterBin does not contain cache/dart-sdk/bin/dart.exe.'
}
$dart = (Get-Item -LiteralPath $dartPath).FullName
$utf8 = New-Object Text.UTF8Encoding($false)

function Invoke-Checked {
    param([string]$Executable, [string[]]$Arguments)
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Command failed: $Executable" }
}
function Write-Json {
    param([string]$Path, [object]$Value)
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 30), $utf8)
}
function Assert-CleanSources {
    # Flutter rewrites generated registrants with host line endings. Ask Git
    # about content rather than its cached stat-only porcelain dirty flags.
    git diff --quiet
    if ($LASTEXITCODE -ne 0) { throw 'Commit source changes before packaging.' }
    git diff --cached --quiet
    if ($LASTEXITCODE -ne 0) { throw 'Commit staged source changes before packaging.' }
    $untracked = @(git ls-files --others --exclude-standard)
    if ($LASTEXITCODE -ne 0 -or $untracked.Count -gt 0) {
        throw 'Commit untracked source files before packaging.'
    }
}

Push-Location $projectRoot
try {
    Assert-CleanSources
    $commit = (git rev-parse HEAD).Trim()
    $version = ((Select-String -LiteralPath 'apps/desktop/pubspec.yaml' -Pattern '^version: (.+)$').Matches.Groups[1].Value).Trim()
    $identity = "$version-dev.$($commit.Substring(0, 12))"
    $checkArguments = @{ FlutterBin = $FlutterBin; WindowsRelease = $true }
    if ($Offline) { $checkArguments.Offline = $true }
    & (Join-Path $PSScriptRoot 'check.ps1') @checkArguments

    # Refuse changes made while checks were running, including new files.
    Assert-CleanSources
    if ((git rev-parse HEAD).Trim() -ne $commit) {
        throw 'Sources changed during verification; rerun from a clean fixed commit.'
    }
    New-Item -ItemType Directory -Path $output | Out-Null
    $payload = Join-Path $output 'AgentInfoManage'
    New-Item -ItemType Directory -Path $payload | Out-Null
    $app = Join-Path $payload 'app'
    Copy-Item -LiteralPath (Join-Path $projectRoot 'apps/desktop/build/windows/x64/runner/Release') -Destination $app -Recurse
    foreach ($required in @('info_desktop.exe', 'info-focus-broker.exe', 'flutter_windows.dll', 'sqlcipher.dll', 'data/app.so', 'data/icudtl.dat')) {
        if (-not (Test-Path -LiteralPath (Join-Path $app $required))) { throw "Missing desktop payload: $required" }
    }
    $focusDigestPath = Join-Path $projectRoot 'apps/desktop/build/windows/x64/focused-input-identity/Release/focused_fill_identity.sha256'
    $focusDigest = ([IO.File]::ReadAllText($focusDigestPath)).Trim()
    $actualFocusDigest = (Get-FileHash -LiteralPath (Join-Path $app 'info-focus-broker.exe') -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($focusDigest -notmatch '^[0-9a-f]{64}$' -or $focusDigest -ne $actualFocusDigest) {
        throw 'The packaged focused input helper differs from the runner build identity.'
    }
    foreach ($binary in Get-ChildItem -LiteralPath $app -Filter '*.exe' -Recurse) {
        if ($binary.Name -notin @('info_desktop.exe', 'info-focus-broker.exe', 'info-runtime-worker.exe')) {
            throw "Unexpected executable in desktop payload: $($binary.Name)"
        }
    }
    $cli = Join-Path $payload 'cli'
    New-Item -ItemType Directory -Path $cli | Out-Null
    Push-Location 'packages/info_cli'
    try {
        foreach ($entry in @(@('info', 'info'), @('runtime_worker', 'info-runtime-worker'), @('codex_info', 'info-codex'), @('codex_hook', 'info-codex-hook'), @('prepare_codex', 'info-prepare-codex'))) {
            Invoke-Checked $dart @('compile', 'exe', '--target-os', 'windows', '--target-arch', 'x64', "bin/$($entry[0]).dart", '-o', (Join-Path $cli "$($entry[1]).exe"))
        }
    } finally { Pop-Location }
    # One-shot adapters use the resident execution host in the desktop app.
    # Its worker is a shipped asset next to the app, independent of SDK/PATH.
    Copy-Item -LiteralPath (Join-Path $cli 'info-runtime-worker.exe') -Destination (Join-Path $app 'info-runtime-worker.exe')
    New-Item -ItemType Directory -Path (Join-Path $cli 'template') | Out-Null
    Copy-Item -LiteralPath 'integrations/codex/skills/agent-info-access/SKILL.md' -Destination (Join-Path $cli 'template/SKILL.md')
    New-Item -ItemType Directory -Path (Join-Path $cli 'template/references') | Out-Null
    foreach ($reference in Get-ChildItem -LiteralPath 'integrations/codex/skills/agent-info-access/references' -File -Filter '*.md') {
        Copy-Item -LiteralPath $reference.FullName -Destination (Join-Path $cli "template/references/$($reference.Name)")
    }

    # Fixed official tools are copied from verified archives, never a user's
    # installation. The MSI is read as tables/cabinets; no install action runs.
    if (-not $Python) {
        $Python = Join-Path $projectRoot '.tools/python/cpython-3.13-windows-x86_64-none/python.exe'
    }
    if (-not (Test-Path -LiteralPath $Python -PathType Leaf)) {
        throw 'Pass -Python with a Python 3.13+ executable for tool assembly.'
    }
    Invoke-Checked $Python @((Join-Path $PSScriptRoot 'bundle-windows-tools.py'), (Join-Path $payload 'tools'))

    # This console probe uses only synthetic data in a newly created temp
    # directory and current-user DPAPI. It never opens the application database.
    $diagnostics = Join-Path $payload 'diagnostics'
    $storageBuild = Join-Path $output 'storage-build'
    Push-Location 'packages/info_storage'
    try {
        # Native code assets require dart build cli's relocatable bin/lib
        # bundle. dart compile exe alone does not bundle their loader mapping.
        Invoke-Checked $dart @('build', 'cli', '--target-os', 'windows', '--target-arch', 'x64', '--target', 'bin/info-storage-check.dart', '--output', $storageBuild)
    } finally { Pop-Location }
    Copy-Item -LiteralPath (Join-Path $storageBuild 'bundle') -Destination $diagnostics -Recurse

    $notices = Join-Path $payload 'notices'
    $provenance = Join-Path $payload 'provenance'
    New-Item -ItemType Directory -Path $notices, $provenance | Out-Null
    Copy-Item -LiteralPath 'third_party/windows-tools.json' -Destination $provenance
    $flutterRoot = Split-Path -Parent (Get-Item -LiteralPath $FlutterBin).FullName
    Copy-Item -LiteralPath (Join-Path $flutterRoot 'LICENSE') -Destination (Join-Path $notices 'Flutter-LICENSE')
    Copy-Item -LiteralPath (Join-Path $flutterRoot 'bin/cache/dart-sdk/LICENSE') -Destination (Join-Path $notices 'Dart-LICENSE')
    Copy-Item -LiteralPath (Join-Path $flutterRoot 'bin/cache/LICENSE.dart_sdk_archive.md') -Destination (Join-Path $notices 'Dart-THIRD-PARTY-NOTICES.md')
    Copy-Item -LiteralPath (Join-Path $flutterRoot 'bin/cache/artifacts/engine/windows-x64-release/license.windows_flutter.md') -Destination (Join-Path $notices 'Flutter-engine-NOTICES.md')
    Copy-Item -LiteralPath 'third_party/SQLCipher-LICENSE.md' -Destination $notices
    Copy-Item -LiteralPath 'apps/desktop/assets/fonts/OFL.txt' -Destination (Join-Path $notices 'NotoSansSC-OFL.txt')
    $packages = @{}
    foreach ($package in @('packages/info_cli', 'packages/info_core', 'packages/info_storage', 'apps/desktop')) {
        $configPath = [IO.Path]::GetFullPath((Join-Path $package '.dart_tool/package_config.json'))
        $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
        foreach ($dependency in $config.packages) {
            $uri = [Uri]::new([Uri]$configPath, $dependency.rootUri)
            $root = $uri.LocalPath
            $key = $dependency.name
            if ($packages.ContainsKey($key)) { continue }
            $packages[$key] = $root
            foreach ($notice in Get-ChildItem -LiteralPath $root -File | Where-Object { $_.Name -match '^(LICENSE|LICENCE|NOTICE|COPYING)(\.|$)' }) {
                Copy-Item -LiteralPath $notice.FullName -Destination (Join-Path $notices "$key-$($notice.Name)")
            }
        }
        Copy-Item -LiteralPath (Join-Path $package 'pubspec.lock') -Destination (Join-Path $provenance (($package.Replace('/', '-')) + '-pubspec.lock'))
    }
    $sqliteHashSource = Join-Path $packages.sqlite3 'lib/src/hook/asset_hashes.dart'
    Copy-Item -LiteralPath $sqliteHashSource -Destination (Join-Path $provenance 'sqlite3-native-asset-hashes.dart')
    $expectedCipher = (Select-String -LiteralPath $sqliteHashSource -Pattern "'sqlcipher.x64.windows.dll': '([a-f0-9]{64})'").Matches.Groups[1].Value
    $actualCipher = (Get-FileHash -LiteralPath (Join-Path $app 'sqlcipher.dll') -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($expectedCipher -ne $actualCipher) { throw 'Desktop SQLCipher DLL differs from the pinned sqlite3 native asset.' }
    $diagnosticCipher = @(Get-ChildItem -LiteralPath $diagnostics -Filter 'sqlcipher.dll' -Recurse)
    if ($diagnosticCipher.Count -ne 1) { throw 'Missing or ambiguous diagnostic SQLCipher DLL.' }
    foreach ($dll in $diagnosticCipher) {
        if ((Get-FileHash -LiteralPath $dll.FullName -Algorithm SHA256).Hash.ToLowerInvariant() -ne $actualCipher) {
            throw 'Diagnostic and desktop SQLCipher DLLs differ.'
        }
    }
    Copy-Item -LiteralPath 'docs/development/windows-online-delivery.md' -Destination (Join-Path $payload 'README.md')
    Copy-Item -LiteralPath 'docs/development/windows-codex-integration.md' -Destination (Join-Path $payload 'CODEX-INTEGRATION.md')
    Copy-Item -LiteralPath 'docs/development/windows-online-acceptance.md' -Destination (Join-Path $payload 'ACCEPTANCE.md')
    $flutterVersion = (& $flutter --version --machine | Out-String | ConvertFrom-Json)
    if ($LASTEXITCODE -ne 0) { throw 'Cannot record Flutter SDK version.' }
    # Record revisions and versions without publishing the builder's username
    # or absolute SDK installation directory.
    $flutterVersion.PSObject.Properties.Remove('flutterRoot')
    $dartVersion = (& $dart --version 2>&1 | Out-String).Trim()
    $runnerProject = 'apps/desktop/build/windows/x64/runner/info_desktop.vcxproj'
    $windowsSdk = (Select-String -LiteralPath $runnerProject -Pattern '<WindowsTargetPlatformVersion>([^<]+)</WindowsTargetPlatformVersion>').Matches.Groups[1].Value
    $msvcToolset = @((Select-String -LiteralPath $runnerProject -Pattern '<PlatformToolset>([^<]+)</PlatformToolset>').Matches | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
    $visualStudio = @(& $vswhere -products '*' -format json | ConvertFrom-Json | Select-Object productId, installationVersion)
    $files = @(Get-ChildItem -LiteralPath $payload -File -Recurse | Sort-Object FullName | ForEach-Object {
        [ordered]@{
            path = $_.FullName.Substring($payload.Length + 1).Replace('\', '/')
            bytes = $_.Length
            sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    })
    Assert-CleanSources
    if ((git rev-parse HEAD).Trim() -ne $commit) { throw 'Sources changed during packaging.' }
    Write-Json (Join-Path $payload 'manifest.json') ([ordered]@{
        format = 2; product = 'Agent Info Manage'; release = $identity
        sourceCommit = $commit; sourceDirty = $false; architecture = 'windows-x64'
        builtAtUtc = [DateTime]::UtcNow.ToString('o')
        signing = 'unsigned development preview'
        runtimePrerequisite = 'Microsoft Visual C++ v14 x64 Redistributable (not included)'
        buildHost = [Environment]::OSVersion.VersionString
        flutter = $flutterVersion; dart = $dartVersion; visualStudio = $visualStudio
        windowsSdk = $windowsSdk; msvcToolset = $msvcToolset
        sqlcipherSha256 = $actualCipher
        focusedFill = [ordered]@{
            helperProtocol = 1; helper = 'app/info-focus-broker.exe'; sha256 = $actualFocusDigest
            trustSource = 'SHA-256 compiled into the native desktop runner; this manifest is provenance only'
        }
        verification = 'Full headless check.ps1 and Windows release compilation; no desktop/Codex/clean-machine acceptance implied'
        files = $files
    })
    $archive = Join-Path $output "agent-info-manage-$identity-windows-x64.zip"
    Compress-Archive -LiteralPath $payload -DestinationPath $archive -CompressionLevel Optimal
    $digest = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText("$archive.sha256", "$digest  $([IO.Path]::GetFileName($archive))`n", $utf8)
    & (Join-Path $PSScriptRoot 'test-windows-package.ps1') -ArchivePath $archive -DartExecutable $dart
    Assert-CleanSources
    if ((git rev-parse HEAD).Trim() -ne $commit) {
        throw 'Sources changed during extracted verification; the archive is not a verified delivery.'
    }
    Write-Host "Verified development package: $archive"
    Write-Json "$archive.verified.json" ([ordered]@{
        archiveSha256=$digest; sourceCommit=$commit; verifiedAtUtc=[DateTime]::UtcNow.ToString('o')
    })
    if (-not $PackageOnly) {
        & (Join-Path $PSScriptRoot 'install-windows-preview.ps1') -ArchivePath $archive -CleanBuildArtifacts
    }
} finally { Pop-Location }
