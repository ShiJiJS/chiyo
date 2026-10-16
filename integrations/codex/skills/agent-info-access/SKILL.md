---
name: agent-info-access
description: Request user-approved personal information through Agent Info, or submit user-designated source information as an import proposal for desktop review; reuse this chat's approved fields and handle pending or denied access.
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
   Send the JSON through the execution tool's stdin/input channel. Never embed
   the private reference in a shell command or here-string: the parent shell's
   arguments and command logs would then contain it. If the available tool
   cannot provide stdin separately, stop and report that integration limitation.
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
5. Stop on `denied`, `expired`, `cancelled`, `revoked`, or `unauthorized`.
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

For user-requested imports, first explain that the importing agent has already
seen the designated source data. Submit only that source, never scan unrelated
personal files. Use `import-submit` with `items`: each has `name`, `description`,
and `fields` containing `name`, `description`, `value`, and `kind` (`structured`
or `textNote`). Names, descriptions, and field descriptions become public catalog
metadata after confirmation: keep private facts in values. Optional
`suggestedDirectory`, `suggestedTags`, and `suggestedTemplate` are review hints;
they do not create organization labels or reuse a template field's identity.
Keep batches within 20 items, 200 total fields, 50 fields per item, and 240000
UTF-8 bytes of item JSON. Each value is at most 64000 characters.

Save the returned `proposalId` and query it with `import-status` using this same
private association. Pending proposals are owner-only previews, absent from the
public catalog. Querying returns status, never private proposal contents or
credentials. Wait for desktop confirmation; do not retry submission merely
because confirmation is slow. `rejected` means stop this import. Confirmed items
still require a normal access request before reading: submission does not grant
read access, overwrite existing information, approve requests, or export the
library. New-item proposals cannot update existing items; reviewed updates use a
separate workflow. Restart ends the old session association, even when an owner
can still review its encrypted pending proposal.

Current integration is a development preview: use fictional data. Startup,
clear, and fork create new associations; resume and compact preserve the reference
already in this chat, with no ID-based recovery or renewal. Root/child propagation and
SessionEnd are separate implementation work; do not promise them yet. Do not
install hooks or change user configuration without explicit authorization.
