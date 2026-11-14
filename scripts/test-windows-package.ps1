param(
    [Parameter(Mandatory = $true)][string]$ArchivePath,
    [string]$DartExecutable,
    [switch]$RequireNativeBackgroundFill,
    [switch]$RequireSshSessionTransport,
    [switch]$PayloadOnly
)

# Developer-side headless verification. Never starts the desktop executable.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$dart = $null
if (-not $PayloadOnly) {
    if (-not $DartExecutable -or -not (Test-Path -LiteralPath $DartExecutable -PathType Leaf) -or
        [IO.Path]::GetExtension($DartExecutable) -ine '.exe') {
        throw 'Use the Dart SDK executable (cache/dart-sdk/bin/dart.exe), not the Flutter dart.bat wrapper.'
    }
    $dart = (Get-Item -LiteralPath $DartExecutable).FullName
}
$archive = (Get-Item -LiteralPath $ArchivePath).FullName
$expectedArchive = ((Get-Content -LiteralPath "$archive.sha256" -Raw).Split(' ')[0]).Trim()
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expectedArchive) {
    throw 'Archive checksum mismatch.'
}
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testRoot = Join-Path $tempBase ("Agent Info 验证 " + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$priorDelivery = $env:INFO_TEST_DELIVERY
$priorBundle = $env:INFO_TEST_BUNDLE
$priorPath = $env:PATH
try {
    Expand-Archive -LiteralPath $archive -DestinationPath $testRoot
    $payload = Join-Path $testRoot 'AgentInfoManage'
    $manifest = Get-Content -LiteralPath (Join-Path $payload 'manifest.json') -Raw | ConvertFrom-Json
    if ($manifest.PSObject.Properties['displayName']) {
        if ($manifest.displayName -ne '知予') { throw 'Unexpected application display name.' }
        & (Join-Path $PSScriptRoot 'test-windows-branding.ps1') -Executable (Join-Path $payload 'app/info_desktop.exe') -Icon (Join-Path $payload 'app/chiyo.ico')
    }
    if (Test-Path -LiteralPath (Join-Path $payload 'app/native_assets.json')) {
        throw 'The test-only absolute native asset cache must not be shipped.'
    }
    $nativeAssets = Get-Content -LiteralPath (Join-Path $payload 'app/data/flutter_assets/NativeAssetsManifest.json') -Raw | ConvertFrom-Json
    $cipherLoader = @($nativeAssets.'native-assets'.windows_x64.'package:sqlite3/src/ffi/libsqlite3.g.dart')
    if ($cipherLoader.Count -ne 2 -or $cipherLoader[0] -ne 'absolute' -or $cipherLoader[1] -ne 'sqlcipher.dll') {
        throw 'The extracted release SQLCipher loader is not portable.'
    }
    if ($manifest.architecture -ne 'windows-x64' -or $manifest.sourceDirty) { throw 'Invalid preview identity.' }
    if ($manifest.format -notin @(1, 2)) { throw 'Unsupported preview manifest.' }
    if ($manifest.format -eq 2) {
        $focus = $manifest.focusedFill
        if ($focus.helperProtocol -ne 1 -or $focus.helper -ne 'app/info-focus-broker.exe' -or
            $focus.sha256 -notmatch '^[0-9a-f]{64}$') {
            throw 'Invalid focused input helper provenance.'
        }
        $focusPath = Join-Path $payload 'app/info-focus-broker.exe'
        if (-not (Test-Path -LiteralPath $focusPath -PathType Leaf) -or
            (Get-FileHash -LiteralPath $focusPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $focus.sha256) {
            throw 'Focused input helper checksum mismatch.'
        }
    }
    # Keep format 2 readable by existing Apps. The added block records build
    # provenance; only the runner's compiled identity grants runtime trust.
    $nativeProperty = $manifest.PSObject.Properties['nativeBackgroundFill']
    $nativePath = Join-Path $payload 'app/info-native-background-broker.exe'
    if ($RequireNativeBackgroundFill -and -not $nativeProperty) {
        throw 'Missing native background helper provenance.'
    }
    if (-not $nativeProperty -and (Test-Path -LiteralPath $nativePath)) {
        throw 'Missing native background helper provenance.'
    }
    if ($nativeProperty) {
        $native = $nativeProperty.Value
        $hasFields = $null -ne $native
        foreach ($field in @('helperProtocol', 'helper', 'sha256', 'trustSource')) {
            if ($null -eq $native -or -not $native.PSObject.Properties[$field]) { $hasFields = $false }
        }
        if (-not $hasFields -or $manifest.format -ne 2 -or
            $native.helperProtocol -ne 1 -or $native.helper -cne 'app/info-native-background-broker.exe' -or
            $native.sha256 -isnot [string] -or $native.sha256 -cnotmatch '^[0-9a-f]{64}$' -or
            $native.trustSource -cne 'SHA-256 compiled into the native desktop runner; this manifest is provenance only') {
            throw 'Invalid native background helper provenance.'
        }
        if (-not (Test-Path -LiteralPath $nativePath -PathType Leaf) -or
            (Get-FileHash -LiteralPath $nativePath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $native.sha256) {
            throw 'Native background helper checksum mismatch.'
        }
        $nativeEntries = @($manifest.files | Where-Object { $_.path -ieq 'app/info-native-background-broker.exe' })
        if ($nativeEntries.Count -ne 1 -or $nativeEntries[0].path -cne 'app/info-native-background-broker.exe' -or
            $nativeEntries[0].sha256 -cne $native.sha256 -or $nativeEntries[0].bytes -ne (Get-Item -LiteralPath $nativePath).Length) {
            throw 'Native background helper must have one matching files entry.'
        }
    }
    $appSsh = Join-Path $payload 'app/info-ssh-session.exe'
    $cliSsh = Join-Path $payload 'cli/info-ssh-session.exe'
    $hasSsh = (Test-Path -LiteralPath $appSsh -PathType Leaf) -or (Test-Path -LiteralPath $cliSsh -PathType Leaf)
    if ($RequireSshSessionTransport -or $hasSsh) {
        if (-not (Test-Path -LiteralPath $appSsh -PathType Leaf) -or
            -not (Test-Path -LiteralPath $cliSsh -PathType Leaf) -or
            (Get-FileHash -LiteralPath $appSsh -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $cliSsh -Algorithm SHA256).Hash) {
            throw 'The SSH session transport must ship identical helpers beside the desktop and CLI.'
        }
    }
    if ($manifest.format -eq 2) {
        $app = Join-Path $payload 'app'
        $allowedExecutables = @('info_desktop.exe', 'info-focus-broker.exe', 'info-runtime-worker.exe')
        if ($hasSsh) { $allowedExecutables += 'info-ssh-session.exe' }
        if ($nativeProperty) { $allowedExecutables += 'info-native-background-broker.exe' }
        foreach ($binary in Get-ChildItem -LiteralPath $app -Filter '*.exe' -Recurse) {
            $relativeBinary = $binary.FullName.Substring($app.Length + 1).Replace('\', '/')
            if ($relativeBinary -notin $allowedExecutables) {
                throw 'Test or unknown executable in desktop payload.'
            }
        }
    }
    foreach ($entry in $manifest.files) {
        $path = [IO.Path]::GetFullPath((Join-Path $payload $entry.path))
        if (-not $path.StartsWith("$payload\", [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe manifest path.' }
        $file = Get-Item -LiteralPath $path
        if ($file.Length -ne $entry.bytes -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $entry.sha256) {
            throw "Payload checksum mismatch: $($entry.path)"
        }
    }
    if (@(Get-ChildItem -LiteralPath $payload -Recurse -File).Count -ne @($manifest.files).Count + 1) {
        throw 'Unlisted payload files.'
    }
    $hasChiyo = $manifest.PSObject.Properties['cliEntrypoint']
    if ($hasChiyo) {
        if ($manifest.cliEntrypoint -ne 'cli/chiyo.exe' -or
            -not (Test-Path -LiteralPath (Join-Path $payload 'cli/chiyo.exe') -PathType Leaf)) {
            throw 'The package is missing its declared chiyo command.'
        }
    }
    $appWorker = Join-Path $payload 'app/info-runtime-worker.exe'
    $cliWorker = Join-Path $payload 'cli/info-runtime-worker.exe'
    if (-not (Test-Path -LiteralPath $appWorker -PathType Leaf) -or
        -not (Test-Path -LiteralPath $cliWorker -PathType Leaf) -or
        (Get-FileHash -LiteralPath $appWorker -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $cliWorker -Algorithm SHA256).Hash) {
        throw 'The resident host must ship the same worker beside the desktop and CLI.'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $payload 'cli/template/references/credential-use.md') -PathType Leaf)) {
        throw 'The extracted SDK-free bundle is missing the credential-use Skill reference.'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $payload 'cli/template/references/information-files.md') -PathType Leaf)) {
        throw 'The extracted SDK-free bundle is missing the information-files Skill reference.'
    }
    if ($PayloadOnly) {
        Write-Host 'PASS: extracted payload integrity only; no executables started and no full acceptance receipt produced.'
        return
    }
    # Restrict only this process and its children. Do not change the user's PATH.
    $env:PATH = "$env:SystemRoot\System32;$env:SystemRoot;$env:SystemRoot\System32\WindowsPowerShell\v1.0"
    $storage = Join-Path $payload 'diagnostics/bin/info-storage-check.exe'
    & $storage
    if ($LASTEXITCODE -ne 0) { throw 'Extracted SQLCipher/DPAPI release probe failed.' }
    $bundle = Join-Path $testRoot '最终 Codex bundle'
    & (Join-Path $payload 'cli/info-prepare-codex.exe') $bundle
    if ($LASTEXITCODE -ne 0) { throw 'Extracted SDK-free preparation failed.' }
    $env:INFO_TEST_DELIVERY = $payload
    $env:INFO_TEST_BUNDLE = $bundle
    function Invoke-LockedPackageTests {
        param([string]$Package, [string[]]$Tests)
        Push-Location (Join-Path (Split-Path -Parent $PSScriptRoot) $Package)
        $packageLock = Join-Path (Get-Location) 'pubspec.lock'
        $originalPackageLock = [IO.File]::ReadAllBytes($packageLock)
        try {
            if ($env:PUB_HOSTED_URL -eq 'https://pub.flutter-io.cn') {
                $temporaryPackageLock = [Text.Encoding]::UTF8.GetString($originalPackageLock).Replace('https://pub.dev', 'https://pub.flutter-io.cn')
                [IO.File]::WriteAllText($packageLock, $temporaryPackageLock, (New-Object Text.UTF8Encoding($false)))
            }
            # The preceding headless build populated this exact cache. Prevent
            # 'dart test' from silently re-resolving dev dependencies under a mirror.
            & $dart pub get --enforce-lockfile --offline
            if ($LASTEXITCODE -ne 0) { throw 'Pinned SDK-free test dependencies are unavailable.' }
            & $dart test @Tests
            if ($LASTEXITCODE -ne 0) { throw "Extracted package checks failed: $Package" }
        } finally {
            try {
                $expectedLock = [Text.Encoding]::UTF8.GetString($originalPackageLock).Replace('https://pub.flutter-io.cn', 'https://pub.dev').Replace("`r`n", "`n")
                $actualLock = [IO.File]::ReadAllText($packageLock).Replace('https://pub.flutter-io.cn', 'https://pub.dev').Replace("`r`n", "`n")
                if ($actualLock -cne $expectedLock) {
                    throw 'SDK-free tests changed dependency versions/hashes; preserving the lock for inspection.'
                }
                [IO.File]::WriteAllBytes($packageLock, $originalPackageLock)
            } finally { Pop-Location }
        }
    }
    Invoke-LockedPackageTests -Package 'packages/info_cli' -Tests @('test/bundle_preparation_test.dart', 'test/cli_test.dart', 'test/codex_process_test.dart', 'test/codex_focused_fill_test.dart', 'test/codex_information_files_test.dart', 'test/codex_association_windows_test.dart')
    if ($hasChiyo) {
        Invoke-LockedPackageTests -Package 'packages/info_cli' -Tests @('test/windows_chiyo_cli_test.dart', 'test/windows_chiyo_context_test.dart', 'test/windows_chiyo_registration_test.dart')
    }
    # Actual extracted CLI/worker with encrypted source-side owner/Job tests;
    # focused input and executable classification remain controlled fixtures.
    Invoke-LockedPackageTests -Package 'packages/info_storage' -Tests @('test/mixed_lifecycle_windows_test.dart')
    Write-Host 'PASS: extracted checksums, SDK-free CLI/hooks, encrypted mixed lifecycle, synthetic SQLCipher/DPAPI. Desktop and user configuration untouched.'
} finally {
    $env:INFO_TEST_DELIVERY = $priorDelivery
    $env:INFO_TEST_BUNDLE = $priorBundle
    $env:PATH = $priorPath
    # Delete only the new, explicitly bounded test directory.
    $resolved = [IO.Path]::GetFullPath($testRoot)
    if (-not $resolved.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -or $resolved -eq $tempBase) {
        throw 'Refusing cleanup outside the temporary test directory.'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
