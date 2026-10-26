[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ArchivePath,
    [string]$InstallDirectory = 'C:\Software\AgentInfoManage',
    [int]$RunningProcessId = 0,
    [string]$PreviewReason,
    [switch]$CleanBuildArtifacts
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$archive = (Get-Item -LiteralPath $ArchivePath).FullName
$digest = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
if ($digest -ne ((Get-Content -LiteralPath "$archive.sha256" -Raw).Split(' ')[0]).Trim()) { throw 'Archive checksum mismatch.' }
$verified = "$archive.verified.json"
if (-not $PreviewReason) {
    if (-not (Test-Path -LiteralPath $verified) -or
        (Get-Content -LiteralPath $verified -Raw | ConvertFrom-Json).archiveSha256 -ne $digest) {
        throw 'Full package acceptance is missing. An explicitly requested preview needs -PreviewReason.'
    }
}
$install = [IO.Path]::GetFullPath($InstallDirectory).TrimEnd([IO.Path]::DirectorySeparatorChar)
$parent = Split-Path -Parent $install
if (-not $parent -or $install -eq [IO.Path]::GetPathRoot($install)) { throw 'Use a dedicated application directory.' }
New-Item -ItemType Directory -Path $parent -Force | Out-Null
$ancestor = Get-Item -LiteralPath $parent -Force
while ($ancestor) {
    if ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked installation path is unsupported.' }
    $ancestor = $ancestor.Parent
}
if (Test-Path -LiteralPath $install) {
    if ((Get-Item -LiteralPath $install -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked installation directory.' }
    $existing = Get-Content -LiteralPath (Join-Path $install 'installation.json') -Raw | ConvertFrom-Json
    if ($existing.product -ne 'Agent Info Manage') { throw 'Destination is not a managed Agent Info installation.' }
    $unknown = @(Get-ChildItem -LiteralPath $install -Force | Where-Object { $_.Name -notin @('current','package','installation.json','预览说明.txt') })
    if ($unknown.Count) { throw 'Unmanaged files in installation directory; keep them unchanged.' }
}
$stage = Join-Path $parent ('.AgentInfoManage-stage-' + [Guid]::NewGuid().ToString('N'))
$previous = Join-Path $parent ('.AgentInfoManage-previous-' + [Guid]::NewGuid().ToString('N'))
$desktop = [Environment]::GetFolderPath('Desktop')
$shortcutPath = Join-Path $desktop '信息授权.lnk'
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$exe = Join-Path $install 'current/app/info_desktop.exe'
if ((Test-Path -LiteralPath $shortcutPath) -and $shortcut.TargetPath -ne $exe) {
    throw 'Desktop shortcut already points elsewhere; keep it unchanged.'
}
New-Item -ItemType Directory -Path $stage | Out-Null
$swapped = $false
try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($archive)
    try {
        foreach ($entry in $zip.Entries) {
            $full = [IO.Path]::GetFullPath((Join-Path $stage $entry.FullName))
            if (-not $full.StartsWith("$stage\", [StringComparison]::OrdinalIgnoreCase) -or
                -not $entry.FullName.StartsWith('AgentInfoManage/') -or
                (($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) { throw 'Unsafe archive entry.' }
        }
    } finally { $zip.Dispose() }
    Expand-Archive -LiteralPath $archive -DestinationPath $stage
    $payload = Join-Path $stage 'AgentInfoManage'
    $manifest = Get-Content -LiteralPath (Join-Path $payload 'manifest.json') -Raw | ConvertFrom-Json
    if ($manifest.product -ne 'Agent Info Manage' -or $manifest.sourceDirty -or $manifest.architecture -ne 'windows-x64') { throw 'Invalid package identity.' }
    foreach ($entry in $manifest.files) {
        $file = [IO.Path]::GetFullPath((Join-Path $payload $entry.path))
        if (-not $file.StartsWith("$payload\", [StringComparison]::OrdinalIgnoreCase) -or
            (Get-Item -LiteralPath $file).Length -ne $entry.bytes -or
            (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() -ne $entry.sha256) { throw 'Payload checksum mismatch.' }
    }
    if (@(Get-ChildItem -LiteralPath $payload -File -Recurse).Count -ne $manifest.files.Count + 1) { throw 'Unlisted payload files.' }
    Move-Item -LiteralPath $payload -Destination (Join-Path $stage 'current')
    New-Item -ItemType Directory -Path (Join-Path $stage 'package') | Out-Null
    Copy-Item -LiteralPath $archive -Destination (Join-Path $stage 'package')
    Copy-Item -LiteralPath "$archive.sha256" -Destination (Join-Path $stage 'package')
    if (Test-Path -LiteralPath $verified) { Copy-Item -LiteralPath $verified -Destination (Join-Path $stage 'package') }
    [ordered]@{ product='Agent Info Manage'; release=$manifest.release; sourceCommit=$manifest.sourceCommit;
        archiveName=[IO.Path]::GetFileName($archive); archiveSha256=$digest; installedAtUtc=[DateTime]::UtcNow.ToString('o');
        fullPackageAcceptancePassed=[bool](-not $PreviewReason); previewReason=$PreviewReason } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stage 'installation.json') -Encoding utf8
    $note = "版本：$($manifest.release)`n运行current/app/info_desktop.exe，保留完整目录。首次打开旧资料库会升级，建议事先导出加密备份。`n"
    if ($PreviewReason) { $note += "开发预览，尚未通过全部整包验收：$PreviewReason`n" }
    $note | Set-Content -LiteralPath (Join-Path $stage '预览说明.txt') -Encoding utf8
    $cli = Join-Path $stage 'current/cli/info.exe'
    $statusArgs = @('app','status')
    if ($RunningProcessId) { $statusArgs += @('--pid',"$RunningProcessId") }
    else {
        $installedProcess = @(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -eq $exe })
        if ($installedProcess.Count -gt 1) { throw 'Multiple installed instances; resolve before replacement.' }
        if ($installedProcess.Count -eq 1) { $RunningProcessId = $installedProcess[0].ProcessId; $statusArgs += @('--pid',"$RunningProcessId") }
    }
    if ($RunningProcessId) {
        $state = (& $cli @statusArgs | ConvertFrom-Json)
        if ($LASTEXITCODE -ne 0 -or $state.status -ne 'running') { throw 'Cannot confirm the requested running instance.' }
        $quit = (& $cli app quit --pid $RunningProcessId --timeout-ms 15000 | ConvertFrom-Json)
        if ($LASTEXITCODE -ne 0 -or $quit.status -ne 'exited') { throw 'Normal exit failed; keep the running installation.' }
    }
    if (Test-Path -LiteralPath $install) { Move-Item -LiteralPath $install -Destination $previous }
    try { Move-Item -LiteralPath $stage -Destination $install; $swapped = $true }
    catch { if (Test-Path -LiteralPath $previous) { Move-Item -LiteralPath $previous -Destination $install }; throw }
    $shortcut.TargetPath = $exe
    $shortcut.WorkingDirectory = Split-Path -Parent $exe
    $shortcut.IconLocation = "$exe,0"
    $shortcut.Description = '信息授权'
    $shortcut.Save()
    # Only the verified, exact prior install is removed, after the new shortcut is saved.
    if (Test-Path -LiteralPath $previous) {
        if ([IO.Path]::GetFullPath($previous) -ne (Join-Path $parent (Split-Path -Leaf $previous))) { throw 'Unsafe previous directory.' }
        Remove-Item -LiteralPath $previous -Recurse -Force
    }
    Write-Host "Installed $($manifest.release): $exe"
    Write-Host "Shortcut: $shortcutPath"
    if ($CleanBuildArtifacts) { & (Join-Path $PSScriptRoot 'clean-windows-artifacts.ps1') -InstallDirectory $install }
} finally {
    if (-not $swapped -and (Test-Path -LiteralPath $stage)) {
        if ([IO.Path]::GetFullPath($stage) -ne (Join-Path $parent (Split-Path -Leaf $stage))) { throw 'Unsafe staging directory.' }
        Remove-Item -LiteralPath $stage -Recurse -Force
    }
}
