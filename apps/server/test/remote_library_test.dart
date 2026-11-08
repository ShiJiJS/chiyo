import 'dart:convert';
import 'dart:io';
import 'package:info_cli/agent_client.dart';
import 'package:info_core/info_core.dart';
import 'package:info_remote/agent_connection.dart';
import 'package:info_remote/owner_client.dart';
import 'package:info_server/agent_devices.dart';
import 'package:info_server/mounted_database_key_store.dart';
import 'package:info_server/online_server.dart';
import 'package:info_server/server_configuration.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_workspace/approval_transport.dart';
import 'package:info_workspace/library_transport.dart';
import 'package:info_workspace/workspace_source.dart';
import 'package:info_workspace/workspace_transport.dart';
import 'package:info_workspace/workspace_information_codec.dart';
import 'package:test/test.dart';
import 'support/tls_fixture.dart';

void main() {
  test(
    'HTTPS classification, nested moves, order and scoped Agent organization survive encrypted reopen',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'chiyo-remote-library-',
      );
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
        repo = await EncryptedInformationRepository.open(
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
          serverId: 'remote-library-synthetic',
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

      Future<void> reopen() async {
        final port = server.port;
        await close();
        await open(port: port);
      }

      await open();
      addTearDown(() async {
        await close();
        await root.delete(recursive: true);
      });
      Future<WorkspaceCatalog> catalog() async => workspaceCatalogFromJson(
        (await owner.request('GET', '/v1/owner/catalog'))['workspace'],
      );
      Future<WorkspaceClassificationReceipt> change(
        WorkspaceClassificationChange c,
      ) async {
        final receipt = classificationReceiptFromJson(
          await owner.request(
            'POST',
            '/v1/owner/classification/changes',
            classificationChangeToJson(c),
          ),
        );
        expect(receipt.matches(c), isTrue);
        expect(
          classificationReceiptFromJson(
            await owner.request(
              'GET',
              '/v1/owner/classification/operations/${c.operationId}',
            ),
          ).commandDigest,
          c.digest,
        );
        return receipt;
      }

      Future<String> directory(String name, {String? parentId}) async =>
          (await change(
            WorkspaceDirectoryChange(
              operationId: 'create-$name',
              expectedVersion: (await catalog()).version,
              action: WorkspaceDirectoryAction.create,
              name: name,
              parentId: parentId,
            ),
          )).targetId;
      final a = await directory('Root'),
          child = await directory('Child', parentId: a),
          target = await directory('Target');
      final tag = (await change(
        WorkspaceTagChange(
          operationId: 'create-tag',
          expectedVersion: (await catalog()).version,
          action: WorkspaceTagAction.create,
          name: 'Synthetic tag',
        ),
      )).targetId;
      final rename = WorkspaceDirectoryChange(
        operationId: 'rename-root',
        expectedVersion: (await catalog()).version,
        action: WorkspaceDirectoryAction.update,
        directoryId: a,
        name: 'Renamed',
      );
      final renamed = await change(rename);
      expect((await change(rename)).version, renamed.version);
      await expectLater(
        change(
          WorkspaceDirectoryChange(
            operationId: 'stale',
            expectedVersion: rename.expectedVersion,
            action: WorkspaceDirectoryAction.update,
            directoryId: a,
            name: 'Stale',
          ),
        ),
        throwsA(isA<RemoteFailure>().having((e) => e.code, 'code', 'conflict')),
      );
      await expectLater(
        change(
          WorkspaceDirectoryChange(
            operationId: 'duplicate',
            expectedVersion: (await catalog()).version,
            action: WorkspaceDirectoryAction.create,
            name: 'Target',
          ),
        ),
        throwsA(
          isA<RemoteFailure>().having((e) => e.code, 'code', 'validation'),
        ),
      );
      Future<String> save(String name, String? dir) async =>
          (await owner.request('POST', '/v1/owner/saves/save-$name', {
                'name': name,
                'description': 'Synthetic library item',
                'directoryId': dir,
                'tagIds': [tag],
                'fields': [
                  {
                    'name': 'Body',
                    'description': '',
                    'text': 'PRIVATE_BODY_$name',
                  },
                ],
              }))['itemId']
              as String;
      final one = await save('Nested', child), two = await save('Direct', null);
      final definition = Map<String, Object?>.from(
        ((await owner.request('GET', '/v1/owner/catalog'))['templates'] as List)
            .cast<Map>()
            .singleWhere((d) => d['id'] == 'document'),
      );
      final three = (await owner.save(
        'save-Anchor',
        WorkspaceInformationCodec().create(
          WorkspaceCreate(
            operationId: 'save-Anchor',
            typeId: 'document',
            name: 'Anchor',
            expectedTemplateVersion: definition['templateVersion'] as String?,
            expectedTemplateDigest: definition['packageDigest'] as String?,
            directoryId: target,
            tagIds: [tag],
            values: {'bodyFormat': 'markdown', 'body': 'PRIVATE_BODY_Anchor'},
            relations: {
              'related': [
                WorkspaceRecordRef(WorkspaceRecordKind.information, one),
              ],
            },
          ),
          definition,
        ),
      )).itemId;
      final selection = WorkspaceLibrarySelection(
        directoryIds: [a, child],
        records: [
          WorkspaceRecordRef(WorkspaceRecordKind.information, one),
          WorkspaceRecordRef(WorkspaceRecordKind.information, two),
        ],
      );
      Future<WorkspaceLibraryMovePreview> preview(
        WorkspaceLibrarySelection s,
        String? dest, {
        WorkspaceLibraryPosition? position,
      }) async => libraryMovePreviewFromJson(
        await owner.request('POST', '/v1/owner/library/preview', {
          'selection': s.toJson(),
          'targetId': dest,
          'position': position?.toJson(),
        }),
      );
      Future<WorkspaceLibraryMoveReceipt> move(
        String id,
        WorkspaceLibrarySelection s,
        String? dest, {
        WorkspaceLibraryPosition? position,
      }) async {
        final p = await preview(s, dest, position: position);
        final c = WorkspaceLibraryMoveCommand(
          operationId: id,
          selection: s,
          targetId: dest,
          reviewToken: p.token,
          position: position,
        );
        final r = libraryMoveReceiptFromJson(
          await owner.request(
            'POST',
            '/v1/owner/library/moves',
            libraryMoveCommandToJson(c),
          ),
        );
        expect(r.matches(c), isTrue);
        expect(
          libraryMoveReceiptFromJson(
            await owner.request(
              'POST',
              '/v1/owner/library/moves',
              libraryMoveCommandToJson(c),
            ),
          ).inputHash,
          r.inputHash,
        );
        return r;
      }

      final p = await preview(selection, target);
      expect(p.roots, [a]);
      expect(p.scope.directories, hasLength(2));
      expect(p.scope.records.map((r) => r.ref.id).toSet(), {one, two});
      expect(p.records.single.ref.id, two);
      expect(p.targetPath, ['Target']);
      expect(
        jsonEncode(libraryMovePreviewToJson(p)),
        isNot(contains('PRIVATE_BODY')),
      );
      final invalidCycle = await preview(
        WorkspaceLibrarySelection(directoryIds: [a]),
        child,
      );
      expect(invalidCycle.conflicts, isNotEmpty);
      final cycle = WorkspaceLibraryMoveCommand(
        operationId: 'cycle',
        selection: WorkspaceLibrarySelection(directoryIds: [a]),
        targetId: child,
        reviewToken: invalidCycle.token,
      );
      await expectLater(
        owner.request(
          'POST',
          '/v1/owner/library/moves',
          libraryMoveCommandToJson(cycle),
        ),
        throwsA(isA<RemoteFailure>()),
      );
      final moved = await move('move-once', selection, target);
      await move(
        'reorder-once',
        WorkspaceLibrarySelection(
          records: [WorkspaceRecordRef(WorkspaceRecordKind.information, three)],
        ),
        target,
        position: WorkspaceLibraryPosition.record(
          WorkspaceRecordRef(WorkspaceRecordKind.information, two),
          after: false,
        ),
      );
      await owner.request('POST', '/v1/owner/library/order', {
        'sort': 'manual',
      });
      final order = await owner.request('GET', '/v1/owner/library/order');
      final records = (order['records'] as List)
          .map(recordRefFromJson)
          .toList();
      expect(
        records.indexWhere((r) => r.id == three),
        lessThan(records.indexWhere((r) => r.id == two)),
      );
      expect((await catalog()).directoryCounts[target], 3);
      await reopen();
      expect(owner.initialLibrarySort, 'manual');
      expect(await owner.request('GET', '/v1/owner/library/order'), order);
      expect(
        libraryMoveReceiptFromJson(
          await owner.request('GET', '/v1/owner/library/operations/move-once'),
        ).inputHash,
        moved.inputHash,
      );
      expect(
        (await catalog()).directories.singleWhere((d) => d.id == a).parentId,
        target,
      );
      expect(
        (await catalog()).directories
            .singleWhere((d) => d.id == child)
            .parentId,
        a,
      );
      expect(
        (await owner.request(
          'GET',
          '/v1/owner/information/$one',
        ))['directoryId'],
        child,
      );
      expect(
        (await owner.request(
          'GET',
          '/v1/owner/information/$two',
        ))['directoryId'],
        target,
      );
      expect(
        (await owner.request('GET', '/v1/owner/information'))['items'],
        hasLength(3),
      );
      final retained = (await owner.information()).singleWhere(
        (i) => i.id == three,
      );
      expect(retained.layout!.typeId, 'document');
      expect(retained.layout!.relations['related']!.single.id, one);
      expect(
        retained.fields.any((f) => f.value == 'PRIVATE_BODY_Anchor'),
        isTrue,
      );
      final enrolled = await owner.request('POST', '/v1/owner/devices', {
        'operationId': 'enroll-org',
        'name': 'Synthetic organization CLI',
      });
      final profile = AgentConnectionProfile(
        address: owner.address,
        deviceToken: enrolled['deviceToken'] as String,
        serverId: owner.serverId,
        certificate: await File(fixture.ca).readAsString(),
      );
      final cli = AgentClient.remote(profile);
      addTearDown(cli.close);
      expect(
        (await cli.openLifecycleSession(
          'Synthetic organization root',
        ))['status'],
        'ok',
      );
      Future<Map<String, dynamic>> run(
        String command, [
        Map<String, dynamic> values = const {},
      ]) => cli.execute({'command': command, ...values});
      expect(jsonEncode(await run('directory-list')), contains('Renamed'));
      final requested = await run('organize-request', {
        'purpose': 'Organize only approved rows',
        'itemIds': [one, two],
      });
      expect(requested['status'], 'pending');
      final taskId = requested['taskId'] as String;
      expect(
        (await run('organize-metadata', {'taskId': taskId}))['status'],
        'pending',
      );
      Future<void> approve(
        String task,
        List<String> selected,
        String op,
      ) async {
        final detail = approvalDetailFromJson(
          await owner.request('GET', '/v1/owner/approvals/$task'),
        );
        expect(detail.request.kind, WorkspaceApprovalKind.organization);
        final c = WorkspaceApprovalChange(
          operationId: op,
          requestId: task,
          reviewToken: detail.reviewToken,
          action: WorkspaceApprovalAction.approve,
          selected: selected,
          fieldMinutes: 10,
        );
        await owner.request(
          'POST',
          '/v1/owner/approvals/decisions',
          approvalChangeToJson(c),
        );
      }

      await approve(taskId, [one], 'approve-scope');
      await reopen();
      final metadata = await run('organize-metadata', {'taskId': taskId});
      expect(metadata['status'], 'ok');
      expect((metadata['items'] as List).single['id'], one);
      expect(jsonEncode(metadata), isNot(contains('PRIVATE_BODY')));
      final before = await owner.request('GET', '/v1/server');
      final outside = OrganizationChange(
        itemId: two,
        baseVersion:
            (await owner.request(
                  'GET',
                  '/v1/owner/information/$two',
                ))['version']
                as int,
        directoryId: target,
      );
      expect(
        (await run('organize-submit', {
          'taskId': taskId,
          'changes': [outside.toJson()],
        }))['status'],
        'invalid_proposal',
      );
      final allowed = OrganizationChange(
        itemId: one,
        baseVersion: (metadata['items'] as List).single['version'] as int,
        directoryName: 'Organized',
        tagNames: ['Reviewed'],
      );
      expect(
        (await run('organize-submit', {
          'taskId': taskId,
          'changes': [allowed.toJson()],
        }))['status'],
        'confirmed',
      );
      expect(
        (await owner.request('GET', '/v1/server'))['workspaceObservation'],
        isNot(before['workspaceObservation']),
      );
      expect(
        (await run('organize-status', {'taskId': taskId}))['status'],
        'confirmed',
      );
      final result = await owner.request('GET', '/v1/owner/information/$one');
      expect(
        (await catalog()).directories
            .singleWhere((d) => d.id == result['directoryId'])
            .name,
        'Organized',
      );
      expect(
        (await owner.request(
          'GET',
          '/v1/owner/information/$two',
        ))['directoryId'],
        target,
      );
      final removal = tagRemovalFromJson(
        await owner.request('GET', '/v1/owner/classification/tag-removal/$tag'),
      );
      expect(removal.affectedCount, 2);
      await change(
        WorkspaceTagChange(
          operationId: 'remove-tag',
          expectedVersion: removal.catalogVersion,
          action: WorkspaceTagAction.delete,
          tagId: tag,
          removalToken: removal.token,
        ),
      );
      expect((await catalog()).tags.any((t) => t.id == tag), isFalse);
      final next = await run('organize-request', {
        'purpose': 'Expiry',
        'itemIds': [two],
      });
      await approve(next['taskId'] as String, [two], 'approve-expiring');
      now = now.add(const Duration(minutes: 11));
      expect(
        (await run('organize-status', {'taskId': next['taskId']}))['status'],
        'expired',
      );
      now = now.subtract(const Duration(minutes: 5));
      await reopen();
      expect(
        (await run('organize-metadata', {'taskId': next['taskId']}))['status'],
        'expired',
      );
      final last = await run('organize-request', {
        'purpose': 'Ended root',
        'itemIds': [two],
      });
      await approve(last['taskId'] as String, [two], 'approve-final');
      expect(
        (await cli.endLifecycleSession(cli.endCapability!))['status'],
        'ended',
      );
      await reopen();
      expect(
        (await run('organize-metadata', {'taskId': last['taskId']}))['status'],
        'unauthorized',
      );
      await expectLater(
        change(
          WorkspaceDirectoryChange(
            operationId: 'delete-unconnected',
            expectedVersion: (await catalog()).version,
            action: WorkspaceDirectoryAction.delete,
            directoryId: a,
          ),
        ),
        throwsA(
          isA<RemoteFailure>().having((e) => e.code, 'code', 'unsupported'),
        ),
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
