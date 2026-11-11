import 'package:info_workspace/form_transport.dart';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:info_workspace/file_transport.dart';
import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_remote/owner_client.dart';
import 'package:info_server/agent_devices.dart';
import 'package:info_server/mounted_database_key_store.dart';
import 'package:info_server/online_server.dart';
import 'package:info_server/server_configuration.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_workspace/workspace_source.dart';
import 'package:info_workspace/workspace_transport.dart';
import 'package:info_workspace/workspace_information_codec.dart';
import 'package:test/test.dart';
import 'support/tls_fixture.dart';

void main() {
  test(
    'HTTPS owner uploads, replaces, restores and rereads exact originals through encrypted reopen',
    () async {
      final root = await Directory.systemTemp.createTemp('chiyo-owner-files-');
      await initializeServerSecrets('${root.path}/secrets');
      final fixture = await createTlsFixture(root);
      final tls = SecurityContext()
        ..useCertificateChain(fixture.certificate)
        ..usePrivateKey(fixture.privateKey);
      final trust = SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificates(fixture.ca);
      final token = base64Url
          .encode(await File('${root.path}/secrets/owner.token').readAsBytes())
          .replaceAll('=', '');
      final keys = MountedDatabaseKeyStore('${root.path}/secrets/database.key');
      late EncryptedInformationRepository repo;
      late OnlineInformationRuntime runtime;
      late OnlineServer server;
      late OwnerClient owner;
      var now = DateTime.utc(2026, 11, 8);
      Future<void> open({int port = 0}) async {
        repo = await EncryptedInformationRepository.openOnline(
          '${root.path}/data',
          keys,
        );
        runtime = await OnlineInformationRuntime.open(
          repository: repo,
          clock: () => now,
        );
        server = await OnlineServer.start(
          runtime: runtime,
          devices: AgentDeviceRegistry(repo),
          tls: tls,
          ownerToken: token,
          serverId: 'owner-files-synthetic',
          port: port,
        );
        owner = await OwnerClient.connect(
          address: Uri.parse('https://127.0.0.1:${server.port}'),
          token: token,
          trust: trust,
        );
      }

      Future<void> close() async {
        owner.close();
        await server.close();
        await runtime.close();
        await repo.close();
      }

      await open();
      addTearDown(() async {
        await close();
        await root.delete(recursive: true);
      });
      Future<Map<String, dynamic>> upload(
        String operation,
        String name,
        List<int> bytes,
      ) => owner.request('POST', '/v1/owner/files/uploads', {
        'operationId': operation,
        'originalName': name,
        'mediaType': 'application/octet-stream',
        'bytes': base64Encode(bytes),
      });
      final bytes = Uint8List(informationFileByteLimit);
      for (var n = 0; n < bytes.length; n++) {
        bytes[n] = n % 251;
      }
      final uploaded = await upload('upload-one', 'synthetic.bin', bytes);
      final candidate = fileCandidateFromJson(uploaded['candidate']);
      expect(candidate.byteLength, informationFileByteLimit);
      expect(uploaded['sha256'], sha256.convert(bytes).toString());
      expect(await upload('upload-one', 'synthetic.bin', bytes), uploaded);
      expect((await repo.informationFileStagingUsage()).files, 1);
      expect(jsonEncode(uploaded), isNot(contains('bytes')));
      await expectLater(
        upload('upload-one', 'changed.bin', [1]),
        throwsA(
          isA<RemoteFailure>().having(
            (e) => e.code,
            'code',
            'operation_conflict',
          ),
        ),
      );
      await expectLater(
        upload('bad-name', '../escape.bin', [1]),
        throwsA(isA<RemoteFailure>()),
      );
      expect((await repo.informationFileStagingUsage()).files, 1);
      expect(await owner.information(), isEmpty);
      final import = WorkspaceFileImport(
        operationId: 'import-once',
        selectionId: candidate.selectionId,
        name: 'Synthetic original',
      );
      final saved = await owner.request(
        'POST',
        '/v1/owner/files/import',
        fileImportToJson(import),
      );
      final receipt = fileReceiptFromJson(saved['receipt']);
      expect(receipt.commandDigest, import.digest);
      expect(
        await owner.request(
          'POST',
          '/v1/owner/files/import',
          fileImportToJson(import),
        ),
        saved,
      );
      expect((await repo.informationFileStagingUsage()).files, 0);
      final item = (await owner.information()).single;
      final detail = WorkspaceInformationCodec().decode(item);
      final key = detail.fieldIds.entries.single.value == item.fields.single.id
          ? detail.fieldIds.keys.single
          : throw StateError('Missing file key');
      expect(detail.record.type.id, 'file');
      final ref = receipt.record;
      Future<WorkspaceFileHistory> history() async => fileHistoryFromJson(
        await owner.request('POST', '/v1/owner/files/history', {
          'record': recordRefToJson(ref),
          'fieldKey': key,
        }),
      );
      Future<WorkspaceFileOriginal> read(int version) async =>
          fileOriginalFromJson(
            await owner.request('POST', '/v1/owner/files/read', {
              'record': recordRefToJson(ref),
              'fieldKey': key,
              'version': version,
            }),
          );
      expect((await read(1)).bytes, bytes);
      expect((await history()).current.ref.version, 1);
      final second = fileCandidateFromJson(
        (await upload(
          'upload-two',
          'replacement.txt',
          utf8.encode('SECOND_SYNTHETIC_ORIGINAL'),
        ))['candidate'],
      );
      final change = WorkspaceFileChange(
        operationId: 'replace-once',
        record: ref,
        fieldKey: key,
        expectedRecordVersion: item.version,
        expectedFileVersion: 1,
        kind: WorkspaceFileChangeKind.replace,
        selectionId: second.selectionId,
      );
      final replaced = fileReceiptFromJson(
        await owner.request(
          'POST',
          '/v1/owner/files/changes',
          fileChangeToJson(change),
        ),
      );
      expect(replaced.file!.version, 2);
      expect(replaced.commandDigest, change.digest);
      expect(
        fileReceiptFromJson(
          await owner.request(
            'POST',
            '/v1/owner/files/changes',
            fileChangeToJson(change),
          ),
        ).file,
        replaced.file,
      );
      expect((await history()).versions, hasLength(2));
      expect(utf8.decode((await read(2)).bytes), 'SECOND_SYNTHETIC_ORIGINAL');
      expect((await read(1)).bytes, bytes);
      final restored = WorkspaceFileChange(
        operationId: 'restore-once',
        record: ref,
        fieldKey: key,
        expectedRecordVersion: (await owner.information()).single.version,
        expectedFileVersion: 2,
        kind: WorkspaceFileChangeKind.restore,
        restoreVersion: 1,
      );
      expect(
        fileReceiptFromJson(
          await owner.request(
            'POST',
            '/v1/owner/files/changes',
            fileChangeToJson(restored),
          ),
        ).file!.version,
        3,
      );
      expect((await read(3)).bytes, bytes);
      final pending = fileCandidateFromJson(
        (await upload('cancel-upload', 'cancel.bin', [0, 255]))['candidate'],
      );
      await owner.request(
        'DELETE',
        '/v1/owner/files/selections/${pending.selectionId}',
      );
      expect((await repo.informationFileStagingUsage()).files, 0);
      await expectLater(
        owner.request(
          'POST',
          '/v1/owner/files/import',
          fileImportToJson(
            WorkspaceFileImport(
              operationId: 'cancelled-import',
              selectionId: pending.selectionId,
              name: 'Must not save',
            ),
          ),
        ),
        throwsA(
          isA<RemoteFailure>().having(
            (e) => e.code,
            'code',
            'selection_expired',
          ),
        ),
      );
      final device = await owner.request('POST', '/v1/owner/devices', {
        'operationId': 'enroll',
        'name': 'No owner file access',
      });
      await expectLater(
        OwnerClient.connect(
          address: owner.address,
          token: device['deviceToken'] as String,
          trust: trust,
        ),
        throwsA(
          isA<RemoteFailure>().having((e) => e.code, 'code', 'unauthorized'),
        ),
      );
      final originalAddress = owner.address;
      await close();
      await open(port: originalAddress.port);
      expect((await history()).versions, hasLength(3));
      expect((await read(3)).bytes, bytes);
      expect((await read(1)).bytes, bytes);
      expect(
        fileReceiptFromJson(
          await owner.request('GET', '/v1/owner/files/operations/import-once'),
        ).commandDigest,
        import.digest,
      );
      expect(
        fileReceiptFromJson(
          await owner.request('GET', '/v1/owner/files/operations/replace-once'),
        ).file!.version,
        2,
      );
      expect(await owner.information(), hasLength(1));

      // A genuine retained legacy template can contain multiple file fields.
      // Install no unsupported plugin format just to make this test pass.
      final template = await runtime.service.owner
          .createTemplate('Synthetic retained template', '', [
            const TemplateFieldInput('Title', ''),
            const TemplateFieldInput('First file', '', kind: FieldKind.file),
            const TemplateFieldInput('Second file', '', kind: FieldKind.file),
          ]);
      final listed = await owner.request(
        'GET',
        '/v1/owner/files/legacy-templates',
      );
      final projected = legacyTemplateFromJson(
        (listed['items'] as List).single,
      );
      expect(projected.id, template.id);
      // Removed setup/conversion routes cannot revive the deleted pages.
      for (final (method, path, body) in <(String, String, Object?)>[
        ('GET', '/v1/owner/agent-sessions', null),
        (
          'POST',
          '/v1/owner/files/legacy-templates/${template.id}/convert',
          {'expectedVersion': template.version},
        ),
      ]) {
        await expectLater(
          owner.request(method, path, body),
          throwsA(
            isA<RemoteFailure>().having((e) => e.code, 'code', 'not_found'),
          ),
        );
      }

      expect(
        projected.fields.where((f) => f.kind == WorkspaceLegacyFieldKind.file),
        hasLength(2),
      );
      final fields = projected.definition['fields'] as List;
      final a = fileCandidateFromJson(
        (await upload('form-a', 'first.bin', [1, 2, 3]))['candidate'],
      );
      final b = fileCandidateFromJson(
        (await upload('form-b', 'second.bin', [4, 5, 6]))['candidate'],
      );
      WorkspaceCreate form({
        bool duplicate = false,
        bool wrongVersion = false,
      }) => WorkspaceCreate(
        operationId: 'form-save',
        typeId: 'generic',
        name: 'Two original files',
        legacyTemplateId: template.id,
        expectedLegacyVersion: wrongVersion
            ? template.version + 1
            : template.version,
        values: {fields[0]['key'] as String: 'Synthetic title'},
        fileSelections: {
          fields[1]['key'] as String: a.selectionId,
          fields[2]['key'] as String: duplicate ? a.selectionId : b.selectionId,
        },
      );
      Future<Map<String, dynamic>> saveForm(WorkspaceCreate input) =>
          owner.request(
            'POST',
            '/v1/owner/files/forms',
            workspaceCreateToJson(input),
          );
      await expectLater(
        saveForm(form(wrongVersion: true)),
        throwsA(isA<RemoteFailure>().having((e) => e.code, 'code', 'conflict')),
      );
      await expectLater(
        saveForm(form(duplicate: true)),
        throwsA(
          isA<RemoteFailure>().having(
            (e) => e.code,
            'code',
            'selection_expired',
          ),
        ),
      );
      expect(await owner.information(), hasLength(1));
      expect((await repo.informationFileStagingUsage()).files, 2);
      final formResult = InformationRecordReceipt.fromJson(
        await saveForm(form()),
      );
      expect(
        InformationRecordReceipt.fromJson(await saveForm(form())).itemId,
        formResult.itemId,
      );
      expect((await repo.informationFileStagingUsage()).files, 0);
      await close();
      await open(port: originalAddress.port);
      final savedForm = (await owner.information()).singleWhere(
        (i) => i.id == formResult.itemId,
      );
      expect(savedForm.fields, hasLength(3));
      expect(savedForm.fields.first.value, 'Synthetic title');
      for (var n = 1; n < 3; n++) {
        final detail = WorkspaceInformationCodec().decode(savedForm);
        final content = fileOriginalFromJson(
          await owner.request('POST', '/v1/owner/files/read', {
            'record': recordRefToJson(detail.record.ref),
            'fieldKey': fields[n]['key'],
            'version': 1,
          }),
        );
        expect(content.bytes, n == 1 ? [1, 2, 3] : [4, 5, 6]);
      }
      expect(await owner.information(), hasLength(2));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
