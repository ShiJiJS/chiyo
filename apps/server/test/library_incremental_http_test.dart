import 'dart:convert';
import 'dart:io';

import 'package:info_core/info_core.dart';
import 'package:info_core/library_sync_changes.dart';
import 'package:info_remote/library_replication_client.dart';
import 'package:info_remote/owner_client.dart';
import 'package:info_storage/info_storage.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:test/test.dart';

import 'support/device_credential_fixture.dart';
import 'support/owner_reply_proxy.dart';

class _Keys implements DatabaseKeyStore {
  List<int>? value;
  @override
  Future<List<int>?> read() async => value;
  @override
  Future<void> create(List<int> key) async => value = List.of(key);
}

class _Local {
  _Local(this.root, this.repo, this.service)
    : incremental = LibraryIncremental(LibraryReplication(repo));
  final Directory root;
  final EncryptedInformationRepository repo;
  final InformationService service;
  final LibraryIncremental incremental;
  static Future<_Local> open() async {
    final root = await Directory.systemTemp.createTemp(
      'http-incremental-local-',
    );
    final repo = await EncryptedInformationRepository.open(root.path, _Keys());
    return _Local(root, repo, InformationService(repository: repo));
  }

  Future<void> close() async {
    await service.close();
    await repo.close();
    await root.delete(recursive: true);
  }
}

Future<int> pull(
  LibraryIncrementalClient remote,
  _Local local,
  int cursor,
) async {
  for (final summary in await remote.changes(cursor)) {
    final export = await remote.prepareDelta(summary);
    final file = File(
      '${local.root.path}/delta-${summary.operationId}.encrypted',
    );
    try {
      await remote.transport.download(export.contents, file);
      final receipt = await local.service.owner.exportLibrary(
        () => local.incremental.installDelta(
          path: file.path,
          transferKey: export.contents.transferKey,
          transfer: export.transfer,
        ),
      );
      expect(receipt.conflict, false);
      await local.incremental.advanceProgress(
        remote.identity.replicaId,
        expected: cursor,
        next: summary.cursor,
      );
      cursor = summary.cursor;
    } finally {
      await remote.transport.release(export.contents);
      if (await file.exists()) await file.delete();
    }
  }
  return cursor;
}

Future<InformationItem> saveFile(
  OwnerAccess owner,
  String root,
  List<int> bytes, [
  InformationItem? old,
]) async {
  final input = File('$root/synthetic-original.bin');
  await input.writeAsBytes(bytes);
  final draft = await owner.beginInformationFileDraft();
  try {
    final staged = await owner.stageInformationFile(draft, input.path);
    return await owner.commitInformationDraft(
      draft,
      'file-version-${old?.version ?? 0}',
      InformationDraftInput(
        name: '合成同步文件',
        description: '',
        itemId: old?.id,
        baseVersion: old?.version,
        fields: [
          InformationDraftField.stagedFile(
            '文件',
            '',
            staged.id,
            fieldId: old?.fields.single.id,
          ),
        ],
      ),
    );
  } finally {
    await owner.releaseInformationFileDraft(draft);
  }
}

Future<void> initializeLocal(
  LibraryIncrementalClient remote,
  _Local local,
  String operation,
) async {
  final export = await remote.prepareInitial(operation);
  final file = File('${local.root.path}/initial.encrypted');
  try {
    final baseline = await remote.readBaseline(export);
    await remote.transport.download(export.contents, file);
    await local.service.owner.restoreLibrary(
      () => local.incremental.installInitialWithBaseline(
        path: file.path,
        transferKey: export.contents.transferKey,
        operationId: operation,
        transfer: export.contents.transfer,
        baseline: baseline,
        expectedSourceReplicaId: remote.identity.replicaId,
      ),
    );
  } finally {
    await remote.transport.release(export.contents);
    if (await file.exists()) await file.delete();
  }
}

void main() {
  test(
    'two real clients retain distinct originals with the same display version and keep receiving independent data',
    () async {
      final host = await DeviceCredentialFixture.create(replication: true);
      final a = await _Local.open(), b = await _Local.open();
      try {
        await host.runtime.run(
          () => saveFile(host.runtime.service.owner, host.root.path, [1, 2, 3]),
        );
        final remote = await LibraryIncrementalClient.connect(host.owner);
        await initializeLocal(remote, a, 'initial-a');
        await initializeLocal(remote, b, 'initial-b');
        final changedA = await saveFile(a.service.owner, a.root.path, [
          4,
          5,
          6,
        ], a.repo.items.single);
        final changedB = await saveFile(b.service.owner, b.root.path, [
          7,
          8,
          9,
        ], b.repo.items.single);
        final metaA = (await a.repo.informationAttachmentVersions(
          changedA.fields.single.attachment!.attachmentId,
        )).singleWhere((v) => v.reference == changedA.fields.single.attachment);
        final metaB = (await b.repo.informationAttachmentVersions(
          changedB.fields.single.attachment!.attachmentId,
        )).singleWhere((v) => v.reference == changedB.fields.single.attachment);
        expect(
          metaA.reference.attachmentVersion,
          metaB.reference.attachmentVersion,
        );
        expect(metaA.sha256, isNot(metaB.sha256));
        for (final entry in await a.service.owner.exportLibrary(
          () => a.incremental.after(0),
        )) {
          final file = File('${a.root.path}/delta-${entry.cursor}.encrypted');
          final export = await a.service.owner.exportLibrary(
            () => a.incremental.exportDelta(
              file.path,
              sourceReplicaId: entry.batch.sourceReplicaId,
              operationId: entry.batch.operationId,
            ),
          );
          expect(
            (await remote.uploadDelta(
              file: file,
              transfer: export.transfer,
              transferKey: export.transferKey,
            )).conflict,
            false,
          );
          await file.delete();
        }
        var conflicted = false;
        for (final entry in await b.service.owner.exportLibrary(
          () => b.incremental.after(0),
        )) {
          final file = File('${b.root.path}/delta-${entry.cursor}.encrypted');
          final export = await b.service.owner.exportLibrary(
            () => b.incremental.exportDelta(
              file.path,
              sourceReplicaId: entry.batch.sourceReplicaId,
              operationId: entry.batch.operationId,
            ),
          );
          conflicted |= (await remote.uploadDelta(
            file: file,
            transfer: export.transfer,
            transferKey: export.transferKey,
          )).conflict;
          await file.delete();
        }
        expect(conflicted, true);
        final server = LibraryIncremental(LibraryReplication(host.repo));
        expect(
          await host.runtime.run(
            () => host.runtime.service.owner.exportLibrary(
              () => server.readAttachment(metaA, 0, 3),
            ),
          ),
          [4, 5, 6],
        );
        expect(
          await host.runtime.run(
            () => host.runtime.service.owner.exportLibrary(
              () => server.readAttachment(metaB, 0, 3),
            ),
          ),
          [7, 8, 9],
        );
        final independent = await host.runtime.run(
          () => host.runtime.service.owner.createInformation('独立资料', '', [
            const FieldInput('正文', '', 'SYNTHETIC_UNRELATED'),
          ]),
        );
        var cursor = await b.incremental.progress(remote.identity.replicaId);
        for (final summary in await remote.changes(cursor)) {
          final export = await remote.prepareDelta(summary);
          final file = File(
            '${b.root.path}/received-${summary.cursor}.encrypted',
          );
          try {
            await remote.transport.download(export.contents, file);
            await b.service.owner.exportLibrary(
              () => b.incremental.installDelta(
                path: file.path,
                transferKey: export.contents.transferKey,
                transfer: export.transfer,
              ),
            );
            await b.incremental.advanceProgress(
              remote.identity.replicaId,
              expected: cursor,
              next: summary.cursor,
            );
            cursor = summary.cursor;
          } finally {
            await remote.transport.release(export.contents);
            if (await file.exists()) await file.delete();
          }
        }
        expect(b.repo.items.any((i) => i.id == independent.id), true);
        expect(
          await b.service.owner.exportLibrary(
            () => b.incremental.readAttachment(metaA, 0, 3),
          ),
          [4, 5, 6],
        );
        expect(
          await b.service.owner.exportLibrary(
            () => b.incremental.readAttachment(metaB, 0, 3),
          ),
          [7, 8, 9],
        );
        expect(
          (await b.service.owner.exportLibrary(b.incremental.status)).conflicts,
          greaterThan(0),
        );
      } finally {
        await a.close();
        await b.close();
        await host.dispose();
      }
    },
  );

  test(
    'real HTTPS initial copy and later deltas survive restart without changing idle storage',
    () async {
      final host = await DeviceCredentialFixture.create(replication: true);
      final local = await _Local.open();
      var stopped = false;
      try {
        final item = await host.runtime.run(
          () => host.runtime.service.owner.createInformation('服务器合成资料', '', [
            const FieldInput('正文', '', 'SYNTHETIC_INITIAL'),
          ]),
        );
        var remote = await LibraryIncrementalClient.connect(host.owner);
        final exported = await remote.prepareInitial('initial-http');
        final baseline = await remote.readBaseline(exported);
        final file = File('${local.root.path}/initial.encrypted');
        await remote.transport.download(exported.contents, file);
        await local.service.owner.restoreLibrary(
          () => local.incremental.installInitialWithBaseline(
            path: file.path,
            transferKey: exported.contents.transferKey,
            operationId: 'local-initial-http',
            transfer: exported.contents.transfer,
            baseline: baseline,
            expectedSourceReplicaId: remote.identity.replicaId,
          ),
        );
        await remote.transport.release(exported.contents);
        await file.delete();
        expect(
          local.service.owner.information.single.fields.single.value,
          'SYNTHETIC_INITIAL',
        );
        final ref = FieldRef(item.id, item.fields.single.id);
        await host.runtime.run(
          () => host.runtime.service.owner.correctValue(ref, 'SYNTHETIC_DELTA'),
        );
        var cursor = await pull(remote, local, baseline.cursor);
        expect(
          local.service.owner.information.single.fields.single.value,
          'SYNTHETIC_DELTA',
        );
        final key = await File(
          '${host.root.path}/secrets/database.key',
        ).readAsBytes();
        final observer = sqlite.sqlite3.open(
          '${host.root.path}/data/library.db',
        );
        try {
          observer.execute(
            'PRAGMA key = "x\'${key.map((v) => v.toRadixString(16).padLeft(2, '0')).join()}\'"',
          );
          final before = observer
              .select('PRAGMA data_version')
              .single
              .values
              .single;
          for (var i = 0; i < 3; i++) {
            expect(await remote.changes(cursor), isEmpty);
            expect((await remote.status()).cursor, cursor);
          }
          expect(
            observer.select('PRAGMA data_version').single.values.single,
            before,
          );
        } finally {
          observer.close();
        }
        await host.reopen();
        remote = await LibraryIncrementalClient.connect(host.owner);
        await host.runtime.run(
          () => host.runtime.service.owner.createInformation('重启后的资料', '', [
            const FieldInput('正文', '', 'SYNTHETIC_RESTART'),
          ]),
        );
        cursor = await pull(remote, local, cursor);
        expect(
          await local.incremental.progress(remote.identity.replicaId),
          cursor,
        );
        expect(local.service.owner.information, hasLength(2));
        await host.close();
        stopped = true;
        final session = local.service.agent.openSession('断开 NAS 后本机申请');
        final request = local.service.agent.request(session, '合成读取', [ref]);
        local.service.owner.approve(request.id, [ref]);
        final grant = local.service.agent.claim(session, request.id);
        expect(
          await local.service.agent.read(grant.token, ref),
          'SYNTHETIC_DELTA',
        );
      } finally {
        await local.close();
        if (stopped) {
          await host.root.delete(recursive: true);
        } else {
          await host.dispose();
        }
      }
    },
  );

  test(
    'chunked baseline resumes and a lost delta commit is queried after a real server restart',
    () async {
      final host = await DeviceCredentialFixture.create(replication: true);
      final local = await _Local.open();
      final proxy = await OwnerReplyProxy.start(
        tls: host.tls,
        trust: host.trust,
        target: () => host.owner.address,
        serverId: host.owner.serverId,
      );
      final connection = await OwnerClient.connect(
        address: proxy.address,
        token: host.token,
        trust: host.trust,
      );
      try {
        var remote = await LibraryIncrementalClient.connect(connection);
        final item = await local.service.owner.createInformation(
          '上传的合成资料',
          '',
          [const FieldInput('正文', '', 'SYNTHETIC_UPLOAD')],
        );
        final file = File('${local.root.path}/initial.encrypted');
        final prepared = await local.service.owner.exportLibrary(
          () => local.incremental.exportInitialWithBaseline(file.path),
        );
        // Transport fixture: many valid tombstones model a long-lived library
        // without creating thousands of UI operations in this protocol test.
        final deleted = {
          for (var i = 0; i < 4000; i++)
            LibrarySyncKey(LibrarySyncKind.tag, 'synthetic-deleted-tag-$i'),
        };
        final baseline = LibrarySyncBaseline(
          libraryId: prepared.baseline.libraryId,
          sourceReplicaId: prepared.baseline.sourceReplicaId,
          snapshotId: prepared.baseline.snapshotId,
          cursor: prepared.baseline.cursor,
          versions: {
            ...prepared.baseline.versions,
            for (final key in deleted) key: 'a' * 64,
          },
          tombstones: {...prepared.baseline.tombstones, ...deleted},
        );
        expect(
          utf8.encode(jsonEncode(baseline.toJson())).length,
          greaterThan(LibraryReplicationClient.chunkBytes),
        );
        var dropped = false;
        proxy.beforeReply = (path) async {
          if (!dropped && path.endsWith('/baseline/write')) {
            dropped = true;
            proxy.dropNextPath = path;
          }
        };
        await expectLater(
          remote.uploadInitial(
            file: file,
            transfer: prepared.initial.transfer,
            transferKey: prepared.initial.transferKey,
            baseline: baseline,
            operationId: 'initial-upload',
          ),
          throwsA(isA<RemoteFailure>()),
        );
        expect(host.repo.items, isEmpty);
        final initial = await remote.uploadInitial(
          file: file,
          transfer: prepared.initial.transfer,
          transferKey: prepared.initial.transferKey,
          baseline: baseline,
          operationId: 'initial-upload',
        );
        expect(initial.identity.libraryId, prepared.initial.transfer.libraryId);
        expect(host.repo.items.single.fields.single.value, 'SYNTHETIC_UPLOAD');
        await file.delete();
        expect(
          (await remote.uploadInitial(
            file: file,
            transfer: prepared.initial.transfer,
            transferKey: prepared.initial.transferKey,
            baseline: baseline,
            operationId: 'initial-upload',
          )).toJson(),
          initial.toJson(),
        );
        remote = await LibraryIncrementalClient.connect(connection);
        await local.service.owner.correctValue(
          FieldRef(item.id, item.fields.single.id),
          'SYNTHETIC_UPLOAD_DELTA',
        );
        final change = (await local.service.owner.exportLibrary(
          () => local.incremental.after(0),
        )).single;
        final deltaFile = File('${local.root.path}/delta.encrypted');
        final delta = await local.service.owner.exportLibrary(
          () => local.incremental.exportDelta(
            deltaFile.path,
            sourceReplicaId: change.batch.sourceReplicaId,
            operationId: change.batch.operationId,
          ),
        );
        var lost = false;
        proxy.beforeReply = (path) async {
          if (!lost && path.endsWith('/commit')) {
            lost = true;
            proxy.dropNextPath = path;
          }
        };
        await expectLater(
          remote.uploadDelta(
            file: deltaFile,
            transfer: delta.transfer,
            transferKey: delta.transferKey,
          ),
          throwsA(isA<RemoteFailure>()),
        );
        expect(lost, true);
        expect(
          host.repo.items.single.fields.single.value,
          'SYNTHETIC_UPLOAD_DELTA',
        );
        await host.reopen();
        await deltaFile.delete();
        remote = await LibraryIncrementalClient.connect(connection);
        final receipt = await remote.uploadDelta(
          file: deltaFile,
          transfer: delta.transfer,
          transferKey: delta.transferKey,
        );
        expect(receipt.conflict, false);
        final changes = await remote.changes(0);
        expect(
          changes.where((c) => c.operationId == change.batch.operationId),
          hasLength(1),
        );
        expect(host.repo.items, hasLength(1));
        var localCursor = change.cursor;
        for (var i = 0; i < 3; i++) {
          await local.service.owner.correctValue(
            FieldRef(item.id, item.fields.single.id),
            'SYNTHETIC_UPLOAD_DELTA_$i',
          );
          final next = (await local.service.owner.exportLibrary(
            () => local.incremental.after(localCursor),
          )).single;
          final path = File('${local.root.path}/next-$i.encrypted');
          final outgoing = await local.service.owner.exportLibrary(
            () => local.incremental.exportDelta(
              path.path,
              sourceReplicaId: next.batch.sourceReplicaId,
              operationId: next.batch.operationId,
            ),
          );
          expect(
            (await remote.uploadDelta(
              file: path,
              transfer: outgoing.transfer,
              transferKey: outgoing.transferKey,
            )).conflict,
            false,
          );
          await path.delete();
          localCursor = next.cursor;
        }
        expect(
          host.repo.items.single.fields.single.value,
          'SYNTHETIC_UPLOAD_DELTA_2',
        );
      } finally {
        connection.close();
        await proxy.close();
        await local.close();
        await host.dispose();
      }
    },
  );

  test(
    'incremental transport remains owner-only and shares the bounded resource quota',
    () async {
      final old = await DeviceCredentialFixture.create();
      try {
        await expectLater(
          LibraryIncrementalClient.connect(old.owner),
          throwsA(
            isA<RemoteFailure>().having(
              (e) => e.code,
              'code',
              'unsupported_sync',
            ),
          ),
        );
      } finally {
        await old.dispose();
      }
      final host = await DeviceCredentialFixture.create(replication: true);
      try {
        final raw = HttpClient(context: host.trust);
        try {
          final request = await raw.getUrl(
            host.owner.address.resolve(
              '${LibraryReplicationClient.base}/changes',
            ),
          );
          request.headers.set(
            'authorization',
            'Bearer ${host.profiles.first.deviceToken}',
          );
          final response = await request.close();
          await response.drain<void>();
          expect(response.statusCode, 401);
        } finally {
          raw.close(force: true);
        }
        final remote = await LibraryIncrementalClient.connect(host.owner);
        await expectLater(
          host.owner.request(
            'POST',
            '${LibraryReplicationClient.base}/changes/feed',
            {'wireVersion': 2, 'cursor': -1, 'limit': 32},
          ),
          throwsA(
            isA<RemoteFailure>().having(
              (e) => e.code,
              'code',
              'invalid_request',
            ),
          ),
        );
        final a = await remote.prepareInitial('quota-a'),
            b = await remote.prepareInitial('quota-b');
        await expectLater(
          remote.prepareInitial('quota-c'),
          throwsA(
            isA<RemoteFailure>().having(
              (e) => e.code,
              'code',
              'sync_transfer_capacity',
            ),
          ),
        );
        await remote.transport.release(a.contents);
        await remote.transport.release(b.contents);
        final result = await remote.prepareInitial('quota-c');
        await remote.transport.release(result.contents);
      } finally {
        await host.dispose();
      }
    },
  );
}
