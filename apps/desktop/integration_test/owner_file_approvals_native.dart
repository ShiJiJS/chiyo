// Synthetic native acceptance support; never imported by a production entry.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_core/agent_server.dart';
import 'package:info_desktop/workspace/approvals_controller.dart';
import 'package:info_desktop/workspace/approvals_page.dart';
import 'package:info_desktop/workspace/owner_workspace_approvals.dart';
import 'package:info_desktop/workspace/owner_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_desktop/workspace/zhiyu_theme.dart';

class _Cli {
  _Cli(this.process)
    : lines = StreamIterator(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      ),
      errors = process.stderr.transform(utf8.decoder).join();
  final Process process;
  final StreamIterator<String> lines;
  final Future<String> errors;
  static Future<_Cli> start(int port) async => _Cli(
    await Process.start(
      '${File(Platform.resolvedExecutable).parent.path}/info-m07-check',
      ['--port', '$port'],
    ),
  );
  Future<Map<String, dynamic>> call(Map<String, Object?> input) async {
    process.stdin.writeln(jsonEncode(input));
    await process.stdin.flush();
    if (!await lines.moveNext().timeout(const Duration(seconds: 20))) {
      throw StateError('Synthetic CLI exited');
    }
    final result = jsonDecode(lines.current) as Map<String, dynamic>;
    expect(result.containsKey('sessionSecret'), false);
    expect(result.containsKey('token'), false);
    return result;
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

class _Observed extends OwnerWorkspaceApprovals {
  _Observed({required super.owner});
  String? approvedOperation;
  @override
  Future<WorkspaceApprovalReceipt> change(WorkspaceApprovalChange c) async {
    final result = await super.change(c);
    if (c.action == WorkspaceApprovalAction.approve) {
      approvedOperation = result.operationId;
    }
    return result;
  }
}

class NativeFileApprovalEvidence {
  const NativeFileApprovalEvidence(this.requestId, this.operationId);
  final String requestId, operationId;
}

Future<NativeFileApprovalEvidence> checkNativeFileApprovals(
  WidgetTester t,
  core.InformationService service,
  OwnerWorkspaceSource source,
  core.InformationItem fileItem,
  List<int> original,
  List<String> checks,
) async {
  final cli = <_Cli>[];
  AgentServer? server;
  ApprovalsController? model;
  late String requestId;
  final observed = _Observed(owner: service.owner);
  Future<void> ready(bool Function() done) async {
    for (var i = 0; i < 500; i++) {
      await t.pump(const Duration(milliseconds: 20));
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      if (done()) return;
    }
    throw TimeoutException('Native approval did not settle');
  }

  Future<void> tap(String key) async {
    final target = find.byKey(ValueKey(key));
    await t.ensureVisible(target);
    await t.tap(target);
    await t.pump();
  }

  try {
    late core.InformationItem text;
    await t.runAsync(() async {
      text = await service.owner.createInformation('Synthetic M07 text', '', [
        const core.FieldInput('Allowed text', '', 'SYNTHETIC-ALLOWED'),
        const core.FieldInput('Unselected text', '', 'SYNTHETIC-DENIED'),
      ]);
      server = await AgentServer.start(
        service.agent,
        port: 0,
        enableReusableCredentialUse: true,
        enableInformationFiles: true,
      );
      cli.add(await _Cli.start(server!.port));
      expect(
        (await cli.first.call({
          'command': 'session',
          'chatLabel': 'Synthetic native M07',
        }))['status'],
        'ok',
      );
      final request = <String, Object?>{
        'command': 'request',
        'operationId': 'native-file-request',
        'purpose': 'Synthetic native attachment approval',
        'fields': [
          {'itemId': fileItem.id, 'fieldId': fileItem.fields.single.id},
          for (final field in text.fields)
            {'itemId': text.id, 'fieldId': field.id},
        ],
      };
      final result = await cli.first.call(request);
      expect(await cli.first.call(request), result);
      requestId = result['requestId'] as String;
      expect((await source.approvals.read(requestId)).request.id, requestId);
      model = ApprovalsController(observed, const Stream.empty());
      await model!.load();
      expect(model!.detail!.request.id, requestId);
      expect(model!.detail!.request.kind, WorkspaceApprovalKind.file);
      expect(
        model!.detail!.scopes
            .where((s) => s.kind == WorkspaceApprovalScopeKind.file)
            .single
            .fileVersions
            .single
            .byteLength,
        original.length,
      );
      checks.add(
        'actual inherited-sandbox AOT CLI request is the production file approval record and metadata',
      );
    });
    await t.pumpWidget(
      MaterialApp(
        theme: zhiyuTheme(Brightness.light),
        home: Scaffold(
          body: ApprovalsPage(controller: model!, onRecord: (_) {}),
        ),
      ),
    );
    await t.pumpAndSettle();
    final omitted = model!.detail!.scopes.singleWhere(
      (s) => s.fieldId == text.fields.last.id,
    );
    await tap('approval-scope-${omitted.id}');
    await tap('approval-approve');
    await ready(() => !model!.busy && !model!.loading && !model!.reading);
    expect(model!.writeFailure, null);
    expect(model!.detail!.request.state, WorkspaceApprovalState.approved);
    expect(model!.detail!.approved.length, 2);
    final fetching = <String, Object?>{
      'command': 'file-fetch',
      'requestId': requestId,
      'itemId': fileItem.id,
      'fieldId': fileItem.fields.single.id,
      'operationId': 'native-managed-copy',
    };
    late String path;
    await t.runAsync(() async {
      expect(
        (await cli.first.call({
          'command': 'claim',
          'requestId': requestId,
        }))['status'],
        'ok',
      );
      expect(
        (await cli.first.call({
          'command': 'read',
          'requestId': requestId,
          'itemId': text.id,
          'fieldId': text.fields.first.id,
        }))['value'],
        'SYNTHETIC-ALLOWED',
      );
      expect(
        (await cli.first.call({
          'command': 'read',
          'requestId': requestId,
          'itemId': text.id,
          'fieldId': text.fields.last.id,
        }))['status'],
        'unauthorized',
      );
      checks.add(
        'real production approval controls commit a partial file/text grant used by the independent CLI',
      );
      final result = await cli.first.call(fetching);
      expect(result['status'], 'ok');
      final copy = result['delivery'] as Map;
      path = copy['path'] as String;
      expect(path, contains('/Library/Containers/'));
      expect(await File(path).readAsBytes(), original);
      expect((await cli.first.call(fetching))['delivery'], copy);
      final status =
          (await cli.first.call({
                'command': 'file-status',
                'operationId': 'native-managed-copy',
              }))['delivery']
              as Map;
      expect(status['deliveryId'], copy['deliveryId']);
      expect(status.containsKey('path'), false);
      cli.add(await _Cli.start(server!.port));
      await cli.last.call({
        'command': 'session',
        'chatLabel': 'Synthetic other native CLI',
      });
      expect((await cli.last.call(fetching))['status'], 'unauthorized');
      checks.add(
        'real SQLCipher to native protected copy to AOT CLI; exact bytes, original operation reuse and cross-session refusal',
      );
    });
    await t.runAsync(() async {
      final h = await source.grantHistory.read('request:$requestId');
      final fileScope = h.scopes.singleWhere(
        (s) => s.kind == WorkspaceApprovalScopeKind.file,
      );
      final delivery = h.events.singleWhere((e) => e.fileScopeId != null);
      expect(fileScope.fileVersion, delivery.fileVersion);
      expect(delivery.result, contains('受管副本已准备'));
      final preview = await source.grantHistory.filePreview(
        h.summary.id,
        delivery.fileScopeId!,
        page: 1,
      );
      expect(preview.file.ref.version, delivery.fileVersion);
      expect(preview.page, 1);
      expect(preview.pageCount, 2);
      expect(preview.image, isNotEmpty);
      checks.add(
        'real grant history projects exact managed delivery and renders its original PDF through the production native channel',
      );
    });
    await tap('approval-revoke');
    await ready(() => !model!.busy && !model!.loading && !model!.reading);
    expect(model!.writeFailure, null);
    expect(model!.detail!.request.state, WorkspaceApprovalState.revoked);
    await t.runAsync(() async {
      expect(
        (await cli.first.call({
          ...fetching,
          'operationId': 'after-revoke',
        }))['status'],
        'unauthorized',
      );
      await service.agent.drainInformationFileDeliveries();
      expect(await File(path).exists(), false);
      final history = await source.grantHistory.read('request:$requestId');
      expect(history.summary.state, WorkspaceGrantState.revoked);
      expect(
        history.events.singleWhere((e) => e.fileScopeId != null).result,
        contains('登记副本路径已移除'),
      );
      checks.add(
        'real revoke control blocks subsequent AOT CLI fetch and reclaims its registered copy',
      );
    });
    return NativeFileApprovalEvidence(requestId, observed.approvedOperation!);
  } finally {
    await t.pumpWidget(const SizedBox.shrink());
    model?.dispose();
    await t.runAsync(() async {
      for (final child in cli) {
        await child.close();
      }
      await server?.close();
    });
  }
}
