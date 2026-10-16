---
name: agent-info-access
description: Request user-approved personal information through Agent Info, submit user-designated source information for review, or complete a user-assigned metadata-only organization task; reuse this chat's approved fields and handle pending or denied access.
---

Use the Agent Info association supplied by this chat's latest SessionStart hook.
The association is a private capability reference. Never print its contents,
search for other associations, infer a path from a chat ID, or copy it to an
unrelated chat. Same-root children receive an explicitly delegated child-bound
reference through the private procedure below. Do not read Codex transcripts or authentication files. If the reference is
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

For user-requested imports, include `agentName` (for example, `Codex`) and a
short `purpose` explaining this batch. These are self-reported labels, not verified
identity. Give items meaningful names; avoid test/session labels as item titles.
Choose a sensible `suggestedDirectory` and optional `suggestedTags` for each item.
The owner sees these defaults in read-only preview; confirmation reuses matching
labels or creates the proposed labels atomically with the information. An owner
can edit exceptions before confirming. Use private facts only in field values.

For user-requested imports, first explain that the importing agent has already
seen the designated source data. Submit only that source, never scan unrelated
personal files. Use `import-submit` with `items`: each has `name`, `description`,
and `fields` containing `name`, `description`, `value`, and `kind` (`structured`
or `textNote`). Names, descriptions, and field descriptions become public catalog
metadata after confirmation: keep private facts in values. Optional
`suggestedDirectory`, `suggestedTags`, and `suggestedTemplate` are review hints;
directory/tag suggestions are applied only when the owner confirms the batch;
templates remain hints and never reuse an existing field identity.
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

For user-assigned organization, call `organize-tasks` under this chat's existing
association. It lists only tasks explicitly assigned to this authorization session.
If none is available, ask the user to create one in Library → Agent organize and
select this chat; do not search another chat's references or request content access.

1. Call `organize-metadata` with `taskId`. Use its scoped item titles/descriptions,
   item versions, directory tree and tag names. It contains no field values.
2. Prefer existing directory/tag IDs and shallow, reusable categories. Submit one
   `organize-submit` with `taskId` and `changes`. Each change has `itemId`, the
   supplied `baseVersion`, optional existing `directoryId` or a new root
   `directoryName`, and the desired complete `tagIds` / new `tagNames` lists.
   Do not include values, field edits or items outside the task. Limits: 200 items,
   100 tags per item, 200-character label names, 240000 bytes of change JSON.
3. Stop after `proposed`; the owner reviews and confirms the batch. Submission
   ends metadata access for that task. Query `organize-tasks` for its state rather
   than resubmitting. `confirmed` means applied; `rejected`, `cancelled`, `expired`,
   `conflicted` or `unauthorized` means stop and explain the result. Conflicts
   require the user to start a fresh task; no automatic recreation.

Task access lasts at most 30 minutes and ends with its session, cancellation or
submission. It cannot be recovered after restart or used to read values, approve
access requests, modify content or bypass a normal content-access request.

For requested changes, use `update-submit` with `update` containing `itemId`,
the current catalog `version` as `baseVersion`, and `changes`. Each operation is
explicit: `correct` takes `fieldId` and `value` and preserves meaning; `add`
takes a new `field`; `replace` takes `fieldId` and a new `field` for changed
meaning; `remove` takes `fieldId`. A field contains `name`, `description`,
`value`, and `kind`. Optional item `name` and `description` change public metadata.
Query the returned `proposalId` with `update-status`. Only the owner can preview
old values and differences or confirm changes. Obtain normal read authorization
when you need existing values. `conflicted` leaves current information intact;
explain the conflict before preparing a replacement. `rejected` stops the change.
Confirmed corrections keep existing grants; added or replaced fields need new
approval, and removed fields cease to be readable under old grants.

For a child of this root chat, use `delegate` with this parent's existing
`association` and the intended `childChatId`. Its `privateAssociation` response is
sensitive delivery: pass it directly in that child's private task/context, never
in ordinary status, a user-visible report, or an unrelated chat. The child then
uses that reference on stdin under its own CODEX_THREAD_ID. Delegation shares the
same session and approved fields; it grants no extra fields and does not renew
expiry. If the child ID becomes known only after spawning, send its delegated
reference directly afterward. SubagentStart provides guidance only; a parent ID
cannot retrieve a reference. A child missing its proof asks its parent to delegate.

Startup, clear, and fork create new unapproved associations. Resume and compact
retain only the reference already in context. Root SessionEnd permanently ends
that session and its children; subsequent reads fail and pending requests are
cancelled. Ordinary CLI exit, child completion, and switching chats do not end
the root. An ended session requires an explicitly requested reconnect and new
approval. Missing end callbacks rely on fixed expiry. Automatic end uses a
separate end-only credential; invoking it cannot retrieve private information.

Current integration is a development preview: use fictional data. Real Codex
child propagation and end delivery still need Windows acceptance; macOS
validation is deferred. Install hooks or change user configuration only after
explicit user authorization.
