import 'package:info_core/info_core.dart' as core;
import 'package:info_server/owner_library.dart';
import 'package:info_workspace/owner_workspace_template_packages.dart';
import 'package:info_workspace/owner_workspace_history.dart';
import 'package:info_workspace/owner_workspace_approvals.dart';
import 'package:info_workspace/owner_workspace_library_recycle.dart';
import 'package:info_workspace/owner_workspace_grant_history.dart';
import 'package:info_workspace/workspace_source.dart';
import 'package:test/test.dart';
import 'support/device_credential_fixture.dart';

void main() {
  test(
    'original history and batch recycle rules run without Flutter and survive encrypted online reopen',
    () async {
      final f = await DeviceCredentialFixture.create();
      addTearDown(f.dispose);
      late OnlineOwnerLibrary library;
      late OwnerWorkspaceHistory history;
      late OwnerWorkspaceLibraryRecycle recycle;
      late OwnerWorkspaceGrantHistory grants;
      void projections() {
        final o = f.runtime.service.owner;
        library = OnlineOwnerLibrary(
          o,
          OwnerWorkspaceTemplatePackages(owner: o, changed: () {}),
        );
        history = OwnerWorkspaceHistory(owner: o, information: library);
        recycle = OwnerWorkspaceLibraryRecycle(o, library.loadCatalog, () {});
        grants = OwnerWorkspaceGrantHistory(owner: o);
      }

      projections();
      final directory = await f.runtime.run(
        () => f.runtime.service.owner.createDirectory('Synthetic folder'),
      );
      final item = await f.runtime.run(
        () => f.runtime.service.owner.createInformation('Synthetic item', '', [
          const core.FieldInput('Body', '', 'SYNTHETIC_ORIGINAL'),
        ], directoryId: directory.id),
      );
      final credential = await f.runtime.run(
        () => f.runtime.service.owner.createStringCredential(
          name: 'Synthetic token',
          publicPurpose: '',
          secret: 'SYNTHETIC_NEVER_IN_HISTORY',
        ),
      );
      final session = await f.runtime.run(
        () => f.runtime.service.agent.openSession('Synthetic history chat'),
      );
      final field = core.FieldRef(item.id, item.fields.single.id);
      final requested = await f.runtime.run(
        () =>
            f.runtime.service.agent.request(session, 'Synthetic read', [field]),
      );
      final approvals = OwnerWorkspaceApprovals(owner: f.runtime.service.owner);
      final review = await f.runtime.run(() => approvals.read(requested.id));
      await f.runtime.run(
        () => approvals.change(
          WorkspaceApprovalChange(
            operationId: 'shared-approve',
            requestId: requested.id,
            reviewToken: review.reviewToken,
            action: WorkspaceApprovalAction.approve,
            selected: review.scopes.map((s) => s.id),
          ),
        ),
      );
      final proof = await f.runtime.run(
        () => f.runtime.service.agent.claim(session, requested.id),
      );
      expect(
        await f.runtime.run(
          () => f.runtime.service.agent.read(proof.token, field),
        ),
        'SYNTHETIC_ORIGINAL',
      );
      final audit = await f.runtime.run(
        () => grants.read('request:${requested.id}'),
      );
      expect(audit.summary.operationCount, 1);
      expect(audit.scopes.single.active, true);
      expect(
        audit.events.map((e) => e.description).join(),
        isNot(contains('SYNTHETIC_ORIGINAL')),
      );
      await f.runtime.run(
        () => f.runtime.service.owner.correctValue(field, 'SYNTHETIC_UPDATED'),
      );
      final ref = WorkspaceRecordRef(WorkspaceRecordKind.information, item.id);
      final revisions = await f.runtime.run(() => history.loadRevisions(ref));
      expect(revisions.single.version, 1);
      final preview = await f.runtime.run(
        () => history.previewRevision(ref, 1, expectedVersion: 2),
      );
      expect(
        preview.archive.detail.values.values,
        contains('SYNTHETIC_ORIGINAL'),
      );
      final restore = WorkspaceRecordChange(
        operationId: 'shared-revision',
        ref: ref,
        expectedVersion: 2,
        action: WorkspaceRecordAction.restoreRevision,
        revisionVersion: 1,
        expectedCatalogVersion: preview.catalogVersion,
      );
      expect(
        (await f.runtime.run(() => history.changeRecord(restore))).version,
        3,
      );
      final selection = WorkspaceLibrarySelection(
        directoryIds: [directory.id],
        records: [
          WorkspaceRecordRef(WorkspaceRecordKind.credential, credential.id),
        ],
      );
      final removal = await f.runtime.run(() => recycle.preview(selection));
      expect(removal.informationCount, 1);
      expect(removal.credentialCount, 1);
      final command = WorkspaceLibraryRecycleCommand(
        operationId: 'shared-recycle',
        reviewToken: removal.token,
        selection: selection,
      );
      final receipt = await f.runtime.run(() => recycle.change(command));
      expect(
        (await f.runtime.run(
          () => history.queryRecycled(),
        )).rows.single.batch!.id,
        receipt.batchId,
      );
      await f.reopen();
      projections();
      expect(
        (await f.runtime.run(
          () => recycle.receipt(command.operationId),
        ))!.matches(command),
        true,
      );
      expect(
        (await f.runtime.run(() => recycle.change(command))).batchId,
        receipt.batchId,
      );
      expect(
        (await f.runtime.run(
          () => history.lifecycleOperationReceipt(restore.operationId),
        ))!.result.version,
        3,
      );
      final restoredPreview = await f.runtime.run(
        () => recycle.restorePreview(
          receipt.batchId,
          WorkspaceLibraryRestoreOptions(),
        ),
      );
      final restoring = WorkspaceLibraryRecycleCommand(
        operationId: 'shared-batch-restore',
        reviewToken: restoredPreview.token,
        batchId: receipt.batchId,
      );
      await f.runtime.run(() => recycle.change(restoring));
      expect(
        f.runtime.service.owner.information.single.fields.single.value,
        'SYNTHETIC_ORIGINAL',
      );
      expect(
        f.runtime.service.owner.information.single.directoryId,
        directory.id,
      );
      expect(f.runtime.service.owner.credentials.single.enabled, false);
      await expectLater(
        f.runtime.run(() => f.runtime.service.agent.read(proof.token, field)),
        throwsA(isA<core.AccessFailure>()),
      );
      expect(
        (await f.runtime.run(() => history.queryRecycled())).rows,
        isEmpty,
      );
      await f.reopen();
      projections();
      expect(
        (await f.runtime.run(
          () => recycle.receipt(restoring.operationId),
        ))!.matches(restoring),
        true,
      );
      expect(
        f.runtime.service.owner.information.single.fields.single.value,
        'SYNTHETIC_ORIGINAL',
      );
    },
  );
}
