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

## Win32 receiver for App-host integration

`focus_fixture` contains two masked controls (IDs 101 / 102) and a plain text
control (ID 103). The second masked control supports focus-change checks; the
plain control must be refused by a production fill. A successful synthetic
match now also requires both other controls to be empty. `empty` means all
three controls are empty, so misdirected input cannot be hidden by an empty
first password control.

`packages/info_cli/test/support/windows_password_receiver.dart` wraps the
receiver's existing private frames. It configures a synthetic value, verifies
boolean results, clears fields, arms a focus change and closes the receiver
by EOF. It does not activate windows or send keyboard input. Reuse it with the
actual HTTPS / App-host implementation instead of duplicating host protocols.

From `packages/info_cli`, after building `focus_fixture`:

```powershell
$env:WINDOWS_PASSWORD_RECEIVER = 'C:/path/to/build/focused-input-native/Release/info-focus-fixture.exe'
dart test test/windows_password_receiver_test.dart
```

The test checks pipe framing, empty-field metadata and normal window shutdown;
it does not prove a credential fill. An unset executable or another OS is an
explicit skip.

## Interactive browser probe

`packages/info_cli/test/support/windows_browser_fill_probe.dart` prepares a
loopback synthetic page and an isolated Memory service, then drives a compiled
JSON-lines CLI with the production Windows broker. It opens no browser itself.
The operator owns foreground selection and must use an authorized browser tool.
Its arguments are fixed broker executable, CLI executable, and a fresh evidence
directory. The initial public state contains the page URL; `command.json`
accepts increasing integer `id` values and actions `probe`, `authorize`, `fill`,
`duplicate`, `reserve`, `send-reserved`, `clear`, `arm-change`, `query`, `close`.
Public results contain only application identity, statuses and test booleans;
random synthetic material stays in the credential service and test receiver.

This helper's existence is not browser compatibility evidence. Stop when a
browser tool refuses control or cannot establish page context; do not change
security settings or route around that check. `close` shuts down the local
probe without any browser interaction; a 20-minute bound also ends it.

## Windows HTTPS to App-host acceptance

`apps/desktop/integration_test/windows_remote_focused_fill_test.dart` runs an
isolated HTTPS server with SQLCipher and Windows DPAPI, the real desktop runner,
`StorageDesktopLauncher`'s production private host, the build-bound native
driver, and the Win32 receiver above. No production NAS profile or credential
is loaded. The desktop platform fixture replaces OS notifications and final
process termination; it still invokes the App's normal host-close lifecycle.

From `apps/desktop`, with the fixed repository SDK and dependencies available:

```powershell
flutter test integration_test/windows_remote_focused_fill_test.dart -d windows --no-pub --dart-define=FILL_RECEIVER=C:/path/to/info-focus-fixture.exe --dart-define=FILL_EVIDENCE=C:/project/build/fresh-windows-fill
```

Use a fresh evidence directory. Wait for `state.json` to report
`awaiting_focus`. Use an authorized native UI tool to focus receiver control
101. Write increasing `id` and `action` pairs to `command.json`, waiting for the
same ID in `state.json` after every action:

1. `probe`, `request`, `approve`, `fill`, `duplicate`, `clear`.
2. Focus plain control 103, then `fill`: no field may receive input.
3. Refocus password control 101, then `arm-change`, `fill`, `attention-block`.
4. `clear`, `quit`, `finish`.

The synthetic owner approval goes through the real HTTPS owner endpoint.
The receiver independently checks exact Unicode and whitespace, other fields,
paste events and clipboard sequence. A changed target must stop later batches
and require attention; the test never acknowledges an unknown operation to
retry it. `quit` checks that App lifecycle closes the host and rejects new input.
Complete within the receiver's five-minute safety limit. Teardown closes its
pipe and removes the isolated server state normally. This does not establish
browser compatibility or installation against a live NAS.

## Windows public batch CLI and real App host

`apps/desktop/integration_test/windows_credential_batch_fill_test.dart` covers
the v3 public command path with the real Windows runner, its build-bound native
helper, the production `StorageDesktopLauncher` private batch host, and a
separately compiled same-source `chiyo.exe`. It creates an independent HTTPS /
SQLCipher / DPAPI library and private chat; it never loads the installed App's
profiles or a production NAS. Approval uses the ordinary Workspace owner
review/decision transport. Notifications and final process termination use the
same desktop platform fixture as the earlier test; this is not OS notification
or installed release acceptance.

Prepare a same-source AOT CLI and an exclusively owned synthetic Ego TaskSpace
using the installed Ego Skill. Supply its actual space and Page labels below.
Chrome uses a new headless profile inside the new evidence directory; the App
finds its own installed Ego helper, with no helper path in Agent business input.
From `apps/desktop`, use a fresh evidence directory for every run:

```powershell
flutter test integration_test/windows_credential_batch_fill_test.dart -d windows --no-pub --dart-define=BATCH_EVIDENCE=C:/project/build/new-batch-app --dart-define=BATCH_CLI=C:/project/build/batch-cli/chiyo.exe '--dart-define=BATCH_CHROME=C:/Program Files/Google/Chrome/Application/chrome.exe' --dart-define=BATCH_RECEIVER=C:/project/build/focused-input-native/Release/info-focus-fixture.exe --dart-define=BATCH_EGO_SPACE=7 --dart-define=BATCH_EGO_PAGE=p1
```

Chrome and Ego are automatic. Each receiver checks exact fake Unicode, emoji
and whitespace, the untouched other field, and exactly one input event after
retrying the original operation. Their fake fields are cleared afterwards.
When `state.json` reports `awaiting_win32_focus`, use authorized Computer Use
only on the newly created synthetic Win32 receiver:

1. Focus its masked control 101, then write `{"id":1,"action":"native-positive"}`
   to the evidence directory's `command.json`. Wait for ID 1 in `state.json`.
2. Focus ordinary control 103, then write `{"id":2,"action":"native-plain"}`.
   The original approved request must be refused and every control stay empty.
3. Write `{"id":3,"action":"finish"}`. The normal App quit lifecycle must close
   the private host and make new capability requests unavailable.

The native receiver checks an exact synthetic match, unchanged clipboard and
no paste; control selection is separate from the production credential input.
Complete this phase within four minutes. Normal teardown closes the owned
Win32 receiver, the headless Chrome and the encrypted fixture. The caller must
finish its Ego TaskSpace after observing the completed result. A passing test
does not establish live-NAS deployment or compatibility with every website or
ordinary application.

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
