# Windows SSH transport

`info-ssh-session.exe` is both a headless OpenSSH broker and the broker's private
ASKPASS child. It uses an owner-only, remote-client-rejected named pipe, verifies
the helper's file identity and SSH parent/creation identity, and permits one
password response. Arguments/environment contain no authentication response.
Only the three intended stdio handles are inherited. An owned kill-on-close job
keeps SSH children tied to this transport, not to one CLI request.

Common launch configuration must disable keyboard-interactive authentication:
ASKPASS cannot distinguish its arbitrary prompts from password authentication.
Key passphrases and unknown prompts fail explicitly. This module does not parse
remote prompts or implement sudo; the common remote helper handles those.

Run `scripts/build-windows-ssh-session.ps1 -BuildTests`, prepare an isolated Python
environment with `paramiko==5.1.0`, then run the two `ssh_session_windows*_test.dart`
files from `packages/info_cli`. Tests use synthetic programs and loopback SSH.
Override `D7_WINDOWS_SSH_HELPER` / `D7_WINDOWS_SSH_PYTHON` for explicit paths.

Packaging calls `scripts/package-windows-ssh-session.ps1 -DestinationDirectory`
with the CLI payload directory. It includes only the production helper, checks
its digest and capability protocol, and uses a static MSVC runtime. The common
package manifest must include this helper; no desktop installation is performed.
