# Credential use

Use the same private association and stdin-only `info-codex` transport as the
main Skill. Choose command injection below for a CLI tool, or
[Focused password input](#focused-password-input) for a visible local password
box. Identify the actual destination before requesting: the program and input
method, or the visible app/password field. Query the current connection's
capabilities first. The device executor handles injected credentials; approval
alone neither starts the program nor fills a field.

Choose the receiving method before submitting an application:

- For a browser tool with a documented fill API, use a receiver that actually
  reaches that API. First probe the exact login URL and unique password input
  without a real credential. The personal agent-info-access Skill supplies an
  ego-browser stdin bridge; use its browser-filling reference when installed.
  ego-browser nodejs scripts do not inherit the CLI process's environment, so
  program_env alone does not deliver a password into those scripts.
- For a visible desktop or browser password box without a usable script API,
  discover a ready native target before requesting focused input.
- For command-line programs, check the actual stdin/env/file interface first.
  Use a synthetic value to verify an uncertain adapter before requesting real
  credentials. Capability availability alone does not prove the adapter works.

Submit one complete working plan for the task. If an unexecuted plan has to be
replaced, clearly identify the superseded request rather than leaving the user
to choose between similar applications. A successful receiver exit or `sent`
only establishes delivery; verify the service's logged-in result separately.

If the required method is unavailable or a definite failure prevents use,
explain that reason and use [Explicit original-value access](#explicit-original-value-access)
only after its separate approval. A lost response or unknown outcome is not a
reason to switch methods and repeat the action.

## Command injection: request once, reuse within the approved validity

1. Query `capabilities`. New `request-use`, `run-use` and `operation-status`
   default to protocol2 and require `credential-use-reuse.v1`. An unsupported
   service requires a matching whole app/CLI/worker bundle; never silently
   downgrade or create a replacement single-use request.
   For `gh_token`, `ssh_identity` and `aws_shared_credentials`, require
   `credential-tools.v1`. Select the matching receiver in
   `credentialTools` with `available:true` and use its exact absolute
   `executable`. In server mode these are current-device CLI observations, not
   paths on the server. A prepared bundle refers to its matching App's tools;
   keep that App at its stable path and prepare again after moving/upgrading it.
   Missing or invalid entries require restoring the matching package, not
   guessing another executable. For general programs, require the chosen
   `program_*` receiver in `supportedCredentialReceivers` and use the actual
   installed executable. Its presence in this list means the receiving method
   exists, not that every program or its sandbox permits a successful launch.
   Tool discovery is public metadata; the owner still approves credential use,
   and each operation independently checks executable identity and version.
2. Query `credential-catalog` for public metadata, form, current version and
   suggested binding. Select the one credential relevant to the task. Submit
   one `request-use` with `purpose`, `credentials` (`alias`, `credentialId`,
   `version`) and the first complete `launch` (`receiver`, absolute `executable`,
   exact `argv`, existing absolute `cwd`, typed `env`). This first command helps
   the owner understand the task; it is not the only command allowed forever.
   Optional `readFields` contains ordinary item/field IDs, independently approved.
3. Keep the returned `requestId`. Use `status` or bounded `wait` on that same
   request (`timeoutMs`0–300000) and continue unrelated work while pending.
   Approval does not start anything. Inspect `decision.credentialUse.approved`,
   current `state` and the returned validity; only `available` admits a new operation.
   Timed credential use has a fixed `expiresAt` (normally two hours; the user can choose
   2, 4, 8 or 24 hours). If `credential-ssh-session-validity.v1` is available for protocol2
   `ssh_identity`, the user may instead choose “不限时（限本聊天）” in the App.
   The decision then returns `validity:"session"`, `expiresAt:null` and `sessionId`.
   Null expiry alone is not permission: check this capability, the explicit
   validity, approved scope and `available` state. The Agent submits the normal
   request; it does not self-approve session validity or send a huge duration.
   This option applies only to SSH, not ordinary reads or other receivers.
   Ordinary fields have their own user-approved deadline and use claim/read.
   With `credential-account.v1`, an available approved use also returns the
   stored login account in `decision.credentialUse.account` when nonempty.
   Use this account for the approved service; it is not a password. It stays
   out of the public catalog and is omitted for pending or invalid grants.
   An absent/empty account is unknown; do not guess it from the service name.
4. For each logical command, choose a new unique `operationId` and send
   `run-use` with the same `requestId` and that command's complete `launch`.
   The alias, credential version and receiver remain in the approved scope.
   For `program_*`, executable identity and typed credential positions also stay
   fixed. A different program or injection position requires a new request.
   Legal new commands within that scope need no new approval and never extend
   a timed deadline or turn a session grant into permission for another chat. CLI validates the real receiver and freezes each operation's
   executable identity, parameters, directory and effective injection plan.
5. Keep `executionId`. `accepted` means the operation was registered, not that
   the process started or succeeded. Query `execution-status` and distinguish
   preparing/running/exited/prepare_failed/start_failed/unknown; use an exit code
   only when actually recorded. Stop polling at a terminal fact and use bounded
   intervals while running. A failed operation does not consume the whole grant.
6. If output is needed and `outputAvailable` is true, use `execution-output`
   with executionId, cursor0 and limit1–16. Decode `dataBase64` for its `stream`
   and advance `nextCursor` while `hasMore`. OutputComplete/outputTruncated are
   separate facts. At most4MiB is retained per task, up to16 resident tasks;
   completed caches may be evicted, expire after30minutes, or disappear on host
   exit. Missing output is not a reason to launch the command again.

Examples omit the private `association`; pass the current reference separately
in each stdin JSON object as required by the main Skill. Replace public IDs and
absolute paths using the actual catalog and local program installation.

```json
{"protocolVersion":2,"command":"request-use","purpose":"Check the skill repository","credentials":[{"alias":"github_token","credentialId":"CREDENTIAL_ID","version":1}],"launch":{"receiver":"gh_token","executable":"C:/Program Files/GitHub CLI/gh.exe","argv":["repo","view","northstar/agent-skills"],"cwd":"C:/work/northstar","env":{"GH_TOKEN":{"secret":"github_token"}}}}
```

After approval, the first operation still needs its own ID and full launch:

```json
{"protocolVersion":2,"command":"run-use","requestId":"REQUEST_ID","operationId":"repo-inspection-01","launch":{"receiver":"gh_token","executable":"C:/Program Files/GitHub CLI/gh.exe","argv":["repo","view","northstar/agent-skills"],"cwd":"C:/work/northstar","env":{"GH_TOKEN":{"secret":"github_token"}}}}
```

For a second different command use another operationId and supply its full launch
under the same request. Preserve each submitted object until its result is known.

## SSH example: several commands in the same chat

Query `capabilities` and `credential-catalog`, choose the actual SSH key and the
host already trusted in App settings. Submit a normal protocol2 `request-use`
with `receiver:"ssh_identity"`, the discovered OpenSSH `executable`, typed
`"-i",{"file":"ssh_key"}` arguments and an empty `env`. Include the required
noninteractive flags `-T`, `-o`, `BatchMode=yes`; put the host after the key and
port options. Remote command arguments stay separate, for example `"uname","-s"`
rather than one `"uname -s"` argument. A complete illustrative launch is:

```json
{"receiver":"ssh_identity","executable":"/usr/bin/ssh","argv":["-T","-o","BatchMode=yes","-i",{"file":"ssh_key"},"-p","22","user@host.example","uname","-s"],"cwd":"/absolute/workdir","env":{}}
```

Use the discovered path and the actual approved host/account/port. The user may approve
“本聊天内不限时”; then check the returned decision above. Run `uname -s` and
`uptime` as two logical `run-use` operations with different operationIds under
the same requestId, checking each execution result. This example uses read-only
commands; the approved remote task determines actual arguments, not this list.

The request's approval-wait deadline, a timed grant's expiry, a command timeout
and an already-open SSH connection are separate. Revocation, session end,
credential disable/change or host-trust change blocks **new uses**. Revocation
neither terminates a running command/connection nor undoes remote changes.
For server connections, closing/reopening the App or ordinary server maintenance
does not end an otherwise valid grant, restore an ended grant or extend its
deadline. Legacy local-only hosts have their own restart rules. If the actual
root end callback was not delivered, do not claim switching or archiving a chat
ended permission; the user can revoke it in the App. Keep ordinary reads, other
credential types and older timed grants on their existing rules.

## Retry identity and uncertain results

The de-duplication key is this private session plus operationId. Repeating the
same requestId/operationId/launch returns the original facts with duplicate:true;
it never returns new material or launches again. Changing content under the same
ID gives operation_conflict, including when trying another request in this session.

After a lost response, copy the exact original run-use object and change only
command to operation-status. This queries the original operation even if no
executionId was received. A found operation is not permission to replay it.
Unknown results and material_claim_failed require checking that original task;
never automatically change the ID or use a direct shell to replay it. If an
explicit failure confirms the operation was not successful, fix and assess the
cause before deliberately submitting a new logical operation with a new ID.

A typed unavailable/capacity result with operationClaimed:false allows retrying
that same unclaimed operation while eligible. Denial, expiry, revocation,
credential rotation/disable/delete and session end block new uses. App exit is
not revocation in server mode.
Report that reason; never silently recreate the request. Scope expansion needs
new owner approval. Old protocol1 records retain one attempt: only when
continuing such a returned record, legacy run-use explicitly sends protocolVersion1
and requestId. Do not reinterpret an old record as a reusable grant.

## Typed injection

The three `program_*` receivers require protocol2, including when the caller
supplies a protocol version explicitly.

- program_stdin: a string credential via `"stdin":{"secret":"password"}` in
  the launch, with `"env":{}`. The executor writes its exact UTF-8 bytes then EOF,
  without adding a newline. Use only programs documented to read the credential
  from stdin; OpenSSH password authentication does **not** read from stdin.
- program_env: a string credential via an explicit variable such as
  `"env":{"SERVICE_TOKEN":{"secret":"token"}}`. The variable exists only in
  the approved target program, not the worker or parent shell.
- program_file: a string or file credential via `{"file":"credential"}` in
  argv or env. The program receives a private temporary file's path. The same
  managed cleanup and operation rules below apply.
- gh_token: string credential through `"env":{"GH_TOKEN":{"secret":"github_token"}}`.
  Only the CLI-created child's environment receives it; global and parent shell
  environments are unchanged. This supports the validated GitHub CLI receiver,
  not arbitrary programs or arbitrary secret variable names.
- ssh_identity: unencrypted private key, noninteractive OpenSSH to Linux/Unix.
  Put `"-i",{"file":"ssh_key"}` as separate argv entries, with `"env":{}`.
  CLI creates a protected copy, passes its full path, and adds strict-host,
  single-identity and empty-config controls. The owner first confirms a host
  snapshot in settings. Unknown/changed hosts and password/PTY interaction fail.
- aws_shared_credentials: one static default profile through
  `"env":{"AWS_SHARED_CREDENTIALS_FILE":{"file":"aws_file"}}`, with explicit
  region arguments. CLI provides a protected credentials copy and independent
  empty AWS config; existing profiles, SSO, credential processes, instance
  metadata and interactive prompts are not inherited.

The credential entry alias must match its typed reference. Literal text such as
`{{SSH_KEY_FILE}}` or `{{file:ssh_key}}` stays literal; neither the shell nor this
CLI substitutes strings. Secrets are not placed in argv. Each file operation
owns independent temporary material; one finishing never cleans another's files.

For example, a real helper that accepts its password on stdin can use:

```json
{"protocolVersion":2,"command":"request-use","purpose":"Sign in to the requested service","credentials":[{"alias":"password","credentialId":"CREDENTIAL_ID","version":1}],"launch":{"receiver":"program_stdin","executable":"/absolute/path/to/login-helper","argv":["--password-stdin","--url","https://service.example"],"cwd":"/absolute/workdir","env":{},"stdin":{"secret":"password"}}}
```

After approval, submit `run-use` with the request ID, a new operation ID and the
same complete launch. The helper path and flags above are illustrative: check
the real program's interface first. For an API client or browser automation
tool, the receiving process can read stdin/env/file and pass the value to its
documented header/fill API. Bind the intended URL/tab/field in that helper's
arguments and check the actual destination before filling. This does not imply
Chiyo provides a universal browser extension or supports every browser tool.
SSH password use needs an actual tested askpass-capable receiver; do not invent
`ssh_password` or claim `program_stdin` makes OpenSSH read a password.

For cleanup failure, call cleanup-use with that operation's executionId. This
retries cleanup only. Cleanup_busy retains files while a group may be active;
identity mismatch needs owner review. Let the registered cleanup mechanism handle
paths. Revocation blocks new operations, but does not terminate running programs
or recall injected data. After restart, uncertain facts stay unknown and cleanup
checks the original registered process groups before deleting anything.

For protocol2 operations, known direct credential byte echoes are masked before output is retained, with
bounded stream matching. This does not cover arbitrary encodings, screenshots,
external files or deliberate disclosure. The approved program receives the raw
credential; runtime injection is not a sandbox. Use task results, not deliberate
credential-printing commands, and report only the needed nonsecret facts.

## Focused password input

Local input is available only when the current connection advertises it. A
capability means the installed host offers that operation, not that every
browser is supported. In server mode keep the matching App running on the
Agent's current computer and connected to the same server. The server approves
the credential use; that local App verifies the target and performs the input.
The App's private filling host is discovered automatically. Do not configure a
server-side desktop, copy an owner's connection token, or specify another
device's host. If the App is absent, disconnected, or its filling capability is
unavailable, restore that local connection or choose a supported program receiver
or separately approved original-value access. For approved ordinary attachments, use
[Ordinary information files](information-files.md); they are readable documents,
not credentials for filling or process injection.

1. Query `capabilities`. Require protocol2, `credential-use-reuse.v1` and
   `credential-focused-fill.v1`. For safe target discovery also require
   `credential-focused-target.v1`. If discovery is unavailable, stop this
   workflow and explain it. Use a supported program receiver, or separately
   request original-value access if needed; never invent a receiver/placeholder.
   On Mac, `access_denied` may require the user to enable permission in App
   Settings → 凭据填写. Checking support does not request OS permission.
   Windows has no equivalent global Accessibility consent switch: distinguish
   an absent helper from an unavailable desktop or unsupported target.
2. Select one current **string** credential from `credential-catalog`. Click the
   intended visible password box, then call `focus-target` through a background
   execution tool that preserves the foreground. Require `targetState:ready`
   and keep its returned `application` object (absolute executable and SHA-256).
   This observation neither reserves focus nor verifies the website. A DOM-only
   focus in a hidden, remote or headless browser is insufficient.
3. Send one `request-use` with that credential's actual ID/version and `fill` as
   below. Copy `application` from discovery; use `targetHint` only to explain the
   intended site. Do not combine `fill` with `launch` or `readFields`. Keep its
   returned `requestId`, query `status`/bounded `wait`, and wait for
   `decision.credentialUse.approved` and current `state:available`. The grant
   fixes this credential version, application and the user-approved 2/4/8/24-hour deadline.
4. After approval, prepare an empty password box and click it again. Leave it
   masked and keep the intended application in the desktop foreground. A
   browser tool's DOM focus or visible panel alone may leave the approval app
   foreground. If the tool cannot activate the target window, ask the owner to
   return to it. Require `focus-target:ready` for the approved application before
   proceeding. Call `fill-use` in the
   background with a new logical `operationId`; supply no secret, command,
   window handle or file path. If the execution tool opens a terminal or cannot
   carry private stdin separately, report that transport limitation.
5. Query `fill-status` with the original requestId/operationId until a terminal
   `fillState`, using bounded polling. `checking` is in progress; `sent` means
   input events were sent, not proof of full receipt or login. Verify the login
   result without printing the password. Filling does not
   clear the box or submit the form. Continue the user's authorized website task
   only after the result is understood.

As with command examples, include the private `association` only in stdin. Replace
the application object with discovery's actual object and credential IDs/version
with the catalog result; the values below are illustrative, not an allowlist.

```json
{"protocolVersion":2,"command":"focus-target"}
{"protocolVersion":2,"command":"request-use","purpose":"Sign in to the project portal","credentials":[{"alias":"portal_password","credentialId":"CREDENTIAL_ID","version":1}],"fill":{"application":{"executable":"C:/Apps/WorkBrowser/WorkBrowser.exe","sha256":"8b31313131313131313131313131313131313131313131313131313131313131"},"targetHint":"https://portal.beichen.example/login"}}
{"protocolVersion":2,"command":"fill-use","requestId":"REQUEST_ID","operationId":"portal-fill-01"}
{"protocolVersion":2,"command":"fill-status","requestId":"REQUEST_ID","operationId":"portal-fill-01"}
```

For a lost response or `fill_unknown`, query the **same** `fill-status`. Repeating
the same fill-use ID returns the original fact, even after revocation; it sends no
new input. A new ID means a new attempt, not a polling method. `not_found` alone
does not prove a timed-out request cannot still arrive: stop and inspect rather
than automatically replacing or resending an uncertain operation.

`refused` records zero sent events; explain its reason (for example,
desktop_locked/unsupported_target/application_changed) before a deliberate new
attempt after the cause is resolved. `busy` does not queue input for a future
focus. `partial`, `unknown`, `audit_unavailable` or `fill_needs_attention` require
stopping and owner inspection. The owner checks/clears the target and explicitly
acknowledges it in the app before a deliberate new operation. The agent has no
acknowledgment command; another approved request or ID cannot bypass the hold.
The original outcome and deadline are preserved.

Separate successful logical fills may reuse the same grant before expiry, after
preparing and clicking the intended empty box each time. Revocation, rotation,
disable/delete, expiry, session end or restart block new uses; they never justify
automatic reapproval. File credentials and command grants cannot be used as fill
grants. Filling returns metadata only: no executionId/exitCode, command output or
cleanup-use path. The host checks the actual local password target, uses native
input without the ordinary clipboard, and refuses an unverifiable target.

The application identity is not a verified website origin. Password masking or
redaction by another browser tool is that tool's behavior, not an Agent Info
guarantee; explicit value extraction or a revealed-password screenshot can expose
secrets. This workflow limits accidental disclosure during normal use, not
deliberate readback or arbitrary third-party capture.

## Explicit original-value access

Use this fallback for a **string** credential only when direct delivery cannot
complete the task. Require `credential-reveal.v1`. Explain the actual limitation
and that the password will enter the current AI chat; submit a separate
`request-reveal`. An existing `request-use` approval cannot be used for this.

```json
{"protocolVersion":2,"command":"request-reveal","credentialId":"CREDENTIAL_ID","version":1,"purpose":"Sign in to the service requested by the user","fallbackReason":"The current browser has no usable input or program receiver; the password will enter this AI chat."}
```

Keep the returned request ID and wait for its approval with the normal `status`
or `wait` commands. Only when that reveal grant is available, call:

```json
{"protocolVersion":2,"command":"read-reveal","requestId":"REVEAL_REQUEST_ID","operationId":"password-read-01"}
```

The explicit response contains `secret`; use it only for the approved task and
do not repeat it in user-facing summaries. Each operation ID can return the
value once. A lost response must not trigger automatic new IDs or a new request.
Denial, expiry, revocation or changed credentials require stopping; normal use
cannot be silently escalated to this fallback. File credentials are excluded.
The user can separately view/copy their stored string credential in the App;
that Owner action does not require them to approve themselves.
