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

Totals: Standards 0 documented breaches and 1 judgment-only duplication
observation; Spec 2 P2 defects. A single isolated implementer is addressing all
three findings; correction verification is pending.
