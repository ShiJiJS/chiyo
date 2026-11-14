# Windows SSH transport

`info-ssh-session.exe` is both a headless OpenSSH broker and the broker's private
ASKPASS child. It uses an owner-only, remote-client-rejected named pipe, verifies
the helper's file identity and SSH parent/creation identity, and permits one
password response. Arguments/environment contain no authentication response.
Only the three intended stdio handles are inherited. An owned kill-on-close job
keeps SSH children tied to this transport, not to one CLI request. A bounded
stdin writer runs separately from authentication/control so pre-authentication
SSH backpressure cannot prevent ASKPASS replies.

Common launch configuration must disable keyboard-interactive authentication:
ASKPASS cannot distinguish its arbitrary prompts from password authentication.
Key passphrases and unknown prompts fail explicitly. This module does not parse
remote prompts or implement sudo; the common remote helper handles those.

Run `scripts/build-windows-ssh-session.ps1 -BuildTests`, prepare an isolated Python
environment with `paramiko==5.1.0`, then run `ssh_session_windows_test.dart` and
`ssh_session_windows_identity_test.dart` from `packages/info_cli`. Tests use
synthetic programs and loopback SSH. Missing prerequisites produce an explicit
skip, not an acceptance pass.
Override `D7_WINDOWS_SSH_HELPER` / `D7_WINDOWS_SSH_PYTHON` for explicit paths.

For actual same-Shell/PTY/sudo checks, build the common disposable image in
`scripts/qa/ssh-session-fixture`, then use `remote_fixture.py <fresh build dir>
--image <image>` on Windows. It keeps WSL alive and listens only on loopback.
Set `D7_WINDOWS_SSH_REMOTE_FIXTURE` to that directory and
`D7_WINDOWS_SSH_REMOTE_PORT` from its `facts.json`; run
`ssh_session_windows_remote_test.dart`. Create its `stop` file after tests and
wait for the controller to stop the owned container. Host keys remain in
container tmpfs; native Windows ssh-keygen creates the synthetic client key with
private ACLs. This is transport/remote-helper acceptance; CLI authorization and
local/server library integration are tested by the common implementation.

Packaging calls `scripts/package-windows-ssh-session.ps1 -DestinationDirectory`
with the CLI payload directory. It includes only the production helper, checks
its digest and capability protocol, and uses a static MSVC runtime. The common
package manifest must include this helper; no desktop installation is performed.
