# Ordinary information files

Read this branch for a catalog field with `kind:file`, such as a resume or a
document the user wants read or uploaded. This grants access to the original
file contents. Token strings and private-key files used to authenticate belong
to [Credential use](credential-use.md), which supplies use rather than raw data.

Use the main Skill's private association and separate stdin transport for every
command. Examples below omit `association`; include the current private
reference in that same stdin JSON object, never in shell arguments.

## Request and fetch

1. Query `capabilities`; require protocol2 and `information-attachments.v1`.
   If absent, report that the installed app/CLI bundle cannot deliver files.
   An old client or a text `read` is not a substitute for this capability.
2. Discover actual item/field IDs in `catalog`. The public file entry describes
   the field; it contains no original filename, body or source path. Include
   this field with any text fields needed in one ordinary `request`. Keep that
   requestId and use the main Skill's bounded status/wait workflow. Credential
   use and classification approvals are separate capabilities.
3. After approval, inspect `claim` for the owner's final fields and expiry.
   Fetch only an approved file field using `file-fetch` with requestId, itemId,
   fieldId and a unique logical operationId. Use the actual deadline returned
   after user approval; fetches and process exits do not renew it.

```json
{"protocolVersion":2,"command":"file-fetch","requestId":"REQUEST_ID","itemId":"ITEM_ID","fieldId":"FILE_FIELD_ID","operationId":"resume-copy-01"}
{"protocolVersion":2,"command":"file-status","operationId":"resume-copy-01"}
{"protocolVersion":2,"command":"file-release","deliveryId":"DELIVERY_ID"}
```

An `ok` fetch returns `delivery` with deliveryId, fieldVersion,
attachmentVersion, fileName, mediaType, byteLength, path, state and expiresAt.
`ready` means the host prepared a copy; it does not mean a tool read or uploaded
it. Keep the deliveryId/operationId and actual returned path for this task.

## Use the returned file

Pass `delivery.path` directly to a same-machine document reader or a supported
browser upload/file-chooser API. Read ordinary document contents when needed for
the user's task. Use the user's requested destination for uploads; approval to
read a file does not authorize sending it to unrelated sites.

`fileName` describes the original file. The managed path uses a safe basename
such as `attachment.txt`, so it may differ from fileName. Use the returned path
without rebuilding it, moving the managed file, or guessing a temporary folder.
The media type/extension is a hint, not a parser or executable-safety guarantee.

A local path is usable only when the consuming tool can access this machine's
filesystem. If its remote/headless browser cannot, report that transport limit.
The app does not implement a remote upload bridge or inline Base64 delivery.
File input selection alone is not upload success: check the consuming tool or
website's actual result. After it has finished and closed its file input or
reader, call `file-release` using deliveryId, including on task cancellation.
Release concerns this managed copy, not files the user independently saved.
With a server connection, the CLI's device guardian manages this copy even when
the App is closed. The server records device reports; a server path is not a
path to a file on the consuming device.

## Reuse and uncertain operations

Within the same live grant, a genuinely new file use can fetch again with a new
operationId, without another approval. A new operation gets the field's current
attachment version; replacement of the same field does not change an older
delivered copy. Newly added/replaced-meaning fields need their own approval.

For a timeout, lost response or `delivery_unknown`, query `file-status` with the
**original operationId** (or its deliveryId when known). Status returns facts,
not a path. For a known ready copy still within the grant, retry the same fetch
arguments and operationId to retrieve that original copy. It must not create a
second copy or select a newer version. Changed fetch arguments with the same ID
are an operation conflict.

- `preparing`: query the same operation with bounded polling.
- `ready`: use the known copy, then release it.
- `cleanup_pending`: leave ownership with the app and report the cleanup issue;
  the app retains the registration and quota until it can safely reclaim it.
- `released`, `expired`, `failed` or `unknown`: report the recorded result;
  an old operation is not a fresh fetch. `not_found` after a transport timeout
  alone does not prove the first fetch cannot still arrive. Resolve the original
  operation before deciding whether a new logical use is needed.

Revocation, expiry, deleted fields or session end stop new fetches. With a server
connection, App exit/reopen and ordinary server maintenance keep the original
still-valid grant and deadline; they do not revive ended or expired permission.
Keep successful operation facts distinct from current permission; no automatic
reapproval, session recovery from public IDs, or retry under a new ID to hide an
uncertain result. Restored backup history is not an active grant or live copy.

## File proposals and errors

For user-supplied file ingestion or new versions, read
[source intake and file proposals](information-file-intake.md). Query current
upload/update capabilities and dynamic file examples, then give the supplied
path to the CLI for submission. This is a proposal, not admission or reading
permission. On an old service without that capability, defer the affected
proposal and explain what is missing. Preserve file fields as files.

For permission/integrity/capacity/service errors, retain the original public
operation IDs and explain the error. Let the owner check the current field,
quota or pending cleanup; do not delete history or change scope to force a
fetch. A revoked grant stops new access but cannot retract copies already read,
saved elsewhere or uploaded by a consuming tool.
