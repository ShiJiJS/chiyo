@TestOn('!windows')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/local_library_sync.dart';
import 'package:info_remote/connection_profile.dart';
import 'package:info_remote/local_library_configuration.dart';
import 'package:info_remote/owner_client.dart';
import 'package:info_storage/info_storage.dart';

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

void main() {
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
