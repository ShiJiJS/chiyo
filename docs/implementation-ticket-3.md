# Issue #3: encrypted manual information

## Implemented boundary

The owner uses `InformationService.owner` to create an information item, inspect its fields and correct ordinary values. Item and field IDs are random and independent of paths. Values and public descriptions are separate. Existing grants retain the approved ID set and read current field values. Corrections increment item/field versions. Semantic replacement, version history and import review belong to later tickets.

`info_storage` is an owner-process dependency; `info_cli` does not depend on it. The repository uses Drift 2.35.2 and sqlite3 3.7.1 with the root `source: sqlcipher` native build hook. Runtime checks require SQLCipher before opening/creating the library, key the connection before schema reads, and use memory temporary storage. Schema version 2 adds versions/settings to the version 1 schema through a transaction. Sessions, requests and bearer credentials remain memory-only.

There is no plaintext or empty-library fallback on key/database errors. Existing DB files are never deleted/recreated by open. Native SQLCipher errors are converted to value-free `StorageFailure` codes. A library lock prevents multiple instances writing through independent repositories. A missing key for an existing database fails closed.

## Platform keys

Windows uses current-user DPAPI through `Crypt32.dll` FFI with `CRYPTPROTECT_UI_FORBIDDEN`, not machine-wide protection. A versioned encrypted envelope is stored beside the DB under the current user's LocalAppData `AgentInfoManage` directory; the directory inherits that user's profile permissions. Exclusive envelope creation prevents overwrite. The library lock spans creation and readback; a partial/invalid envelope fails closed and is not silently replaced. Plaintext native buffers are cleared before freeing. Dart managed values cannot promise complete memory erasure; this remains the accepted same-user application security boundary.

The preferred flutter_secure_storage candidate was evaluated but its Windows ATL prerequisite could not be installed (automatic approval rejected the installation). This implementation does not retry or bypass that installation. Direct system DPAPI avoids that dependency. The envelope is tied to the OS user and is not a portable backup; independent recovery-key backup is a later ticket.

macOS has a private Flutter method channel to Security.framework generic-password Keychain storage, using a stable service/account and refusing duplicate creation. Its queries request failure instead of authentication UI. No shell arguments carry keys. This bridge has **not** been built or run on macOS and cannot be claimed as accepted.

## Verification performed on Windows, 2026-10-16

- Core public-use-case tests: create, read after approval, ordinary correction, stable IDs/versions, hidden values in catalog, scope denial; all preexisting core tests pass.
- Actual SQLCipher database tests: encrypted save/reopen, old-token rejection after restart, missing/wrong-key preservation, migration from encrypted v1 fixture and persisted settings.
- Actual current-user DPAPI tests: create, reopen through a new adapter, duplicate refusal, corrupted-envelope rejection. Only isolated temporary test paths used.
- Real CLI process over an ephemeral loopback port reads reopened encrypted data after approval and is denied another field. No normal application storage, production key label, or existing desktop process used.
- Separate dependency fixture loads plain SQLite and proves the repository rejects it before creating a DB.
- Headless Dart AOT release bundle built with `dart build cli --target=tool/release_smoke.dart --output=build/release-smoke`; running its console executable reports `SQLCipher 4.19.0 community`. It verifies actual DPAPI, encrypted reopen, old-token invalidation, plaintext-marker scanning and encrypted schema migration. This is a console probe, **not** Flutter application startup.
- `flutter test` verifies manual creation and approval/revocation widgets; Windows `flutter build windows --release` succeeds. The resulting desktop executable was **not launched**.

Tests scan DB/auxiliary files for a unique synthetic marker; SQLCipher wrong-key diagnostic output contains no test values. Such scans support, but do not prove, cryptographic confidentiality. Native libraries/licenses still require distribution review in the packaging tickets.

## Outstanding acceptance

Keep Issue #3 open pending real Windows desktop startup/manual create-edit-restart verification, and macOS release build plus actual Keychain create/reopen/upgrade/migration/failure checks. No GUI interaction was performed in this ticket due to the user's restriction. Full backup recovery is not yet implemented; UI explicitly restricts use to fictional data. No claim is made that desktop startup, signing/upgrade identity, locked macOS Keychain, or cross-platform recovery has been validated.

## Repeatable checks

Run `dart test` from `packages/info_core`, `packages/info_storage`, and `packages/info_cli`; run `flutter test` from `apps/desktop`. For the missing-engine guard, run `dart pub get` and `dart run bin/probe.dart` inside `packages/info_storage/test/plain_engine`. Run the AOT smoke bundle on Windows only; it creates and removes a temporary fixture directory. Flutter builds do not authorize launching or manipulating the user's desktop.
