$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '../register-windows-cli.ps1')

function Assert-Equal($Actual, $Expected, [string]$Case) {
    if ($Actual -cne $Expected) { throw "Registration check failed: $Case" }
}
$directory = 'C:\Software\知予 安装\current\cli'
Assert-Equal (Add-ChiyoPathDirectory '' $directory) $directory 'empty user path'
Assert-Equal (Add-ChiyoPathDirectory $null $directory) $directory 'missing user path'
$original = 'C:\custom;;%USERPROFILE%\tools;C:\keep spaces\bin;'
$joined = Add-ChiyoPathDirectory $original $directory
Assert-Equal $joined ($original + $directory) 'all existing entries and empty segments remain byte-for-byte'
Assert-Equal (Add-ChiyoPathDirectory $joined $directory) $joined 'repeat registration'
foreach ($equivalent in @($directory.ToLowerInvariant(), $directory.Replace('\','/'), ($directory+'\'), ('"'+$directory+'"'))) {
    $existing = 'C:\before;' + $equivalent + ';C:\after'
    Assert-Equal (Add-ChiyoPathDirectory $existing $directory) $existing 'case/separator/quoted equivalent is not duplicated'
}
$priorFixture = $env:CHIYO_PATH_TEST_ROOT
try {
    $env:CHIYO_PATH_TEST_ROOT = 'C:\Software\知予 安装'
    $existing = '%CHIYO_PATH_TEST_ROOT%\current\cli;C:\after'
    Assert-Equal (Add-ChiyoPathDirectory $existing $directory) $existing 'expanded equivalent preserves original variable text'
} finally { $env:CHIYO_PATH_TEST_ROOT = $priorFixture }

$base = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'build/cli-registration-tests'
New-Item -ItemType Directory -Path $base -Force | Out-Null
$root = Join-Path (Get-Item -LiteralPath $base).FullName ('安装 空格 '+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $root 'current/cli') -Force | Out-Null
$beforeUser = [Environment]::GetEnvironmentVariable('Path', 'User')
$beforeProcess = $env:PATH
try {
    $file = Join-Path $root 'current/cli/chiyo.exe'
    [IO.File]::WriteAllText($file, 'Synthetic identity fixture; this file is never executed.')
    $commit = '1' * 40
    $manifest = @{
        product='Agent Info Manage'; sourceCommit=$commit; sourceDirty=$false; architecture='windows-x64'; cliEntrypoint='cli/chiyo.exe'
        files=@(@{path='cli/chiyo.exe';bytes=(Get-Item -LiteralPath $file).Length;sha256=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()})
    }
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $root 'current/manifest.json') -Encoding utf8
    @{product='Agent Info Manage';sourceCommit=$commit} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'installation.json') -Encoding utf8
    Assert-Equal (Get-ChiyoInstalledCliDirectory $root) (Join-Path $root 'current\cli') 'managed install identity'
    $preview = Register-ChiyoWindowsCli -Directory $root -WhatIf
    Assert-Equal $preview.applied $false 'WhatIf never writes environment'
    Assert-Equal ([Environment]::GetEnvironmentVariable('Path','User')) $beforeUser 'user PATH unchanged by WhatIf'
    Assert-Equal $env:PATH $beforeProcess 'process PATH unchanged by WhatIf'
    [IO.File]::AppendAllText($file, ' changed')
    $rejected = $false
    try { Get-ChiyoInstalledCliDirectory $root | Out-Null } catch { $rejected = $true }
    Assert-Equal $rejected $true 'modified binary is refused before PATH changes'
} finally {
    $actual = (Get-Item -LiteralPath $root -Force).FullName
    $boundary = (Get-Item -LiteralPath $base).FullName.TrimEnd('\')+'\'
    if (-not $actual.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -or
        ((Get-Item -LiteralPath $actual -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Registration fixture escaped its build directory.'
    }
    Remove-Item -LiteralPath $actual -Recurse -Force
}
Write-Host 'PASS: Windows CLI PATH equivalence, preservation, managed identity and dry-run checks; user/system PATH unchanged.'
