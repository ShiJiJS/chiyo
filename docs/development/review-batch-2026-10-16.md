# Increment review: df5c744 to 584047d

Two independent reviewers inspected the pinned increment
`git diff df5c744...584047d`, using the specification, published ticket bodies,
AGENTS/domain instructions, GLOSSARY and ADRs 0001–0005. #17 was developing in
another worktree and is outside this review. Remaining real platform checks
are tracked acceptance gates, not evidence of completed validation.

## Standards

No confirmed documented-standard breach was found. Core remains independent
of Flutter, owner operations are separate from CLI capabilities, fixed field
identities and separate revoke-only credentials follow the ADRs, and platform
acceptance remains explicitly open.

One judgment-only observation: manual value correction in
`packages/info_core/lib/info_core.dart` and reviewed correction in
`packages/info_core/lib/update_access.dart` duplicate the identity-preserving
construction of a field with a new value and incremented version. A focused
`InformationField.correctValue` operation can share this rule while semantic
replacement continues to create a new identity.

## Spec

Two P2 defects were confirmed through public-interface probes:

1. Startup failure handling in `apps/desktop/lib/main.dart` awaits a core close
   that can now throw on audit persistence failure, skipping the error UI and
   leaving cleanup incomplete. Partially started server/runtime resources
   must be managed; failed audit facts must remain available for retry. Spec
   section 9 requires failed recording to pause disclosure and explain the
   failure without silently discarding records.
2. `packages/info_core/lib/update_access.dart` rejects all empty-field results.
   This prevents a reviewed removal of the final field and metadata updates
   on a valid empty-field item, although #14 deliberately preserves the item's
   identity and public metadata after deleting its final field. #13's field
   removal must still use recycle and invalidate the old field grant.

No additional scope expansion was reported. The durable-read permission
rechecks were verified in this review. The probes used fictional in-memory
information and did not interact with the desktop.

Initial totals: Standards 0 documented breaches and 1 judgment-only duplication
observation; Spec 2 P2 defects. These corrections were merged at `9b8f827`.
Targeted review confirmed the empty-field and correction-rule fixes. Startup
review then reproduced a remaining native callback problem: after successful
failure cleanup, close/quit events still reached the stopped runtime and were
ignored. The same implementer corrected this at `89175f8`; fully flushed and
closed resources permit exit, while failed recording still retains ownership
and retry. Thirteen related headless tests passed; final combined review is
still required.

## Complete backup increment: 584047d to 2fc45f9

Standards found no documented breach and one judgment-only duplication
observation: startup loading and pre-commit recovery preparation decoded the
same current-item rows separately. They now share a pure decoder.

Spec found one P1 defect, reproduced in a real temporary SQLCipher library:
removing multiple fields in one reviewed change creates a valid multi-field
partial recycle entry, but backup validation required exactly one field and
rejected the entire export. The fix accepts nonempty partial entries with all
existing identity/type/size checks, and round-trip tests cover multiple removals,
semantic replacements and history rollback. Both corrections were merged at
`2e18e5c`.

## Full specification fact checks

Two further P2 gaps were confirmed:

- Spec section 4 explicitly requires information-item creation and modification
  times. Neither the model, encrypted rows, historical snapshots nor backups
  preserved them. They cannot reliably be inferred from proposal or revision
  dates; older unknown facts must remain unknown.
- Backup history validation assumed wall-clock timestamps could not move
  backwards. A real SQLCipher probe approved at 12:00, rolled back to 11:00 and
  found export rejected. Revoking at 11:00 made export fail even after 13:00,
  because the stored terminal time preceded approval. Format/type/identity and
  authorization-duration checks must remain, but unsupported chronology
  assumptions cannot reject valid core states.

The same isolated implementer is addressing these gaps. No additional
implementer was used for review corrections. Combined totals so far: Standards
0 documented breaches, 2 judgment observations; Spec 5 confirmed defects
(1 P1, 4 P2). The outstanding time-fact and clock-rollback corrections and final
delivery review are pending.
