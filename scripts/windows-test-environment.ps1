# TLS fixtures create disposable certificates. This is a development dependency,
# not part of the desktop/CLI runtime or a change to the user's global PATH.
function Initialize-WindowsTestEnvironment {
    if ($env:OS -ne 'Windows_NT') { return }
    $openssl = Get-Command openssl.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $openssl) {
        foreach ($git in @(Get-Command git.exe -CommandType Application -ErrorAction SilentlyContinue)) {
            $candidate = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $git.Source) '../usr/bin/openssl.exe'))
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                # Append so unrelated Windows tools keep their existing order.
                $env:PATH = "$env:PATH;$(Split-Path -Parent $candidate)"
                $openssl = Get-Command openssl.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
                break
            }
        }
    }
    if (-not $openssl) {
        throw 'TLS tests require OpenSSL. Put an existing openssl.exe on this process PATH or install Git for Windows with its bundled OpenSSL; do not skip certificate checks.'
    }
    $version = & $openssl.Source version
    if ($LASTEXITCODE -ne 0) { throw 'OpenSSL could not start; TLS fixture tests cannot run.' }
    Write-Host "Windows test certificate tool: $version"
}
