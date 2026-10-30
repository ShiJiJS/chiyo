// Run via scripts/qa/check-owner-cli.py. No personal library or OS key store.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/desktop_bootstrap.dart';
import 'package:info_desktop/workspace/approvals_controller.dart';
import 'package:info_desktop/workspace/grant_history_controller.dart';
import 'package:info_desktop/workspace/owner_workspace_approvals.dart';
import 'package:info_desktop/workspace/owner_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import '../test/support/desktop_platform_fixture.dart';

class _Keys implements DatabaseKeyStore {
  @override
  Future<List<int>?> read() async => List.generate(32, (i) => i + 1);
  @override
  Future<void> create(List<int> _) async =>
      throw StateError('fixture key only');
}

/// Drops a response only after the real server has completed the request.
class _Proxy {
  _Proxy(this.server, this.port) {
    server.listen(_forward);
  }
  final HttpServer server;
  final int port;
  final client = HttpClient();
  bool dropRequestReply = false;
  int requestWrites = 0;
  Future<void> _forward(HttpRequest request) async {
    try {
      final outgoing = await client.post('127.0.0.1', port, request.uri.path);
      outgoing.headers.contentType = ContentType.json;
      await outgoing.addStream(request);
      final response = await outgoing.close();
      final bytes = await response.fold<List<int>>([], (a, b) => a..addAll(b));
      if (request.uri.path == '/request') {
        requestWrites++;
        if (dropRequestReply) {
          dropRequestReply = false;
          (await request.response.detachSocket(writeHeaders: false)).destroy();
          return;
        }
      }
      request.response.statusCode = response.statusCode;
      request.response.headers.contentType = ContentType.json;
      request.response.add(bytes);
      await request.response.close();
    } on Object {
      request.response.statusCode = 503;
      request.response.write('{"status":"service_unavailable"}');
      await request.response.close();
    }
  }

  Future<void> close() async {
    await server.close(force: true);
    client.close(force: true);
  }
}

class _Cli {
  _Cli(this.process) {
    lines = StreamIterator(
      process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    errors = process.stderr.transform(utf8.decoder).join();
  }
  final Process process;
  late final StreamIterator<String> lines;
  late final Future<String> errors;
  Future<Map<String, dynamic>> command(Map<String, Object?> value) async {
    process.stdin.writeln(jsonEncode(value));
    await process.stdin.flush();
    expect(await lines.moveNext().timeout(const Duration(seconds: 15)), isTrue);
    final result = jsonDecode(lines.current) as Map<String, dynamic>;
    expect(result.containsKey('token'), isFalse);
    expect(result.containsKey('sessionSecret'), isFalse);
    expect(result.containsKey('endCapability'), isFalse);
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
    } finally {
      await lines.cancel();
    }
    expect(await errors, isEmpty);
  }
}

class _LostReply extends OwnerWorkspaceApprovals {
  _LostReply({required super.owner});
  bool loseNext = false;
  int writes = 0;
  @override
  Future<WorkspaceApprovalReceipt> change(
    WorkspaceApprovalChange change,
  ) async {
    writes++;
    final receipt = await super.change(change);
    if (loseNext) {
      loseNext = false;
      throw const WorkspaceFailure('unknown_outcome', '合成响应丢失');
    }
    return receipt;
  }
}

Future<Map<String, dynamic>> _oneShot(
  String binary,
  Map<String, Object?> input, {
  List<String> arguments = const [],
  Map<String, String>? environment,
}) async {
  final process = await Process.start(
    binary,
    arguments,
    environment: environment,
  );
  final output = process.stdout.transform(utf8.decoder).join();
  final errors = process.stderr.transform(utf8.decoder).join();
  process.stdin.write(jsonEncode(input));
  await process.stdin.close();
  try {
    expect(await process.exitCode.timeout(const Duration(seconds: 20)), 0);
  } on TimeoutException {
    process.kill();
    await process.exitCode;
    rethrow;
  }
  expect(await errors, isEmpty);
  return jsonDecode(await output) as Map<String, dynamic>;
}

void main() {
  test(
    'compiled clients and owner controllers share durable requests and exact scopes',
    () async {
      final root = Directory(Platform.environment['OWNER_CLI_ROOT']!);
      final tools = Directory(Platform.environment['OWNER_CLI_TOOLS']!);
      final phase = Platform.environment['OWNER_CLI_PHASE']!;
      expect(
        await File('${root.path}/fixture-marker').readAsString(),
        'disposable-owner-cli-v1',
      );
      expect(['live', 'reopen'], contains(phase));
      var now = DateTime.utc(2026, 10, 30);
      final repo = await EncryptedInformationRepository.open(
        '${root.path}/library',
        _Keys(),
        clock: () => now,
      );
      final service = core.InformationService(
        repository: repo,
        clock: () => now,
      );
      final bootstrap = DesktopBootstrap(
        port: 0,
        platform: NativeDesktopFixture(),
        openLibrary: () async => DesktopLibrary(
          service: service,
          backups: repo.backups,
          close: repo.close,
        ),
      );
      await bootstrap.start();
      expect(bootstrap.state, DesktopStartupState.ready);
      final approvals = _LostReply(owner: service.owner);
      final source = OwnerWorkspaceSource(
        owner: service.owner,
        approvals: approvals,
        refreshInterval: Duration.zero,
      );
      final proxy = _Proxy(
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
        bootstrap.boundPort!,
      );
      final clients = <_Cli>[];
      final checks = <String>[];
      final stateFile = File('${root.path}/identities.json');
      final state = phase == 'live'
          ? <String, dynamic>{}
          : jsonDecode(await stateFile.readAsString()) as Map<String, dynamic>;
      var stopped = false;
      Future<_Cli> cli() async {
        final c = _Cli(
          await Process.start('${tools.path}/info', [
            '--port',
            '${proxy.server.port}',
          ]),
        );
        clients.add(c);
        return c;
      }

      Future<void> decide(
        String request,
        WorkspaceApprovalAction action, {
        String? select,
      }) async {
        final m = ApprovalsController(source.approvals, const Stream.empty());
        try {
          await m.open(request);
          expect(m.readFailure, isNull);
          if (select != null) {
            for (final scope in m.detail!.scopes) {
              if (scope.fieldId != select) m.toggle(scope.id);
            }
          }
          m.lifetime(1);
          await m.decide(action);
          if (m.uncertain) {
            final writes = approvals.writes;
            await m.reconcile();
            expect(m.uncertain, isFalse);
            expect(approvals.writes, writes);
            checks.add('lost-owner-reply-queried-without-replay');
          }
          expect(m.writeFailure, isNull);
        } finally {
          m.dispose();
        }
      }

      Future<void> stop() async {
        await source.dispose();
        await bootstrap.runtime!.stop();
        bootstrap.runtime!.dispose();
        bootstrap.dispose();
        stopped = true;
      }

      try {
        final c = await cli();
        if (phase == 'reopen') {
          final detail = await source.readDetail(
            WorkspaceRecordRef(
              WorkspaceRecordKind.information,
              state['item'] as String,
            ),
          );
          expect(detail.values['host'], 'CORRECTED-HOST');
          expect(detail.fieldIds['host'], state['host']);
          final history = await source.grantHistory.query(
            const WorkspaceGrantQuery(limit: 100),
          );
          expect(history.total, state['historyCount']);
          expect(history.items.any((h) => h.state.isActive), isFalse);
          final receipt = await source.approvals.receipt(
            state['approvalOperation'] as String,
          );
          expect(receipt, isNotNull);
          final old = await source.grantHistory.read(
            'request:${state['openRequest']}',
          );
          expect(old.summary.state, WorkspaceGrantState.sessionEnded);
          expect(
            (await c.command({
              'command': 'session',
              'chatLabel': 'reopened',
            }))['status'],
            'ok',
          );
          expect(
            (await c.command({
              'command': 'claim',
              'requestId': state['openRequest'],
            }))['status'],
            'unauthorized',
          );
          expect(
            (await c.command({
              'command': 'read',
              'requestId': state['openRequest'],
              'itemId': state['item'],
              'fieldId': state['host'],
            }))['status'],
            'unauthorized',
          );
          checks.addAll([
            'independent-owner-reopen-preserves-data-and-history',
            'reopen-does-not-restore-capabilities',
          ]);
        } else {
          final template = await source.loadTemplate('server');
          final saved = await source.createRecord(
            WorkspaceCreate(
              operationId: 'cli-seed',
              typeId: 'server',
              name: 'CLI合成服务器',
              values: {
                'host': 'PRIVATE-HOST',
                'port': '22',
                'user': 'PRIVATE-USER',
                'purpose': '',
              },
              expectedTemplateVersion: template['templateVersion'] as String,
              expectedTemplateDigest: template['packageDigest'] as String,
            ),
          );
          expect(
            saved,
            isA<WorkspaceSaved>(),
            reason: saved is WorkspaceRejected ? saved.failure.code : null,
          );
          final detail = (saved as WorkspaceSaved).detail;
          state['item'] = detail.record.ref.id;
          state['host'] = detail.fieldIds['host'];
          state['user'] = detail.fieldIds['user'];
          final fields = [
            for (final key in ['host', 'user'])
              {'itemId': state['item'], 'fieldId': state[key]},
          ];
          Map<String, Object?> read(String id, String field) => {
            'command': 'read',
            'requestId': id,
            'itemId': state['item'],
            'fieldId': field,
          };
          Future<String> request(String op) async {
            final result = await c.command({
              'command': 'request',
              'operationId': op,
              'purpose': 'CLI合成用途',
              'fields': fields,
            });
            expect(result['status'], 'pending');
            return result['requestId'] as String;
          }

          final catalog = await c.command({
            'command': 'catalog',
            'query': 'CLI合成服务器',
          });
          expect(catalog['total'], 1);
          expect(jsonEncode(catalog), isNot(contains('PRIVATE-')));
          expect(
            (await c.command({
              'command': 'session',
              'chatLabel': 'CLI合成聊天',
            }))['status'],
            'ok',
          );
          final r = await request('partial');
          expect(
            (await c.command({'command': 'claim', 'requestId': r}))['status'],
            'pending',
          );
          expect(
            (await c.command(read(r, state['host'] as String)))['status'],
            'unauthorized',
          );
          expect(await request('partial'), r);
          expect(service.owner.informationRequests, hasLength(1));
          expect(
            (await c.command({
              'command': 'request',
              'operationId': 'partial',
              'purpose': 'changed',
              'fields': fields,
            }))['status'],
            'operation_conflict',
          );
          checks.addAll([
            'real-workspace-save',
            'catalog-no-body',
            'pending-denied',
            'request-idempotency-and-conflict',
          ]);
          final other = await cli();
          expect(
            (await other.command({
              'command': 'session',
              'chatLabel': 'CLI合成聊天',
            }))['status'],
            'ok',
          );
          expect(
            (await other.command({
              'command': 'claim',
              'requestId': r,
            }))['status'],
            'unauthorized',
          );
          approvals.loseNext = true;
          await decide(
            r,
            WorkspaceApprovalAction.approve,
            select: state['host'] as String,
          );
          final grant = await c.command({'command': 'claim', 'requestId': r});
          expect(grant['status'], 'ok');
          expect(grant['fields'], [fields.first]);
          expect(
            (await c.command(read(r, state['host'] as String)))['value'],
            'PRIVATE-HOST',
          );
          expect(
            (await c.command(read(r, state['user'] as String)))['status'],
            'unauthorized',
          );
          expect(
            (await other.command({
              'command': 'claim',
              'requestId': r,
            }))['status'],
            'unauthorized',
          );
          await service.owner.correctValue(
            core.FieldRef(state['item'] as String, state['host'] as String),
            'CORRECTED-HOST',
          );
          expect(
            (await c.command(read(r, state['host'] as String)))['value'],
            'CORRECTED-HOST',
          );
          expect(
            (await c.command({
              'command': 'claim',
              'requestId': r,
            }))['expiresAt'],
            grant['expiresAt'],
          );
          final history = GrantHistoryController(
            source.grantHistory,
            source.approvals,
            const Stream.empty(),
          );
          try {
            await history.open('request:$r');
            expect(history.canRevoke, isTrue);
            expect(history.detail!.summary.operationCount, 3);
            await history.revoke();
            expect(history.decisionFailure, isNull);
            expect(history.detail!.summary.state, WorkspaceGrantState.revoked);
          } finally {
            history.dispose();
          }
          expect(
            (await c.command(read(r, state['host'] as String)))['status'],
            'unauthorized',
          );
          checks.addAll([
            'partial-approval-and-cross-chat-denial',
            'stable-correction-fixed-deadline',
            'history-revoke-stops-cached-bearer',
          ]);
          final denied = await request('denied');
          await decide(denied, WorkspaceApprovalAction.deny);
          expect(
            (await c.command({
              'command': 'claim',
              'requestId': denied,
            }))['status'],
            'denied',
          );
          final expired = await request('expires');
          await decide(expired, WorkspaceApprovalAction.approve);
          expect(
            (await c.command({
              'command': 'claim',
              'requestId': expired,
            }))['status'],
            'ok',
          );
          now = now.add(const Duration(minutes: 2));
          expect(
            (await c.command(read(expired, state['host'] as String)))['status'],
            'unauthorized',
          );
          expect(
            (await source.grantHistory.read('request:$expired')).summary.state,
            WorkspaceGrantState.expired,
          );
          checks.add('denial-and-fixed-expiry');
          proxy.dropRequestReply = true;
          final before = proxy.requestWrites;
          final unknown = await c.command({
            'command': 'request',
            'operationId': 'lost-request',
            'purpose': 'lost reply',
            'fields': fields,
          });
          expect(unknown['status'], 'request_unknown');
          expect(proxy.requestWrites, before + 1);
          final recovered = await c.command({
            'command': 'request-status',
            'operationId': 'lost-request',
          });
          expect(recovered['status'], 'pending');
          expect(proxy.requestWrites, before + 1);
          await decide(
            recovered['requestId'] as String,
            WorkspaceApprovalAction.deny,
          );
          checks.add('lost-request-reply-found-without-resubmission');
          final hooks = Directory('${root.path}/synthetic-hook-state');
          final started = await _oneShot(
            '${tools.path}/info-codex-hook',
            {
              'hook_event_name': 'SessionStart',
              'source': 'startup',
              'session_id': 'm03-synthetic-chat',
            },
            arguments: [
              '--port',
              '${proxy.server.port}',
              '--state-root',
              hooks.path,
            ],
          );
          final context =
              jsonDecode(
                    started['hookSpecificOutput']['additionalContext']
                        as String,
                  )
                  as Map<String, dynamic>;
          final association = context['association'] as String;
          Future<Map<String, dynamic>> adapter(
            Map<String, Object?> command, {
            String chat = 'm03-synthetic-chat',
          }) => _oneShot(
            '${tools.path}/info-codex',
            {'association': association, ...command},
            environment: {'CODEX_THREAD_ID': chat},
          );
          final hookRequest = await adapter({
            'command': 'request',
            'operationId': 'hook-read',
            'purpose': 'synthetic lifecycle',
            'fields': fields,
          });
          expect(hookRequest['status'], 'pending');
          final hookId = hookRequest['requestId'] as String;
          await decide(
            hookId,
            WorkspaceApprovalAction.approve,
            select: state['host'] as String,
          );
          expect(
            (await adapter(read(hookId, state['host'] as String)))['value'],
            'CORRECTED-HOST',
          );
          expect(
            (await adapter(
              read(hookId, state['host'] as String),
              chat: 'unrelated-synthetic-chat',
            ))['status'],
            'association_unavailable',
          );
          final ended = await _oneShot(
            '${tools.path}/info-codex-hook',
            {
              'hook_event_name': 'SessionEnd',
              'session_id': 'm03-synthetic-chat',
            },
            arguments: ['--state-root', hooks.path],
          );
          expect(ended['systemMessage'], contains('ended'));
          expect(
            (await adapter(read(hookId, state['host'] as String)))['status'],
            'unauthorized',
          );
          expect(
            (await source.grantHistory.read('request:$hookId')).summary.state,
            WorkspaceGrantState.sessionEnded,
          );
          checks.add('synthetic-hook-end-invalidates-one-shot-client');
          final openRequest = await request('closing');
          await decide(openRequest, WorkspaceApprovalAction.approve);
          expect(
            (await c.command({
              'command': 'claim',
              'requestId': openRequest,
            }))['status'],
            'ok',
          );
          state['openRequest'] = openRequest;
          // Obtain a known durable receipt by one additional genuine denial.
          final finalRequest = await request('final-denial');
          final finalDetail = await source.approvals.read(finalRequest);
          final finalReceipt = await source.approvals.change(
            WorkspaceApprovalChange(
              operationId: 'durable-final-receipt',
              requestId: finalRequest,
              reviewToken: finalDetail.reviewToken,
              action: WorkspaceApprovalAction.deny,
            ),
          );
          state['approvalOperation'] = finalReceipt.operationId;
          state['historyCount'] = (await source.grantHistory.query(
            const WorkspaceGrantQuery(limit: 100),
          )).total;
          await stateFile.writeAsString(jsonEncode(state));
          await stop();
          expect(
            (await c.command(
              read(openRequest, state['host'] as String),
            ))['status'],
            'service_unavailable',
          );
          checks.add('application-stop-closes-endpoint-and-capabilities');
        }
        await File('${root.path}/$phase-result.json').writeAsString(
          jsonEncode({
            'phase': phase,
            'passed': true,
            'pid': pid,
            'clientPids': clients.map((c) => c.process.pid).toList(),
            'checks': checks,
          }),
        );
      } finally {
        for (final client in clients) {
          await client.close();
        }
        await proxy.close();
        if (!stopped) await stop();
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
