param(
    [Parameter(Mandatory=$true)][string]$Executable,
    [Parameter(Mandatory=$true)][string]$Icon,
    [switch]$VerifySource
)

# Inspect PE resources as data; never launch the desktop application.
$ErrorActionPreference = 'Stop'
$exe = (Get-Item -LiteralPath $Executable).FullName
$version = [Diagnostics.FileVersionInfo]::GetVersionInfo($exe)
if ($version.ProductName -ne '知予' -or $version.FileDescription -ne '知予') {
    throw 'The compiled executable still has an old application name.'
}
if (-not ([System.Management.Automation.PSTypeName]'ChiyoBrandingResources').Type) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class ChiyoBrandingResources {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern IntPtr LoadLibraryExW(string file, IntPtr reserved, uint flags);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern IntPtr FindResourceW(IntPtr module, IntPtr name, IntPtr type);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern IntPtr LoadResource(IntPtr module, IntPtr resource);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern uint SizeofResource(IntPtr module, IntPtr resource);
    [DllImport("kernel32.dll")] static extern IntPtr LockResource(IntPtr resource);
    [DllImport("kernel32.dll")] static extern bool FreeLibrary(IntPtr module);
    public static byte[] Read(string file, int name, int type) {
        var module=LoadLibraryExW(file, IntPtr.Zero, 0x22);
        if (module==IntPtr.Zero) throw new Win32Exception();
        try {
            var resource=FindResourceW(module, (IntPtr)name, (IntPtr)type);
            if (resource==IntPtr.Zero) throw new Win32Exception();
            var size=SizeofResource(module, resource);
            var loaded=LoadResource(module, resource);
            var pointer=LockResource(loaded);
            if (size==0 || pointer==IntPtr.Zero) throw new Win32Exception();
            var result=new byte[size];
            Marshal.Copy(pointer, result, 0, result.Length);
            return result;
        } finally { FreeLibrary(module); }
    }
}
'@
}
$ico = [IO.File]::ReadAllBytes((Get-Item -LiteralPath $Icon).FullName)
$group = [ChiyoBrandingResources]::Read($exe, 101, 14)
if ($ico.Length -lt 6 -or $group.Length -lt 6 -or
    [BitConverter]::ToUInt16($ico,0) -ne 0 -or [BitConverter]::ToUInt16($ico,2) -ne 1) {
    throw 'Invalid application icon container.'
}
$count = [BitConverter]::ToUInt16($ico,4)
if ($count -ne 5 -or [BitConverter]::ToUInt16($group,4) -ne $count -or
    $ico.Length -lt 6+16*$count -or $group.Length -ne 6+14*$count) {
    throw 'Incomplete compiled application icon sizes.'
}
$sha = [Security.Cryptography.SHA256]::Create()
try {
    for ($i=0; $i -lt $count; $i++) {
        $a=6+16*$i; $b=6+14*$i
        for ($j=0; $j -lt 12; $j++) {
            if ($ico[$a+$j] -ne $group[$b+$j]) { throw 'Compiled icon directory differs from the shipped icon.' }
        }
        $length=[BitConverter]::ToUInt32($ico,$a+8)
        $offset=[BitConverter]::ToUInt32($ico,$a+12)
        if ($offset -lt 6+16*$count -or [long]$offset+$length -gt $ico.Length) { throw 'Invalid icon frame range.' }
        $expected=[byte[]]::new($length)
        [Array]::Copy($ico,$offset,$expected,0,$length)
        $actual=[ChiyoBrandingResources]::Read($exe,[BitConverter]::ToUInt16($group,$b+12),3)
        if ([BitConverter]::ToString($sha.ComputeHash($expected)) -ne [BitConverter]::ToString($sha.ComputeHash($actual))) {
            throw 'The compiled executable contains an old icon.'
        }
        if ($VerifySource) {
            $size=if ($ico[$a] -eq 0) {256} else {[int]$ico[$a]}
            $source=Join-Path (Split-Path -Parent $PSScriptRoot) "apps/desktop/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_$size.png"
            if ([BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($source))) -ne [BitConverter]::ToString($sha.ComputeHash($actual))) {
                throw 'The Windows icon is not synchronized with the approved application artwork.'
            }
        }
    }
} finally { $sha.Dispose() }
Write-Host 'PASS: compiled 知予 product name and five original icon frames; application was not launched.'
