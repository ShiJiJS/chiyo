---
name: agent-info-access
description: Request approved information or ordinary file delivery, Windows/Mac credential command use or supported local password filling through Agent Info; submit designated source information for review and perform approved classification changes using this chat's private association.
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

For user-requested app shutdown or an authorized test-version switch, use the
reviewed Windows delivery's `cli/info.exe app status`, then `app quit`.
Default discovery targets that delivery only; another installation requires its
verified PID with `--pid`. `exited` confirms process exit; `shutdown_failed`
keeps unsaved records open for repair, and `timeout` is unknown. Query before
retrying; never force-kill. Quitting ends all chats' current grants. This native
lifetime entry does not read information or approve anything.

For Token, SSH private-key, AWS credential-file use or local password filling, read
[Credential use](references/credential-use.md) before requesting or running it.
Choose its command or focused-input branch. Both request fixed-term use and
identify each operation separately; focused filling supplies no command or secret
value. For a `kind:file` information field, read
[Ordinary information files](references/information-files.md) before fetching or
passing its copy to a document/browser tool. Ordinary text access below reads
approved structured/text-note values; file access uses its separate fetch path.

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
   Respect the user's actual selection. For text fields use `read` with
   `requestId`, `itemId`, and `fieldId`; for a file use the linked file workflow.
   Each new text-read process privately claims the existing grant before
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

For user-requested organization, use this chat's existing private association:

1. Use the public catalog to select the information IDs relevant to the user's
   request. Send one `organize-request` with `purpose`, `itemIds` and `agentName`.
   Keep its returned `taskId`. The desktop shows this request in Access approvals;
   never ask the user to create a task, select a chat or copy a task prompt.
2. Continue independent work while `pending`. Use `organize-wait` with the same
   `taskId` (`timeoutMs`0–300000), or `organize-status`. A timeout leaves that
   request pending: never automatically resubmit it. Approval permits metadata
   access AND automatic category/tag changes only for the user's final selection.
3. When `active`, call `organize-metadata`. Use only its final item IDs/versions,
   titles, public descriptions and category/tag names. It contains no field values.
   Prefer existing category/tag IDs and shallow reusable categories.
4. Call `organize-submit` once with `taskId` and `changes`. Each change contains
   `itemId`, supplied `baseVersion`, existing `directoryId` or new root
   `directoryName`, and the complete desired `tagIds`/new `tagNames` lists.
   No value/field/content edits or out-of-scope items. Limits:200items,100tags/item,
   200-character names,240000UTF-8bytes of changes. `confirmed` means the whole
   batch was applied; no second user confirmation is needed. If no changes are
   needed, submit an empty `changes` list to finish without rewriting items. Report
   the result.
5. On an uncertain response, query the same status before retrying. Stop on
   `confirmed`, `rejected`, `cancelled`, `expired`, `conflicted` or `unauthorized`;
   never silently recreate an expired/conflicting request. If still `active` after
   a storage failure, retry the same plan only within its original deadline.

Organization access lasts at most30minutes after approval and ends on completion, revocation,
expiry, session end or restart. This does not grant values, content edits, approval
powers or a larger normal content grant. Legacy `proposed` results still require
owner review; do not treat a legacy metadata grant as automatic-write permission.

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
