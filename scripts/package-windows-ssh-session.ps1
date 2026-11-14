# Called by the package builder after its CLI payload directory is prepared.
# Does not install, run the App, or package synthetic test executables.
param(
    [Parameter(Mandatory = $true)][string]$DestinationDirectory,
    [string]$BuildDirectory = 'build/ssh-session/native'
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
if (-not [IO.Path]::IsPathRooted($BuildDirectory)) { $BuildDirectory = Join-Path $projectRoot $BuildDirectory }
& (Join-Path $PSScriptRoot 'build-windows-ssh-session.ps1') -OutputDirectory $BuildDirectory | Out-Null
$source = Join-Path $BuildDirectory 'Release/info-ssh-session.exe'
New-Item -ItemType Directory -Force -Path $DestinationDirectory | Out-Null
$destination = Join-Path $DestinationDirectory 'info-ssh-session.exe'
Copy-Item -LiteralPath $source -Destination $destination -Force
$sourceHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant() -cne $sourceHash) { throw 'SSH helper payload digest differs.' }
$startInfo = [Diagnostics.ProcessStartInfo]::new((Resolve-Path -LiteralPath $destination).Path)
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$startInfo.RedirectStandardOutput = $true
$startInfo.Arguments = '--capabilities'
$probe = [Diagnostics.Process]::Start($startInfo)
$capabilities = $probe.StandardOutput.ReadToEnd()
$probe.WaitForExit()
if ($probe.ExitCode -ne 0) { throw 'Packaged SSH helper did not start.' }
$probe.Dispose()
$observed = $capabilities | ConvertFrom-Json
if ($observed.transport -ne 1 -or $observed.askpass -ne 1 -or $observed.headless -ne $true) { throw 'Packaged SSH helper protocol differs.' }
[PSCustomObject]@{ Path = $destination; Sha256 = $sourceHash }
