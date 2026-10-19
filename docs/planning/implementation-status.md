# Implementation status

> 当前执行入口（2026-10-19）：[Windows后续计划](windows-next-iteration.md)继续跟踪三项新增调整。#36原型与#33凭据复用已完成，见[#33最终验收](../development/issue33-completion.md)；Windows源码已启用v2，接续#35→#37→#38→#30。当前已交付0.4.0+8包仍为v1，不表示用户已经更新。#23通知、#18新整包/干净环境及真实Codex联合门槛保持开放。下文旧阶段状态/自动继续同步安排仅作历史；无子Agent、服务器同步暂停，Mac及双向恢复延期。

> #35检查点（2026-10-19）：8b36ead已接入Flutter审批/历史/分页/人工确认，见[客户端检查点](../development/issue35-focused-fill-ui.md)。本轮315项零跳过（核心190/桌面125）、客户端16项连续三轮、两包分析/Release、49项原型检查及21张四主题渲染通过；[原生4092d96证据](../development/issue35-focused-fill-native.md)单列。正式bootstrap/打包、完整Windows GUI/SQLCipher/CLI及内置浏览器仍待；生产关闭、schema18/备份7不变，#35保持OPEN，用户包未更新。

2026-10-16：用户要求更新方案与GitHub tickets；[新计划](design-audit-2026-10-16/README.md)跟踪round05界面与凭据注入。任务按依赖推进，D0先补齐原型及协议。仅完成规划发布，未新增生产实现或实机验收；下方旧实现进度保留为基线事实。

Integration branch: `integration/local-information-access`.

Source of truth: [specification #1](https://github.com/ShiJiJS/agent-info-manage/issues/1), its 18 sub-issues, and their native GitHub blocking relationships. The initial documentation baseline is `9df5f7a`. The approved ticket bodies are also preserved in `published-tickets/`.

## Current preview: Agent-initiated organization and simpler records, 0.3.1

Current package source **`ad997289237b9666302251de3ba83d812f5f466e`**, version **0.3.1+6**;
implementation is `67d1c825672a34aae07142cf77c383df319da2fa`, followed by the
bundled-instruction correction. This supersedes the 0.3.0 desktop-created task
flow. Real native acceptance remains partial: the user confirmed two explicitly
selected imports in0.2.2 and approved a real0.3.1 CLI organization request for
those two items. Metadata read, automatic classification and post-completion denial
passed. A later fictional batch confirmed2items/5fields with category/tag reuse;
the final content grant contained both requested fields, and both read successfully
three times without a renewed scope/deadline. Partial approval/unapproved-field
denial, revocation/restart and native result-screen feedback remain pending.
See the dated Windows acceptance record.

- Agent CLI sends an organization request into the existing approval inbox.
  The user selects a fixed subset and approves metadata access plus automatic
  category/tag updates once. No desktop task creation or second confirmation.
  Metadata excludes fields/values; approval lasts at most30minutes, ends on
  completion/revocation/session end/expiry, and does not survive restart.
- The whole approved identity/version set is checked, even if only some items
  change. Atomic writes include labels/items/revisions/result; commit validation
  rejects a session ending or expiring while storage is awaited. Empty results
  complete without new item versions and remain accessible read-only.
  Old tasks without autoApply retain their original confirmation boundary.
- Detail editing sits by the title/description, classification is clickable,
  history/delete use concise icons, and the repeated field-count row is removed.
  Recycle records have read-only details and a right-aligned restore action.
  Import/change records split source, purpose, titles, time and status across
  levels, with right-aligned actions and no middle-dot/hyphen metadata joins.
- Standards:0 documented breaches/confirmed bugs;1 optional duplicate polling
  observation deliberately retained. Spec:3 initial P2 findings and1 targeted
  follow-up gap fixed and independently verified. Unscored UI review and
  targeted follow-ups found no remaining static mandatory issue. Actual
  fictional Flutter renders inspected, including long text,200%text,failures,
  conflicts and unchanged results. Native motion/focus/scroll remain unverified.
- Final clean-source pipeline passed **194 headless tests** (CLI18,core80,
  storage41,desktop55), four analyses, native Windows release, four AOT CLI
  builds, synthetic SQLCipher4.19.0/DPAPI diagnostics and **11 extracted
  SDK-free CLI/hook checks**. Final55 desktop tests also passed three consecutive
  root runs; the later source change only synchronizes bundled documentation.
- EXE:`build/windows-agent-led-0.3.1-final/AgentInfoManage/app/info_desktop.exe`.
- ZIP:`build/windows-agent-led-0.3.1-final/agent-info-manage-0.3.1+6-dev.ad997289237b-windows-x64.zip`.
- Size:46,089,027bytes; SHA-256:`a1ec120bc5ac2a9a54417447c1d9b8d24392ae4c0e585d338eb2ccd8cff6e7c4`.
- Manifest:`build/windows-agent-led-0.3.1-final/AgentInfoManage/manifest.json`.
- Build log:`.scratch/agent-led-organization-2026-10-16/package-final.log`.

Schema12 is unchanged from0.3.0;0.2.2/schema11 still needs additive migration.
Before upgrading real data, export a backup and save its recovery key separately
in the current app, fully quit the old tray process, then run the new package.
Build preparation did not launch/control the desktop, change real data/config or
run hosted macOS jobs. The later user-approved live CLI run changed only the two
requested items' categories/tags. The later user-confirmed synthetic batch added
two fictional items; only its two explicitly approved fields were read. No real
infos field values or user configuration were accessed during these runs.
See [Windows acceptance](../development/windows-acceptance.md)
and [review record](../development/review-agent-led-organization-2026-10-16.md).
Issue#1 is synchronized; PR#20 stays draft and all native acceptance gates remain
open. Earlier paragraphs below record historical snapshots.

## 2026-10-16

- Initialized the previously documentation-only checkout and empty remote repository. Published the documentation baseline on `main`.
- Read all 19 issue bodies, labels, states, and comments; verified 18 native sub-issues and 27 blocking edges. All implementation issues remain open.
- Implemented and merged #2 at `6a21789`. Core, real CLI subprocess, widget, and native Windows desktop/CLI tests passed; the Windows release build succeeded. The user confirmed the supplied screenshot shows the expected application. Its initial data is fictional and in memory. Evidence: [first authorization slice](../development/first-authorization-slice.md).
- Implemented #3, #4, and #6 in separate worktrees and merged them into the integration branch. Their code and headless checks are integrated; required manual/platform acceptance remains open as listed below.
- Installed and verified Flutter 3.47.7, Dart 3.13.5, Visual Studio Build Tools 2022 17.14.41, and Windows SDK 10.0.26100.0. Flutter doctor recognizes the Windows desktop toolchain. No real personal information has been migrated.

Local SDK: `C:/Users/Todoki/.local/share/flutter`. The installation did not change the user's global PATH. For a PowerShell development session, prepend its `bin` directory to that process's PATH. Android tooling is not installed or required for this release.

The optional Windows ATL component is absent; an attempt to add it was rejected by automatic approval. #3 uses a current-user DPAPI adapter through Dart FFI instead. Actual DPAPI and SQLCipher have passed isolated Windows tests and an AOT console probe. This did not retry the rejected installation or substitute a plaintext key file. macOS native build and Keychain acceptance have not run.

## Integrated batch: #3, #4, #6

| Ticket | Implemented and automatically checked | Still required |
| --- | --- | --- |
| #3 | Owner creation/correction, encrypted persistence and migration, current-user DPAPI, fail-closed key/engine checks, real CLI access to reopened data, Windows release build | Real Windows desktop create/edit/restart; macOS release and Keychain create/reopen/upgrade/failure checks |
| #4 | Fixed pending deadline, reject/cancel/expiry, bounded CLI wait and later status query, encrypted settings, approval widgets | User and CLI jointly demonstrate waiting, later approval, and querying the original request in the actual desktop |
| #6 | Private random chat association, real hook/CLI subprocess reuse, isolation from other chat identifiers, no extension/revival, compiled Windows adapter tests | Install/trust only with user coordination, actual Codex two-chat and compaction/resume tests, macOS checks |

Evidence: [encrypted information](../implementation-ticket-3.md), [pending workflow](../development/pending-request-workflow.md), [Codex adapter](../../integrations/codex/README.md). The resulting Windows application has not been launched by the agent. No Codex hooks were installed and no existing Codex configuration was changed.

The consolidated branch at `3b23fb4` passed all analysis, 30 headless tests (core 14, CLI 7, storage 5, widgets 4), and Windows release compilation. Follow-up review corrections and their final verification are recorded below when complete. Earlier per-ticket test counts in evidence documents describe those ticket snapshots, not the final consolidated suite.

Final verification at `7ab89fd`: all static analysis passed; **33 headless tests** passed (core 17, CLI 7, storage 5, widgets 4), plus **5 compiled Codex bundle subprocess tests**. Windows release compilation succeeded after the review fixes. The executable is `apps/desktop/build/windows/x64/runner/Release/info_desktop.exe`; keep its DLLs and data directory alongside it. The reviewable, uninstalled Codex bundle is `build/codex-preview/`.

### Standards

Three review observations were addressed: lifecycle state is typed with an owner-facing snapshot and exhaustive UI rendering; the obsolete fictional-only service comment is corrected; exact dependency pins are explicitly provisional development versions. ADR 0004's macOS, upgrade and independent-recovery acceptance gates remain open and unchanged. Follow-up review of the corrections found no new issue.

### Spec

One confirmed P2 defect was fixed: an expired grant could become readable after the system clock moved backwards. Status, claim and read now share terminal expiry evaluation. Three public-interface regressions cover the separate entry points; the reviewer verified the correction. The later #16 implementation retains the in-memory token-to-request association only to link denied reads to audit history; terminal expiry still denies access and cannot be reversed by clock rollback. This review covers its implemented batch, not later changes or outstanding manual/platform acceptance.

Review totals: Standards 3 observations addressed (production acceptance still pending); Spec 1 defect fixed. No remaining code finding was reported in the correction review.

The draft [PR #20](https://github.com/ShiJiJS/agent-info-manage/pull/20) remains an integration surface, not a completed release. All issues remain open. Later batches below update the implementation frontier; see [manual acceptance](../development/manual-acceptance.md) and the per-ticket evidence for user-coordinated checks.

## Next development batch: #5, #9, #10

The user explicitly requested continuing dependent implementation on 2026-10-16. These tickets now build on the merged and headlessly verified #3 information-repository contract: #5 adjusts the approved scope/duration, #9 adds organization and public catalog search, and #10 adds field templates. Each uses an isolated worktree and TDD at the already agreed public-service/CLI/widget boundaries. Their start does not change the outstanding acceptance status of #3/#4/#6 or close any GitHub dependency.

Implementation dependencies and acceptance gates are tracked separately so unavailable desktop/macOS checks do not force unrelated code work to stop. Only the implemented upstream contracts are reused; unsupported behavior is not assumed. Required real-platform checks remain a release gate.

At `3d3f393`, #5/#9/#10 are merged and their combined tree passed **51 headless tests** (core 25, CLI 9, storage 7, widgets 10), with all static analysis clean. Evidence: [adjusted approval](../development/adjusted-approval.md), [organized catalog](../development/organized-catalog.md), [field templates](../development/field-templates.md). Owner approval can replace/add fields and set a duration, resolve a directory to fixed field IDs, and show requested versus selected names. Saved metadata is searchable with bounded pagination; directory/tag labels remain owner-only. Template changes do not rewrite existing items or grants. Schema 4 combines organization and template migrations and preserves field types.

User confirmed the audit retention policy: default 90 days, selectable 30/90/180/365 days with confirmation before shortening/cleaning older records. Local specification and GitHub #1 were synchronized at `201a5b7`.

#8 background lifecycle, #11 reviewed import proposals, and #12 independent encrypted backup were started in separate worktrees. #11 followed the merged #9/#10 contracts. Desktop/manual and macOS acceptance remain open for every new feature; none of these test counts are real GUI evidence.

At `bab2e95`, #8 and #11 are also merged. Their combined branch passed **62 headless tests** (core 29, CLI 10, storage 8, widgets 15), with four package analyses clean. The preceding #8 branch independently compiled the native Windows runner with tray support; native tray/notification interactions were not launched. #11 stores only an independent random proposal-session binding, never the session secret, and its full-app widget test verifies confirmed imports immediately appear after switching back to the library. Evidence: [background runtime](../development/background-runtime.md), [reviewed import proposals](../development/import-proposals.md).

Next in progress: #12 encrypted backup, #13 versioned reviewed updates (after #5/#11), and #16 grant/access history (after #4/#5). User also confirmed that audit write failures pause content delivery rather than allowing unrecorded reads; local spec and GitHub #1 were synchronized at `4ce3048`.

At `2cd07cb`, #13 and #16 are merged. The combined tree passed **79 headless tests** (core 38, CLI 11, storage 11, widgets 19), with all analysis clean. [Reviewed updates](../development/reviewed-updates.md) add versioned diffs, explicit correction/add/meaning replacement/removal, current-version publication and owner-only prior snapshots. Removed field identities stay blocked in old grants. [Grant/access history](../implementation-ticket-16.md) records value-free facts and normalized IDs, snapshots original approved names, and implements the confirmed retention and failure policies. Audit writes complete before content delivery; failures retain pending facts for explicit retry. Async close flushes records before closing storage; a failed full quit remains visible for save/retry rather than discarding its queue.

#12 backup and #14 recycle/restore are currently in progress. The user approved the complete #17 backup scope (current data, organization, unexpired recycle/versions/grant/access history; no pending proposals, requests or live credentials), synchronized in the local spec and GitHub #1 at `0fb03d0`. #12 still declares its initial current-data scope; complete history recovery is not yet implemented. #7 real Codex child/root lifecycle and final distribution/platform acceptance remain open.

At `731a044`, #12 and #14 are also merged. Their combined tree passed **103 headless tests** (CLI 12, core 45, storage 21, widgets 25), with static analysis clean. [Independent encrypted backup](../development/independent-encrypted-backup.md) separates the recovery key from the OS-managed device key, validates the entire encrypted snapshot, and restores atomically only into an empty library. [Reviewed deletion and recycle](../implementation-ticket-14.md) adds explicit owner confirmation, 30-day recovery, stable identities with monotonic versions, and persistent value-free deletion facts. Restoring does not revive an invalidated grant. Terminal import proposals now retain only value-free receipts, including an upgrade migration; duplicate confirmation after deletion cannot recreate information. Deleting the last field retains the item's metadata, and the initial backup format preserves this valid state.

The user accepted the separate revoke-only Codex hook capability and the risk that a forged or delayed local end event could disconnect access early; it cannot obtain information. This is recorded in [ADR 0005](../adr/0005-end-only-codex-lifecycle.md), the local spec, and GitHub #1. #7 is implementing this boundary; #15 has started after #14 for owner-only version history, retention and restoration. #17 full-history backup remains downstream, and real Codex/macOS/distribution acceptance is still open.

An [opt-in macOS validation workflow](../development/macos-ci-validation.md) is prepared to compile and test on a hosted Mac without operating the user's desktop. Ordinary integration pushes do not trigger it. The user asked to defer hosted validation and finish Windows first, then use their own Mac; no hosted run was started and no macOS result is claimed.

At `785d44c`, #15 is merged. Its tree passed **114 headless tests** (CLI 13, core 50, storage 23, widgets 28), with all analysis clean. [Version history](../implementation-ticket-15.md) provides owner-only 30-day history, differences, optimistic conflict checks and restoration as a new current version. Deleted identities must first be restored explicitly through the recycle bin; history cannot bypass that rule. Schema 10 retains value-free purge facts so cleaning content remains terminal after clock rollback and reopening.

The Windows native release compiled successfully in a detached validation worktree at `d256a8a` (through #12/#14). The original checkout's release executable was locked by the existing application; it was left running and unchanged. Later #15/#7/#17 changes still require a combined rebuild. No new desktop window was launched. #17 has now started from #15 to extend the full supported backup scope and coordinate successful restore with runtime credential invalidation.

At `584047d`, #7 is merged. Its tree passed **126 headless tests** (CLI 16, core 58, storage 23, widgets 29) with all analysis clean, plus **9 freshly compiled Windows bundle subprocess tests** and an actual isolated Windows AOT SQLCipher/DPAPI probe. [Chat lifecycle evidence](../development/chat-lifecycle.md) covers proof-delegated children, the separate end-only capability/index, bounded SessionEnd, terminal session behavior, and rechecking every permission after waiting for durable audit. Ordinary revoke, expiry, field deletion and deletion/restoration during a pending read all block disclosure and record the denied result. The release probe's async read/close callers were corrected and its encrypted reopen, old-token invalidation, plaintext-marker scan and schema migration checks passed.

Two-axis code review is running against the pinned increment `df5c744...584047d`. #17 is developing separately, and required real Windows desktop/Codex evidence is still outstanding. No hooks were installed, trusted or copied into the user's Codex configuration.

The Windows native release at `584047d` also compiled successfully in the detached validation worktree, including #7/#15. [The pinned review](../development/review-batch-2026-10-16.md) reported Standards: 0 documented breaches and 1 judgment-only duplication observation; Spec: 2 P2 defects (retryable startup failure cleanup and reviewed updates of valid zero-field items). One isolated implementer is fixing all three with regression tests. These corrections and #17 still need integration and final combined verification.

#17 was merged at `2fc45f9`: full supported history/recycle scope, legacy format 1 support, archived-only recovered grant facts, runtime restore invalidation and export that preserves reads/revocation/end. Windows headless and release evidence is detailed in [complete backup](../development/complete-backup.md); real Windows/macOS exchange remains open. Review corrections merged through `89175f8` fix valid multi-field recycle exports, share row decoding, allow valid empty-field updates, and make startup failures retain unsaved facts while keeping error-window close/quit reachable after safe cleanup.

Final spec fact checks also identified missing item creation/modification timestamps and backup validation that rejects valid wall-clock rollback history. The same review implementer is adding preserved/unknown legacy time facts and correcting chronology assumptions. #18 has started from the implemented Windows contracts to prepare a reproducible unsigned ZIP, SDK-free CLI and final-path Codex materials; it does not install or trust user hooks or claim clean-machine/desktop acceptance. Its extracted-package tests caught and corrected a missing native-assets bundle in the SQLCipher diagnostic, which now runs from its relocated bin/lib layout. Final combined checks and the concrete user test package are still pending.

## Windows preview: final automatic verification

The Windows-first source at **`cffc549744fc467ba81f3e8ddb92e4ee6eb7d008`**
passed the complete package pipeline on 2026-10-16. All four package analyses
were clean and **159 headless tests** passed: CLI 17, core 71, storage 37,
Flutter widgets 34. The native Windows release and four independent AOT CLI
executables compiled successfully. After checksum verification and extraction
to a path containing Chinese characters and spaces, **11 CLI/hook subprocess
tests** passed with SDK/Git removed from the child PATH. The relocated console
diagnostic actually loaded SQLCipher 4.19.0 community and verified current-user
DPAPI, encrypted reopen, old-token invalidation, plaintext-marker absence and
schema migration. No desktop executable was launched or Codex configuration
installed/trusted. This verifies a development package on this Windows host,
not a clean-machine, real desktop or Codex acceptance result.

Local delivery (ignored build output, not committed binaries):

- ZIP: `build/windows-preview-cffc549/agent-info-manage-0.1.0+1-dev.cffc549744fc-windows-x64.zip`.
- SHA-256: `604d5144d335c606435a56d8cbadc1176bfa340833812fcd551cdb13ef1261d7`;
  the adjacent `.zip.sha256` file contains the same value.
- Already expanded application: `build/windows-preview-cffc549/AgentInfoManage/app/info_desktop.exe`;
  keep the complete adjacent DLL/data directories. Source identity and every
  payload file hash are in `AgentInfoManage/manifest.json`.
- Build log: `.scratch/windows-package-cffc549.log`. Rebuild instructions and
  runtime prerequisites: [Windows delivery](../development/windows-delivery.md).

#17's complete supported backup implementation is integrated, including
schema 11 item time facts, format 3 with 1/2 compatibility, grouped recycle,
clock rollback and runtime permission invalidation. #18's unsigned x64 preview
and SDK-free Codex material generator are ready for coordinated validation.
The final [two-axis review](../development/review-batch-2026-10-16.md) reports
all 5 spec defects and both judgment observations corrected, with no new
findings in the correction/delivery or final harness reviews. A failed first
package check exposed the developer-side Flutter wrapper's Git dependency;
`cffc549` fixes it without adding SDK requirements to consumers.

Next: the user fully exits any older demonstration, starts the application
from the delivery directory above using fictional information, and verifies
create/correct/restart before jointly exercising desktop approval with CLI.
Continue the [Windows acceptance table](../development/windows-acceptance.md)
for tray, notifications, native file dialogs, real Codex, clean environment
and upgrade. #17's actual two-platform exchange and #19's macOS delivery are
deferred to the user's own Mac. No hosted Mac job was run. All Issues remain
open and PR #20 remains draft until their required acceptance is complete.

## Redesigned Windows preview

The user's requested UI preview is packaged from
**`d23a11cd178c2baef5679a58fbbfea90a0aa45eb`**. The authorization inbox,
shared desktop theme and navigation, information details, proposals, history
and backup views are included. The build ran in an isolated worktree so an
older desktop process was left untouched.

All four analyses and **164 headless tests** passed (CLI 17, core 71,
storage 37, widgets 39). The Windows release compiled, and the packaged
SQLCipher/DPAPI diagnostic and **11 extracted CLI/hook subprocess tests**
passed. No desktop was launched or Codex configuration installed/trusted;
native visual, notification, tray and clean-machine acceptance remain open.

- Already expanded executable:
  `build/windows-ui-preview-d23a11c/AgentInfoManage/app/info_desktop.exe`.
  Keep its neighboring DLLs and `data/` directory.
- ZIP:
  `build/windows-ui-preview-d23a11c/agent-info-manage-0.1.0+1-dev.d23a11cd178c-windows-x64.zip`
  (31,487,819 bytes).
- SHA-256:
  `442e563c3fe74a675ed20004ad71872c51c9db97aa75a89a141be8dd0cd7a46b`.
  The adjacent checksum file and `AgentInfoManage/manifest.json` record the
  archive hash, exact source and per-file checksums.
- Build log: `.scratch/windows-ui-package-d23a11c.log`.

This supersedes the older preview for viewing the redesigned interface.
Fully exit an older tray instance before opening this executable. This is
an unsigned development preview; use fictional information for validation.
No new GitHub release or hosted macOS job was created.

## Desktop controls and typography preview

The user rejected the previous Material appearance and requested a new
Windows package directly, without screenshot collections or comparison
pages. Source **`f9c8876c480eb61257aa3c7741a10153629bd3a7`** keeps the
approved inbox layout but replaces the forms, selectors and dialog framing,
uses neutral navigation and fixed desktop control density, and bundles
Noto Sans SC Regular/Medium for consistent Chinese/Latin typography. Ordinary
text and controls use weight 400; headings use 500. Platform window titles
and default Flutter icons were also replaced; no authorization rule changed.

The Windows package pipeline passed all four analyses and **166 headless
tests** (CLI 17, core 71, storage 37, widgets 41), native release compilation,
the relocated SQLCipher/DPAPI diagnostic and **11 extracted CLI/hook tests**.
The relevant 29 UI/interaction checks additionally passed three consecutive
runs before packaging. Both shipped font hashes match the source assets, and
their OFL license is included in the application and delivery notices.

- Executable:
  `build/windows-desktop-ui-v2-f9c8876/AgentInfoManage/app/info_desktop.exe`.
- Archive:
  `build/windows-desktop-ui-v2-f9c8876/agent-info-manage-0.1.0+1-dev.f9c8876c480e-windows-x64.zip`.
- SHA-256:
  `f4657ca23b06095ec75dbc3332465a27d64508a40120f02d38429aa7b7ed153d`.
- Build log: `.scratch/desktop-ui-v2/package.log`.

Only two representative views were internally checked; no comparison page
was produced. An independent, unscored polish review was performed and its
control-size, alignment, weight and state-color feedback addressed. No native
desktop was opened and no user data or Codex configuration was changed. Real
Windows interaction and macOS acceptance remain outstanding; previous
preview directories remain intact.

## Product-wide desktop reshape · previous 0.2.0 preview

The user explicitly revoked the earlier A/inbox visual constraints. Those preview
sections above are historical delivery records, not accepted visual specifications.
The current product-wide implementation is **`cd25320d46da4e739d41edeb9bc56e7eb98f2d74`**,
version **0.2.0+2**. [Design proposal and limitations](../design/desktop-reshape-proposal.md)
record the real references, three internal directions, the user-provided LIMS
reference, representative approval/editor work, shared controls and all-page migration.

The user requested an actual package, with no screenshot collection and no automatic
desktop interaction. Real Flutter offscreen views were internally inspected for
ordinary/long information, 1280×800, 200% text, empty and critical error states,
including revision/delete/recovery dialogs. Three fresh Pro reviewers scored
7 → 8 → 8/10; the three-round limit was reached. The identified corrections and
improvements were verified, with remaining local typography/density refinement and
native interaction explicitly unaccepted. This does not claim user visual approval.

All **44 widget/interaction tests passed three consecutive runs**. Packaging again
passed all four analyses and **169 headless tests** (CLI 17, core 71, storage 37,
widgets 44), Windows release compilation, relocated synthetic SQLCipher/DPAPI
validation and **11 extracted SDK-free CLI/hook checks**. Both shipped AppSans font
weights and hashes match the source, and the OFL notice is included. No native
application was launched, no actual user library was opened, no hook/configuration
was installed, no GitHub release was published, and no hosted macOS job was run.

- Executable: `build/windows-product-reshape-0.2.0/AgentInfoManage/app/info_desktop.exe`.
- ZIP: `build/windows-product-reshape-0.2.0/agent-info-manage-0.2.0+2-dev.cd25320d46da-windows-x64.zip`.
- Archive size: 46,029,710 bytes.
- SHA-256: `8b4705da90fe95c290b3042e90f4bac75e07a0bf8fd7770e5bbe7f6893ab4412`.
- Manifest: `build/windows-product-reshape-0.2.0/AgentInfoManage/manifest.json`.
- Build log: `.scratch/product-reshape-2026-10-16/package.log`.

Fully exit the older tray instance before opening the new executable, and keep all
adjacent DLL/data files; the ZIP is the complete portable preview. Source, data path,
authorization rules and CLI/hook interfaces remain compatible. Actual Windows window,
focus/scroll/animation feel, native file dialogs, tray/notification and real Codex
acceptance remain for the user. macOS still awaits the user's own Mac. All required
platform acceptance issues remain open; PR #20 remains draft.

## Desktop feedback corrections · previous 0.2.1 preview

The user positively received the LIMS direction and requested focused corrections.
Source **`a5a56e2093d8c34e18899f62ab844ac64ccd7924`**, version **0.2.1+3**:
instant single-item menu selection; shared primary-page header origin; a Settings
workspace containing notifications, blank-field entry templates, backup/recovery and
full quit; explicit notification permission/test results; removal of static development
warnings; and a custom Windows caption retaining native resize borders and the
existing close-to-background/fully-quit behavior. The startup-to-ready handover keeps
native maximize-state updates connected. macOS keeps its system window controls.

Real Flutter headless renders were inspected across all five main pages, templates,
backup, editing, notification success/failure, a 24-field long request, 1280×800 and
200% text. One independent, unscored existing-UI review found a notification-state
conflict; the corrected error appearance and guidance were re-rendered and verified.
Evidence: `.scratch/desktop-fixes-2026-10-16/screens/` and `review.md`.

All **49 desktop tests passed three consecutive runs**. Final packaging passed four
analyses, **174 headless tests** (CLI 17, core 71, storage 37, desktop 49), Windows
release compilation, relocated synthetic SQLCipher/DPAPI checks and **11 extracted
SDK-free CLI/hook tests**. A first packaging run hit a preexisting backup-interruption
fixture startup exit 255; its isolated retry and the complete packaging rerun passed.
Those logs are retained in the same task directory. Shipped font hashes match the
source and the exe's FileVersion/ProductVersion are `0.2.1+3`.

- Executable: `build/windows-desktop-fixes-0.2.1/AgentInfoManage/app/info_desktop.exe`.
- ZIP: `build/windows-desktop-fixes-0.2.1/agent-info-manage-0.2.1+3-dev.a5a56e2093d8-windows-x64.zip`.
- Archive size: 46,035,946 bytes.
- SHA-256: `f6801059e75012c41d6774cb2dfe8ab8ef09512f03bf4b4dad1811754830b77f`.
- Manifest: `build/windows-desktop-fixes-0.2.1/AgentInfoManage/manifest.json`.
- Build log: `.scratch/desktop-fixes-2026-10-16/package.log`.

Fully exit the older tray instance before opening the new exe. In this version full
quit lives in **Settings → Notifications and app → Full quit**. Keep the adjacent
DLL/data files or unpack the whole ZIP. No desktop was launched, real user data or
Codex configuration accessed/changed, release published or hosted macOS job run.
Native caption dragging/resizing/maximize/close feel, real notification display,
clean-machine and macOS acceptance remain open. Data and authorization/CLI/hook
boundaries are unchanged; PR #20 stays draft and platform acceptance tickets stay open.

## Sidebar branding trim · current 0.2.2 preview

At the user's request, removed the duplicate small title from the Windows window
bar, retained the sidebar's large icon/name, raised that group by 18px, and removed
the Workspace caption. Main-page origins and window commands retain their behavior.
Source **`f973cc8b99d355d28dbca3de07fec8ba2fc00a88`**, version **0.2.2+4**.

Actual Flutter approval/settings renders were inspected in
`.scratch/desktop-brand-trim-2026-10-16/screens/`. Related 10 existing interaction
checks and analysis passed. Final packaging again passed all four analyses and
**174 headless tests** (CLI 17, core 71, storage 37, desktop 49), Windows release
compilation, relocated synthetic SQLCipher/DPAPI validation and **11 extracted
SDK-free CLI/hook tests**. No native application was launched.

- Executable: `build/windows-brand-trim-0.2.2/AgentInfoManage/app/info_desktop.exe`.
- ZIP: `build/windows-brand-trim-0.2.2/agent-info-manage-0.2.2+4-dev.f973cc8b99d3-windows-x64.zip`.
- Archive size: 46,035,427 bytes.
- SHA-256: `76a63117296e16a09c2e0b1704faddcd5aa8790959990d6fa8971bc897dd1ae8`.
- Manifest: `build/windows-brand-trim-0.2.2/AgentInfoManage/manifest.json`.
- Build log: `.scratch/desktop-brand-trim-2026-10-16/package.log`.

The user authorized pushing the accumulated local UI changes to the existing
integration branch. PR #20 remains draft; platform acceptance is still open.
Fully exit the older tray instance before using this package, and keep all adjacent
DLL/data files. This remains an unsigned Windows x64 development preview.

## Completion rules

The user has asked that further development not manipulate their visible desktop. Run headless tests and compile builds; leave native window interaction and user-visible Codex configuration checks for coordinated user validation. Do not launch the desktop application or native GUI tests without renewed agreement.

Implementation, automated verification, and real platform acceptance are recorded separately. A ticket is not complete merely because its tests pass if it also requires desktop, CLI, Codex, encryption, or cross-platform evidence. Unavailable platform checks remain outstanding. Do not close the parent specification until all required behavior and acceptance checks are complete.

Use the native issue dependencies when selecting work; do not treat ticket numbering as a sequential checklist. The initial frontier contains only #2. After #2 is accepted, #3 (encrypted manual information), #4 (pending request workflow), and #6 (Codex session association) become eligible.
