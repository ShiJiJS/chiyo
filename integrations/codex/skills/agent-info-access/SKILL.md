---
name: agent-info-access
description: Request user-approved personal information through Agent Info when a task needs saved connection details, personal fields, or other private information; reuse this chat's approved fields and handle pending or denied access.
---

Use the Agent Info association supplied by this chat's latest SessionStart hook.
The association is a private capability reference. Never print its contents,
search for other associations, infer a path from a chat ID, or copy it to another
chat. Do not read Codex transcripts or authentication files. If the reference is
missing or unavailable, stop private access and ask the user to reconnect the
integration. Only after that request, run the bundled `info-codex-hook --connect`
to obtain a fresh context reference for the current CODEX_THREAD_ID. This is a
new unapproved session, not a way to find an old grant. Do not retry it silently.
Public chat IDs are not credentials.

1. Call `info-codex` with one JSON object on stdin, including `association` and
   `command`. No command-line arguments. The executable is in the reviewed
   integration bundle; do not locate it by reading private session files.
2. `catalog` returns only public metadata. Choose all fields needed for this
   task and send one `request` with `purpose` and `fields` (objects containing
   `itemId` and `fieldId`). Save the returned public `requestId` in chat context.
   A request does not approve access. Continue independent work while pending.
3. Query that same request using `status` or `wait` (`timeoutMs` from 0 to
   300000). A wait timeout leaves the original request pending. Never resubmit
   merely because a command exited, timed out, or the app was unavailable.
4. When approved, `claim` returns final fields and expiry, without a token.
   Respect the user's actual selection. Use `read` with `requestId`, `itemId`,
   and `fieldId`. Each new process privately claims the existing grant before
   reading, so neither approval nor expiry is renewed by repeated use.
5. Stop on `rejected`, `expired`, `cancelled`, `revoked`, or `unauthorized`.
   Explain the result and ask only if a new need justifies a new request. Do not
   automatically retry approval. `service_unavailable` means resume querying
   the same request after the service returns; after restart old associations
   cannot recover grants. `association_unavailable` requires reconnecting.

Example input shape (replace placeholders without printing the reference):

```json
{"association":"<private reference from this chat>","command":"read","requestId":"<request>","itemId":"<item>","fieldId":"<field>"}
```

Approved fields keep fixed identities. New fields or information items require
another request. Reading does not grant import, approval, or history access.
Revocation stops future reads and cannot remove information already disclosed.

Current integration is a development preview: use fictional data. Startup,
clear, and fork create new associations; resume and compact preserve the reference
already in this chat, with no ID-based recovery or renewal. Root/child propagation and
SessionEnd are separate implementation work; do not promise them yet. Do not
install hooks or change user configuration without explicit authorization.
