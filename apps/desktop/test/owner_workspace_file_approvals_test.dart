@TestOn('mac-os')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_core/agent_server.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/workspace/owner_workspace_source.dart';
import 'package:info_desktop/workspace/owner_workspace_approvals.dart';
import 'package:info_desktop/desktop_controls.dart';
import 'package:info_desktop/workspace/approvals_controller.dart';
import 'package:info_desktop/workspace/grant_history_controller.dart';
import 'package:info_desktop/workspace/grant_history_page.dart';
import 'package:info_desktop/workspace/approvals_page.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_desktop/workspace/zhiyu_theme.dart';
import 'package:sqlite3/sqlite3.dart';

class _RealHttp extends HttpOverrides {}

class _CleanupFiles extends core.NativeInformationDeliveryFiles {
  bool fail = true;
  @override
  Future<void> cleanup(core.InformationDeliveryLease lease) async {
    if (fail) throw const core.RuntimeMaterialFailure('cleanup_failed');
    await super.cleanup(lease);
  }
}

class _Keys implements DatabaseKeyStore {
  List<int>? key;
  @override
  Future<List<int>?> read() async => key;
  @override
  Future<void> create(List<int> bytes) async {
    key = List.of(bytes);
  }
}

class _Cli {
  _Cli(this.process)
    : lines = StreamIterator(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      ),
      errors = process.stderr.transform(utf8.decoder).join();
  final Process process;
  final StreamIterator<String> lines;
  final Future<String> errors;
  static Future<_Cli> start(int port) async {
    final project = Directory('../..').resolveSymbolicLinksSync();
    return _Cli(
      await Process.start(
        '$project/.tools/flutter/bin/cache/dart-sdk/bin/dart',
        [
          '--packages=$project/packages/info_cli/.dart_tool/package_config.json',
          '$project/packages/info_cli/bin/info.dart',
          '--port',
          '$port',
        ],
      ),
    );
  }

  Future<Map<String, dynamic>> call(Map<String, Object?> command) async {
    process.stdin.writeln(jsonEncode(command));
    await process.stdin.flush();
    if (!await lines.moveNext().timeout(const Duration(seconds: 20))) {
      throw StateError('Synthetic CLI exited');
    }
    return jsonDecode(lines.current) as Map<String, dynamic>;
  }

  Future<void> close() async {
    await process.stdin.close();
    try {
      expect(await process.exitCode.timeout(const Duration(seconds: 10)), 0);
    } on TimeoutException {
      process.kill();
      await process.exitCode;
      rethrow;
    }
    await lines.cancel();
    expect(await errors, isEmpty);
  }
}

class _LostReply extends OwnerWorkspaceApprovals {
  _LostReply({required super.owner});
  bool drop = true, wrong = false;
  @override
  Future<WorkspaceApprovalReceipt> change(WorkspaceApprovalChange c) async {
    final r = await super.change(c);
    if (drop) {
      drop = false;
      throw const WorkspaceFailure('unknown_outcome', '合成响应丢失');
    }
    return r;
  }

  @override
  Future<WorkspaceApprovalReceipt?> receipt(String id) async {
    final r = await super.receipt(id);
    if (!wrong || r == null) return r;
    return WorkspaceApprovalReceipt(
      operationId: r.operationId,
      requestId: r.requestId,
      action: r.action,
      reviewToken: r.reviewToken,
      revision: r.revision,
      commandDigest: 'f' * 64,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late _Keys keys;
  late EncryptedInformationRepository repo;
  late core.InformationService service;
  late OwnerWorkspaceSource source;
  late AgentServer server;
  late HttpClient http;
  late core.InformationItem item;
  late DateTime now;
  final clients = <_Cli>[];
  final bytes = utf8.encode('SYNTHETIC-ORIGINAL-FILE');
  var isOpen = false;
  Future<void> open({
    bool files = true,
    core.InformationDeliveryFiles? driver,
  }) async {
    repo = await EncryptedInformationRepository.open(
      '${root.path}/library',
      keys,
      clock: () => now,
    );
    service = core.InformationService(
      repository: repo,
      informationDeliveryFiles: files
          ? driver ?? core.NativeInformationDeliveryFiles()
          : null,
      clock: () => now,
    );
    source = OwnerWorkspaceSource(
      owner: service.owner,
      refreshInterval: Duration.zero,
    );
    server = await AgentServer.start(
      service.agent,
      port: 0,
      enableReusableCredentialUse: true,
      enableInformationFiles: files,
    );
    http = _RealHttp().createHttpClient(null);
    isOpen = true;
  }

  Future<void> close() async {
    for (final cli in clients) {
      await cli.close();
    }
    clients.clear();
    if (!isOpen) return;
    http.close(force: true);
    await server.close();
    await source.dispose();
    await service.close();
    await repo.close();
    isOpen = false;
  }

  Future<core.InformationItem> seed(
    List<int> body, {
    core.InformationItem? previous,
  }) async {
    final path = '${root.path}/合成附件.txt';
    await File(path).writeAsBytes(body);
    final draft = await service.owner.beginInformationFileDraft();
    try {
      final stage = await service.owner.stageInformationFile(
        draft,
        path,
        mediaType: 'text/plain',
      );
      return await service.owner.commitInformationDraft(
        draft,
        'seed',
        core.InformationDraftInput(
          name: '合成文件申请',
          description: '',
          itemId: previous?.id,
          baseVersion: previous?.version,
          fields: [
            core.InformationDraftField.text(
              '说明',
              '',
              'SYNTHETIC-TEXT',
              fieldId: previous?.fields.first.id,
            ),
            core.InformationDraftField.stagedFile(
              '附件',
              '公开文件说明',
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

  core.FieldRef field() => core.FieldRef(item.id, item.fields.last.id);
  String scope() => jsonEncode([item.id, item.fields.last.id]);
  Future<Map<String, dynamic>> httpCall(
    String path,
    Map<String, Object?> body,
  ) async {
    final req = await http.post('127.0.0.1', server.port, path);
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode(body));
    return jsonDecode(await utf8.decoder.bind(await req.close()).join())
        as Map<String, dynamic>;
  }

  Future<({String session, String id})> request({bool mixed = true}) async {
    final s =
        (await httpCall('/session', {'chatLabel': '合成文件聊天'}))['sessionSecret']
            as String;
    final r = await httpCall('/request', {
      'protocolVersion': 2,
      'sessionSecret': s,
      'purpose': '读取合成附件',
      'fields': [
        for (final f in mixed ? item.fields : [item.fields.last])
          {'itemId': item.id, 'fieldId': f.id},
      ],
    });
    return (session: s, id: r['requestId'] as String);
  }

  Future<Map<String, dynamic>> fetch(
    String s,
    String id,
    String operation, {
    String? fieldId,
  }) => httpCall('/information-file/fetch', {
    'protocolVersion': 2,
    'command': 'file-fetch',
    'sessionSecret': s,
    'requestId': id,
    'itemId': item.id,
    'fieldId': fieldId ?? field().fieldId,
    'operationId': operation,
  });
  Future<WorkspaceApprovalChange> command(
    String id, {
    String op = 'approve-file',
    bool mixed = true,
  }) async {
    final d = await source.approvals.read(id);
    return WorkspaceApprovalChange(
      operationId: op,
      requestId: id,
      reviewToken: d.reviewToken,
      action: WorkspaceApprovalAction.approve,
      selected: d.scopes
          .where((s) => mixed || s.kind == WorkspaceApprovalScopeKind.file)
          .map((s) => s.id),
      fileVersions: {scope(): item.fields.last.attachment!.attachmentVersion},
    );
  }

  void sql(String query, [List<Object?> args = const []]) {
    final db = sqlite3.open('${root.path}/library/library.db');
    try {
      final hex = keys.key!
          .map((v) => v.toRadixString(16).padLeft(2, '0'))
          .join();
      db.execute('PRAGMA key = "x\'$hex\'"');
      db.execute(query, args);
    } finally {
      db.close();
    }
  }

  Matcher fails(String code) =>
      throwsA(isA<WorkspaceFailure>().having((e) => e.code, 'code', code));
  setUp(() async {
    root = await Directory.systemTemp.createTemp('owner-file-approval-');
    keys = _Keys();
    now = DateTime.utc(2026, 11, 1);
    await open();
    item = await seed(bytes);
  });
  tearDown(() async {
    await close();
    await root.delete(recursive: true);
  });
  Future<T> real<T>(WidgetTester t, Future<T> Function() action) async {
    var complete = false;
    Object? result, error;
    StackTrace? trace;
    await t.runAsync(() async {
      unawaited(
        Future<T>.sync(action).then(
          (value) {
            result = value;
            complete = true;
          },
          onError: (Object e, StackTrace s) {
            error = e;
            trace = s;
            complete = true;
          },
        ),
      );
    });
    final elapsed = Stopwatch()..start();
    while (!complete && elapsed.elapsed < const Duration(seconds: 20)) {
      await t.pump(const Duration(milliseconds: 20));
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    if (!complete) throw TimeoutException('Owner file I/O did not settle');
    if (error != null) Error.throwWithStackTrace(error!, trace!);
    return result as T;
  }

  Future<void> settle(WidgetTester t, bool Function() done) async {
    for (var i = 0; i < 200; i++) {
      await t.pump(const Duration(milliseconds: 20));
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      if (done()) {
        await t.pump();
        return;
      }
    }
    fail('Owner file UI did not settle');
  }

  test(
    'independent public CLI request, partial file approval, exact copy/replay and revoke',
    () async {
      final cli = await _Cli.start(server.port);
      clients.add(cli);
      expect(
        (await cli.call({
          'command': 'session',
          'chatLabel': '独立CLI合成聊天',
          'externalChatId': 'synthetic-file-cli-chat',
        }))['status'],
        'ok',
      );
      final input = <String, Object?>{
        'command': 'request',
        'operationId': 'cli-request',
        'purpose': '合成文件领取',
        'agentName': '合成文件 Agent',
        'fields': [
          for (final f in item.fields) {'itemId': item.id, 'fieldId': f.id},
        ],
      };
      final r = await cli.call(input);
      expect(await cli.call(input), r);
      final id = r['requestId'] as String;
      final fetching = <String, Object?>{
        'command': 'file-fetch',
        'requestId': id,
        'itemId': item.id,
        'fieldId': field().fieldId,
        'operationId': 'original-copy',
      };
      expect((await cli.call(fetching))['status'], 'unauthorized');
      final model = ApprovalsController(source.approvals, const Stream.empty());
      addTearDown(model.dispose);
      await model.load();
      expect(model.detail!.request.kind, WorkspaceApprovalKind.file);
      expect(model.detail!.scopes.last.available, true);
      expect(
        model.detail!.scopes.last.fileVersions.single.filename,
        '合成附件.txt',
      );
      expect(model.draft!.files[scope()], 1);
      model.toggle(model.detail!.scopes.first.id);
      await model.decide(WorkspaceApprovalAction.approve);
      expect(model.writeFailure, null);
      expect(
        (await cli.call({'command': 'claim', 'requestId': id}))['status'],
        'ok',
      );
      expect(
        (await cli.call({
          'command': 'read',
          'requestId': id,
          'itemId': item.id,
          'fieldId': item.fields.first.id,
        }))['status'],
        'unauthorized',
      );
      expect(
        (await cli.call({
          'command': 'read',
          'requestId': id,
          'itemId': item.id,
          'fieldId': field().fieldId,
        }))['status'],
        'file_delivery_required',
      );
      final ready = await cli.call(fetching);
      expect(ready['status'], 'ok');
      final delivery = ready['delivery'] as Map;
      final path = delivery['path'] as String;
      expect(File(path).readAsBytesSync(), bytes);
      expect((await cli.call(fetching))['delivery'], delivery);
      final status =
          (await cli.call({
                'command': 'file-status',
                'operationId': 'original-copy',
              }))['delivery']
              as Map;
      expect(status['deliveryId'], delivery['deliveryId']);
      expect(status['state'], 'ready');
      expect(status.containsKey('path'), false);
      expect(status.containsKey('fileName'), false);
      expect(service.owner.informationFileDeliveries.length, 1);
      final other = await _Cli.start(server.port);
      clients.add(other);
      await other.call({'command': 'session', 'chatLabel': '其他CLI'});
      expect((await other.call(fetching))['status'], 'unauthorized');
      await model.decide(WorkspaceApprovalAction.revoke);
      expect(model.writeFailure, null);
      expect(
        (await cli.call({
          ...fetching,
          'operationId': 'after-revoke',
        }))['status'],
        'unauthorized',
      );
      await service.agent.drainInformationFileDeliveries();
      expect(File(path).existsSync(), false);
    },
  );
  test(
    'current metadata only, old review conflicts, and retained versions cannot be selected',
    () async {
      final r = await request();
      final before = await command(r.id);
      final old = await source.approvals.read(r.id);
      expect(old.fileVersionPolicy, contains('当前版本'));
      item = await seed(utf8.encode('SECOND-ORIGINAL'), previous: item);
      await expectLater(source.approvals.change(before), fails('conflict'));
      final current = await source.approvals.read(r.id);
      final file = current.scopes.last;
      expect(file.fileVersions.map((v) => v.ref.version), [2]);
      expect(current.reviewToken, isNot(before.reviewToken));
      await expectLater(
        source.approvals.change(
          WorkspaceApprovalChange(
            operationId: 'old-version',
            requestId: r.id,
            reviewToken: current.reviewToken,
            action: WorkspaceApprovalAction.approve,
            selected: [file.id],
            fileVersions: {file.id: 1},
          ),
        ),
        fails('conflict'),
      );
      await source.approvals.change(await command(r.id, mixed: false));
      final copy = (await fetch(r.session, r.id, 'current'))['delivery'] as Map;
      expect(
        File(copy['path'] as String).readAsStringSync(),
        'SECOND-ORIGINAL',
      );
    },
  );
  test(
    'missing or extra file choices and text-as-file cannot widen selected scope',
    () async {
      final r = await request();
      final d = await source.approvals.read(r.id);
      for (final versions in <Map<String, int>>[
        {},
        {scope(): 1, 'extra': 1},
      ]) {
        await expectLater(
          source.approvals.change(
            WorkspaceApprovalChange(
              operationId: 'bad-choice',
              requestId: r.id,
              reviewToken: d.reviewToken,
              action: WorkspaceApprovalAction.approve,
              selected: [scope()],
              fileVersions: versions,
            ),
          ),
          fails('conflict'),
        );
      }
      final text = d.scopes.first;
      await expectLater(
        source.approvals.change(
          WorkspaceApprovalChange(
            operationId: 'text-choice',
            requestId: r.id,
            reviewToken: d.reviewToken,
            action: WorkspaceApprovalAction.approve,
            selected: [text.id],
            fileVersions: {text.id: 1},
          ),
        ),
        fails('conflict'),
      );
      expect((await fetch(r.session, r.id, 'none'))['status'], 'unauthorized');
    },
  );
  test(
    'SQLCipher verifies original hash inside approval and rolls back all facts',
    () async {
      final r = await request();
      final c = await command(r.id);
      final ref = item.fields.last.attachment!;
      sql(
        'UPDATE information_attachment_versions SET body=? WHERE attachment_id=? AND version=?',
        [Uint8List(bytes.length), ref.attachmentId, ref.attachmentVersion],
      );
      await expectLater(source.approvals.change(c), fails('file_unavailable'));
      expect(await source.approvals.receipt(c.operationId), null);
      expect((await service.owner.history()).grants, isEmpty);
      expect(
        (await fetch(r.session, r.id, 'bad-original'))['status'],
        'unauthorized',
      );
      sql(
        'UPDATE information_attachment_versions SET body=? WHERE attachment_id=? AND version=?',
        [bytes, ref.attachmentId, ref.attachmentVersion],
      );
    },
  );
  test(
    'file scope can be excluded when this instance has no delivery driver',
    () async {
      await close();
      await open(files: false);
      item = service.owner.information.single;
      final session = service.agent.openSession('合成不支持文件的实例');
      final r = (
        session: session,
        id: service.agent.request(session, '合成部分审批', [
          for (final f in item.fields) core.FieldRef(item.id, f.id),
        ]).id,
      );
      final d = await source.approvals.read(r.id);
      expect(d.scopes.last.available, false);
      expect(d.scopes.first.available, true);
      expect(d.approveUnavailableReason, null);
      await source.approvals.change(
        WorkspaceApprovalChange(
          operationId: 'text-only',
          requestId: r.id,
          reviewToken: d.reviewToken,
          action: WorkspaceApprovalAction.approve,
          selected: [d.scopes.first.id],
        ),
      );
      expect(
        (await httpCall('/claim', {
          'sessionSecret': r.session,
          'requestId': r.id,
        }))['status'],
        'ok',
      );
    },
  );
  test(
    'same-field replacement after approval follows current-value policy, copies remain immutable',
    () async {
      final r = await request();
      await source.approvals.change(await command(r.id, mixed: false));
      final first =
          (await fetch(r.session, r.id, 'old-copy'))['delivery'] as Map;
      item = await seed(utf8.encode('CURRENT-REPLACEMENT'), previous: item);
      final next =
          (await fetch(r.session, r.id, 'new-copy'))['delivery'] as Map;
      expect(File(first['path'] as String).readAsBytesSync(), bytes);
      expect(
        File(next['path'] as String).readAsStringSync(),
        'CURRENT-REPLACEMENT',
      );
      expect(next['attachmentVersion'], 2);
    },
  );
  test(
    'receipt insertion failure commits no grant, and exact retry is safe',
    () async {
      final r = await request();
      final c = await command(r.id);
      sql(
        "CREATE TRIGGER reject_file_approval BEFORE INSERT ON information_approval_operations BEGIN SELECT RAISE(ABORT,'synthetic'); END",
      );
      await expectLater(source.approvals.change(c), fails('unknown_outcome'));
      expect(await source.approvals.receipt(c.operationId), null);
      expect((await service.owner.history()).grants, isEmpty);
      expect(
        (await fetch(r.session, r.id, 'before-retry'))['status'],
        'unauthorized',
      );
      sql('DROP TRIGGER reject_file_approval');
      await source.approvals.change(c);
      expect((await fetch(r.session, r.id, 'after-retry'))['status'], 'ok');
    },
  );
  test(
    'expiry and session end reject new copies and reclaim originals already delivered',
    () async {
      final r = await request();
      await source.approvals.change(await command(r.id));
      final copy =
          (await fetch(r.session, r.id, 'before-expiry'))['delivery'] as Map;
      now = now.add(const Duration(minutes: 121));
      expect((await fetch(r.session, r.id, 'expired'))['status'], 'expired');
      await service.agent.drainInformationFileDeliveries();
      expect(File(copy['path'] as String).existsSync(), false);
      expect(
        (await source.grantHistory.read(
          'request:${r.id}',
        )).events.singleWhere((e) => e.fileScopeId != null).result,
        contains('授权已到期'),
      );
      final ended = await request();
      await source.approvals.change(await command(ended.id, op: 'approve-end'));
      final active =
          (await fetch(ended.session, ended.id, 'before-end'))['delivery']
              as Map;
      service.agent.endSession(ended.session);
      await service.agent.drainInformationFileDeliveries();
      expect(
        (await fetch(ended.session, ended.id, 'ended'))['status'],
        'unauthorized',
      );
      expect(File(active['path'] as String).existsSync(), false);
      final event = (await source.grantHistory.read(
        'request:${ended.id}',
      )).events.singleWhere((e) => e.fileScopeId != null);
      expect(event.result, contains('会话已结束'));
      expect(event.result, isNot(contains('已到期')));
    },
  );
  test(
    'SQLCipher reopen preserves original receipt and terminal history, never restores a file permission',
    () async {
      final r = await request();
      final c = await command(r.id);
      await source.approvals.change(c);
      final first =
          (await fetch(r.session, r.id, 'before-reopen'))['delivery'] as Map;
      await close();
      await open();
      item = service.owner.information.single;
      expect(File(first['path'] as String).existsSync(), false);
      expect(
        (await source.approvals.receipt(c.operationId))!.commandDigest,
        c.digest,
      );
      await source.approvals.change(c);
      expect(service.owner.sessions, isEmpty);
      expect(
        (await fetch(r.session, r.id, 'old-session'))['status'],
        'unauthorized',
      );
      final detail = await source.approvals.read(r.id);
      expect(detail.request.state, WorkspaceApprovalState.sessionEnded);
      expect(detail.scopes.last.fileVersions, isEmpty);
      expect(detail.scopes.every((s) => !s.available), true);
    },
  );

  test(
    'SQL transaction rejects an out-of-band field attachment switch despite unchanged item version',
    () async {
      item = await seed(utf8.encode('SECOND'), previous: item);
      final ref = item.fields.last.attachment!;
      final r = await request();
      final c = await command(r.id);
      sql(
        'UPDATE information_file_fields SET attachment_version=1 WHERE field_id=?',
        [field().fieldId],
      );
      try {
        await expectLater(source.approvals.change(c), fails('conflict'));
        expect(await source.approvals.receipt(c.operationId), null);
        expect(
          (await fetch(r.session, r.id, 'none'))['status'],
          'unauthorized',
        );
      } finally {
        sql(
          'UPDATE information_file_fields SET attachment_version=? WHERE field_id=?',
          [ref.attachmentVersion, field().fieldId],
        );
      }
    },
  );
  test(
    'visible file metadata participates in review identity even if item version is unchanged',
    () async {
      final r = await request();
      final c = await command(r.id);
      final ref = item.fields.last.attachment!;
      sql(
        "UPDATE information_attachment_versions SET metadata=json_set(metadata,'\$.originalName','合成变更.txt') WHERE attachment_id=? AND version=?",
        [ref.attachmentId, ref.attachmentVersion],
      );
      try {
        final now = await source.approvals.read(r.id);
        expect(now.reviewToken, isNot(c.reviewToken));
        await expectLater(source.approvals.change(c), fails('conflict'));
        expect(await source.approvals.receipt(c.operationId), null);
      } finally {
        sql(
          "UPDATE information_attachment_versions SET metadata=json_set(metadata,'\$.originalName','合成附件.txt') WHERE attachment_id=? AND version=?",
          [ref.attachmentId, ref.attachmentVersion],
        );
      }
    },
  );
  test('zero-byte original is reviewed and delivered intact', () async {
    item = await seed([]);
    final r = await request();
    await source.approvals.change(await command(r.id));
    final delivered =
        (await fetch(r.session, r.id, 'empty'))['delivery'] as Map;
    expect(delivered['byteLength'], 0);
    expect(File(delivered['path'] as String).readAsBytesSync(), isEmpty);
  });
  testWidgets(
    'real approval controls preserve lost reply, reject wrong receipt and approve only selected file',
    (t) async {
      t.view.physicalSize = const Size(1600, 1100);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final r = await real(t, request);
      final backend = _LostReply(owner: service.owner);
      final model = ApprovalsController(backend, const Stream.empty());
      await real(t, model.load);
      await t.pumpWidget(
        MaterialApp(
          theme: zhiyuTheme(Brightness.light),
          home: Scaffold(
            body: ApprovalsPage(controller: model, onRecord: (_) {}),
          ),
        ),
      );
      await settle(
        t,
        () => find
            .byKey(const ValueKey('approval-approve'))
            .evaluate()
            .isNotEmpty,
      );
      expect(find.text('当前附件版本'), findsOneWidget);
      expect(find.textContaining('v1 · 合成附件.txt'), findsOneWidget);
      final text = model.detail!.scopes.first.id;
      await t.ensureVisible(find.byKey(ValueKey('approval-scope-$text')));
      await t.tap(find.byKey(ValueKey('approval-scope-$text')));
      await t.pump();
      await t.ensureVisible(find.byKey(const ValueKey('approval-approve')));
      await t.tap(find.byKey(const ValueKey('approval-approve')));
      await settle(t, () => model.uncertain && !model.busy);
      expect(
        t
            .widget<DesktopButton>(find.byKey(const ValueKey('approval-deny')))
            .onPressed,
        null,
      );
      expect(model.draft!.selected, {scope()});
      backend.wrong = true;
      await t.ensureVisible(find.byKey(const ValueKey('approval-reconcile')));
      await t.tap(find.byKey(const ValueKey('approval-reconcile')));
      await settle(t, () => !model.busy);
      expect(model.uncertain, true);
      backend.wrong = false;
      await t.tap(find.byKey(const ValueKey('approval-reconcile')));
      await settle(
        t,
        () =>
            !model.busy && !model.uncertain && !model.loading && !model.reading,
      );
      expect(model.detail!.request.state, WorkspaceApprovalState.approved);
      expect(model.detail!.approved, {scope()});
      final delivered = await real(
        t,
        () => fetch(r.session, r.id, 'widget-copy'),
      );
      expect(
        File(
          (delivered['delivery'] as Map)['path'] as String,
        ).readAsBytesSync(),
        bytes,
      );
      expect((await real(t, () => service.owner.history())).grants.length, 1);
      await t.pumpWidget(const SizedBox.shrink());
      model.dispose();
      await real(t, close);
    },
  );
  test(
    'approval snapshot and actual deliveries retain distinct exact versions, not current content',
    () async {
      final r = await request();
      await source.approvals.change(await command(r.id, mixed: false));
      final hid = 'request:${r.id}';
      var h = await source.grantHistory.read(hid);
      expect(h.summary.kind, WorkspaceApprovalKind.file);
      expect(h.scopes.single.fileVersion, 1);
      expect(h.scopeNotice, contains('不锁定后续领取版本'));
      expect(
        (await source.grantHistory.filePreview(hid, scope())).text,
        utf8.decode(bytes),
      );
      await fetch(r.session, r.id, 'history-v1');
      item = await seed(utf8.encode('SYNTHETIC-HISTORY-V2'), previous: item);
      await fetch(r.session, r.id, 'history-v2');
      h = await source.grantHistory.read(hid);
      final deliveries = h.events.where((e) => e.fileScopeId != null).toList();
      expect(deliveries, hasLength(2));
      expect(h.scopes.single.fileVersion, 1);
      expect(h.summary.operationCount, 2);
      for (final e in deliveries) {
        final p = await source.grantHistory.filePreview(hid, e.fileScopeId!);
        expect(p.file.ref.version, e.fileVersion);
        expect(
          p.text,
          e.fileVersion == 1 ? utf8.decode(bytes) : 'SYNTHETIC-HISTORY-V2',
        );
      }
      expect(
        (await source.grantHistory.filePreview(hid, scope())).text,
        utf8.decode(bytes),
      );
      expect(
        jsonEncode(h.events.map((e) => [e.description, e.result]).toList()),
        isNot(contains(root.path)),
      );
      expect(
        (await source.grantHistory.query(
          const WorkspaceGrantQuery(kind: WorkspaceApprovalKind.file),
        )).total,
        1,
      );
      expect(
        (await source.grantHistory.query(
          const WorkspaceGrantQuery(keyword: 'SYNTHETIC-HISTORY-V2'),
        )).total,
        0,
      );
      final other = await request();
      await source.approvals.change(
        await command(other.id, op: 'other-approved', mixed: false),
      );
      await expectLater(
        source.grantHistory.filePreview(
          'request:${other.id}',
          deliveries.first.fileScopeId!,
        ),
        fails('not_found'),
      );
      await expectLater(
        source.grantHistory.filePreview(
          hid,
          jsonEncode([item.id, item.fields.first.id]),
        ),
        fails('not_found'),
      );
      await expectLater(
        source.grantHistory.filePreview(hid, scope(), page: 1),
        fails('invalid_request'),
      );
      await close();
      await open();
      h = await source.grantHistory.read(hid);
      expect(h.summary.state.isActive, false);
      expect(h.events.where((e) => e.fileScopeId != null), hasLength(2));
      expect(
        (await source.grantHistory.filePreview(hid, scope())).text,
        utf8.decode(bytes),
      );
      expect(service.owner.sessions, isEmpty);
    },
  );

  test(
    'real copy cleanup failure stays pending in history until actual cleanup succeeds',
    () async {
      await close();
      final driver = _CleanupFiles();
      await open(driver: driver);
      item = service.owner.information.single;
      final r = await request();
      await source.approvals.change(await command(r.id, mixed: false));
      final result =
          (await fetch(r.session, r.id, 'pending-cleanup'))['delivery'] as Map;
      final path = result['path'] as String;
      try {
        final d = await source.approvals.read(r.id);
        await source.approvals.change(
          WorkspaceApprovalChange(
            operationId: 'revoke-pending',
            requestId: r.id,
            reviewToken: d.reviewToken,
            action: WorkspaceApprovalAction.revoke,
          ),
        );
        await service.owner.reconcileInformationFileDeliveries();
        var h = await source.grantHistory.read('request:${r.id}');
        final event = h.events.singleWhere((e) => e.fileScopeId != null);
        expect(event.result, contains('待清理，不能认作已回收'));
        expect(event.result, contains('副本清理失败'));
        expect(File(path).existsSync(), true);
        expect(h.summary.state, WorkspaceGrantState.revoked);
        driver.fail = false;
        await service.owner.reconcileInformationFileDeliveries();
        h = await source.grantHistory.read('request:${r.id}');
        expect(
          h.events.singleWhere((e) => e.fileScopeId != null).result,
          contains('登记副本路径已移除'),
        );
        expect(File(path).existsSync(), false);
        final result = h.events
            .singleWhere((e) => e.fileScopeId != null)
            .result;
        expect(result, contains('授权已撤销或失效'));
        expect(result, isNot(contains('已到期')));
      } finally {
        driver.fail = false;
        await service.owner.reconcileInformationFileDeliveries();
      }
    },
  );

  test(
    'stored unknown delivery facts do not imply success; delivery state changes refresh source',
    () async {
      final r = await request();
      await source.approvals.change(await command(r.id, mixed: false));
      await fetch(r.session, r.id, 'unknown-projection');
      service.agent.endSession(r.session);
      await service.owner.reconcileInformationFileDeliveries();
      final prior = service.owner.informationFileDeliveries.single;
      expect(prior.lease, null);
      var changes = 0;
      final sub = source.changes.listen((_) => changes++);
      try {
        source.refreshFromOwner();
        await Future<void>.delayed(Duration.zero);
        changes = 0;
        // Synthetic persisted unknown fact, not a simulated successful delivery.
        await repo.saveInformationFileDelivery(
          core.InformationFileDelivery.fromArchiveJson({
            ...prior.toArchiveJson(),
            'id': 'synthetic-unknown-history',
            'operationId': 'synthetic-unknown-operation',
            'state': 'unknown',
            'reason': 'delivery_unknown',
          }),
        );
        source.refreshFromOwner();
        await Future<void>.delayed(Duration.zero);
        expect(changes, 1);
        final h = await source.grantHistory.read('request:${r.id}');
        final e = h.events.singleWhere(
          (e) => e.id == 'delivery:synthetic-unknown-history',
        );
        expect(e.result, contains('交付结果未知'));
        expect(e.result, contains('仅历史事实'));
        expect(e.result, isNot(contains('副本已准备')));
      } finally {
        await sub.cancel();
      }
    },
  );

  test(
    'corrupt historical bytes or lost approval snapshot never fall back to current attachment',
    () async {
      final r = await request();
      await source.approvals.change(await command(r.id, mixed: false));
      await fetch(r.session, r.id, 'historical-original');
      final hid = 'request:${r.id}';
      final event = (await source.grantHistory.read(
        hid,
      )).events.singleWhere((e) => e.fileScopeId != null);
      final old = item.fields.last.attachment!;
      item = await seed(utf8.encode('SYNTHETIC-CURRENT-ONLY'), previous: item);
      // Equal-length corrupt original in this isolated fixture; current v2 remains intact.
      sql(
        'UPDATE information_attachment_versions SET body=? WHERE attachment_id=? AND version=?',
        [
          List<int>.filled(bytes.length, 0),
          old.attachmentId,
          old.attachmentVersion,
        ],
      );
      await expectLater(
        source.grantHistory.filePreview(hid, scope()),
        fails('attachment_integrity_failed'),
      );
      await expectLater(
        source.grantHistory.filePreview(hid, event.fileScopeId!),
        fails('attachment_integrity_failed'),
      );
      expect(
        (await service.owner.readInformationAttachment(
          item.fields.last.attachment!,
        )).bytes,
        utf8.encode('SYNTHETIC-CURRENT-ONLY'),
      );
      sql(
        'UPDATE information_attachment_versions SET body=? WHERE attachment_id=? AND version=?',
        [bytes, old.attachmentId, old.attachmentVersion],
      );
      now = now.add(const Duration(days: 31));
      await service.owner.purgeRevisions();
      expect(
        (await source.grantHistory.read(hid)).scopes.single.fileVersion,
        null,
      );
      await expectLater(
        source.grantHistory.filePreview(hid, scope()),
        fails('snapshot_unavailable'),
      );
      // The delivery pins the original version, still owned by this attachment.
      expect(
        (await source.grantHistory.filePreview(hid, event.fileScopeId!)).text,
        utf8.decode(bytes),
      );
      expect(
        (await source.grantHistory.read(
          hid,
        )).events.singleWhere((e) => e.fileScopeId != null).fileVersion,
        1,
      );
    },
  );

  testWidgets(
    'real history controls preview approval snapshot and distinct delivered original',
    (t) async {
      final r = await real(t, request);
      await real(t, () async {
        await source.approvals.change(await command(r.id, mixed: false));
        item = await seed(
          utf8.encode('SYNTHETIC-DELIVERED-V2'),
          previous: item,
        );
        await fetch(r.session, r.id, 'widget-history');
      });
      final m = GrantHistoryController(
        source.grantHistory,
        source.approvals,
        const Stream.empty(),
      );
      await real(t, () => m.open('request:${r.id}'));
      t.view.physicalSize = const Size(1440, 1000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      await t.pumpWidget(
        MaterialApp(
          theme: zhiyuTheme(Brightness.light),
          home: Scaffold(
            body: GrantHistoryPage(
              controller: m,
              onRecord: (_) {},
              onRequest: (_) {},
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      var button = find.byKey(ValueKey('grant-file-${scope()}'));
      await t.ensureVisible(button);
      await t.tap(button);
      await settle(
        t,
        () => find.text(utf8.decode(bytes)).evaluate().isNotEmpty,
      );
      expect(find.text('SYNTHETIC-DELIVERED-V2'), findsNothing);
      await t.tap(find.widgetWithText(DesktopButton, '关闭'));
      await t.pumpAndSettle();
      final event = m.detail!.events.singleWhere((e) => e.fileScopeId != null);
      button = find.byKey(ValueKey('grant-delivery-${event.id}'));
      await t.ensureVisible(button);
      await t.tap(button);
      await settle(
        t,
        () => find.text('SYNTHETIC-DELIVERED-V2').evaluate().isNotEmpty,
      );
      expect(find.text('实际交付的附件v2'), findsOneWidget);
      expect(t.takeException(), null);
      await t.pumpWidget(const SizedBox.shrink());
      m.dispose();
      await real(t, close);
    },
  );
}
