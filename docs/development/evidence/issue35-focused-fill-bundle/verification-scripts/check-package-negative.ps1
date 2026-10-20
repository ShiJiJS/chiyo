$ErrorActionPreference = 'Stop'
$root = 'C:/Project/network_config/info-manage'
$fixtureRoot = Join-Path $root 'build/qa-issue35/package-fixtures-02'
if (Test-Path -LiteralPath $fixtureRoot) { throw 'Use a fresh fixture root.' }
New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
$cases = @(
    @{ name = 'bad-digest'; expected = 'Focused input helper checksum mismatch.' },
    @{ name = 'bad-path'; expected = 'Invalid focused input helper provenance.' },
    @{ name = 'test-executable'; expected = 'Test or unknown executable in desktop payload.' },
    @{ name = 'future-format'; expected = 'Unsupported preview manifest.' },
    @{ name = 'legacy-format'; expected = 'Unlisted payload files.' }
)
$facts = @()
foreach ($case in $cases) {
    $folder = Join-Path $fixtureRoot $case.name
    $payload = Join-Path $folder 'AgentInfoManage'
    $app = Join-Path $payload 'app'
    New-Item -ItemType Directory -Path $app -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $app 'info-focus-broker.exe'), 'abc')
    $digest = (Get-FileHash -LiteralPath (Join-Path $app 'info-focus-broker.exe') -Algorithm SHA256).Hash.ToLowerInvariant()
    $focus = @{ helperProtocol = 1; helper = 'app/info-focus-broker.exe'; sha256 = $digest }
    $format = 2
    switch ($case.name) {
        'bad-digest' { $focus.sha256 = '0' * 64 }
        'bad-path' { $focus.helper = '../outside.exe' }
        'test-executable' { [IO.File]::WriteAllText((Join-Path $app 'info-focus-fixture.exe'), 'synthetic-only') }
        'future-format' { $format = 99 }
        'legacy-format' { $format = 1 }
    }
    $manifest = @{ format = $format; architecture = 'windows-x64'; sourceDirty = $false; focusedFill = $focus; files = @() }
    [IO.File]::WriteAllText((Join-Path $payload 'manifest.json'), ($manifest | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
    $archive = Join-Path $folder 'fixture.zip'
    Compress-Archive -LiteralPath $payload -DestinationPath $archive
    $archiveDigest = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText("$archive.sha256", "$archiveDigest  fixture.zip`n")
    $failure = $null
    try {
        & (Join-Path $root 'scripts/test-windows-package.ps1') -ArchivePath $archive -DartExecutable 'C:/Users/Todoki/.local/share/flutter/bin/cache/dart-sdk/bin/dart.exe'
    } catch {
        $failure = $_.Exception.Message
    }
    if ($failure -cne $case.expected) { throw "Unexpected package result for $($case.name): $failure" }
    $facts += @{ case = $case.name; expectedRefusal = $failure; passed = $true }
    Write-Output "PASS $($case.name)"
}
[IO.File]::WriteAllText((Join-Path $fixtureRoot 'result.json'), ($facts | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
