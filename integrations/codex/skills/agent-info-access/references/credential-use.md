# Windows credential use

Use the same private association and stdin-only `info-codex` transport as the
main Skill. The CLI launches each operation and injects its credential into that
child process. Your own shell does not receive the secret or a secret-file path.

## Request once, operate within the fixed deadline

1. Query `capabilities`. New `request-use`, `run-use` and `operation-status`
   default to protocol2 and require `credential-use-reuse.v1`. An unsupported
   service requires a matching whole app/CLI/worker bundle; never silently
   downgrade or create a replacement single-use request.
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
   current `state` and fixed `expiresAt`; only `available` admits a new operation.
   Credential use defaults to15minutes (owner may choose30); ordinary fields
   independently default to8hours and use the main Skill's claim/read workflow.
4. For each logical command, choose a new unique `operationId` and send
   `run-use` with the same `requestId` and that command's complete `launch`.
   The alias, credential version and receiver remain in the approved scope.
   Legal new commands within that scope need no new approval and never extend
   the deadline. CLI validates the real receiver and freezes each operation's
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
credential rotation/disable/delete, session end and app restart block new uses.
Report that reason; never silently recreate the request. Scope expansion needs
new owner approval. Old protocol1 records retain one attempt: only when
continuing such a returned record, legacy run-use explicitly sends protocolVersion1
and requestId. Do not reinterpret an old record as a reusable grant.

## Typed injection

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

For cleanup failure, call cleanup-use with that operation's executionId. This
retries cleanup only. Cleanup_busy retains files while a group may be active;
identity mismatch needs owner review. Let the registered cleanup mechanism handle
paths. Revocation blocks new operations, but does not terminate running programs
or recall injected data. After restart, uncertain facts stay unknown and cleanup
checks the original registered process groups before deleting anything.

Known direct credential byte echoes are masked before output is retained, with
bounded stream matching. This does not cover arbitrary encodings, screenshots,
external files or deliberate disclosure. The approved program receives the raw
credential; runtime injection is not a sandbox. Use task results, not deliberate
credential-printing commands, and report only the needed nonsecret facts.

Ordinary attachments and local focused password filling are not enabled by this
receiver protocol; do not invent commands for those separately planned features.
