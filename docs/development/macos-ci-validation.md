# macOS headless validation

The optional [workflow](../../.github/workflows/macos-validation.yml) runs on a
GitHub-hosted macOS 15 ARM64 machine. It pins the same official Flutter 3.47.7
commit used on Windows, analyzes and tests all packages, compiles the native
macOS release, and tests an AOT-compiled Codex bundle in subprocesses. It does
not launch the desktop app, install hooks, access user Codex files, or use a
signing certificate. It does not upload build artifacts or create a release.

The Mac release step now uses `scripts/build-macos-release.py` for the pinned
SDK's [Flutter #191575](https://github.com/flutter/flutter/issues/191575) AOT
crash. It verifies the exact SDK revision and source checksum, temporarily
compiles the unused experimental windowing flag as false, and restores the SDK
source after the build. A lock prevents concurrent patching; unrelated SDK
edits are preserved and rejected. This is a recorded build workaround, not a
claim that stock 3.47.7 can compile this composition. Upgrading the SDK requires
reassessing/removing it against the upstream Dart fix. No hosted run was started
as part of this change.

Integration-branch pushes and PR updates do not trigger it. Before merging this
workflow into the default branch, an owner-approved run can be started by
pushing the exact reviewed integration commit to `ci/macos-validation` without
force. Once the workflow is on the default branch, manual dispatch is also
available. Each job has a 30-minute limit; a newer run for the same branch
cancels an older run. Do not repeatedly retry an unchanged failure.

This is a private repository. GitHub-hosted runners consume the owner's
included Actions allowance and may incur charges beyond it; get the owner's
agreement before the first run. Do not change budgets or add payment details.
See [GitHub Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions)
and [runner specifications](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).

Compilation and console tests provide macOS evidence only for the operations
they actually execute. They do not establish Keychain access through the
Flutter MethodChannel, tray/menu/notification behavior, file panel sandbox
permissions, real Codex lifecycle, signing/notarization, clean-machine install,
or Windows/macOS desktop backup exchange. Record these separately in the
ticket evidence and keep the corresponding acceptance criteria open.

Workflow status: prepared on Windows; not executed on macOS. The user asked to
finish Windows first and use their own Mac later. Do not start a hosted run
under the current authorization.
