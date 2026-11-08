import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_server/mounted_database_key_store.dart';
import 'package:info_server/server_configuration.dart';
import 'package:info_workspace/credential_file_selection.dart';
import 'package:info_workspace/owner_workspace_credentials.dart';
import 'package:info_workspace/workspace_source.dart';
import 'package:test/test.dart';

void main() {
  test(
    'shared owner credential rules run without Flutter in the online runtime and preserve exact material, links and generations',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'shared-owner-credentials-',
      );
      await initializeServerSecrets('${root.path}/secrets');
      final keys = MountedDatabaseKeyStore('${root.path}/secrets/database.key');
      late EncryptedInformationRepository repo;
      late OnlineInformationRuntime runtime;
      late OwnerWorkspaceCredentials source;
      Future<void> open() async {
        repo = await EncryptedInformationRepository.open(
          '${root.path}/data',
          keys,
        );
        runtime = await OnlineInformationRuntime.open(repository: repo);
        source = OwnerWorkspaceCredentials(runtime.service.owner);
      }

      Future<void> close() async {
        source.dispose();
        await runtime.close();
        await repo.close();
      }

      await open();
      addTearDown(() async {
        await close();
        await root.delete(recursive: true);
      });
      const secret = 'SYNTHETIC_SHARED_SERVER_TOKEN';
      final information = await runtime.run(
        () => runtime.service.owner.createInformation(
          'Synthetic linked service',
          'Synthetic service',
          [const FieldInput('Address', '', 'https://service.invalid')],
        ),
      );
      final directory = await runtime.run(
        () => runtime.service.owner.createDirectory('Synthetic credentials'),
      );
      final tag = await runtime.run(
        () => runtime.service.owner.createTag('Synthetic tag'),
      );
      final candidate = source.staging.string(secret);
      WorkspaceCredentialWrite write(
        String operation, {
        WorkspaceCredentialCandidate? material,
        WorkspaceCredentialDetail? before,
        String name = 'Synthetic credential',
        String note = '',
      }) => WorkspaceCredentialWrite(
        operationId: operation,
        name: name,
        purpose: 'Synthetic service access',
        privateNote: note,
        binding: 'SYNTHETIC_TOKEN',
        candidateId: material?.id,
        ref: before?.record.ref,
        expectedRecordVersion: before?.recordVersion,
        expectedMaterialVersion: before?.materialVersion,
        directoryId: directory.id,
        tagIds: [tag.id],
        linkedInformation: [
          WorkspaceRecordRef(WorkspaceRecordKind.information, information.id),
        ],
      );
      final input = write('create', material: candidate);
      final receipt = await runtime.run(() => source.save(input));
      expect((await runtime.run(() => source.save(input))).ref, receipt.ref);
      expect(repo.credentialMaterials.single.bytes, utf8.encode(secret));
      var detail = await runtime.run(() => source.read(receipt.ref));
      final generation = detail.useGeneration;
      expect(detail.record.directoryId, directory.id);
      expect(detail.linkedInformation.single.id, information.id);
      final edited = await runtime.run(
        () => source.save(
          write(
            'edit',
            before: detail,
            name: 'Renamed credential',
            note: 'Synthetic note',
          ),
        ),
      );
      detail = await runtime.run(() => source.read(edited.ref));
      expect(detail.recordVersion, 2);
      expect(detail.materialVersion, 1);
      expect(detail.useGeneration, generation);
      final replacement = source.staging.string('SYNTHETIC_REPLACEMENT_TOKEN');
      await runtime.run(
        () => source.save(
          write('replace', before: detail, material: replacement),
        ),
      );
      detail = await runtime.run(() => source.read(receipt.ref));
      expect(detail.materialVersion, 2);
      expect(detail.useGeneration, greaterThan(generation));
      await runtime.run(
        () => source.setEnabled(
          WorkspaceCredentialToggle(
            operationId: 'disable',
            ref: detail.record.ref,
            expectedRecordVersion: detail.recordVersion,
            expectedMaterialVersion: detail.materialVersion,
            enabled: false,
          ),
        ),
      );
      final fileBytes = utf8.encode('SYNTHETIC_PRIVATE_FILE_BYTES');
      final file = source.staging.file(
        SelectedCredentialFile('synthetic.key', fileBytes),
      );
      final fileReceipt = await runtime.run(
        () => source.save(write('create-file', material: file)),
      );
      expect(
        repo.credentialMaterials
            .where((v) => v.credentialId == fileReceipt.ref.id)
            .single
            .bytes,
        fileBytes,
      );
      final canceled = source.staging.string('SYNTHETIC_CANCELED_TOKEN');
      await source.releaseCandidate(canceled.id);
      await expectLater(
        runtime.run(() => source.save(write('canceled', material: canceled))),
        throwsA(
          isA<WorkspaceFailure>().having(
            (e) => e.code,
            'code',
            'selection_expired',
          ),
        ),
      );
      expect(runtime.service.owner.credentials, hasLength(2));
      expect(runtime.service.owner.credentialUseRequests, isEmpty);
      await close();
      await open();
      detail = await runtime.run(() => source.read(receipt.ref));
      expect(detail.enabled, false);
      expect(detail.materialVersion, 2);
      expect(detail.linkedInformation.single.id, information.id);
      expect(detail.record.tags.single.id, tag.id);
      expect(
        (await runtime.run(() => source.read(fileReceipt.ref))).filename,
        'synthetic.key',
      );
      expect(
        (await runtime.run(() => source.receipt('create')))?.ref,
        receipt.ref,
      );
      for (final entity in Directory('${root.path}/data').listSync()) {
        if (entity is File && !entity.path.endsWith('.lock')) {
          final raw = latin1.decode(entity.readAsBytesSync());
          expect(raw, isNot(contains(secret)));
          expect(raw, isNot(contains('SYNTHETIC_PRIVATE_FILE_BYTES')));
        }
      }
    },
  );
}
