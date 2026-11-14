# Small archive fixtures exercise the actual package verifier, without an SDK,
# helper process, UI, user profile or a full product build.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$buildRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot 'build'))
$testRoot = Join-Path $buildRoot ('native background package ' + [Guid]::NewGuid().ToString('N'))
$verifier = Join-Path $projectRoot 'scripts/test-windows-package.ps1'
$utf8 = New-Object Text.UTF8Encoding($false)
$script:passed = 0

function Write-Text {
    param([string]$Path, [string]$Text)
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [IO.File]::WriteAllText($Path, $Text, $utf8)
}

function New-Fixture {
    param([string]$Name, [switch]$Native)
    $root = Join-Path $testRoot $Name
    $payload = Join-Path $root 'AgentInfoManage'
    foreach ($relative in @('app/info_desktop.exe', 'app/info-focus-broker.exe', 'app/info-runtime-worker.exe',
            'cli/info-runtime-worker.exe', 'cli/template/references/credential-use.md', 'cli/template/references/information-files.md')) {
        # These are deliberately not executable programs. PayloadOnly must
        # inspect bytes and never try to run them.
        Write-Text (Join-Path $payload $relative) ('synthetic ' + [IO.Path]::GetFileName($relative))
    }
    Write-Text (Join-Path $payload 'app/data/flutter_assets/NativeAssetsManifest.json') '{"native-assets":{"windows_x64":{"package:sqlite3/src/ffi/libsqlite3.g.dart":["absolute","sqlcipher.dll"]}}}'
    if ($Native) { Write-Text (Join-Path $payload 'app/info-native-background-broker.exe') 'synthetic native helper' }
    $manifest = [ordered]@{
        format = 2; architecture = 'windows-x64'; sourceDirty = $false
        focusedFill = [ordered]@{
            helperProtocol = 1; helper = 'app/info-focus-broker.exe'
            sha256 = (Get-FileHash -LiteralPath (Join-Path $payload 'app/info-focus-broker.exe') -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        files = @(Get-ChildItem -LiteralPath $payload -File -Recurse | ForEach-Object {
            [pscustomobject]@{
                path = $_.FullName.Substring($payload.Length + 1).Replace('\', '/')
                bytes = $_.Length
                sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        })
    }
    if ($Native) {
        $manifest.nativeBackgroundFill = [ordered]@{
            helperProtocol = 1; helper = 'app/info-native-background-broker.exe'
            sha256 = (Get-FileHash -LiteralPath (Join-Path $payload 'app/info-native-background-broker.exe') -Algorithm SHA256).Hash.ToLowerInvariant()
            trustSource = 'SHA-256 compiled into the native desktop runner; this manifest is provenance only'
        }
    }
    return [pscustomobject]@{ Name = $Name; Root = $root; Payload = $payload; Manifest = $manifest }
}

function Test-Fixture {
    param([object]$Fixture, [switch]$RequireNative, [string]$ExpectedFailure = '')
    Write-Text (Join-Path $Fixture.Payload 'manifest.json') ($Fixture.Manifest | ConvertTo-Json -Depth 12)
    $archive = Join-Path $Fixture.Root 'fixture.zip'
    Compress-Archive -LiteralPath $Fixture.Payload -DestinationPath $archive
    $digest = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Text "$archive.sha256" "$digest  fixture.zip"
    $failure = $null
    try {
        & $verifier -ArchivePath $archive -PayloadOnly -RequireNativeBackgroundFill:$RequireNative
    } catch { $failure = $_.Exception.Message }
    if ($ExpectedFailure) {
        if (-not $failure -or -not $failure.Contains($ExpectedFailure)) {
            throw "FAIL $($Fixture.Name): expected '$ExpectedFailure', got '$failure'."
        }
    } elseif ($failure) { throw "FAIL $($Fixture.Name): $failure" }
    $script:passed++
    Write-Host "PASS $($Fixture.Name)"
}

try {
    Test-Fixture (New-Fixture 'legacy')
    Test-Fixture (New-Fixture 'legacy-required') -RequireNative -ExpectedFailure 'Missing native background helper provenance.'
    Test-Fixture (New-Fixture 'native' -Native) -RequireNative

    $fixture = New-Fixture 'no-provenance' -Native
    $fixture.Manifest.Remove('nativeBackgroundFill')
    Test-Fixture $fixture -ExpectedFailure 'Missing native background helper provenance.'

    $fixture = New-Fixture 'null-provenance' -Native
    $fixture.Manifest.nativeBackgroundFill = $null
    Test-Fixture $fixture -ExpectedFailure 'Invalid native background helper provenance.'

    $fixture = New-Fixture 'missing-protocol' -Native
    $fixture.Manifest.nativeBackgroundFill.Remove('helperProtocol')
    Test-Fixture $fixture -ExpectedFailure 'Invalid native background helper provenance.'

    $fixture = New-Fixture 'wrong-protocol' -Native
    $fixture.Manifest.nativeBackgroundFill.helperProtocol = 2
    Test-Fixture $fixture -ExpectedFailure 'Invalid native background helper provenance.'

    $fixture = New-Fixture 'unsafe-path' -Native
    $fixture.Manifest.nativeBackgroundFill.helper = '../info-native-background-broker.exe'
    Test-Fixture $fixture -ExpectedFailure 'Invalid native background helper provenance.'

    $fixture = New-Fixture 'uppercase-digest' -Native
    $fixture.Manifest.nativeBackgroundFill.sha256 = $fixture.Manifest.nativeBackgroundFill.sha256.ToUpperInvariant()
    Test-Fixture $fixture -ExpectedFailure 'Invalid native background helper provenance.'

    $fixture = New-Fixture 'wrong-trust-source' -Native
    $fixture.Manifest.nativeBackgroundFill.trustSource = 'manifest grants runtime trust'
    Test-Fixture $fixture -ExpectedFailure 'Invalid native background helper provenance.'

    $fixture = New-Fixture 'missing-helper' -Native
    Remove-Item -LiteralPath (Join-Path $fixture.Payload 'app/info-native-background-broker.exe')
    Test-Fixture $fixture -ExpectedFailure 'Native background helper checksum mismatch.'

    $fixture = New-Fixture 'tampered-helper' -Native
    Write-Text (Join-Path $fixture.Payload 'app/info-native-background-broker.exe') 'tampered helper'
    Test-Fixture $fixture -ExpectedFailure 'Native background helper checksum mismatch.'

    $fixture = New-Fixture 'unlisted-helper' -Native
    $fixture.Manifest.files = @($fixture.Manifest.files | Where-Object { $_.path -ne 'app/info-native-background-broker.exe' })
    Test-Fixture $fixture -ExpectedFailure 'Native background helper must have one matching files entry.'

    $fixture = New-Fixture 'duplicate-helper-row' -Native
    $fixture.Manifest.files += @($fixture.Manifest.files | Where-Object { $_.path -eq 'app/info-native-background-broker.exe' })
    Test-Fixture $fixture -ExpectedFailure 'Native background helper must have one matching files entry.'

    $fixture = New-Fixture 'conflicting-row-digest' -Native
    ($fixture.Manifest.files | Where-Object { $_.path -eq 'app/info-native-background-broker.exe' }).sha256 = ('0' * 64)
    Test-Fixture $fixture -ExpectedFailure 'Native background helper must have one matching files entry.'

    $fixture = New-Fixture 'conflicting-row-size' -Native
    ($fixture.Manifest.files | Where-Object { $_.path -eq 'app/info-native-background-broker.exe' }).bytes = 0
    Test-Fixture $fixture -ExpectedFailure 'Native background helper must have one matching files entry.'

    $fixture = New-Fixture 'test-executable' -Native
    Write-Text (Join-Path $fixture.Payload 'app/native_background_fixture.exe') 'QA only'
    Test-Fixture $fixture -ExpectedFailure 'Test or unknown executable in desktop payload.'

    $fixture = New-Fixture 'nested-helper' -Native
    Write-Text (Join-Path $fixture.Payload 'app/nested/info-native-background-broker.exe') 'QA only'
    Test-Fixture $fixture -ExpectedFailure 'Test or unknown executable in desktop payload.'

    $fixture = New-Fixture 'unlisted-file' -Native
    Write-Text (Join-Path $fixture.Payload 'unexpected.txt') 'not declared'
    Test-Fixture $fixture -ExpectedFailure 'Unlisted payload files.'

    $fixture = New-Fixture 'focused-helper-regression' -Native
    Write-Text (Join-Path $fixture.Payload 'app/info-focus-broker.exe') 'tampered focused helper'
    Test-Fixture $fixture -ExpectedFailure 'Focused input helper checksum mismatch.'

    Write-Host "PASS: $script:passed package integrity cases; no payload executables started."
} finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    if (-not $resolved.StartsWith("$buildRoot\", [StringComparison]::OrdinalIgnoreCase) -or $resolved -eq $buildRoot) {
        throw 'Refusing cleanup outside the new package fixture directory.'
    }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
