[CmdletBinding(SupportsShouldProcess)]
param([string]$InstallDirectory = 'C:\Software\AgentInfoManage')

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Add-ChiyoPathDirectory {
    param([AllowNull()][AllowEmptyString()][string]$PathValue, [Parameter(Mandatory=$true)][string]$Directory)
    $wanted = [IO.Path]::GetFullPath($Directory).Replace('/', '\').TrimEnd('\')
    foreach ($entry in ($PathValue -split ';')) {
        $candidate = [Environment]::ExpandEnvironmentVariables($entry.Trim().Trim('"')).Replace('/', '\').TrimEnd('\')
        if ([IO.Path]::IsPathRooted($candidate)) {
            try { $candidate = [IO.Path]::GetFullPath($candidate).TrimEnd('\') } catch { continue }
        }
        if ([string]::Equals($wanted, $candidate, [StringComparison]::OrdinalIgnoreCase)) { return $PathValue }
    }
    if ([string]::IsNullOrEmpty($PathValue)) { return $wanted }
    $separator = if ($PathValue.EndsWith(';')) { '' } else { ';' }
    return $PathValue + $separator + $wanted
}

function Get-ChiyoInstalledCliDirectory {
    param([Parameter(Mandatory=$true)][string]$Directory)
    $install = (Get-Item -LiteralPath $Directory -Force).FullName.TrimEnd('\')
    $cli = Join-Path $install 'current/cli'
    $ancestor = Get-Item -LiteralPath $cli -Force
    while ($ancestor) {
        if ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked CLI installation path is unsupported.' }
        $ancestor = $ancestor.Parent
    }
    $receipt = Get-Content -LiteralPath (Join-Path $install 'installation.json') -Raw | ConvertFrom-Json
    $manifest = Get-Content -LiteralPath (Join-Path $install 'current/manifest.json') -Raw | ConvertFrom-Json
    if ($receipt.product -ne 'Agent Info Manage' -or $manifest.product -ne $receipt.product -or
        $manifest.sourceDirty -or $manifest.architecture -ne 'windows-x64' -or
        $manifest.sourceCommit -ne $receipt.sourceCommit -or $manifest.cliEntrypoint -ne 'cli/chiyo.exe') {
        throw 'The installation does not declare a matching chiyo command.'
    }
    $rows = @($manifest.files | Where-Object { $_.path -eq 'cli/chiyo.exe' })
    $binary = Get-Item -LiteralPath (Join-Path $cli 'chiyo.exe') -Force
    if ($rows.Count -ne 1 -or ($binary.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
        $binary.Length -ne $rows[0].bytes -or
        (Get-FileHash -LiteralPath $binary.FullName -Algorithm SHA256).Hash.ToLowerInvariant() -ne $rows[0].sha256) {
        throw 'Installed chiyo executable differs from its package manifest.'
    }
    return (Get-Item -LiteralPath $cli).FullName
}

function Send-ChiyoEnvironmentChange {
    try {
        if (-not ('Chiyo.Windows.EnvironmentChange' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace Chiyo.Windows {
    public static class EnvironmentChange {
        [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern IntPtr SendMessageTimeout(IntPtr window, uint message,
            UIntPtr wParam, string lParam, uint flags, uint timeout, out UIntPtr result);
        public static bool Notify() {
            UIntPtr result;
            return SendMessageTimeout(new IntPtr(0xffff), 0x1a, UIntPtr.Zero,
                "Environment", 2, 2000, out result) != IntPtr.Zero;
        }
    }
}
'@
        }
        return [Chiyo.Windows.EnvironmentChange]::Notify()
    } catch { return $false }
}

function Register-ChiyoWindowsCli {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory=$true)][string]$Directory)
    $cli = Get-ChiyoInstalledCliDirectory -Directory $Directory
    $read = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $false)
    try {
        $old = if ($read) { $read.GetValue('Path', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) } else { $null }
        $kind = if ($null -ne $old) { $read.GetValueKind('Path') } else { [Microsoft.Win32.RegistryValueKind]::ExpandString }
        if ($kind -notin @([Microsoft.Win32.RegistryValueKind]::String, [Microsoft.Win32.RegistryValueKind]::ExpandString)) {
            throw 'Current user PATH has an unsupported registry value type.'
        }
    } finally { if ($read) { $read.Dispose() } }
    $next = Add-ChiyoPathDirectory -PathValue $old -Directory $cli
    $processNext = Add-ChiyoPathDirectory -PathValue $env:PATH -Directory $cli
    $userChanged = $next -cne $old
    $processChanged = $processNext -cne $env:PATH
    $applied = $false
    $notified = $false
    if ($PSCmdlet.ShouldProcess('current Windows user and installer process PATH', "Register $cli")) {
        if ($userChanged) {
            $write = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment')
            try { $write.SetValue('Path', $next, $kind) } finally { $write.Dispose() }
        }
        $env:PATH = $processNext
        if ($userChanged) { $notified = Send-ChiyoEnvironmentChange }
        $applied = $true
    }
    [pscustomobject]@{
        cliPath = Join-Path $cli 'chiyo.exe'
        userPathChanged = $userChanged
        processPathChanged = $processChanged
        environmentNotificationSent = $notified
        applied = $applied
    }
}

# Dot-sourcing exposes the narrow path/identity helpers for isolated tests.
if ($MyInvocation.InvocationName -ne '.') {
    Register-ChiyoWindowsCli -Directory $InstallDirectory -WhatIf:$WhatIfPreference
}
