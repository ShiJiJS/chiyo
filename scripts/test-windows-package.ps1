param(
    [Parameter(Mandatory = $true)][string]$ArchivePath,
    [Parameter(Mandatory = $true)][string]$DartExecutable
)

# Developer-side headless verification. Never starts the desktop executable.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
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
    if ($manifest.architecture -ne 'windows-x64' -or $manifest.sourceDirty) { throw 'Invalid preview identity.' }
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
    # Restrict only this process and its children. Do not change the user's PATH.
    $env:PATH = "$env:SystemRoot\System32;$env:SystemRoot"
    $storage = Join-Path $payload 'diagnostics/info-storage-check.exe'
    & $storage
    if ($LASTEXITCODE -ne 0) { throw 'Extracted SQLCipher/DPAPI release probe failed.' }
    $bundle = Join-Path $testRoot '最终 Codex bundle'
    & (Join-Path $payload 'cli/info-prepare-codex.exe') $bundle
    if ($LASTEXITCODE -ne 0) { throw 'Extracted SDK-free preparation failed.' }
    $env:INFO_TEST_DELIVERY = $payload
    $env:INFO_TEST_BUNDLE = $bundle
    Push-Location (Join-Path (Split-Path -Parent $PSScriptRoot) 'packages/info_cli')
    try {
        & $DartExecutable test test/bundle_preparation_test.dart test/codex_process_test.dart
        if ($LASTEXITCODE -ne 0) { throw 'Extracted CLI and rendered hooks failed.' }
    } finally { Pop-Location }
    Write-Host 'PASS: extracted checksums, SDK-free CLI/hooks, synthetic SQLCipher/DPAPI. Desktop and user configuration untouched.'
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
