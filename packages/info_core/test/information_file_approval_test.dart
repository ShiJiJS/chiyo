import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';
import 'information_approval_access_test.dart' show DecisionRepository;

class _Copies implements InformationDeliveryFiles {
  final contents = <String, Uint8List>{};
  int sequence = 0;
  @override
  Future<InformationDeliveryLease> reserve(String name) async =>
      InformationDeliveryLease(
        '/synthetic/${++sequence}',
        'directory-$sequence',
        name,
        'file-$sequence',
      );
  @override
  Future<void> write(InformationDeliveryLease lease, Uint8List bytes) async {
    contents[lease.filePath] = Uint8List.fromList(bytes);
  }

  @override
  Future<void> verify(
    InformationDeliveryLease lease,
    int n,
    String digest,
  ) async {
    final bytes = contents[lease.filePath];
    if (bytes == null ||
        bytes.length != n ||
        sha256.convert(bytes).toString() != digest) {
      throw const RuntimeMaterialFailure('integrity_failed');
    }
  }

  @override
  Future<void> cleanup(InformationDeliveryLease lease) async {
    contents.remove(lease.filePath);
  }
}

void main() {
  late Directory root;
  late DecisionRepository repo;
  late InformationService service;
  late _Copies copies;
  late InformationItem item;
  late String session, request;
  late DateTime now;
  FieldRef file() => FieldRef(item.id, item.fields.last.id);
  FieldRef text() => FieldRef(item.id, item.fields.first.id);
  Future<InformationItem> seed(String body, {InformationItem? previous}) async {
    final input = File('${root.path}/synthetic.txt');
    await input.writeAsString(body);
    final draft = await service.owner.beginInformationFileDraft();
    try {
      final stage = await service.owner.stageInformationFile(
        draft,
        input.path,
        mediaType: 'text/plain',
      );
      return await service.owner.commitInformationDraft(
        draft,
        'seed',
        InformationDraftInput(
          name: '合成混合资料',
          description: '',
          itemId: previous?.id,
          baseVersion: previous?.version,
          fields: [
            InformationDraftField.text(
              '说明',
              '',
              'PRIVATE-TEXT',
              fieldId: previous?.fields.first.id,
            ),
            InformationDraftField.stagedFile(
              '文件',
              '',
              stage.id,
              fieldId: previous?.fields.last.id,
            ),
          ],
        ),
      );
    } finally {
      await service.owner.releaseInformationFileDraft(draft);
    }
  }

  InformationApprovalCommand command({
    String id = 'approve-file',
    Map<FieldRef, InformationAttachmentRef>? expected,
    List<FieldRef>? selected,
  }) => InformationApprovalCommand(
    operationId: id,
    requestId: request,
    action: InformationApprovalAction.approve,
    reviewToken: 'a' * 64,
    commandDigest: 'b' * 64,
    fields: selected ?? [text(), file()],
    itemVersions: {item.id: item.version},
    expectedFiles: expected ?? {file(): item.fields.last.attachment!},
  );
  InformationFileFetchInput fetch(String id) =>
      InformationFileFetchInput.fromJson({
        'protocolVersion': 2,
        'command': 'file-fetch',
        'requestId': request,
        'itemId': item.id,
        'fieldId': file().fieldId,
        'operationId': id,
      });
  Matcher failure(String code) =>
      throwsA(isA<AccessFailure>().having((e) => e.status, 'status', code));
  setUp(() async {
    root = await Directory.systemTemp.createTemp('file-approval-core-');
    repo = DecisionRepository();
    copies = _Copies();
    now = DateTime.utc(2026, 11, 1);
    service = InformationService(
      repository: repo,
      informationDeliveryFiles: copies,
      clock: () => now,
    );
    item = await seed('ORIGINAL-FILE');
    session = service.agent.openSession('合成文件聊天');
    request = service.agent.request(session, 'mixed', [text(), file()]).id;
    await service.owner.history();
  });
  tearDown(() async {
    repo.failLookup = false;
    if (!(repo.release?.isCompleted ?? true)) repo.release!.complete();
    await service.close();
    await root.delete(recursive: true);
  });

  test(
    'mixed atomic decision permits text and exact file delivery but never inline bytes',
    () async {
      final c = command();
      await service.owner.decideInformationRequest(c);
      final grant = service.agent.claim(session, request);
      expect(await service.agent.read(grant.token, text()), 'PRIVATE-TEXT');
      await expectLater(
        service.agent.read(grant.token, file()),
        failure('file_delivery_required'),
      );
      final delivered =
          (await service.agent.fetchInformationFile(
                session,
                fetch('copy'),
              ))['delivery']
              as Map;
      expect(utf8.decode(copies.contents[delivered['path']]!), 'ORIGINAL-FILE');
      final again = await service.owner.decideInformationRequest(c);
      expect(again.commandDigest, c.commandDigest);
      expect(repo.grantHistory.length, 1);
      expect(
        (await service.agent.fetchInformationFile(
          session,
          fetch('copy'),
        ))['delivery'],
        delivered,
      );
    },
  );
  test(
    'missing, extra and wrong file review bindings cannot approve',
    () async {
      await expectLater(
        service.owner.decideInformationRequest(command(expected: {})),
        failure('scope_changed'),
      );
      await expectLater(
        service.owner.decideInformationRequest(
          command(expected: {file(): InformationAttachmentRef('wrong', 1)}),
        ),
        failure('scope_changed'),
      );
      await expectLater(
        service.owner.decideInformationRequest(
          command(
            expected: {text(): item.fields.last.attachment!},
            selected: [text()],
          ),
        ),
        failure('invalid_scope'),
      );
      expect(
        await service.owner.informationApprovalReceipt('approve-file'),
        null,
      );
      expect(repo.grantHistory, isEmpty);
    },
  );
  test(
    'file replacement invalidates old review; fixed fields still read latest after approval',
    () async {
      final old = command();
      item = await seed('SECOND-FILE', previous: item);
      await expectLater(
        service.owner.decideInformationRequest(old),
        failure('scope_changed'),
      );
      await service.owner.decideInformationRequest(command());
      final first =
          (await service.agent.fetchInformationFile(
                session,
                fetch('v2'),
              ))['delivery']
              as Map;
      expect(utf8.decode(copies.contents[first['path']]!), 'SECOND-FILE');
      item = await seed('THIRD-FILE', previous: item);
      final second =
          (await service.agent.fetchInformationFile(
                session,
                fetch('v3'),
              ))['delivery']
              as Map;
      expect(utf8.decode(copies.contents[second['path']]!), 'THIRD-FILE');
      expect(utf8.decode(copies.contents[first['path']]!), 'SECOND-FILE');
    },
  );
  test(
    'partial text approval omits files; unsupported delivery never approves a file',
    () async {
      await service.owner.decideInformationRequest(
        command(expected: {}, selected: [text()]),
      );
      await expectLater(
        service.agent.fetchInformationFile(session, fetch('unselected')),
        throwsA(isA<InformationFileFailure>()),
      );
      await service.close();
      service = InformationService(repository: repo, clock: () => now);
      session = service.agent.openSession('no file driver');
      request = service.agent.request(session, 'file', [file()]).id;
      await expectLater(
        service.owner.decideInformationRequest(
          command(id: 'no-driver', selected: [file()]),
        ),
        failure('unsupported_capability'),
      );
    },
  );
  test(
    'pending storage does not expose a file grant and session end wins',
    () async {
      repo.pause();
      final outcome = service.owner.decideInformationRequest(command());
      final checked = expectLater(outcome, failure('request_changed'));
      await repo.entered!.future;
      expect(
        () => service.agent.claim(session, request),
        failure('decision_unknown'),
      );
      service.agent.endSession(session);
      repo.release!.complete();
      await checked;
      expect(
        await service.owner.informationApprovalReceipt('approve-file'),
        null,
      );
      expect(repo.grantHistory, isEmpty);
    },
  );
  test(
    'lost file decision response never publishes a bearer during original-result reconciliation',
    () async {
      repo.loseResponse = true;
      await expectLater(
        service.owner.decideInformationRequest(command()),
        throwsStateError,
      );
      expect(
        await service.owner.informationApprovalReceipt('approve-file'),
        isNotNull,
      );
      expect(
        () => service.agent.claim(session, request),
        throwsA(isA<AccessFailure>()),
      );
      await service.owner.decideInformationRequest(command());
      await expectLater(
        service.agent.fetchInformationFile(session, fetch('never-copy')),
        throwsA(isA<InformationFileFailure>()),
      );
      expect(copies.sequence, 0);
    },
  );
}
