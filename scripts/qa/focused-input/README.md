# Focused-input checks (#35)

The current native target inspects technical focus metadata only. It does not
read field values/window titles/clipboard, handle secrets, or send input. It is
excluded from normal application builds and packaging. This is not a shipped
fill CLI or an authorization adapter.

After configuring the existing Windows Flutter build, run from `apps/desktop`
(use the Flutter SDK configured for this repository):

```powershell
flutter build windows --debug --no-pub
$taskCmake = (Select-String -LiteralPath build/windows/x64/CMakeCache.txt -Pattern '^CMAKE_COMMAND:INTERNAL=').Line.Split('=', 2)[1]
& $taskCmake --build build/windows/x64 --config Debug --target focus_inspector focus_snapshot_test
& ./build/windows/x64/focused_input/Debug/focus_snapshot_test.exe
```

Repeat the two final commands with `Release` for the release checks. The 24
checks exercise recognition predicates and JSON encoding; they are not 24 live
controls or a successful fill. `info-focus-inspector.exe --inspect` writes a
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
