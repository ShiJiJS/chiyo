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

First prove a session-scoped Python 3/POSIX helper using capability checks, not OS
name allowlists. OpenSSH runs it over a nonterminal byte channel with strict host
verification. The helper creates a remote PTY per run while retaining one Shell
process. Thus SSH stdout carries framed control messages, while remote PTYs carry
ordinary terminal bytes, including ANSI and merged stdout/stderr.

Shell control input is separate from user input. Each run executes in the same
Shell under redirections to a fresh PTY. Completion reports travel separately
from command stdout/stderr. Forged output markers remain output. Input frames
include runId; the helper checks it and writes only that run's PTY. Late input
can at worst reach an obsolete terminal, never the Shell command stream or the
next run's terminal. JSON-lines control messages are bounded; output is base64.

The helper is a connection child, not a permanent remote service. It changes no
sudoers/SSH settings and installs no software. Its reviewable code and nonsecret
session files occupy a private temporary directory, removed on exit. Secrets use
memory and dedicated pipes, never files. Missing capabilities fail explicitly.
This does not isolate the helper from deliberately hostile code with the same
remote account's existing authority.

## sudo gate

Never inject based on `Password:` terminal text. A managed sudo invocation uses
`sudo -A` and a session ASKPASS helper with a dedicated receive channel bound to
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
