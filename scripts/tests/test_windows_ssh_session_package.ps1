# Inspect synthetic archive bytes only; never execute a payload or build an App.
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$testRoot = Join-Path $projectRoot ('build/ssh-package-' + [Guid]::NewGuid().ToString('N'))
$utf8 = New-Object Text.UTF8Encoding($false)
function Write-Text([string]$Path, [string]$Text) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    [IO.File]::WriteAllText($Path, $Text, $utf8)
}
function Check([string]$Name, [bool]$App, [bool]$Cli, [bool]$Different, [bool]$Required, [bool]$Failure) {
    $root = Join-Path $testRoot $Name
    $payload = Join-Path $root 'AgentInfoManage'
    foreach ($file in @('app/info_desktop.exe','app/info-focus-broker.exe','app/info-runtime-worker.exe','cli/info-runtime-worker.exe',
            'cli/template/references/credential-use.md','cli/template/references/information-files.md')) {
        Write-Text (Join-Path $payload $file) 'synthetic bytes'
    }
    Write-Text (Join-Path $payload 'app/data/flutter_assets/NativeAssetsManifest.json') '{"native-assets":{"windows_x64":{"package:sqlite3/src/ffi/libsqlite3.g.dart":["absolute","sqlcipher.dll"]}}}'
    if ($App) { Write-Text (Join-Path $payload 'app/info-ssh-session.exe') 'synthetic transport' }
    if ($Cli) { Write-Text (Join-Path $payload 'cli/info-ssh-session.exe') $(if ($Different) { 'different transport' } else { 'synthetic transport' }) }
    $manifest = [ordered]@{
        format=2; architecture='windows-x64'; sourceDirty=$false
        focusedFill=[ordered]@{helperProtocol=1; helper='app/info-focus-broker.exe'; sha256=(Get-FileHash -LiteralPath (Join-Path $payload 'app/info-focus-broker.exe')).Hash.ToLowerInvariant()}
        files=@(Get-ChildItem -LiteralPath $payload -File -Recurse | ForEach-Object {
            [ordered]@{path=$_.FullName.Substring($payload.Length+1).Replace('\','/');bytes=$_.Length;sha256=(Get-FileHash -LiteralPath $_.FullName).Hash.ToLowerInvariant()}
        })
    }
    Write-Text (Join-Path $payload 'manifest.json') ($manifest | ConvertTo-Json -Depth 12)
    $archive = Join-Path $root 'fixture.zip'
    Compress-Archive -LiteralPath $payload -DestinationPath $archive
    Write-Text "$archive.sha256" ((Get-FileHash -LiteralPath $archive).Hash.ToLowerInvariant() + '  fixture.zip')
    $errorMessage = $null
    try { & (Join-Path $projectRoot 'scripts/test-windows-package.ps1') -ArchivePath $archive -PayloadOnly -RequireSshSessionTransport:$Required }
    catch { $errorMessage = $_.Exception.Message }
    if ($Failure) {
        if (-not $errorMessage -or -not $errorMessage.Contains('SSH session transport must ship identical helpers')) { throw "Unexpected verification result for ${Name}: $errorMessage" }
    } elseif ($errorMessage) { throw "Unexpected verification failure for ${Name}: $errorMessage" }
    Write-Host "PASS $Name"
}
Check 'legacy' $false $false $false $false $false
Check 'required-missing' $false $false $false $true $true
Check 'paired' $true $true $false $true $false
Check 'missing-cli' $true $false $false $false $true
Check 'missing-app' $false $true $false $false $true
Check 'different-helpers' $true $true $true $false $true
Write-Host 'PASS: six synthetic SSH package integrity cases. Fixtures retained under build for review.'
