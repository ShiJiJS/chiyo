@TestOn('!windows')
library;

// Real OnlineServer fixture uses POSIX secret mounts. Windows behavior is
// exercised by the explicit existing-NAS tests, without relaxing that boundary.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_desktop/desktop_controls.dart';
import 'package:info_desktop/workspace/owner_agent_templates.dart';
import 'package:info_desktop/workspace/owner_proposal_password_input.dart';
import 'package:info_desktop/workspace/proposals_controller.dart';
import 'package:info_desktop/workspace/remote_proposal_password_store.dart';
import 'package:info_desktop/workspace/remote_workspace_proposals.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_remote/owner_client.dart';
import 'package:info_server/agent_devices.dart';
import 'package:info_server/mounted_database_key_store.dart';
import 'package:info_server/online_server.dart';
import 'package:info_server/server_configuration.dart';
import 'package:info_storage/info_storage.dart';
import '../../server/test/support/tls_fixture.dart';

class _RealHttp extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final previous = HttpOverrides.current;
  setUpAll(() => HttpOverrides.global = _RealHttp());
  tearDownAll(() => HttpOverrides.global = previous);
  testWidgets(
    'private fill loss recovers the exact operation after restart; unknown and absent outcomes never admit part of a proposal',
    (t) async {
      late Directory root;
      late EncryptedInformationRepository repo;
      late core.OnlineInformationRuntime runtime;
      late OnlineServer server;
      late OwnerClient client;
      late HttpServer proxy;
      late HttpClient upstream;
      late SecurityContext tls;
      late String token;
      const serverId = 'synthetic-password-recovery';
      var failLookup = false, dropFill = true, dropBeforeCommit = false;
      var posts = 0, decisions = 0;
      final operations = <String>[];
      Future<void> open([int port = 0]) async {
        repo = await EncryptedInformationRepository.open(
          '${root.path}/data',
          MountedDatabaseKeyStore('${root.path}/secrets/database.key'),
        );
        runtime = await core.OnlineInformationRuntime.open(repository: repo);
        server = await OnlineServer.start(
          runtime: runtime,
          devices: AgentDeviceRegistry(repo),
          tls: tls,
          ownerToken: token,
          serverId: serverId,
          port: port,
        );
      }

      Future<void> close() async {
        await server.close();
        await runtime.close();
        await repo.close();
      }

      await t.runAsync(() async {
        root = await Directory.systemTemp.createTemp('proposal-password-loss-');
        await initializeServerSecrets('${root.path}/secrets');
        final fixture = await createTlsFixture(root);
        tls = SecurityContext()
          ..useCertificateChain(fixture.certificate)
          ..usePrivateKey(fixture.privateKey);
        final trust = SecurityContext(withTrustedRoots: false)
          ..setTrustedCertificates(fixture.ca);
        token = base64Url
            .encode(
              await File('${root.path}/secrets/owner.token').readAsBytes(),
            )
            .replaceAll('=', '');
        await open();
        upstream = HttpClient(context: trust);
        proxy = await HttpServer.bindSecure(
          InternetAddress.loopbackIPv4,
          0,
          tls,
        );
        proxy.listen((request) async {
          try {
            final fill =
                request.method == 'POST' &&
                request.uri.path.endsWith('/passwords/fill');
            final bytes = await request.fold<List<int>>(
              [],
              (a, b) => a..addAll(b),
            );
            if (fill) {
              posts++;
              operations.add(
                (jsonDecode(utf8.decode(bytes)) as Map)['operationId']
                    as String,
              );
            }
            if (request.uri.path.endsWith('/decisions')) decisions++;
            if (failLookup &&
                request.uri.path.contains('/password-operations/')) {
              request.response.statusCode = 503;
              request.response.headers.set('x-chiyo-server-id', serverId);
              request.response.headers.contentType = ContentType.json;
              request.response.write(
                jsonEncode({'error': 'server_unavailable'}),
              );
              await request.response.close();
              return;
            }
            if (fill && dropBeforeCommit) {
              (await request.response.detachSocket(
                writeHeaders: false,
              )).destroy();
              return;
            }
            final next = await upstream.openUrl(
              request.method,
              Uri.parse(
                'https://127.0.0.1:${server.port}',
              ).resolve(request.uri.toString()),
            );
            for (final key in [
              'authorization',
              'content-type',
              'x-chiyo-server-id',
            ]) {
              final value = request.headers.value(key);
              if (value != null) next.headers.set(key, value);
            }
            next.add(bytes);
            final response = await next.close();
            final body = await response.fold<List<int>>(
              [],
              (a, b) => a..addAll(b),
            );
            if (fill && dropFill) {
              (await request.response.detachSocket(
                writeHeaders: false,
              )).destroy();
              return;
            }
            request.response.statusCode = response.statusCode;
            request.response.headers.contentType = ContentType.json;
            request.response.headers.set('x-chiyo-server-id', serverId);
            request.response.add(body);
            await request.response.close();
          } on Object {
            try {
              await request.response.close();
            } on Object {
              /* disconnected */
            }
          }
        });
        client = await OwnerClient.connect(
          address: Uri.parse('https://127.0.0.1:${proxy.port}'),
          token: token,
          trust: trust,
        );
      });
      var phase = 'setup';
      Future<void> until(bool Function() ready) async {
        for (var i = 0; i < 400; i++) {
          if (ready()) return;
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await t.pump(const Duration(milliseconds: 30));
        }
        fail('Password recovery did not settle: $phase');
      }

      Future<T> io<T>(Future<T> Function() action) async {
        var done = false;
        late T value;
        Object? error;
        await t.runAsync(() async {
          unawaited(
            action().then<void>(
              (result) {
                value = result;
                done = true;
              },
              onError: (Object e) {
                error = e;
                done = true;
              },
            ),
          );
        });
        await until(() => done);
        if (error != null) throw error!;
        return value;
      }

      Future<String> proposal() => io(() async {
        final templates = currentAgentTemplates(runtime.service.owner);
        final template = templates.templates.singleWhere(
          (t) => t.id == 'credential.accountPassword',
        );
        final session = runtime.service.agent.openSession(
          'Synthetic response loss',
        );
        return runtime.service.agent.submitImport(session, [
          for (final key in ['first', 'second'])
            core.ImportItemInput(
              'Synthetic $key',
              '',
              [],
              key: key,
              templateId: template.id,
              templateVersion: template.version,
              templateDigest: template.digest,
              credential: core.CredentialImportInput.owner(
                account: '$key-user',
              ),
            ),
        ]);
      });
      final privateStore = RemoteProposalPasswordStore(client);
      final passwords = OwnerProposalPasswords.remote(client);
      final source = RemoteWorkspaceProposals(client, changed: () {});
      final model = ProposalsController(source, const Stream.empty())
        ..bindPasswords(passwords);
      Future<void> showInputs() async {
        final d = model.detail!;
        await t.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ListenableBuilder(
                listenable: passwords,
                builder: (context, _) => Column(
                  children: [
                    for (final item in d.items)
                      passwords.input(
                        d.summary.id,
                        d.summary.version,
                        item.id,
                        enabled: true,
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
        for (final item in d.items) {
          final field = find.byKey(
            ValueKey('proposal-owner-password-${item.id}'),
          );
          await until(() => t.widget<DesktopTextField>(field).enabled == true);
        }
      }

      Future<void> enterAll(String suffix) async {
        await showInputs();
        for (final item in model.detail!.items) {
          await t.enterText(
            find.byKey(ValueKey('proposal-owner-password-${item.id}')),
            'SYNTHETIC_${item.credential!.account}_$suffix',
          );
          await t.pump();
        }
        expect(model.canConfirm, true);
      }

      Matcher fails(String code) =>
          throwsA(isA<WorkspaceFailure>().having((e) => e.code, 'code', code));
      try {
        phase = 'automatic receipt recovery';
        final first = await proposal();
        final values = {
          'first': 'SYNTHETIC_AUTO_FIRST',
          'second': 'SYNTHETIC_AUTO_SECOND',
        };
        final result = await io(() => privateStore.fill(first, 1, values));
        expect(result.resultingVersion, 2);
        expect(posts, 1);
        expect(
          (await io(() => privateStore.fill(first, 1, values))).operationId,
          result.operationId,
        );
        expect(posts, 1);
        expect(repo.managedCredentials, isEmpty);
        expect(
          await io(() => privateStore.read(first, 2, 'first')),
          values['first'],
        );
        await io(
          () => expectLater(
            privateStore.read(first, 1, 'first'),
            fails('conflict'),
          ),
        );

        phase = 'lost fill and failed receipt query';
        final second = await proposal();
        await io(() => model.open(second));
        await enterAll('LOST');
        failLookup = true;
        await io(() => model.decide(WorkspaceProposalAction.confirm));
        expect(model.uncertain, true);
        expect(model.frozen, true);
        expect(posts, 2);
        expect(decisions, 0);
        expect(repo.managedCredentials, isEmpty);
        await io(() => model.decide(WorkspaceProposalAction.confirm));
        await io(model.reconcile);
        expect(posts, 2);
        expect(model.uncertain, true);
        expect(model.detail!.summary.version, 1);
        expect(decisions, 0);

        phase = 'reopen encrypted server and reconcile';
        await io(() async {
          final port = server.port;
          await close();
          await open(port);
        });
        failLookup = false;
        await io(model.reconcile);
        expect(model.uncertain, false);
        expect(model.detail!.summary.version, 2);
        expect(model.notice, contains('尚未入库'));
        expect(decisions, 0);
        expect(repo.managedCredentials, isEmpty);
        await showInputs();
        for (final item in model.detail!.items) {
          final field = t.widget<DesktopTextField>(
            find.byKey(ValueKey('proposal-owner-password-${item.id}')),
          );
          expect(
            field.controller!.text,
            'SYNTHETIC_${item.credential!.account}_LOST',
          );
        }
        dropFill = false;
        await io(() => model.decide(WorkspaceProposalAction.confirm));
        expect(model.writeFailure, isNull, reason: model.writeFailure?.code);
        expect(model.detail!.summary.status, WorkspaceProposalStatus.completed);
        expect(repo.managedCredentials, hasLength(2));
        expect(decisions, 1);
        expect(runtime.service.owner.credentialUseRequests, isEmpty);

        phase = 'confirmed absence allows explicit corrected retry';
        final third = await proposal();
        await io(() => model.open(third));
        await enterAll('ABSENT');
        dropBeforeCommit = true;
        await io(() => model.decide(WorkspaceProposalAction.confirm));
        expect(model.uncertain, true);
        final droppedOperation = operations.last;
        expect(repo.managedCredentials, hasLength(2));
        await io(model.reconcile);
        expect(model.uncertain, false);
        expect(model.detail!.summary.version, 1);
        expect(model.canConfirm, true);
        expect(decisions, 1);
        await enterAll('CORRECTED');
        dropBeforeCommit = false;
        await io(() => model.decide(WorkspaceProposalAction.confirm));
        expect(model.writeFailure, isNull, reason: model.writeFailure?.code);
        expect(operations.last, isNot(droppedOperation));
        expect(repo.managedCredentials, hasLength(4));
        expect(decisions, 2);
        expect(
          repo.credentialMaterials.map((m) => utf8.decode(m.bytes)),
          containsAll([
            'SYNTHETIC_first-user_CORRECTED',
            'SYNTHETIC_second-user_CORRECTED',
          ]),
        );
        expect(t.takeException(), isNull);
      } finally {
        phase = 'cleanup';
        await t.pumpWidget(const SizedBox());
        model.dispose();
        passwords.dispose();
        privateStore.dispose();
        await io(() async {
          client.close();
          await proxy.close(force: true);
          upstream.close(force: true);
          await close();
          await root.delete(recursive: true);
        });
      }
    },
  );
}
