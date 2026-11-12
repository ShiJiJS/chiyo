# Focused-input checks (#35)

The production `info-focus-broker.exe` uses UI Automation to inspect technical
focus metadata and SendInput to fill a verified foreground password control.
It never reads field values, window titles, DOM or clipboard. It is installed
with the desktop App; its identity is bound into that App at build time.

The inspector, synthetic receivers, fault stubs and tests are excluded from
normal application builds and packaging. Only a synthetic receiver reads its
own fake input to check the result. Never use these fixtures with real secrets.

## Independent native checks

From the repository root, use the Visual Studio CMake executable (or `cmake`
when it is on PATH):

```powershell
cmake -S apps/desktop/windows/focused_input -B build/focused-input-native -G "Visual Studio 17 2022" -A x64
cmake --build build/focused-input-native --config Release --target check_focused_input focus_broker focus_fixture credential_receiver_fixture
ctest --test-dir build/focused-input-native -C Release --output-on-failure
```

This uses the same sources and compiler warnings as the desktop build, without
building Flutter or overwriting its build directory. `check_focused_input`
runs the 24 snapshot and 23 guard assertions; CTest exposes those two suites.
They are state/identity checks, not 47 live controls or successful fills.
Repeat with `Debug` when validating changes to native code.

## Command receiver feasibility

Use a project-local Python environment. Paramiko 5.1.0 is needed only for the
optional loopback SSH checks. Pass a new disposable output directory:

```powershell
python scripts/qa/focused-input/check-windows-receivers.py --receiver build/focused-input-native/Release/credential_receiver_fixture.exe --output build/focused-input-receivers --ssh C:/Windows/System32/OpenSSH/ssh.exe
```

The receiver checks exact UTF-8 stdin and file bytes, Windows Unicode environment
values, whitespace and newlines. It prints only match results. The SSH fixture
generates a fresh host key, pins it in a temporary known-hosts file, accepts
only the synthetic password and fixed `/usr/bin/true` command, and never loads
personal SSH configuration or keys. Temporary material is removed on exit.

The stdin SSH check is a bounded negative observation: the native client may
wait for a console prompt while ignoring its stdin pipe. The separate askpass
check uses the compiled synthetic receiver and `SSH_ASKPASS_REQUIRE=force`.
The synthetic password exists in that QA child's environment; this helper is
not a production secret transport. These checks prove OS receiver behavior,
not Chiyo approval, worker lifecycle, private file ACLs, or shipped SSH password
support. Test those separately against the shared runtime implementation.

## Desktop build diagnostics

Alternatively, after configuring the Windows Flutter build, run from `apps/desktop`
(use the Flutter SDK configured for this repository):

```powershell
flutter build windows --debug --no-pub
$taskCmake = (Select-String -LiteralPath build/windows/x64/CMakeCache.txt -Pattern '^CMAKE_COMMAND:INTERNAL=').Line.Split('=', 2)[1]
& $taskCmake --build build/windows/x64 --config Debug --target focus_inspector focus_snapshot_test
& ./build/windows/x64/focused_input/Debug/focus_snapshot_test.exe
```

Repeat the two final commands with `Release` for the release checks.
`info-focus-inspector.exe --inspect` writes a
private technical snapshot, including process identities. Use a hidden process
with captured output and a bounded timeout; do not publish raw snapshots as an
ordinary Agent response. Production must supply a separate safe projection.

`target.html` is an empty same-machine password/plain/disabled-control fixture.
It contains no credentials and does not read or submit input values. Serve only
on loopback, open an owned test tab, then close the tab/server/control session.
DOM focus from a browser tool does not prove native foreground focus. Do not
attempt to unlock Windows or change security/accessibility settings to obtain
a passing result. Record unsupported/locked results and resume native testing
when an ordinary unlocked desktop is available.

The fuller implementation and test gates are in
[`local-focused-fill-contract.md`](../../../docs/design/local-focused-fill-contract.md).
