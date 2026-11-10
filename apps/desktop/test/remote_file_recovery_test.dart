@TestOn('!windows')
library;

// Real OnlineServer fixture uses POSIX secret mounts. Windows behavior is
// exercised by the explicit existing-NAS tests, without relaxing that boundary.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_desktop/information_files.dart';
import 'package:info_desktop/workspace/remote_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_remote/owner_client.dart';
import 'package:info_server/agent_devices.dart';
import 'package:info_server/mounted_database_key_store.dart';
import 'package:info_server/online_server.dart';
import 'package:info_server/server_configuration.dart';
import 'package:info_storage/info_storage.dart';
import '../../server/test/support/tls_fixture.dart';

class _RealHttp extends HttpOverrides {}

class _Picker implements InformationFilePicker {
  String? path;
  int choices = 0;
  @override
  Future<String?> choose() async {
    choices++;
    return path;
  }

  @override
  Future<String?> saveAs(String name) async => null;
}

void main() {
  test(
    'lost file upload and import replies keep original selections and durable receipts',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final root = await Directory.systemTemp.createTemp(
          'chiyo-file-response-loss-',
        );
        await initializeServerSecrets('${root.path}/secrets');
        final fixture = await createTlsFixture(root);
        final tls = SecurityContext()
          ..useCertificateChain(fixture.certificate)
          ..usePrivateKey(fixture.privateKey);
        final trust = SecurityContext(withTrustedRoots: false)
          ..setTrustedCertificates(fixture.ca);
        final token = base64Url
            .encode(
              await File('${root.path}/secrets/owner.token').readAsBytes(),
            )
            .replaceAll('=', '');
        final repo = await EncryptedInformationRepository.open(
          '${root.path}/data',
          MountedDatabaseKeyStore('${root.path}/secrets/database.key'),
        );
        final runtime = await core.OnlineInformationRuntime.open(
          repository: repo,
        );
        const serverId = 'file-response-loss-synthetic';
        final server = await OnlineServer.start(
          runtime: runtime,
          devices: AgentDeviceRegistry(repo),
          tls: tls,
          ownerToken: token,
          serverId: serverId,
        );
        final direct = await OwnerClient.connect(
          address: Uri.parse('https://127.0.0.1:${server.port}'),
          token: token,
          trust: trust,
        );
        final upstream = HttpClient(context: trust);
        final proxy = await HttpServer.bindSecure(
          InternetAddress.loopbackIPv4,
          0,
          tls,
        );
        var uploads = 0, imports = 0, dropUploads = true, failReceipts = false;
        proxy.listen((request) async {
          try {
            final isLookup =
                request.method == 'GET' &&
                (request.uri.path.contains('/files/uploads/') ||
                    request.uri.path.contains('/files/operations/'));
            if (failReceipts && isLookup) {
              request.response.statusCode = 503;
              request.response.headers.set('x-chiyo-server-id', serverId);
              request.response.headers.contentType = ContentType.json;
              request.response.write(
                jsonEncode({'error': 'server_unavailable'}),
              );
              await request.response.close();
              return;
            }
            final next = await upstream.openUrl(
              request.method,
              direct.address.resolve(request.uri.path),
            );
            for (final key in [
              'authorization',
              'content-type',
              'x-chiyo-server-id',
            ]) {
              final value = request.headers.value(key);
              if (value != null) next.headers.set(key, value);
            }
            await next.addStream(request);
            final response = await next.close();
            final bytes = await response.fold<List<int>>(
              [],
              (a, b) => a..addAll(b),
            );
            final upload =
                request.method == 'POST' &&
                request.uri.path == '/v1/owner/files/uploads';
            final importing =
                request.method == 'POST' &&
                request.uri.path == '/v1/owner/files/import';
            if (upload) uploads++;
            if (importing) imports++;
            if (upload && dropUploads || importing) {
              final socket = await request.response.detachSocket(
                writeHeaders: false,
              );
              socket.destroy();
              return;
            }
            request.response.statusCode = response.statusCode;
            request.response.headers.set(
              'x-chiyo-server-id',
              response.headers.value('x-chiyo-server-id')!,
            );
            request.response.headers.contentType = ContentType.json;
            request.response.add(bytes);
            await request.response.close();
          } on Object {
            try {
              request.response.statusCode = 503;
              await request.response.close();
            } on Object {
              /* disconnected */
            }
          }
        });
        RemoteWorkspaceSource? source;
        try {
          final owner = await OwnerClient.connect(
            address: Uri.parse('https://127.0.0.1:${proxy.port}'),
            token: token,
            trust: trust,
          );
          final picker = _Picker();
          final original = File('${root.path}/synthetic-original.txt');
          await original.writeAsString('ORIGINAL_SYNTHETIC_CONTENT');
          picker.path = original.path;
          source = RemoteWorkspaceSource(owner, filePicker: picker);
          final first = (await source.files.pick())!;
          expect(uploads, 1);
          expect(picker.choices, 1);
          expect((await repo.informationFileStagingUsage()).files, 1);
          // The POST reply was lost but its matching GET recovered that stage.
          final command = WorkspaceFileImport(
            operationId: 'lost-import',
            selectionId: first.selectionId,
            name: 'Synthetic remotely saved file',
          );
          await expectLater(
            source.importFile(command),
            throwsA(
              isA<WorkspaceFailure>().having(
                (e) => e.code,
                'code',
                'unknown_outcome',
              ),
            ),
          );
          expect(imports, 1);
          expect(await direct.information(), hasLength(1));
          failReceipts = true;
          await expectLater(
            source.fileOperationReceipt(command.operationId),
            throwsA(isA<WorkspaceFailure>()),
          );
          failReceipts = false;
          final receipt = (await source.fileOperationReceipt(
            command.operationId,
          ))!;
          expect(receipt.commandDigest, command.digest);
          expect(
            (await source.readFilePreview(receipt.record, 'file')).text,
            'ORIGINAL_SYNTHETIC_CONTENT',
          );
          expect(imports, 1);
          // Failure of both POST observation and GET is not confirmed absence.
          failReceipts = true;
          await expectLater(
            source.files.pick(),
            throwsA(
              isA<WorkspaceFailure>().having(
                (e) => e.code,
                'code',
                'unknown_outcome',
              ),
            ),
          );
          expect(picker.choices, 2);
          expect((await repo.informationFileStagingUsage()).files, 1);
          final other = File('${root.path}/other.txt');
          await other.writeAsString('OTHER');
          picker.path = other.path;
          failReceipts = false;
          final recovered = (await source.files.pick())!;
          expect(recovered.filename, 'synthetic-original.txt');
          expect(picker.choices, 2);
          expect((await repo.informationFileStagingUsage()).files, 1);
          // Confirm integrated remote form saves retain native multi-file rules.
          final template = await runtime.service.owner
              .createTemplate('Synthetic multi file', '', [
                const core.TemplateFieldInput('Title', ''),
                const core.TemplateFieldInput(
                  'First',
                  '',
                  kind: core.FieldKind.file,
                ),
                const core.TemplateFieldInput(
                  'Second',
                  '',
                  kind: core.FieldKind.file,
                ),
              ]);
          final legacy = (await source.legacyTemplates.load()).single;
          expect(legacy.id, template.id);
          final fields = legacy.definition['fields'] as List;
          dropUploads = false;
          final second = (await source.files.pick())!;
          final form = WorkspaceCreate(
            operationId: 'multi-form',
            typeId: 'generic',
            name: 'Two attached originals',
            legacyTemplateId: legacy.id,
            expectedLegacyVersion: legacy.version,
            values: {fields[0]['key'] as String: 'Synthetic title'},
            fileSelections: {
              fields[1]['key'] as String: recovered.selectionId,
              fields[2]['key'] as String: second.selectionId,
            },
          );
          final saved = await source.createRecord(form) as WorkspaceSaved;
          expect(saved.detail.values[fields[0]['key']], 'Synthetic title');
          expect(
            (await source.readFilePreview(
              saved.detail.record.ref,
              fields[1]['key'] as String,
            )).text,
            'ORIGINAL_SYNTHETIC_CONTENT',
          );
          expect(
            (await source.readFilePreview(
              saved.detail.record.ref,
              fields[2]['key'] as String,
            )).text,
            'OTHER',
          );
          expect(
            (await source.recordOperationReceipt('multi-form'))!.result.ref,
            saved.detail.record.ref,
          );
          expect((await repo.informationFileStagingUsage()).files, 0);
          // An unknown upload during close is canceled in the same batch as held selections.
          await source.files.pick();
          failReceipts = true;
          dropUploads = true;
          await expectLater(
            source.files.pick(),
            throwsA(isA<WorkspaceFailure>()),
          );
          expect((await repo.informationFileStagingUsage()).files, 2);
          await source.dispose();
          source = null;
          expect((await repo.informationFileStagingUsage()).files, 0);
          expect(await direct.information(), hasLength(2));
        } finally {
          await source?.dispose();
          direct.close();
          upstream.close(force: true);
          await proxy.close(force: true);
          await server.close();
          await runtime.close();
          await repo.close();
          await root.delete(recursive: true);
        }
      }, _RealHttp());
    },
  );
}
