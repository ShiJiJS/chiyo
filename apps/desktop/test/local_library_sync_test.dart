@TestOn('!windows')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/local_library_sync.dart';
import 'package:info_desktop/local_library_sync_controller.dart';
import 'package:info_remote/connection_profile.dart';
import 'package:info_remote/local_library_configuration.dart';
import 'package:info_remote/owner_client.dart';
import 'package:info_storage/info_storage.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import '../../server/test/support/device_credential_fixture.dart';
import '../../server/test/support/owner_reply_proxy.dart';

class _Keys implements DatabaseKeyStore {
  List<int>? key;
  @override
  Future<List<int>?> read() async => key;
  @override
  Future<void> create(List<int> bytes) async => key = List.of(bytes);
}

class _Local {
  _Local(this.root, this.config);
  final Directory root;
  final LocalLibraryConfiguration config;
  final keys = _Keys();
  late EncryptedInformationRepository repo;
  late InformationService service;
  LocalLibrarySync get sync => LocalLibrarySync(
    configuration: config,
    owner: service.owner,
    replication: LibraryReplication(repo),
  );
  static Future<_Local> create() async {
    final root = await Directory.systemTemp.createTemp(
      'chiyo-sync-coordinator-',
    );
    final local = _Local(
      root,
      await LocalLibraryConfiguration.open('${root.path}/profile'),
    );
    await local.open();
    return local;
  }

  Future<void> open() async {
    repo = await EncryptedInformationRepository.open(
      config.libraryDirectory,
      keys,
    );
    service = InformationService(repository: repo);
  }

  Future<void> reopen() async {
    await service.close();
    await repo.close();
    await open();
  }

  Future<void> dispose() async {
    await service.close();
    await repo.close();
    await root.delete(recursive: true);
  }
}

ConnectionProfile _profile(DeviceCredentialFixture host, [Uri? address]) =>
    ConnectionProfile(
      address: (address ?? host.owner.address).toString(),
      token: host.token,
      certificate: host.certificate,
      serverId: host.owner.serverId,
    );

class _ManualTimer implements Timer {
  _ManualTimer(this.action);
  final void Function(Timer) action;
  @override
  bool isActive = true;
  @override
  int tick = 0;
  void fire() {
    if (!isActive) return;
    tick++;
    action(this);
  }

  @override
  void cancel() => isActive = false;
}

void main() {
  test(
    'App restart resumes an interrupted encrypted delta upload from the confirmed byte offset',
    () async {
      final host = await DeviceCredentialFixture.create(replication: true);
      final local = await _Local.create();
      final proxy = await OwnerReplyProxy.start(
        tls: host.tls,
        trust: host.trust,
        target: () => host.owner.address,
        serverId: host.owner.serverId,
      );
      try {
        await local.sync.connect(_profile(host, proxy.address));
        final input = File('${local.root.path}/synthetic-original.bin');
        await input.writeAsBytes(
          List.generate(1024 * 1024 + 37, (i) => i % 251),
        );
        final owner = local.service.owner;
        final draft = await owner.beginInformationFileDraft();
        try {
          final file = await owner.stageInformationFile(draft, input.path);
          await owner.commitInformationDraft(
            draft,
            'delta-original',
            InformationDraftInput(
              name: '断线上传的合成文件',
              description: '',
              fields: [InformationDraftField.stagedFile('原文', '', file.id)],
            ),
          );
        } finally {
          await owner.releaseInformationFileDraft(draft);
        }
        int uploadWrites() => proxy.requests.entries
            .where(
              (e) =>
                  e.key.endsWith('/write') &&
                  !e.key.endsWith('/baseline/write'),
            )
            .fold(0, (n, e) => n + e.value);
        final priorWrites = uploadWrites();
        var dropped = false;
        proxy.beforeReply = (path) async {
          if (!dropped &&
              path.contains('/replication/transfers/') &&
              path.endsWith('/write') &&
              !path.endsWith('/baseline/write')) {
            dropped = true;
            proxy.dropNextPath = path;
          }
        };
        await expectLater(
          local.sync.synchronize(),
          throwsA(isA<RemoteFailure>()),
        );
        expect(dropped, true);
        final pending = (await local.sync.readConfiguration())['delta'] as Map;
        final archive = File(
          '${local.config.directory}/replication-staging/${pending['fileId']}/content.encrypted',
        );
        final byteLength = await archive.length();
        expect(byteLength, greaterThan(512 * 1024));
        expect(host.repo.items, isEmpty);
        await local.reopen();
        expect((await local.sync.synchronize()).uploaded, 1);
        expect(host.repo.items, hasLength(1));
        expect(
          await host.runtime.run(
            () => host.repo.readInformationAttachmentChunk(
              host.repo.items.single.fields.single.attachment!,
              0,
              64,
            ),
          ),
          List.generate(64, (i) => i % 251),
        );
        expect(
          uploadWrites() - priorWrites,
          (byteLength / (512 * 1024)).ceil(),
        );
        expect((await local.sync.readConfiguration())['delta'], isNull);
        expect(await archive.exists(), false);
      } finally {
        await proxy.close();
        await local.dispose();
        await host.dispose();
      }
    },
  );

  test(
    'App sync reports a held conflict and still receives unrelated records',
    () async {
      final host = await DeviceCredentialFixture.create(replication: true);
      final a = await _Local.create(), b = await _Local.create();
      try {
        final original = await host.runtime.run(
          () => host.runtime.service.owner.createInformation('双方共同资料', '', [
            const FieldInput('正文', '', 'SYNTHETIC_BASE'),
          ]),
        );
        await a.sync.connect(_profile(host));
        await b.sync.connect(_profile(host));
        final field = FieldRef(original.id, original.fields.single.id);
        await a.service.owner.correctValue(field, 'SYNTHETIC_A_EDIT');
        await b.service.owner.correctValue(field, 'SYNTHETIC_B_EDIT');
        await a.sync.synchronize();
        expect((await b.sync.synchronize()).needsReview, true);
        expect(host.repo.items.single.fields.single.value, 'SYNTHETIC_A_EDIT');
        expect(b.repo.items.single.fields.single.value, 'SYNTHETIC_B_EDIT');
        expect((await a.sync.synchronize()).needsReview, true);
        await host.runtime.run(
          () => host.runtime.service.owner.createInformation('不依赖冲突的资料', '', [
            const FieldInput('正文', '', 'SYNTHETIC_UNRELATED'),
          ]),
        );
        expect((await b.sync.synchronize()).downloaded, 1);
        expect(b.repo.items, hasLength(2));
        expect(
          b.repo.items
              .singleWhere((item) => item.id == original.id)
              .fields
              .single
              .value,
          'SYNTHETIC_B_EDIT',
        );
        await b.reopen();
        expect((await b.sync.synchronize()).needsReview, true);
        expect(b.repo.items, hasLength(2));
      } finally {
        await a.dispose();
        await b.dispose();
        await host.dispose();
      }
    },
  );

  test(
    'startup, timer and manual sync share one real pass; settings and disposal stop scheduled work',
    () async {
      final host = await DeviceCredentialFixture.create(replication: true);
      final local = await _Local.create();
      LocalLibrarySyncController? controller;
      try {
        final sync = local.sync;
        await sync.connect(_profile(host));
        final timers = <_ManualTimer>[];
        controller = LocalLibrarySyncController(
          sync: sync,
          changed: () {},
          clock: () => DateTime.utc(2026, 11, 11),
          schedule: (interval, action) {
            expect(interval, const Duration(minutes: 1));
            final timer = _ManualTimer(action);
            timers.add(timer);
            return timer;
          },
        );
        await controller.restore();
        await controller.synchronize();
        expect(controller.updatedAt, DateTime.utc(2026, 11, 11));
        expect(controller.enabled, true);
        expect(timers, hasLength(1));
        await local.service.owner.createInformation('定时同步新增', '', [
          const FieldInput('正文', '', 'SYNTHETIC_TIMER'),
        ]);
        timers.single.fire();
        final first = controller.synchronize(),
            duplicate = controller.synchronize();
        expect(identical(first, duplicate), true);
        await first;
        expect(host.repo.items, hasLength(1));
        await controller.pause();
        expect(timers.single.isActive, false);
        await local.service.owner.createInformation('暂停时保留本地', '', [
          const FieldInput('正文', '', 'SYNTHETIC_PAUSE'),
        ]);
        timers.single.fire();
        await controller.synchronize();
        expect(host.repo.items, hasLength(1));
        await sync.disable();
        await controller.restore();
        expect(controller.enabled, false);
        expect(timers, hasLength(1));
        // Re-enabling an empty or populated link keeps the same initial copy.
        final snapshot = (await sync.readConfiguration())['initialSnapshotId'];
        await sync.connect(_profile(host));
        expect((await sync.readConfiguration())['initialSnapshotId'], snapshot);
        await controller.restore();
        await controller.synchronize();
        expect(host.repo.items, hasLength(2));
        expect(timers, hasLength(2));
        controller.dispose();
        controller = null;
        expect(timers.last.isActive, false);
      } finally {
        controller?.dispose();
        await local.dispose();
        await host.dispose();
      }
    },
  );

  test(
    'failed background sync keeps local contents and recovers on the next scheduled pass',
    () async {
      final host = await DeviceCredentialFixture.create(replication: true);
      final local = await _Local.create();
      final proxy = await OwnerReplyProxy.start(
        tls: host.tls,
        trust: host.trust,
        target: () => host.owner.address,
        serverId: host.owner.serverId,
      );
      LocalLibrarySyncController? controller;
      try {
        final sync = local.sync;
        await sync.connect(_profile(host, proxy.address));
        await local.service.owner.createInformation('断网仍保留资料', '', [
          const FieldInput('正文', '', 'SYNTHETIC_RECOVER'),
        ]);
        late _ManualTimer timer;
        controller = LocalLibrarySyncController(
          sync: sync,
          changed: () {},
          schedule: (_, action) => timer = _ManualTimer(action),
        );
        proxy.failGetPrefix = '/v1/';
        await controller.restore();
        await expectLater(
          controller.synchronize(),
          throwsA(isA<RemoteFailure>()),
        );
        expect(controller.failure, isA<RemoteFailure>());
        expect(controller.updatedAt, isNull);
        expect(local.repo.items, hasLength(1));
        expect(host.repo.items, isEmpty);
        proxy.failGetPrefix = null;
        timer.fire();
        await controller.synchronize();
        expect(controller.failure, isNull);
        expect(controller.updatedAt, isNotNull);
        expect(host.repo.items, hasLength(1));
      } finally {
        controller?.dispose();
        await proxy.close();
        await local.dispose();
        await host.dispose();
      }
    },
  );

  test(
    'the App synchronizes both directions from independent durable cursors without replaying its initial snapshot',
    () async {
      final host = await DeviceCredentialFixture.create(replication: true);
      final a = await _Local.create(), b = await _Local.create();
      sqlite.Database? observerA, observerServer;
      try {
        final syncA = a.sync;
        await a.service.owner.exportLibrary(syncA.incremental.start);
        await a.service.owner.createInformation('初始资料一', '', [
          const FieldInput('正文', '', 'INITIAL_ONE'),
        ]);
        await a.service.owner.createInformation('初始资料二', '', [
          const FieldInput('正文', '', 'INITIAL_TWO'),
        ]);
        await syncA.connect(_profile(host));
        final saved = await syncA.readConfiguration();
        final peer = saved['remoteReplicaId'] as String;
        expect(await syncA.incremental.progress(peer, outgoing: true), 2);
        expect(await syncA.incremental.progress(peer), 0);
        expect(host.repo.items, hasLength(2));
        await b.sync.connect(_profile(host));
        await a.service.owner.createInformation('A 的离线新增', '', [
          const FieldInput('正文', '', 'OFFLINE_A'),
        ]);
        final fromA = await syncA.synchronize();
        expect(fromA.uploaded, 1);
        expect(fromA.downloaded, 0);
        expect(host.repo.items, hasLength(3));
        final fromServer = await b.sync.synchronize();
        expect(fromServer.downloaded, 1);
        expect(b.repo.items, hasLength(3));
        await host.runtime.run(
          () => host.runtime.service.owner.createInformation('服务器新增', '', [
            const FieldInput('正文', '', 'SERVER_NEW'),
          ]),
        );
        await b.service.owner.createInformation('B 的本地新增', '', [
          const FieldInput('正文', '', 'LOCAL_B'),
        ]);
        final fromB = await b.sync.synchronize();
        expect(fromB.uploaded, 1);
        expect(fromB.downloaded, 1);
        expect(b.repo.items, hasLength(5));
        await a.reopen();
        final afterRestart = await a.sync.synchronize();
        expect(afterRestart.downloaded, 2);
        expect(a.repo.items, hasLength(5));
        expect(host.repo.items, hasLength(5));
        // Catch up acknowledgement of already-known server operations once.
        await a.sync.synchronize();
        await b.sync.synchronize();
        observerA = sqlite.sqlite3.open(
          '${a.config.libraryDirectory}/library.db',
        );
        observerA.execute(
          'PRAGMA key = "x\'${a.keys.key!.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}\'"',
        );
        final serverKey = await File(
          '${host.root.path}/secrets/database.key',
        ).readAsBytes();
        observerServer = sqlite.sqlite3.open(
          '${host.root.path}/data/library.db',
        );
        observerServer.execute(
          'PRAGMA key = "x\'${serverKey.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}\'"',
        );
        final beforeA = observerA
            .select('PRAGMA data_version')
            .single
            .values
            .single;
        final beforeServer = observerServer
            .select('PRAGMA data_version')
            .single
            .values
            .single;
        for (var i = 0; i < 3; i++) {
          final idle = await a.sync.synchronize();
          expect(
            (idle.uploaded, idle.downloaded, idle.needsReview),
            (0, 0, false),
          );
        }
        expect(
          observerA.select('PRAGMA data_version').single.values.single,
          beforeA,
        );
        expect(
          observerServer.select('PRAGMA data_version').single.values.single,
          beforeServer,
        );
        expect(
          await Directory(
            '${a.config.directory}/replication-staging',
          ).list().length,
          0,
        );
        await a.sync.disable();
        await a.service.owner.createInformation('关闭同步后的本地资料', '', [
          const FieldInput('正文', '', 'STAYS_LOCAL'),
        ]);
        expect((await a.sync.synchronize()).uploaded, 0);
        expect(host.repo.items, hasLength(5));
        await a.sync.connect(_profile(host));
        expect((await a.sync.synchronize()).uploaded, 1);
        expect(host.repo.items, hasLength(6));
      } finally {
        observerA?.close();
        observerServer?.close();
        await a.dispose();
        await b.dispose();
        await host.dispose();
      }
    },
  );

  test(
    'a lost delta commit reply is reconciled after both processes restart without the encrypted file',
    () async {
      final host = await DeviceCredentialFixture.create(replication: true);
      final local = await _Local.create();
      final proxy = await OwnerReplyProxy.start(
        tls: host.tls,
        trust: host.trust,
        target: () => host.owner.address,
        serverId: host.owner.serverId,
      );
      try {
        await local.sync.connect(_profile(host, proxy.address));
        await local.service.owner.createInformation('断线后核对同一新增', '', [
          const FieldInput('正文', '', 'SYNTHETIC_DELTA_RETRY'),
        ]);
        var dropped = false;
        proxy.beforeReply = (path) async {
          if (!dropped &&
              path.contains('/replication/transfers/') &&
              path.endsWith('/commit')) {
            dropped = true;
            proxy.dropNextPath = path;
          }
        };
        await expectLater(
          local.sync.synchronize(),
          throwsA(isA<RemoteFailure>()),
        );
        expect(dropped, true);
        expect(host.repo.items, hasLength(1));
        final pending = (await local.sync.readConfiguration())['delta'] as Map;
        final original = File(
          '${local.config.directory}/replication-staging/${pending['fileId']}/content.encrypted',
        );
        await original.delete();
        await local.reopen();
        await host.reopen();
        final resumed = await local.sync.synchronize();
        expect(resumed.uploaded, 1);
        expect((await local.sync.readConfiguration())['delta'], isNull);
        expect(host.repo.items, hasLength(1));
        expect(local.repo.items, hasLength(1));
        expect((await local.sync.synchronize()).uploaded, 0);
      } finally {
        await proxy.close();
        await local.dispose();
        await host.dispose();
      }
    },
  );

  test(
    'an interrupted pull restarts safely when both App and server processes reopen',
    () async {
      final host = await DeviceCredentialFixture.create(replication: true);
      final local = await _Local.create();
      final proxy = await OwnerReplyProxy.start(
        tls: host.tls,
        trust: host.trust,
        target: () => host.owner.address,
        serverId: host.owner.serverId,
      );
      var reads = 0;
      proxy.beforeReply = (path) async {
        if (path.contains('/replication/transfers/') &&
            path.endsWith('/read') &&
            !path.endsWith('/baseline/read') &&
            ++reads == 2) {
          proxy.dropNextPath = path;
        }
      };
      try {
        final item = await host.runtime.run(() async {
          final input = File('${host.root.path}/synthetic-large.bin');
          await input.writeAsBytes(
            List.generate(1024 * 1024 + 51, (i) => i % 251),
          );
          final owner = host.runtime.service.owner;
          final draft = await owner.beginInformationFileDraft();
          try {
            final file = await owner.stageInformationFile(draft, input.path);
            return await owner.commitInformationDraft(
              draft,
              'interrupted-pull-file',
              InformationDraftInput(
                name: '断线续传文件',
                description: '',
                fields: [InformationDraftField.stagedFile('原文', '', file.id)],
              ),
            );
          } finally {
            await owner.releaseInformationFileDraft(draft);
          }
        });
        final profile = _profile(host, proxy.address);
        await expectLater(
          local.sync.connect(profile),
          throwsA(isA<RemoteFailure>()),
        );
        final pending =
            (await local.sync.readConfiguration())['pending'] as Map;
        final partial = File(
          '${local.config.directory}/replication-staging/${pending['fileId']}/content.encrypted',
        );
        expect(await partial.length(), 512 * 1024);
        expect(local.repo.items, isEmpty);
        await local.reopen();
        await host.reopen();
        await local.sync.connect(profile);
        expect(local.repo.items.single.id, item.id);
        expect(
          await local.repo.readInformationAttachmentChunk(
            item.fields.single.attachment!,
            0,
            64,
          ),
          List.generate(64, (i) => i % 251),
        );
        expect((await local.sync.readConfiguration())['pending'], isNull);
        expect(host.repo.items.single.id, item.id);
      } finally {
        await proxy.close();
        await local.dispose();
        await host.dispose();
      }
    },
  );
  test(
    'the App coordinator resumes the exact durable push after process restart and lost commit reply',
    () async {
      final host = await DeviceCredentialFixture.create(replication: true);
      final local = await _Local.create();
      final proxy = await OwnerReplyProxy.start(
        tls: host.tls,
        trust: host.trust,
        target: () => host.owner.address,
        serverId: host.owner.serverId,
      );
      var dropped = false;
      proxy.beforeReply = (path) async {
        if (!dropped &&
            path.contains('/replication/transfers/') &&
            path.endsWith('/commit')) {
          dropped = true;
          proxy.dropNextPath = path;
        }
      };
      try {
        await local.service.owner.createInformation('合成 App 上传', '', [
          const FieldInput('正文', '', 'SYNTHETIC_COORDINATOR_UPLOAD'),
        ]);
        final profile = _profile(host, proxy.address);
        await expectLater(
          local.sync.connect(profile),
          throwsA(isA<RemoteFailure>()),
        );
        expect(dropped, true);
        final pending = await local.sync.readConfiguration();
        expect(pending['enabled'], false);
        expect(pending['pending'], isA<Map>());
        expect(
          host.repo.items.single.fields.single.value,
          'SYNTHETIC_COORDINATOR_UPLOAD',
        );
        final commits = proxy.requests.entries
            .where((e) => e.key.endsWith('/commit'))
            .fold(0, (n, e) => n + e.value);
        await local.reopen();
        await host.reopen();
        await local.sync.connect(profile);
        final saved = await local.sync.readConfiguration();
        expect(saved['enabled'], true);
        expect(saved['pending'], isNull);
        expect(saved['server']['serverId'], profile.serverId);
        expect(host.repo.items, hasLength(1));
        expect(local.repo.items, hasLength(1));
        expect(
          proxy.requests.entries
              .where((e) => e.key.endsWith('/commit'))
              .fold(0, (n, e) => n + e.value),
          commits,
        );
        expect(
          await Directory(
            '${local.config.directory}/replication-staging',
          ).list().length,
          0,
        );
        proxy.failGetPrefix = '/v1/';
        final requests = jsonEncode(proxy.requests);
        await local.sync.disable();
        expect((await local.sync.readConfiguration())['enabled'], false);
        expect(jsonEncode(proxy.requests), requests);
        expect(host.repo.items, hasLength(1));
        expect(local.repo.items, hasLength(1));
      } finally {
        await proxy.close();
        await local.dispose();
        await host.dispose();
      }
    },
  );

  test(
    'the App can finish the first server pull directly into usable local mode',
    () async {
      final host = await DeviceCredentialFixture.create(replication: true);
      final local = await _Local.create();
      try {
        final item = await host.runtime.run(
          () => host.runtime.service.owner.createInformation('原服务器资料', '', [
            const FieldInput('正文', '', 'SYNTHETIC_COORDINATOR_PULL'),
          ]),
        );
        await local.sync.connect(_profile(host), enabled: false);
        expect(local.repo.items.single.id, item.id);
        expect((await local.sync.readConfiguration())['enabled'], false);
        await local.reopen();
        expect(
          local.repo.items.single.fields.single.value,
          'SYNTHETIC_COORDINATOR_PULL',
        );
        await local.service.owner.createInformation('本地继续编辑', '', [
          const FieldInput('正文', '', 'SYNTHETIC_LOCAL_ONLY'),
        ]);
        expect(local.repo.items, hasLength(2));
        expect(host.repo.items, hasLength(1));
      } finally {
        await local.dispose();
        await host.dispose();
      }
    },
  );

  test(
    'two different nonempty libraries and a wrong server identity preserve both sides',
    () async {
      final host = await DeviceCredentialFixture.create(replication: true);
      final local = await _Local.create();
      try {
        await host.runtime.run(
          () => host.runtime.service.owner.createInformation('服务器原资料', '', [
            const FieldInput('正文', '', 'SYNTHETIC_REMOTE_ORIGINAL'),
          ]),
        );
        await local.service.owner.createInformation('本地原资料', '', [
          const FieldInput('正文', '', 'SYNTHETIC_LOCAL_ORIGINAL'),
        ]);
        final profile = _profile(host);
        await expectLater(
          local.sync.connect(profile),
          throwsA(
            isA<RemoteFailure>().having(
              (e) => e.code,
              'code',
              'different_libraries',
            ),
          ),
        );
        await expectLater(
          local.sync.connect(
            ConnectionProfile(
              address: profile.address,
              token: profile.token,
              certificate: profile.certificate,
              serverId: 'wrong-server-identity',
            ),
          ),
          throwsA(
            isA<RemoteFailure>().having(
              (e) => e.code,
              'code',
              'server_changed',
            ),
          ),
        );
        expect(
          local.repo.items.single.fields.single.value,
          'SYNTHETIC_LOCAL_ORIGINAL',
        );
        expect(
          host.repo.items.single.fields.single.value,
          'SYNTHETIC_REMOTE_ORIGINAL',
        );
        expect((await local.sync.readConfiguration())['pending'], isNull);
      } finally {
        await local.dispose();
        await host.dispose();
      }
    },
  );
}
