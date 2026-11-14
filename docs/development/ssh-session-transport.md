# SSH session transport contract

Implements #146 and the approved specification at `3231374c`. This contract does
not narrow the interactive acceptance criteria.

## Ownership

- Common/Mac chat owns `packages/info_cli/lib/ssh_session*.dart` except
  `ssh_session_windows.dart`, `chiyo_ssh.dart`, shared CLI/host/core/server wiring,
  `scripts/ssh_session/remote_helper.py`, common tests, and this document.
- Windows chat owns `packages/info_cli/lib/ssh_session_windows.dart`,
  `packages/info_cli/windows/ssh_session/`,
  `packages/info_cli/test/ssh_session_windows*_test.dart`, and dedicated Windows
  build scripts. Request common changes instead of duplicating the state machine.
- Integration chat owns the approved specification, final approval UI and
  compatibility review, and integration.

## Platform API

`ssh_session_transport.dart` defines `SshTransportLauncher.start(SshTransportLaunch)`
returning `SshTransportProcess`. Launch contains the exact OpenSSH executable,
arguments, nonsecret environment, and a login challenge handler. No password is a
launch argument or environment value.

The process exposes `Stream<List<int>> output` (SSH stdout: helper protocol),
`diagnostics` (SSH stderr), `Future<int> exitCode`, `send(List<int>)`,
`closeInput()`, and `terminate()`. Common code serializes protocol writes. Platform
code must not parse terminal prompts, retry, enqueue commands, or recognize output
markers. It releases the private ASKPASS endpoint on termination.

`SshLoginChallenge` binds a challenge ID and password prompt category to the
verified SSH child process identity. Its handler returns secret bytes or null to
refuse. Only that verified authentication receives the one-use response. Unknown,
MFA, and private-key passphrase challenges fail explicitly until supported.

Windows exports `WindowsSshTransportLauncher`; its constructor may require an
explicit bundled helper path. It must run without a foreground terminal. Exact
Dart declarations follow in the next common commit.

## Isolation gate and remote helper

The capability-checked Python 3/POSIX helper requires Bash, remote PTY/ioctl,
process identity inspection, and Unix peer credentials; missing capabilities fail
explicitly without installing dependencies or checking an OS-name allowlist.
OpenSSH uses a nonterminal byte channel with strict host verification. The helper
allocates a real controlling PTY for one persistent Shell and enables Bash job
control. SSH stdout carries JSON-lines frames; terminal output is base64 inside
output events and cannot become a completion report.

The Shell reads commands from a separate pipe, never from its PTY. Each eval has
stdin/stdout/stderr redirected to the controlling PTY; completion goes to the
Shell's original stdout pipe, outside those redirections. Input frames bind runId;
a single-threaded broker closes the input gate and flushes queued PTY input both
at completion and before admitting another run. Thus a late input cannot become
a Shell command or the next program's input. Background terminal readers have
their own process groups and receive SIGTTIN rather than stealing foreground
input. Ctrl+C targets the terminal foreground group; the persistent Shell handles
INT and survives. Deliberately changing job control, traps, or control descriptors
can invalidate the session; this is not a sandbox against the approved account.

The helper is a connection child, not a permanent remote service. It changes no
sudoers/SSH settings and installs no software. Its reviewable code and nonsecret
session files occupy a private temporary directory, removed on exit. Secrets use
memory and dedicated pipes, never files. Missing capabilities fail explicitly.
This does not isolate the helper from deliberately hostile code with the same
remote account's existing authority.

## sudo gate

Never inject based on `Password:` terminal text. The session defines `sudo` (also `chiyo_sudo`) as a managed Shell function,
so ordinary `sudo command` needs no Agent-written ASKPASS script. It invokes the
verified system `sudo -A` and a session ASKPASS helper with a dedicated receive channel bound to
runId, the requesting process, and one authentication action. Verify the receiver
is still alive before requesting/rechecking authorization and sending one reply.
The channel closes after that action; neither the business program nor Shell
reads it. Ordinary sudo TTY prompts do not become managed credential receivers.
The common implementation will define the exact managed invocation syntax and
capability. No real credential delivery precedes proof of this property.

## Common responsibilities

Common code owns controller/library/device binding, live authorization checks,
ready/busy/draining/closed/lost, operation digests and deduplication, bounded secret
filtering, and cursor gaps. CLI exit does not close the resident host. Revocation
rejects run/input/credential but permits the original controller to query,
interrupt, or close; an existing run may finish naturally. Lost transports never
reconnect or replay, and unfinished runs become unknown.
