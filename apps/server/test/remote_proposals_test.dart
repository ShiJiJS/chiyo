import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_remote/agent_connection.dart';
import 'package:info_remote/owner_client.dart';
import 'package:info_server/agent_devices.dart';
import 'package:info_server/mounted_database_key_store.dart';
import 'package:info_server/online_server.dart';
import 'package:info_server/server_configuration.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_workspace/proposal_transport.dart';
import 'package:info_workspace/workspace_information_codec.dart';
import 'package:info_workspace/workspace_source.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'support/tls_fixture.dart';

void main() {
  test(
    'formal CLI submits typed linked proposals; owner reviews, recovers failures, restarts and corrects stale updates',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'chiyo-remote-proposals-',
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
      Future<void> open({int port = 0}) async {
        repo = await EncryptedInformationRepository.openOnline(
          '${root.path}/data',
          keys,
        );
        runtime = await OnlineInformationRuntime.open(repository: repo);
        server = await OnlineServer.start(
          runtime: runtime,
          devices: AgentDeviceRegistry(repo),
          tls: tls,
          ownerToken: token,
          serverId: 'remote-proposals-synthetic',
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

      await open();
      addTearDown(() async {
        await close();
        await root.delete(recursive: true);
      });
      await runtime.run(
        () => runtime.service.owner.createDirectory('Existing'),
      );
      final enrolled = await owner.request('POST', '/v1/owner/devices', {
        'operationId': 'proposal-enrollment',
        'name': 'Synthetic proposal CLI',
      });
      final config = await AgentConnectionProfile(
        address: owner.address,
        deviceToken: enrolled['deviceToken'] as String,
        serverId: owner.serverId,
        certificate: await File(fixture.ca).readAsString(),
      ).saveIn(Directory('${root.path}/connection'));
      Future<Map<String, dynamic>> invoke(
        String entry,
        Map<String, Object?> input, {
        List<String> args = const [],
      }) async {
        final process = await Process.start(
          Platform.resolvedExecutable,
          ['run', 'bin/$entry.dart', ...args],
          workingDirectory: Directory('../../packages/info_cli').absolute.path,
          environment: {'CODEX_THREAD_ID': 'proposal-root'},
        );
        final output = utf8.decoder.bind(process.stdout).join();
        final errors = utf8.decoder.bind(process.stderr).join();
        try {
          process.stdin.writeln(jsonEncode(input));
          await process.stdin.close();
          expect(
            await process.exitCode.timeout(const Duration(seconds: 30)),
            0,
          );
          final text = await output;
          await errors;
          return jsonDecode(text.trim().split('\n').last)
              as Map<String, dynamic>;
        } finally {
          process.kill();
        }
      }

      final started = await invoke(
        'codex_hook',
        {
          'hook_event_name': 'SessionStart',
          'source': 'startup',
          'session_id': 'proposal-root',
        },
        args: [
          '--connection',
          config.path,
          '--state-root',
          '${root.path}/state',
        ],
      );
      final association =
          jsonDecode(
                started['hookSpecificOutput']['additionalContext'] as String,
              )['association']
              as String;
      Future<Map<String, dynamic>> cli(
        String command, [
        Map<String, Object?> values = const {},
      ]) => invoke('codex_info', {
        'association': association,
        'command': command,
        ...values,
      });
      final directories = await cli('directory-list');
      expect(jsonEncode(directories), contains('Existing'));
      final template =
          (await cli('template-read', {'templateId': 'document'}))['template']
              as Map;
      final example =
          ((template['submissionExample'] as Map)['items'] as List).single
              as Map;
      final submission = <String, Object?>{
        'operationId': 'pair-once',
        'purpose': 'Synthetic related notes',
        'items': [
          for (final key in ['a', 'b'])
            {
              ...Map<String, Object?>.from(example),
              'key': key,
              'name': 'Synthetic $key',
              'values': {
                'bodyFormat': 'markdown',
                'body': '## Synthetic $key\n\n- Original content',
              },
              'suggestedDirectory': 'Existing/Imported',
              'relations': {
                'related': [
                  {'kind': 'information', 'itemKey': key == 'a' ? 'b' : 'a'},
                ],
              },
            },
        ],
      };
      final observation = (await owner.request(
        'GET',
        '/v1/server',
      ))['workspaceObservation'];
      final pending = await cli('import-submit', submission);
      expect(pending['status'], 'pending');
      final id = pending['proposalId'] as String;
      expect((await cli('import-submit', submission))['proposalId'], id);
      expect(
        (await cli('import-status', {
          'operationId': 'pair-once',
        }))['proposalId'],
        id,
      );
      expect(
        (await owner.request('GET', '/v1/server'))['workspaceObservation'],
        isNot(observation),
      );
      expect(await owner.information(), isEmpty);
      final detail = proposalDetailFromJson(
        await owner.request(
          'GET',
          '/v1/owner/proposals/${Uri.encodeComponent(id)}',
        ),
      );
      expect(detail.items, hasLength(2));
      expect(
        detail.items.every((i) => i.proposed.record.type.id == 'document'),
        true,
      );
      final catalog = await owner.request('GET', '/v1/owner/proposals/catalog');
      expect(
        (catalog['directories'] as List).where((d) => d['name'] == 'Existing'),
        hasLength(1),
      );
      expect(
        (catalog['directories'] as List).singleWhere(
          (d) => d['name'] == 'Imported',
        )['proposed'],
        true,
      );
      final first = detail.items.first;
      final relationPreview = proposalItemFromJson(
        await owner.request(
          'POST',
          '/v1/owner/proposals/${Uri.encodeComponent(id)}/related',
          {
            'version': detail.summary.version,
            'record': {
              'kind': 'information',
              'id': first.proposed.relations['related']!.single.id,
            },
          },
        ),
      );
      expect(
        relationPreview.proposed.record.name,
        detail.items.last.proposed.record.name,
      );
      WorkspaceProposalChange decision(
        List<WorkspaceProposalItemReview> reviewed, {
        String operation = 'save-once',
      }) => WorkspaceProposalChange(
        operationId: operation,
        proposalId: id,
        version: detail.summary.version,
        reviewToken: detail.reviewToken,
        action: WorkspaceProposalAction.confirm,
        reviewed: reviewed,
      );
      final reviews = detail.items
          .map(WorkspaceProposalItemReview.fromItem)
          .toList();
      await expectLater(
        owner.request(
          'POST',
          '/v1/owner/proposals/decisions',
          proposalChangeToJson(decision([reviews.first])),
        ),
        throwsA(
          isA<RemoteFailure>().having(
            (e) => e.code,
            'code',
            'proposal_incomplete',
          ),
        ),
      );
      expect(await owner.information(), isEmpty);
      expect(runtime.service.owner.directories, hasLength(1));
      final invalidFormat = WorkspaceProposalItemReview(
        itemId: first.id,
        name: first.proposed.record.name,
        description: first.proposed.record.description,
        directoryId: first.proposed.record.directoryId,
        values: {...first.proposed.values, 'bodyFormat': 'html'},
        relations: first.proposed.relations,
      );
      await expectLater(
        owner.request(
          'POST',
          '/v1/owner/proposals/decisions',
          proposalChangeToJson(
            decision([invalidFormat, reviews.last], operation: 'bad-format'),
          ),
        ),
        throwsA(
          isA<RemoteFailure>()
              .having((e) => e.code, 'code', 'validation')
              .having((e) => e.fieldErrors, 'fieldErrors', isNotEmpty),
        ),
      );
      expect(await owner.information(), isEmpty);
      reviews[0] = WorkspaceProposalItemReview(
        itemId: first.id,
        name: first.proposed.record.name,
        description: first.proposed.record.description,
        directoryId: first.proposed.record.directoryId,
        values: {
          ...first.proposed.values,
          'body': '## Owner corrected\n\n- Reviewed content',
        },
        relations: first.proposed.relations,
      );
      final change = decision(reviews);
      Future<void> sql(String statement) async {
        // Error injection only, on this isolated encrypted fixture. All actual
        // admission still goes through the normal HTTPS owner decision endpoint.
        final db = sqlite3.open('${root.path}/data/library.db');
        try {
          final hex = (await keys.read())!
              .map((b) => b.toRadixString(16).padLeft(2, '0'))
              .join();
          db.execute('PRAGMA key = "x\'$hex\'"');
          db.execute(statement);
        } finally {
          db.close();
        }
      }

      await sql(
        "CREATE TRIGGER synthetic_admission_failure BEFORE INSERT ON owner_proposal_operations WHEN NEW.operation_id='save-once' BEGIN SELECT RAISE(ABORT,'synthetic failure'); END",
      );
      await expectLater(
        owner.request(
          'POST',
          '/v1/owner/proposals/decisions',
          proposalChangeToJson(change),
        ),
        throwsA(
          isA<RemoteFailure>().having((e) => e.code, 'code', 'service_failure'),
        ),
      );
      expect(await owner.information(), isEmpty);
      expect(runtime.service.owner.directories, hasLength(1));
      await expectLater(
        owner.request('GET', '/v1/owner/proposals/operations/save-once'),
        throwsA(
          isA<RemoteFailure>().having(
            (e) => e.code,
            'code',
            'operation_not_found',
          ),
        ),
      );
      await sql('DROP TRIGGER synthetic_admission_failure');
      final receipt = proposalReceiptFromJson(
        await owner.request(
          'POST',
          '/v1/owner/proposals/decisions',
          proposalChangeToJson(change),
        ),
      );
      WorkspaceProposalExpectation(detail).check(change, receipt);
      expect(receipt.records, hasLength(2));
      expect((await owner.information()), hasLength(2));
      expect(
        runtime.service.owner.directories
            .map((d) => d.name)
            .where((n) => n == 'Existing'),
        hasLength(1),
      );
      expect(
        (await cli('import-status', {'operationId': 'pair-once'}))['status'],
        'confirmed',
      );
      final repeated = proposalReceiptFromJson(
        await owner.request(
          'POST',
          '/v1/owner/proposals/decisions',
          proposalChangeToJson(change),
        ),
      );
      expect(
        repeated.records.map((r) => r.ref),
        receipt.records.map((r) => r.ref),
      );
      final record = receipt.records.first.ref;
      final saved = proposalItemFromJson(
        await owner.request(
          'POST',
          '/v1/owner/proposals/${Uri.encodeComponent(id)}/saved',
          {
            'record': {'kind': record.kind.name, 'id': record.id},
          },
        ),
      );
      expect(saved.proposed.values['body'], reviews.first.values['body']);
      expect(
        saved.proposed.relations['related']!.single,
        receipt.records.last.ref,
      );
      final currentPort = server.port;
      await close();
      await open(port: currentPort);
      expect(
        (await cli('import-status', {'operationId': 'pair-once'}))['status'],
        'confirmed',
      );
      expect(
        proposalReceiptFromJson(
          await owner.request(
            'GET',
            '/v1/owner/proposals/operations/save-once',
          ),
        ).records.map((r) => r.ref),
        receipt.records.map((r) => r.ref),
      );
      final other = await OwnerClient.connect(
        address: owner.address,
        token: token,
        trust: trust,
      );
      try {
        final actual = (await other.information()).singleWhere(
          (i) => i.id == record.id,
        );
        expect(actual.layout!.typeId, 'document');
        expect(
          actual.fields.any((f) => f.value == reviews.first.values['body']),
          true,
        );
        final update = <String, Object?>{
          'itemId': record.id,
          'baseVersion': 1,
          'templateId': 'document',
          'templateVersion': template['version'],
          'templateDigest': template['digest'],
          'values': {...saved.proposed.values, 'body': 'AI revised text'},
        };
        final proposed = await cli('update-submit', {
          'operationId': 'update-once',
          'update': update,
        });
        expect(proposed['status'], 'pending');
        final updateId = proposed['proposalId'] as String;
        final oldReview = proposalDetailFromJson(
          await owner.request(
            'GET',
            '/v1/owner/proposals/${Uri.encodeComponent(updateId)}',
          ),
        );
        expect(
          oldReview.items.single.before!.values['body'],
          reviews.first.values['body'],
        );
        expect(
          oldReview.items.single.changes.any(
            (c) => c.after == 'AI revised text',
          ),
          true,
        );
        await other.save(
          'manual-owner-edit',
          WorkspaceInformationCodec().edit(
            WorkspaceEdit(
              operationId: 'manual-owner-edit',
              expectedVersion: actual.version,
              record: saved.proposed.record,
              values: {
                ...saved.proposed.values,
                'body': 'Concurrent owner edit',
              },
              relations: saved.proposed.relations,
            ),
            actual,
          ),
        );
        final stale = WorkspaceProposalChange(
          operationId: 'stale-review',
          proposalId: updateId,
          version: oldReview.summary.version,
          reviewToken: oldReview.reviewToken,
          action: WorkspaceProposalAction.confirm,
          reviewed: oldReview.items.map(WorkspaceProposalItemReview.fromItem),
        );
        await expectLater(
          owner.request(
            'POST',
            '/v1/owner/proposals/decisions',
            proposalChangeToJson(stale),
          ),
          throwsA(
            isA<RemoteFailure>().having((e) => e.code, 'code', 'conflict'),
          ),
        );
        expect(
          (await other.information())
              .singleWhere((i) => i.id == record.id)
              .version,
          2,
        );
        final revised = await cli('update-revise', {
          'proposalId': updateId,
          'version': oldReview.summary.version,
          'update': {...update, 'baseVersion': 2},
        });
        expect(revised['status'], 'pending');
        final fresh = proposalDetailFromJson(
          await owner.request(
            'GET',
            '/v1/owner/proposals/${Uri.encodeComponent(updateId)}',
          ),
        );
        expect(
          fresh.items.single.before!.values['body'],
          'Concurrent owner edit',
        );
        final finalChange = WorkspaceProposalChange(
          operationId: 'approve-revised',
          proposalId: updateId,
          version: fresh.summary.version,
          reviewToken: fresh.reviewToken,
          action: WorkspaceProposalAction.confirm,
          reviewed: fresh.items.map(WorkspaceProposalItemReview.fromItem),
        );
        final finalReceipt = proposalReceiptFromJson(
          await owner.request(
            'POST',
            '/v1/owner/proposals/decisions',
            proposalChangeToJson(finalChange),
          ),
        );
        WorkspaceProposalExpectation(fresh).check(finalChange, finalReceipt);
        expect(finalReceipt.records.single.version, 3);
        expect(
          (await cli('update-status', {
            'operationId': 'update-once',
          }))['status'],
          'confirmed',
        );
        expect(
          (await other.information())
              .singleWhere((i) => i.id == record.id)
              .fields
              .any((f) => f.value == 'AI revised text'),
          true,
        );
      } finally {
        other.close();
      }
      final denied = await cli('import-submit', {
        'operationId': 'missing-credential-template-snapshot',
        'items': [
          {
            'name': 'No credential shortcut',
            'description': '',
            'templateId': 'credential.token',
            'values': {},
            'credential': {
              'source': 'agentString',
              'contextExposed': true,
              'secret': 'SYNTHETIC-NOT-SAVED',
            },
          },
        ],
      });
      // Credential imports are now connected, but a missing current template
      // snapshot still cannot bypass the normal proposal validation.
      expect(denied['status'], 'template_changed');
      expect(runtime.service.owner.credentials, isEmpty);
      await invoke(
        'codex_hook',
        {'hook_event_name': 'SessionEnd', 'session_id': 'proposal-root'},
        args: [
          '--connection',
          config.path,
          '--state-root',
          '${root.path}/state',
        ],
      );
      expect(
        (await cli('import-submit', submission))['status'],
        isNot('pending'),
      );
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
