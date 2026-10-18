# Windows credential use

Use the same private association and stdin-only `info-codex` transport as the
main Skill. This branch permits one approved program launch, not secret reading.
The desktop app must remain available to accept and observe the launch. Its
resident CLI host owns the worker; separate adapter calls share authorized
status and bounded memory output. Never run the placeholder command directly
in the agent's own shell or set global environment variables.

## Request, wait, run and observe

1. Call `credential-catalog` (`limit`1–100, optional returned `cursor`). It exposes
   only discoverable metadata, forms, current versions and suggested bindings.
   Select the credential relevant to this task, not every discovered credential.
2. Submit one `request-use` with `purpose`, one `credentials` entry containing
   `alias`, `credentialId`, `version`, and `launch` containing `receiver`, an
   absolute `executable`, exact `argv`, existing absolute `cwd`, and typed `env`.
   Optional `readFields` contains ordinary `itemId`/`fieldId` pairs. These grants
   are independent: credential approval does not imply field access, or vice versa.
   Keep the returned public `requestId` and fixed plan hash.
3. Use `status` or bounded `wait` with that same `requestId`; `timeoutMs` is
   0–300000. Continue unrelated work while pending. Timeout or adapter exit does
   not justify another request. Inspect `decision.credentialUse.approved` and
   its current `state`, not just the overall approved/partially_approved label.
   Only `available` permits a new launch. Ordinary fields, if approved, use the
   main Skill's `claim`/`read` workflow on this request ID.
4. Call `run-use` with only `requestId` plus the private association. The service
   rechecks current session, expiry, credential version and fixed executable/plan.
   Do not send replacement arguments, environment values or working directory.
   `accepted` means an attempt was reserved; it does not mean the program started
   or succeeded. Keep `executionId`. Preparation/start failure also consumes
   the single attempt; a different plan needs a newly reviewed request.
5. Query `execution-status` with `executionId`. Distinguish `preparing`, `running`,
   `exited`, `prepare_failed`, `start_failed` and `unknown`. Check actual `exitCode`
   only when recorded. Stop polling when a terminal fact is available; while
   running use a bounded check interval rather than a tight loop.
6. When `outputAvailable` is true and task output is needed, call
   `execution-output` with that `executionId`, `cursor`0 and `limit`1–16. Decode
   each chunk's `dataBase64` as bytes for its `stream`; continue with `nextCursor`
   while `hasMore`. `outputComplete` and `outputTruncated` are independent facts.
   Output is at most the first4MiB per task, only in the host's memory, globally
   up to16 tasks; finished caches may be evicted, expire after30minutes, and
   disappear when the host exits. Unavailable output is not proof of failure and
   must not trigger another launch.

## Typed delivery

Only these receivers are supported in this Windows version:

- `gh_token`: a string Token in `GH_TOKEN`. Use
  `"env":{"GH_TOKEN":{"secret":"github_token"}}`; the credential entry's alias
  is `github_token`. The actual value is set only on the approved child process.
  This is not a way to run arbitrary executables with arbitrary secret variables.
- `ssh_identity`: an unencrypted SSH private-key file, noninteractive OpenSSH to
  a Linux/Unix host. Put `"-i",{"file":"ssh_key"}` as separate argv entries and
  `"env":{}`; the credential alias is `ssh_key`. The CLI creates a protected copy
  and supplies its full path. The owner must first confirm a known-host snapshot
  in settings. Fixed strict-host, single-identity and empty configuration controls
  are added to the approved effective plan. Unknown/changed hosts, password/PTY
  interaction and Windows remote shells are outside this receiver.
- `aws_shared_credentials`: a static shared-credentials file with one `default`
  profile. Use `"env":{"AWS_SHARED_CREDENTIALS_FILE":{"file":"aws_file"}}`,
  alias `aws_file`, and explicit region arguments. The CLI supplies protected
  credentials and an independent empty AWS config. Existing user profiles, SSO,
  credential processes, instance metadata and interactive prompts are excluded.

`{"file":"alias"}` and `{"secret":"alias"}` are structured values. A literal
string such as `{{SSH_KEY_FILE}}` or `{{file:ssh_key}}` remains literal; neither
the OS nor the agent shell expands it. Strings are not injected into argv.
File paths and private material are prepared by the CLI, never requested as
ordinary readable fields. Generic cookie files or other receivers are not
supported merely because they can be stored as a credential.

Example `launch` for a file credential (the normal association/credential entry
and user-specific IDs belong in the enclosing request):

```json
{"receiver":"ssh_identity","executable":"C:/Windows/System32/OpenSSH/ssh.exe","argv":["-T","-o","BatchMode=yes","-i",{"file":"ssh_key"},"-p","2222","developer@test.beichen.example","/usr/bin/true"],"cwd":"C:/work/project","env":{}}
```

## Uncertain and ended operations

If the launch response is lost or reports `material_claim_failed`, query
`status` for the original request, obtain its existing `executionId`, then
query that execution. Never switch to direct shell execution or automatically
reapply/relaunch an uncertain operation. `unknown` requires checking the
original task and residual resources, not interpreting an absent exit code.

For file cleanup failures use `cleanup-use` with the original `executionId`;
this retries cleanup only. `cleanup_busy` preserves files while a process group
is active or its end is inconclusive. Identity mismatch requires owner review.
Never delete a path inferred from an execution ID or scan for secret files.

Stop on denial, unavailable scope, expiry, revocation, version/use-condition
changes or ended association. Report the specific result; a new need or changed
plan needs a new user-reviewed request. A typed unavailable host/capacity result
with `attemptConsumed:false` leaves the original attempt unspent; resume only
that approved request while still eligible, never create replacement requests
silently. Revocation/session end blocks later launches, not an already running
program. An existing program can outlive the app; reopening records uncertain
results and checks registered process groups before cleaning files.

This is runtime delivery, not a sandbox that hides secrets from the approved
program or other same-user processes. Programs can disclose secrets in output;
avoid commands that intentionally print credentials and report only task facts.
