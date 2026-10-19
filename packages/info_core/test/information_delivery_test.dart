import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:info_core/info_core.dart';
import 'package:info_core/agent_server.dart';
import 'package:test/test.dart';

class _Files implements InformationDeliveryFiles {
  _Files(this.root);
  final Directory root;
  int reserved = 0, written = 0, cleaned = 0;
  bool cleanupBlocked = false, writeFails = false;
  Future<void> Function()? beforeWrite;
  Future<void> Function()? afterVerify;
  Future<void> Function(InformationDeliveryLease)? beforeCleanup;
  final known = <String, InformationDeliveryLease>{};
  @override
  Future<InformationDeliveryLease> reserve(String name) async {
    final dir = await Directory('${root.path}/copy-${++reserved}').create();
    final lease = InformationDeliveryLease(
      dir.path,
      'dir-$reserved',
      name,
      'file-$reserved',
    );
    known[lease.path] = lease;
    await File(lease.filePath).create(exclusive: true);
    return lease;
  }

  @override
  Future<void> write(InformationDeliveryLease lease, Uint8List bytes) async {
    await beforeWrite?.call();
    written++;
    await File(
      lease.filePath,
    ).writeAsBytes(writeFails ? bytes.take(1).toList() : bytes, flush: true);
    if (writeFails) throw StateError('synthetic partial write');
  }

  @override
  Future<void> verify(
    InformationDeliveryLease lease,
    int size,
    String hash,
  ) async {
    if (known[lease.path]?.fileIdentity != lease.fileIdentity) {
      throw const RuntimeMaterialFailure('identity_mismatch');
    }
    final bytes = await File(lease.filePath).readAsBytes();
    if (bytes.length != size || sha256.convert(bytes).toString() != hash) {
      throw const RuntimeMaterialFailure('integrity_failed');
    }
    await afterVerify?.call();
  }

  @override
  Future<void> cleanup(InformationDeliveryLease lease) async {
    await beforeCleanup?.call(lease);
    if (cleanupBlocked) throw const RuntimeMaterialFailure('cleanup_failed');
    if (known[lease.path]?.fileIdentity != lease.fileIdentity) {
      throw const RuntimeMaterialFailure('identity_mismatch');
    }
    final file = File(lease.filePath);
    if (await file.exists()) {
      await file.delete();
    }
    if (await Directory(lease.path).exists()) {
      await Directory(lease.path).delete();
    }
    cleaned++;
  }
}

class _Repository extends MemoryInformationRepository {
  bool fails = false;
  Future<void> Function(InformationFileDelivery)? beforeSave;
  @override
  Future<void> saveInformationFileDelivery(
    InformationFileDelivery value,
  ) async {
    await beforeSave?.call(value);
    if (fails) throw StateError('synthetic delivery audit failure');
    await super.saveInformationFileDelivery(value);
  }
}

class _NoFileGetterRepository extends MemoryInformationRepository {
  @override
  List<InformationFileDelivery> get informationFileDeliveries =>
      throw StateError('file registry unavailable');
}

Matcher fails(String code) =>
    throwsA(isA<InformationFileFailure>().having((e) => e.code, 'code', code));
InformationFileFetchInput fetch(
  String request,
  InformationItem item,
  String op, {
  int field = 1,
}) => InformationFileFetchInput.fromJson({
  'protocolVersion': 2,
  'command': 'file-fetch',
  'requestId': request,
  'itemId': item.id,
  'fieldId': item.fields[field].id,
  'operationId': op,
});
Map<String, dynamic> delivery(Map<String, Object?> reply) =>
    Map<String, dynamic>.from(reply['delivery'] as Map);
void main() {
  late Directory root;
  late _Files files;
  late _Repository repo;
  late InformationService service;
  late DateTime now;
  late InformationItem item;
  late String session, request;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('file-delivery-core-');
    files = _Files(root);
    repo = _Repository();
    now = DateTime.utc(2026, 10, 19);
    service = InformationService(
      repository: repo,
      clock: () => now,
      informationDeliveryFiles: files,
    );
    final source = File('${root.path}/private resume.pdf');
    await source.writeAsBytes([0, 255, 7]);
    final draft = await service.owner.beginInformationFileDraft();
    final stage = await service.owner.stageInformationFile(draft, source.path);
    final other = await service.owner.stageInformationFile(draft, source.path);
    item = await service.owner.commitInformationDraft(
      draft,
      'save',
      InformationDraftInput(
        name: '求职资料',
        description: '',
        fields: [
          const InformationDraftField.text('姓名', '', '虚构姓名'),
          InformationDraftField.stagedFile('简历', '', stage.id),
          InformationDraftField.stagedFile('其他文件', '', other.id),
        ],
      ),
    );
    await service.owner.releaseInformationFileDraft(draft);
    session = service.agent.openSession('虚构聊天');
    request = service.agent
        .request(
          session,
          '填写简历',
          item.fields.map((f) => FieldRef(item.id, f.id)).toList(),
        )
        .id;
  });
  tearDown(() async {
    files.cleanupBlocked = false;
    repo.fails = false;
    repo.beforeSave = null;
    files.beforeWrite = null;
    files.afterVerify = null;
    files.beforeCleanup = null;
    await service.close();
    await root.delete(recursive: true);
  });
  Future<void> approve({Duration lifetime = const Duration(hours: 8)}) async {
    service.owner.approve(
      request,
      item.fields.take(2).map((f) => FieldRef(item.id, f.id)).toList(),
      lifetime: lifetime,
    );
    await service.owner.retryAuditStorage();
  }

  test(
    'operation query observes a pending copy without waiting for IO or creating another operation',
    () async {
      await approve();
      final writing = Completer<void>(), resume = Completer<void>();
      files.beforeWrite = () async {
        writing.complete();
        await resume.future;
      };
      final work = service.agent.fetchInformationFile(
        session,
        fetch(request, item, 'original'),
      );
      try {
        await writing.future;
        final facts = delivery(
          service.agent.informationFileOperationStatus(session, 'original'),
        );
        expect(facts['state'], 'preparing');
        expect(facts, isNot(contains('path')));
        final other = service.agent.openSession('另一个会话');
        expect(
          () => service.agent.informationFileOperationStatus(other, 'original'),
          fails('delivery_not_found'),
        );
        expect(files.reserved, 1);
        expect(files.written, 0);
      } finally {
        resume.complete();
      }
      final ready = delivery(await work);
      expect(
        delivery(
          service.agent.informationFileOperationStatus(session, 'original'),
        )['deliveryId'],
        ready['deliveryId'],
      );
      expect(files.written, 1);
    },
  );
  test(
    'HTTP file capability is explicit and strict private routes preserve mixed partial approval',
    () async {
      final server = await AgentServer.start(
        service.agent,
        port: 0,
        enableReusableCredentialUse: true,
        enableInformationFiles: true,
      );
      final http = HttpClient();
      addTearDown(() async {
        http.close(force: true);
        await server.close();
      });
      Future<Map<String, dynamic>> call(String path, Object body) async {
        final req = await http.post('127.0.0.1', server.port, path);
        req.headers.contentType = ContentType.json;
        req.write(body is String ? body : jsonEncode(body));
        final response = await req.close();
        return jsonDecode(await utf8.decoder.bind(response).join())
            as Map<String, dynamic>;
      }

      expect(
        (await call('/capabilities', {}))['capabilities'],
        contains('information-attachments.v1'),
      );
      expect((await call('/catalog', {}))['status'], 'unsupported_capability');
      final catalog = await call('/catalog', {'protocolVersion': 2});
      expect(catalog['status'], 'ok');
      expect(jsonEncode(catalog), isNot(contains('private resume')));
      expect(jsonEncode(catalog), isNot(contains('sha256')));
      final input = fetch(request, item, 'http').toJson();
      expect(
        (await call('/information-file/fetch', {
          ...input,
          'sessionSecret': session,
        }))['errorCode'],
        'not_authorized',
      );
      await approve();
      final fetched = await call('/information-file/fetch', {
        ...input,
        'sessionSecret': session,
      });
      expect(fetched['status'], 'ok');
      final facts = await call('/information-file/status', {
        'protocolVersion': 2,
        'command': 'file-status',
        'operationId': 'http',
        'sessionSecret': session,
      });
      expect((facts['delivery'] as Map)['state'], 'ready');
      expect(jsonEncode(facts), isNot(contains('path')));
      final other = service.agent.openSession('其他聊天');
      expect(
        (await call('/information-file/status', {
          'protocolVersion': 2,
          'command': 'file-status',
          'operationId': 'http',
          'sessionSecret': other,
        }))['status'],
        'not_found',
      );
      expect(
        (await call('/information-file/fetch', {
          ...input,
          'sessionSecret': session,
          'path': root.path,
        }))['errorCode'],
        'invalid_request',
      );
      final repeated = jsonEncode({...input, 'sessionSecret': session})
          .replaceFirst(
            '"operationId":"http"',
            '"operationId":"http","operationId":"other"',
          );
      expect(
        (await call('/information-file/fetch', repeated))['errorCode'],
        'invalid_json',
      );
      expect(files.written, 1);
      expect(
        (await call('/information-file/fetch', {
          ...fetch(request, item, 'outside', field: 2).toJson(),
          'sessionSecret': session,
        }))['errorCode'],
        'not_authorized',
      );
      final disabled = await AgentServer.start(
        service.agent,
        port: 0,
        enableReusableCredentialUse: true,
      );
      addTearDown(disabled.close);
      final req = await http.post('127.0.0.1', disabled.port, '/capabilities');
      req.headers.contentType = ContentType.json;
      req.write('{}');
      final caps =
          jsonDecode(await utf8.decoder.bind(await req.close()).join()) as Map;
      expect(
        caps['capabilities'],
        isNot(contains('information-attachments.v1')),
      );
    },
  );
  test(
    'unapproved and out-of-scope fetch reject without private metadata or filesystem effects',
    () async {
      await expectLater(
        service.agent.fetchInformationFile(
          session,
          fetch(request, item, 'before'),
        ),
        fails('not_authorized'),
      );
      await approve();
      await expectLater(
        service.agent.fetchInformationFile(
          session,
          fetch(request, item, 'other', field: 2),
        ),
        fails('not_authorized'),
      );
      expect(files.reserved, 0);
      expect(repo.informationFileDeliveries, isEmpty);
      expect(
        jsonEncode(const InformationFileFailure('not_authorized').toJson()),
        isNot(contains('private resume')),
      );
    },
  );
  test(
    'disabled delivery never reads its optional registry during revoke or repeated shutdown',
    () async {
      final other = InformationService(repository: _NoFileGetterRepository());
      final info = await other.owner.createInformation('文本', '', [
        const FieldInput('字段', '', '内容'),
      ]);
      final s = other.agent.openSession('普通聊天');
      final id = other.agent.request(s, '读取', [
        FieldRef(info.id, info.fields.single.id),
      ]).id;
      other.owner.approve(id, [FieldRef(info.id, info.fields.single.id)]);
      other.owner.revoke(id);
      await other.close();
      await other.close();
    },
  );
  test(
    'one mixed approval permits text read and repeated fixed file copies within the original deadline',
    () async {
      await approve();
      final grant = service.agent.claim(session, request);
      expect(
        await service.agent.read(
          grant.token,
          FieldRef(item.id, item.fields.first.id),
        ),
        '虚构姓名',
      );
      await expectLater(
        service.agent.read(grant.token, FieldRef(item.id, item.fields[1].id)),
        throwsA(
          isA<AccessFailure>().having(
            (e) => e.status,
            'status',
            'file_delivery_required',
          ),
        ),
      );
      final first = delivery(
        await service.agent.fetchInformationFile(
          session,
          fetch(request, item, 'one'),
        ),
      );
      final again = delivery(
        await service.agent.fetchInformationFile(
          session,
          fetch(request, item, 'one'),
        ),
      );
      final second = delivery(
        await service.agent.fetchInformationFile(
          session,
          fetch(request, item, 'two'),
        ),
      );
      expect(first['path'], again['path']);
      expect(first['deliveryId'], again['deliveryId']);
      expect(second['path'], isNot(first['path']));
      expect(first['expiresAt'], grant.expiresAt.toIso8601String());
      expect(second['expiresAt'], first['expiresAt']);
      expect(await File(first['path'] as String).readAsBytes(), [0, 255, 7]);
      expect(files.reserved, 2);
      expect(files.written, 2);
      final facts = await service.agent.informationFileStatus(
        session,
        first['deliveryId'] as String,
      );
      expect(jsonEncode(facts), isNot(contains(root.path)));
      expect(jsonEncode(facts), isNot(contains('sha256')));
      expect(jsonEncode(facts), isNot(contains('private resume')));
      expect(
        jsonEncode(
          service.owner.informationFileDeliveries
              .map((r) => r.historyJson())
              .toList(),
        ),
        isNot(contains(root.path)),
      );
    },
  );
  test(
    'same operation with different input conflicts and another session cannot inspect or release',
    () async {
      await approve();
      final first = delivery(
        await service.agent.fetchInformationFile(
          session,
          fetch(request, item, 'same'),
        ),
      );
      await expectLater(
        service.agent.fetchInformationFile(
          session,
          fetch(request, item, 'same', field: 0),
        ),
        fails('operation_conflict'),
      );
      final other = service.agent.openSession('另一个聊天');
      await expectLater(
        service.agent.informationFileStatus(
          other,
          first['deliveryId'] as String,
        ),
        fails('not_authorized'),
      );
      await expectLater(
        service.agent.releaseInformationFile(
          other,
          first['deliveryId'] as String,
        ),
        fails('not_authorized'),
      );
      expect(files.reserved, 1);
    },
  );
  test(
    'replacement affects new operations while duplicate operation keeps its original bytes and version',
    () async {
      await approve();
      final first = delivery(
        await service.agent.fetchInformationFile(
          session,
          fetch(request, item, 'old'),
        ),
      );
      final source = File('${root.path}/updated.pdf');
      await source.writeAsBytes([9, 8]);
      final draft = await service.owner.beginInformationFileDraft();
      final stage = await service.owner.stageInformationFile(
        draft,
        source.path,
      );
      await service.owner.commitInformationDraft(
        draft,
        'replace',
        InformationDraftInput(
          name: item.name,
          description: '',
          itemId: item.id,
          baseVersion: item.version,
          fields: [
            InformationDraftField.text(
              '姓名',
              '',
              '虚构姓名',
              fieldId: item.fields.first.id,
            ),
            InformationDraftField.stagedFile(
              '简历',
              '',
              stage.id,
              fieldId: item.fields[1].id,
            ),
            InformationDraftField.retainedFile(
              '其他文件',
              '',
              item.fields[2].attachment,
              fieldId: item.fields[2].id,
            ),
          ],
        ),
      );
      final duplicate = delivery(
        await service.agent.fetchInformationFile(
          session,
          fetch(request, item, 'old'),
        ),
      );
      final next = delivery(
        await service.agent.fetchInformationFile(
          session,
          fetch(request, item, 'new'),
        ),
      );
      expect(duplicate['path'], first['path']);
      expect(duplicate['attachmentVersion'], 1);
      expect(next['attachmentVersion'], 2);
      expect(await File(first['path'] as String).readAsBytes(), [0, 255, 7]);
      expect(await File(next['path'] as String).readAsBytes(), [9, 8]);
    },
  );
  test(
    'explicit release is idempotent and repeating the operation never recreates its file',
    () async {
      await approve();
      final first = delivery(
        await service.agent.fetchInformationFile(
          session,
          fetch(request, item, 'one'),
        ),
      );
      final id = first['deliveryId'] as String;
      expect(
        delivery(
          await service.agent.releaseInformationFile(session, id),
        )['state'],
        'released',
      );
      expect(
        delivery(
          await service.agent.releaseInformationFile(session, id),
        )['state'],
        'released',
      );
      final repeated = delivery(
        await service.agent.fetchInformationFile(
          session,
          fetch(request, item, 'one'),
        ),
      );
      expect(repeated['state'], 'released');
      expect(repeated.containsKey('path'), isFalse);
      expect(await File(first['path'] as String).exists(), isFalse);
      expect(files.reserved, 1);
      expect(
        delivery(
          await service.agent.fetchInformationFile(
            session,
            fetch(request, item, 'two'),
          ),
        )['state'],
        'ready',
      );
    },
  );
  test(
    'occupied cleanup remains pending and retries without recreating or claiming deletion',
    () async {
      await approve();
      final first = delivery(
        await service.agent.fetchInformationFile(
          session,
          fetch(request, item, 'one'),
        ),
      );
      files.cleanupBlocked = true;
      final pending = delivery(
        await service.agent.releaseInformationFile(
          session,
          first['deliveryId'] as String,
        ),
      );
      expect(pending['state'], 'cleanup_pending');
      expect(pending['errorCode'], 'cleanup_failed');
      expect(await File(first['path'] as String).exists(), isTrue);
      expect(
        delivery(
          await service.agent.fetchInformationFile(
            session,
            fetch(request, item, 'one'),
          ),
        )['state'],
        'cleanup_pending',
      );
      expect(files.reserved, 1);
      files.cleanupBlocked = false;
      expect(await service.owner.reconcileInformationFileDeliveries(), 0);
      expect(
        delivery(
          await service.agent.informationFileStatus(
            session,
            first['deliveryId'] as String,
          ),
        )['state'],
        'released',
      );
    },
  );
  for (final ending in ['revoke', 'expire', 'end', 'delete']) {
    test(
      '$ending latches authorization loss, cleans registered copies and never revives after clock rollback',
      () async {
        await approve(lifetime: const Duration(minutes: 1));
        final first = delivery(
          await service.agent.fetchInformationFile(
            session,
            fetch(request, item, 'one'),
          ),
        );
        switch (ending) {
          case 'revoke':
            service.owner.revoke(request);
          case 'expire':
            now = now.add(const Duration(minutes: 1));
            service.agent.status(session, request);
          case 'end':
            service.agent.endSession(session);
          case 'delete':
            await service.owner.deleteInformation(
              item.id,
              item.version,
              fieldId: item.fields[1].id,
            );
        }
        await service.agent.drainInformationFileDeliveries();
        await service.owner.reconcileInformationFileDeliveries();
        expect(await File(first['path'] as String).exists(), isFalse);
        final code = switch (ending) {
          'expire' => 'grant_expired',
          'end' => 'session_ended',
          'delete' => 'field_removed',
          _ => 'not_authorized',
        };
        now = now.subtract(const Duration(days: 1));
        await expectLater(
          service.agent.fetchInformationFile(
            session,
            fetch(request, item, 'one'),
          ),
          fails(code),
        );
        expect(files.reserved, 1);
      },
    );
  }
  test(
    'initial audit failure creates no copy and the same operation is retained as a failed receipt',
    () async {
      await approve();
      repo.fails = true;
      await expectLater(
        service.agent.fetchInformationFile(
          session,
          fetch(request, item, 'one'),
        ),
        fails('audit_failed'),
      );
      expect(files.reserved, 0);
      expect(files.written, 0);
      repo.fails = false;
      await service.owner.retryAuditStorage();
      expect(
        delivery(
          await service.agent.fetchInformationFile(
            session,
            fetch(request, item, 'one'),
          ),
        )['state'],
        'failed',
      );
      expect(files.reserved, 0);
    },
  );
  test(
    'ready audit failure never returns a path and cleans the already registered copy',
    () async {
      await approve();
      repo.beforeSave = (r) async {
        if (r.state == 'ready') {
          repo.fails = true;
        }
      };
      await expectLater(
        service.agent.fetchInformationFile(
          session,
          fetch(request, item, 'one'),
        ),
        fails('audit_failed'),
      );
      expect(files.reserved, 1);
      expect(files.written, 1);
      expect(service.owner.informationFileDeliveries.single.state, 'failed');
      expect(service.owner.informationFileDeliveries.single.lease, isNull);
      repo.beforeSave = null;
      repo.fails = false;
      await service.owner.retryAuditStorage();
      expect(repo.informationFileDeliveries.single.state, 'failed');
      expect(
        delivery(
          await service.agent.fetchInformationFile(
            session,
            fetch(request, item, 'one'),
          ),
        ).containsKey('path'),
        isFalse,
      );
    },
  );
  test(
    'a registry is saved while empty before writing and a final revocation audit wins before return',
    () async {
      await approve();
      final phases = <String>[];
      repo.beforeSave = (r) async {
        if (r.state == 'preparing' && r.lease != null) {
          expect(await File(r.lease!.filePath).length(), 0);
          phases.add('registered-empty');
        }
        if (r.state == 'ready') {
          phases.add('ready');
          service.owner.revoke(request);
        }
      };
      files.beforeWrite = () async {
        expect(repo.informationFileDeliveries.single.lease, isNotNull);
        phases.add('write');
      };
      await expectLater(
        service.agent.fetchInformationFile(
          session,
          fetch(request, item, 'one'),
        ),
        fails('not_authorized'),
      );
      expect(phases, ['registered-empty', 'write', 'ready']);
      expect(service.owner.informationFileDeliveries.single.lease, isNull);
    },
  );
  test(
    'partial write and later copy tampering fail without replaying the original operation',
    () async {
      await approve();
      files.writeFails = true;
      await expectLater(
        service.agent.fetchInformationFile(
          session,
          fetch(request, item, 'partial'),
        ),
        fails('delivery_io_failed'),
      );
      files.writeFails = false;
      final first = delivery(
        await service.agent.fetchInformationFile(
          session,
          fetch(request, item, 'good'),
        ),
      );
      await File(first['path'] as String).writeAsBytes([1, 2, 3]);
      await expectLater(
        service.agent.fetchInformationFile(
          session,
          fetch(request, item, 'good'),
        ),
        fails('attachment_integrity_failed'),
      );
      expect(
        delivery(
          await service.agent.fetchInformationFile(
            session,
            fetch(request, item, 'good'),
          ),
        )['state'],
        'failed',
      );
      expect(files.written, 2);
    },
  );
  test(
    'close during preparation never exposes a path and drains registered cleanup',
    () async {
      await approve();
      final entered = Completer<void>(), resume = Completer<void>();
      files.beforeWrite = () async {
        entered.complete();
        await resume.future;
      };
      final call = service.agent.fetchInformationFile(
        session,
        fetch(request, item, 'one'),
      );
      final check = expectLater(call, fails('service_unavailable'));
      await entered.future;
      final closing = service.close();
      resume.complete();
      await check;
      await closing;
      expect(service.owner.informationFileDeliveries.single.lease, isNull);
    },
  );
  test(
    'restart classifies unfinished records without replay and cleans known private leases',
    () async {
      await approve();
      final first = delivery(
        await service.agent.fetchInformationFile(
          session,
          fetch(request, item, 'one'),
        ),
      );
      final fresh = InformationService(
        repository: repo,
        clock: () => now,
        informationDeliveryFiles: files,
      );
      addTearDown(fresh.close);
      await fresh.owner.reconcileInformationFileDeliveries();
      expect(await File(first['path'] as String).exists(), isFalse);
      expect(repo.informationFileDeliveries.single.state, 'expired');
      await expectLater(
        fresh.agent.informationFileStatus(
          session,
          first['deliveryId'] as String,
        ),
        fails('not_authorized'),
      );
      expect(files.written, 1);
    },
  );
  test(
    'a second revocation arriving during cleanup is included in the drained work',
    () async {
      await approve();
      final a = delivery(
        await service.agent.fetchInformationFile(
          session,
          fetch(request, item, 'first-grant'),
        ),
      );
      final secondRequest = service.agent.request(session, '第二次用途', [
        FieldRef(item.id, item.fields[1].id),
      ]).id;
      service.owner.approve(secondRequest, [
        FieldRef(item.id, item.fields[1].id),
      ]);
      await service.owner.retryAuditStorage();
      final b = delivery(
        await service.agent.fetchInformationFile(
          session,
          fetch(secondRequest, item, 'second-grant'),
        ),
      );
      final entered = Completer<void>(), resume = Completer<void>();
      files.beforeCleanup = (lease) async {
        if (lease.filePath == b['path']) {
          if (!entered.isCompleted) {
            entered.complete();
          }
          await resume.future;
        }
      };
      service.owner.revoke(secondRequest);
      await entered.future;
      service.owner.revoke(request);
      resume.complete();
      await service.agent.drainInformationFileDeliveries();
      expect(await File(a['path'] as String).exists(), isFalse);
      expect(await File(b['path'] as String).exists(), isFalse);
    },
  );
  test(
    'typed commands and private receipts reject unknown or inconsistent fields and do not alias input maps',
    () async {
      final good = fetch(request, item, 'one').toJson();
      for (final change in <Map<String, Object?>>[
        {'protocolVersion': 1},
        {'protocolVersion': 2.0},
        {'extra': 'value'},
        {'operationId': 'bad\nvalue'},
        {'fieldId': ''},
      ]) {
        expect(
          () => InformationFileFetchInput.fromJson({...good, ...change}),
          throwsA(isA<InformationFileFailure>()),
        );
      }
      await approve();
      await service.agent.fetchInformationFile(
        session,
        fetch(request, item, 'one'),
      );
      final record = repo.informationFileDeliveries.single;
      for (final change in <Map<String, Object?>>[
        {'state': 'new-state'},
        {'fieldVersion': 0},
        {'runtime': false},
        {'state': 'released'},
        {'extra': 'value'},
      ]) {
        expect(
          () => InformationFileDelivery.fromPrivateJson({
            ...record.toPrivateJson(),
            ...change,
          }),
          throwsA(isA<InformationFileFailure>()),
        );
      }
      final copy = record.toPrivateJson();
      (copy['field'] as Map)['fieldName'] = '外部修改';
      (copy['lease'] as Map)['path'] = 'external';
      expect(record.field.fieldName, '简历');
      expect(record.lease!.path, isNot('external'));
    },
  );
  test(
    'bounded registered copies count pending cleanup against the quota',
    () async {
      await approve();
      for (var n = 0; n < informationDeliveryLimit; n++) {
        await service.agent.fetchInformationFile(
          session,
          fetch(request, item, 'op$n'),
        );
      }
      await expectLater(
        service.agent.fetchInformationFile(
          session,
          fetch(request, item, 'overflow'),
        ),
        fails('delivery_capacity'),
      );
      expect(files.reserved, informationDeliveryLimit);
      files.cleanupBlocked = true;
      await service.agent.releaseInformationFile(
        session,
        repo.informationFileDeliveries.first.id,
      );
      await expectLater(
        service.agent.fetchInformationFile(
          session,
          fetch(request, item, 'overflow'),
        ),
        fails('delivery_capacity'),
      );
      files.cleanupBlocked = false;
      await service.owner.reconcileInformationFileDeliveries();
      expect(
        delivery(
          await service.agent.fetchInformationFile(
            session,
            fetch(request, item, 'overflow'),
          ),
        )['state'],
        'ready',
      );
    },
  );
}
