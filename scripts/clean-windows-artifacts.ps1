[CmdletBinding(SupportsShouldProcess)]
param([string]$InstallDirectory = 'C:\Software\AgentInfoManage')

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$project = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$install = [IO.Path]::GetFullPath($InstallDirectory)
if ($install.StartsWith("$project\", [StringComparison]::OrdinalIgnoreCase)) { throw 'Keep the installation outside the source checkout.' }
$receipt = Get-Content -LiteralPath (Join-Path $install 'installation.json') -Raw | ConvertFrom-Json
if ($receipt.product -ne 'Agent Info Manage') { throw 'No verified external installation; keep build outputs.' }
$archive = Join-Path $install "package/$($receipt.archiveName)"
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $receipt.archiveSha256) {
    throw 'Installed archive checksum mismatch; keep build outputs.'
}
$manifest = Get-Content -LiteralPath (Join-Path $install 'current/manifest.json') -Raw | ConvertFrom-Json
foreach ($entry in $manifest.files) {
    $file = [IO.Path]::GetFullPath((Join-Path $install "current/$($entry.path)"))
    if (-not $file.StartsWith("$install\current\", [StringComparison]::OrdinalIgnoreCase) -or
        (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() -ne $entry.sha256) {
        throw 'Installed payload is incomplete; keep build outputs.'
    }
}

$allowed = @('build', '.scratch', 'apps/desktop/build', 'apps/desktop/.dart_tool',
    'packages/info_cli/.dart_tool', 'packages/info_core/.dart_tool', 'packages/info_storage/.dart_tool') |
    ForEach-Object { [IO.Path]::GetFullPath((Join-Path $project $_)) }
$running = @(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath } | ForEach-Object { $_.ExecutablePath })
$targets = [Collections.Generic.List[string]]::new()
function Assert-Contained([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    if (-not ($allowed | Where-Object { $full -eq $_ -or $full.StartsWith("$_\", [StringComparison]::OrdinalIgnoreCase) })) {
        throw "Cleanup path is outside generated artifacts: $full"
    }
    # Reject linked ancestors; removing a link itself below never follows it.
    $parent = [IO.Directory]::GetParent($full)
    while ($parent -and $parent.FullName -ne $project) {
        if ((Get-Item -LiteralPath $parent.FullName -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Linked cleanup ancestor: $($parent.FullName)"
        }
        $parent = $parent.Parent
    }
    return $full
}
function Add-Target([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $full = Assert-Contained $Path
    if ($running | Where-Object { $_ -eq $full -or $_.StartsWith("$full\", [StringComparison]::OrdinalIgnoreCase) }) {
        Write-Warning "Keep running artifact: $full"
        return
    }
    $targets.Add($full)
}
foreach ($item in Get-ChildItem -LiteralPath (Join-Path $project 'build') -Directory -Force) {
    # Only application packaging directories. Keep Codex integration materials and QA evidence.
    if ($item.Name -like 'windows-*') { Add-Target $item.FullName }
}
foreach ($relative in @('apps/desktop/build', 'apps/desktop/.dart_tool',
    'packages/info_cli/.dart_tool', 'packages/info_core/.dart_tool', 'packages/info_storage/.dart_tool')) {
    Add-Target (Join-Path $project $relative)
}
function Find-CompiledFiles([string]$Folder) {
    if (-not (Test-Path -LiteralPath $Folder)) { return }
    foreach ($entry in Get-ChildItem -LiteralPath $Folder -Force) {
        if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        if ($entry.PSIsContainer) {
            if ($entry.Name -like 'aws-cli-*') { continue } # Downloaded test tool, not an application build.
            if ($entry.Name -in @('.dart_tool','build')) { Add-Target $entry.FullName }
            else { Find-CompiledFiles $entry.FullName }
        } elseif ($entry.Extension -in @('.exe','.dll','.dill','.snapshot','.aot','.zip','.pdb','.obj','.lib','.ilk','.exp','.so')) {
            Add-Target $entry.FullName
        }
    }
}
foreach ($item in Get-ChildItem -LiteralPath (Join-Path $project 'build') -Directory -Force) {
    if ($item.Name -like 'qa-*' -or $item.Name -eq 'library-ux') { Find-CompiledFiles $item.FullName }
}
Find-CompiledFiles (Join-Path $project '.scratch')

$script:removedBytes = [long]0
$script:removedFiles = 0
function Remove-GeneratedTree([string]$Path) {
    $full = Assert-Contained $Path
    $item = Get-Item -LiteralPath $full -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        # Nonrecursive unlink: preserve the linked target even if it is outside this repo.
        if ($item.PSIsContainer) { [IO.Directory]::Delete($full) } else { [IO.File]::Delete($full) }
    } elseif ($item.PSIsContainer) {
        foreach ($child in Get-ChildItem -LiteralPath $full -Force) { Remove-GeneratedTree $child.FullName }
        Remove-Item -LiteralPath $full -Force
    } else {
        $length = $item.Length
        Remove-Item -LiteralPath $full -Force
        $script:removedBytes += $length
        $script:removedFiles++
    }
}
foreach ($target in $targets) {
    if ($PSCmdlet.ShouldProcess($target, 'Remove regenerable build artifact')) { Remove-GeneratedTree $target }
}
[pscustomobject]@{ removedBytes = $script:removedBytes; removedFiles = $script:removedFiles; candidates = $targets.Count }
