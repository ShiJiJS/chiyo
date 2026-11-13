import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:info_cli/chiyo_cli.dart';
import 'package:info_cli/chiyo_context.dart';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';
import 'support/device_credential_fixture.dart';

void main() {
  for (final lostReply in [false, true]) {
    test(
      'generic chiyo file delivery over real HTTPS and SQLCipher (lost reply: $lostReply)',
      () async {
        final f = await DeviceCredentialFixture.create(
          loseFirstPath: lostReply ? '/v1/agent/information-file/fetch' : null,
        );
        final contextFile = File(
          '${f.root.path}/generic-file-chat/context.json',
        );
        final source = File('${f.root.path}/中文原件.txt');
        const original = 'SYNTHETIC_ORDINARY_ORIGINAL\n合成附件，不是凭据';
        await source.writeAsString(original);
        final item = await f.runtime.run(() async {
          final draft = await f.runtime.service.owner
              .beginInformationFileDraft();
          try {
            final stage = await f.runtime.service.owner.stageInformationFile(
              draft,
              source.path,
              mediaType: 'text/plain',
            );
            return await f.runtime.service.owner.commitInformationDraft(
              draft,
              'save-attachment',
              InformationDraftInput(
                name: 'Synthetic ordinary attachment',
                description: '',
                fields: [
                  InformationDraftField.stagedFile('Original', '', stage.id),
                ],
              ),
            );
          } finally {
            await f.runtime.service.owner.releaseInformationFileDraft(draft);
          }
        });
        final profileFile = await f.profiles.first.saveIn(
          Directory('${f.root.path}/profile'),
        );
        final started = await ChiyoCli(environment: {}).run([
          'chat',
          'start',
          '--agent',
          'Generic Attachment Agent',
          '--id',
          'generic-file-chat',
          '--label',
          'Read the original attachment',
          '--connection',
          profileFile.path,
          '--context-out',
          contextFile.path,
          '--json',
        ]);
        expect(started.exitCode, 0, reason: started.render());
        final context = await ChiyoContext.load(contextFile, environment: {});
        final script = File.fromUri(
          (await Isolate.resolvePackageUri(
            Uri.parse('package:info_cli/chiyo_cli.dart'),
          ))!,
        ).parent.parent.uri.resolve('bin/chiyo.dart').toFilePath();
        Future<(int, Map<String, dynamic>)> cli(List<String> args) async {
          final binary = Platform.environment['CHIYO_TEST_EXECUTABLE'];
          final environment = Map<String, String>.from(Platform.environment)
            ..removeWhere(
              (key, _) => key.startsWith('CHIYO_') || key.startsWith('CODEX_'),
            );
          final result = await Process.run(
            binary ?? Platform.resolvedExecutable,
            [
              if (binary == null) ...[
                '--packages=${(await Isolate.packageConfig)!.toFilePath()}',
                script,
              ],
              ...args,
              '--json',
            ],
            environment: {
              ...environment,
              'CHIYO_CONTEXT': contextFile.path,
              'CHIYO_CHAT_ID': 'generic-file-chat',
            },
            includeParentEnvironment: false,
            runInShell: false,
            stdoutEncoding: utf8,
            stderrEncoding: utf8,
          );
          expect(result.stderr, isEmpty);
          final raw = result.stdout as String;
          for (final hidden in [
            context.secret,
            f.token,
            f.profiles.first.deviceToken,
            original,
            'cleanupCapability',
          ]) {
            expect(raw, isNot(contains(hidden)));
          }
          return (result.exitCode, jsonDecode(raw) as Map<String, dynamic>);
        }

        // Release the exact synthetic copy even if a later assertion fails.
        String? deliveryId, path;
        addTearDown(() async {
          if (deliveryId != null)
            await cli(['files', 'release', '--delivery', deliveryId]);
          await cli(['chat', 'end']);
          if (path != null) expect(await File(path).exists(), false);
          await f.dispose();
        });
        final (requestCode, created) = await cli([
          'access',
          'request',
          '--item',
          item.id,
          '--field',
          item.fields.single.id,
          '--purpose',
          'Read the supplied original',
          '--operation',
          'request-original',
        ]);
        expect(requestCode, 0, reason: jsonEncode(created));
        final request = (created['data'] as Map)['requestId'] as String;
        final fetch = [
          'files',
          'fetch',
          '--request',
          request,
          '--item',
          item.id,
          '--field',
          item.fields.single.id,
          '--operation',
          'ordinary-copy',
        ];
        if (!lostReply) {
          final (pendingCode, pending) = await cli(fetch);
          expect(pendingCode, 4, reason: jsonEncode(pending));
        }
        await f.runtime.run(() async {
          f.runtime.service.owner.approve(request, [
            FieldRef(item.id, item.fields.single.id),
          ], lifetime: const Duration(hours: 2));
        });
        final (code, fetched) = await cli(fetch);
        if (lostReply) {
          expect(code, 7, reason: jsonEncode(fetched));
          expect((fetched['data'] as Map)['operationId'], 'ordinary-copy');
        } else {
          expect(code, 0, reason: jsonEncode(fetched));
          final delivery = (fetched['data'] as Map)['delivery'] as Map;
          deliveryId = delivery['deliveryId'] as String;
          path = delivery['path'] as String;
        }
        final (_, observed) = await cli([
          'operations',
          'show',
          'ordinary-copy',
        ]);
        expect((observed['data'] as Map)['kind'], 'information-file');
        expect(jsonEncode(observed), isNot(contains('path')));
        final (recoveryCode, recovered) = await cli([
          'operations',
          'retry',
          'ordinary-copy',
        ]);
        expect(recoveryCode, 0, reason: jsonEncode(recovered));
        final delivery = (recovered['data'] as Map)['delivery'] as Map;
        deliveryId ??= delivery['deliveryId'] as String;
        path ??= delivery['path'] as String;
        expect(delivery['deliveryId'], deliveryId);
        expect(delivery['path'], path);
        expect(await File(path).readAsString(), original);
        expect(f.repo.informationFileDeliveries, hasLength(1));
        expect(f.repo.informationFileDeliveries.single.deviceDelivery, true);
        final (_, status) = await cli([
          'files',
          'status',
          '--operation',
          'ordinary-copy',
        ]);
        expect(((status['data'] as Map)['delivery'] as Map)['state'], 'ready');
        expect(jsonEncode(status), isNot(contains(path)));
        // Ordinary server restart retains the original grant, delivery and copy.
        await f.reopen();
        final (reopenCode, reopened) = await cli(fetch);
        expect(reopenCode, 0, reason: jsonEncode(reopened));
        expect(((reopened['data'] as Map)['delivery'] as Map)['path'], path);
        expect(f.repo.informationFileDeliveries, hasLength(1));
        final (releaseCode, released) = await cli([
          'files',
          'release',
          '--delivery',
          deliveryId,
        ]);
        expect(releaseCode, 0, reason: jsonEncode(released));
        expect(await File(path).exists(), false);
        final (retryCode, retry) = await cli(fetch);
        expect(retryCode, 5, reason: jsonEncode(retry));
        expect(
          ((retry['data'] as Map)['delivery'] as Map)['state'],
          'released',
        );
        expect(f.repo.informationFileDeliveries, hasLength(1));
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }
}
