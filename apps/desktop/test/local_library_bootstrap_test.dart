import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:info_cli/agent_client.dart';
import 'package:info_core/info_core.dart';
import 'package:crypto/crypto.dart';
import 'package:info_desktop/desktop_bootstrap.dart';
import 'package:info_desktop/platform/local_library.dart';
import 'package:info_remote/agent_connection.dart';
import 'package:info_remote/automatic_connection.dart';
import 'package:info_remote/local_library_configuration.dart';
import 'package:info_storage/info_storage.dart';

import 'support/desktop_platform_fixture.dart';

class _Keys implements DatabaseKeyStore {
  List<int>? key;
  int creates = 0;
  @override
  Future<List<int>?> read() async => key;
  @override
  Future<void> create(List<int> value) async {
    creates++;
    key = List.of(value);
  }
}

void main() {
  test(
    'authenticated local credential use reaches a real child without exposing the password',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'chiyo-local-credential-',
      );
      final config = await LocalLibraryConfiguration.open(root.path);
      final repository = await EncryptedInformationRepository.open(
        config.libraryDirectory,
        _Keys(),
      );
      final executable = File(
        '../../.tools/flutter/bin/cache/dart-sdk/bin/dart',
      ).absolute;
      final stat = await executable.stat();
      final digest = 'sha256:${sha256.convert(await executable.readAsBytes())}';
      final service = InformationService(
        repository: repository,
        credentialExecutableInspector: (path, receiver) async =>
            ExecutableIdentity(
              path,
              stat.size,
              stat.modified.microsecondsSinceEpoch,
              digest,
            ),
      );
      final boot = DesktopBootstrap(
        openLibrary: () async =>
            DesktopLibrary(service: service, close: repository.close),
        platform: NativeDesktopFixture(),
        port: 0,
        localConfiguration: config,
      );
      await boot.start();
      expect(boot.state, DesktopStartupState.ready);
      final client = AgentClient(
        boot.boundPort!,
        connection: boot.localConnection,
        credentialProcessStarter: (exe, argv, cwd, environment) =>
            Process.start(
              exe,
              [
                File(
                  '../../packages/info_cli/test/support/credential_child.dart',
                ).absolute.path,
                ...argv,
              ],
              workingDirectory: cwd,
              environment: environment,
              includeParentEnvironment: false,
              runInShell: false,
            ),
      );
      try {
        var credential = await service.owner.createStringCredential(
          name: '本地合成凭据',
          publicPurpose: '本地进程验证',
          secret: 'synthetic-token',
        );
        credential = await service.owner.updateCredentialMetadata(
          credential.id,
          credential.revision,
          name: credential.name,
          publicPurpose: credential.publicPurpose,
          privateNote: '',
          suggestedBinding: 'GH_TOKEN',
          discoverable: true,
        );
        await client.execute({'command': 'session', 'chatLabel': '合成本地凭据使用'});
        for (final protocolVersion in [1, 2]) {
          final request = await client.execute({
            'protocolVersion': protocolVersion,
            'command': 'request-use',
            'purpose': '验证本地凭据交付',
            'credentials': [
              {'alias': 'token', 'credentialId': credential.id, 'version': 1},
            ],
            'launch': {
              'receiver': 'gh_token',
              'executable': executable.path,
              'argv': ['api', 'user', '--method', 'GET'],
              'cwd': root.path,
              'env': {
                'GH_TOKEN': {'secret': 'token'},
              },
            },
          });
          expect(request['status'], 'pending');
          await service.owner.decideCredentialUse(
            request['requestId'] as String,
            approveCredential: true,
          );
          final accepted = await client.execute({
            'protocolVersion': protocolVersion,
            'command': 'run-use',
            'requestId': request['requestId'],
            if (protocolVersion == 2) ...{
              'operationId': 'local-credential-op-2',
              'launch': {
                'receiver': 'gh_token',
                'executable': executable.path,
                'argv': ['api', 'user', '--method', 'GET'],
                'cwd': root.path,
                'env': {
                  'GH_TOKEN': {'secret': 'token'},
                },
              },
            },
          });
          expect(accepted['status'], 'accepted', reason: jsonEncode(accepted));
          await client.drainCredentialExecutions();
          final status = await client.execute({
            'command': 'execution-status',
            'executionId': accepted['executionId'],
          });
          expect(status['executionState'], 'exited');
          expect(status['exitCode'], 0);
          final output = await client.execute({
            'command': 'execution-output',
            'executionId': accepted['executionId'],
            'cursor': 0,
            'limit': 16,
          });
          final text = utf8.decode([
            for (final dynamic chunk in output['chunks'] as List)
              ...base64Decode(chunk['dataBase64'] as String),
          ]);
          expect(jsonDecode(text), {
            'tokenMatches': true,
            'argsMatch': true,
            'privateConfig': true,
            'sessionAbsent': true,
          });
          expect(
            jsonEncode([
              accepted,
              status,
              output,
              service.owner.credentialExecutions.last.toJson(),
            ]),
            isNot(contains('synthetic-token')),
          );
        }
      } finally {
        await client.drainCredentialExecutions();
        client.close();
        await boot.close();
        await root.delete(recursive: true);
      }
    },
    skip: Platform.isWindows
        ? 'Uses a POSIX credential subprocess fixture.'
        : false,
  );
  test(
    'encrypted local bootstrap publishes a restricted CLI, persists records and restores a complete backup',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'chiyo-local-library-',
      );
      addTearDown(() => root.delete(recursive: true));
      final keys = _Keys();
      final config = await LocalLibraryConfiguration.open(
        '${root.path}/profile',
      );
      DesktopBootstrap bootstrap() => DesktopBootstrap(
        openLibrary: () => openLocalLibrary(config, keyStore: keys),
        platform: NativeDesktopFixture(),
        port: 0,
        localConfiguration: config,
      );
      var boot = bootstrap();
      addTearDown(() => boot.close());
      await boot.start();
      expect(boot.state, DesktopStartupState.ready);
      final service = boot.library!.service;
      final item = await service.owner.createInformation('合成本地服务器', '', [
        const FieldInput('主机地址', '', 'SYNTHETIC_LOCAL_PRIVATE_VALUE'),
      ]);
      final credential = await service.owner.createStringCredential(
        name: '合成本地凭据',
        publicPurpose: '本地验收',
        secret: 'SYNTHETIC_LOCAL_PASSWORD',
      );
      final input = File('${root.path}/原件.md');
      await input.writeAsString('# 合成文件原文');
      final draft = await service.owner.beginInformationFileDraft();
      late InformationItem attachment;
      try {
        final staged = await service.owner.stageInformationFile(
          draft,
          input.path,
          mediaType: 'text/markdown',
        );
        attachment = await service.owner.commitInformationDraft(
          draft,
          'save-local-file',
          InformationDraftInput(
            name: '合成文件',
            description: '',
            fields: [InformationDraftField.stagedFile('原文', '', staged.id)],
          ),
        );
      } finally {
        await service.owner.releaseInformationFileDraft(draft);
      }

      final profileFile = (await discoverAgentConnection(
        environment: {'CHIYO_CONNECTION_DIRECTORY': config.directory},
      ))!;
      final profile = await AgentConnectionProfile.read(profileFile);
      expect(profile.isLocal, true);
      final anonymous = AgentClient(profile.address.port);
      expect(
        (await anonymous.execute({'command': 'catalog'}))['status'],
        'unauthorized',
      );
      anonymous.close();
      final client = AgentClient.remote(
        profile,
        requireSubmissionMetadata: true,
      );
      addTearDown(client.close);
      expect(
        (await client.execute({'command': 'capabilities'}))['status'],
        'ok',
      );
      expect(
        (await client.execute({'command': 'template-list'}))['status'],
        'ok',
      );
      final catalog = jsonEncode(await client.execute({'command': 'catalog'}));
      expect(catalog, contains(item.name));
      expect(catalog, isNot(contains('SYNTHETIC_LOCAL_PRIVATE_VALUE')));
      expect(catalog, isNot(contains('SYNTHETIC_LOCAL_PASSWORD')));
      expect(
        (await client.execute({
          'command': 'session',
          'chatLabel': '本地流程验收',
          'externalChatId': 'local-library-test-chat',
        }))['status'],
        'ok',
      );
      final request = await client.execute({
        'command': 'request',
        'agentName': '本地验收 Agent',
        'purpose': '读取合成资料',
        'operationId': 'local-read',
        'fields': [
          {'itemId': item.id, 'fieldId': item.fields.single.id},
          {'itemId': attachment.id, 'fieldId': attachment.fields.single.id},
        ],
      });
      expect(request['status'], 'pending');
      final requestId = request['requestId'] as String;
      service.owner.approve(requestId, [
        FieldRef(item.id, item.fields.single.id),
        FieldRef(attachment.id, attachment.fields.single.id),
      ]);
      expect(
        (await client.execute({
          'command': 'claim',
          'requestId': requestId,
        }))['status'],
        'ok',
      );
      expect(
        (await client.execute({
          'command': 'read',
          'requestId': requestId,
          'itemId': item.id,
          'fieldId': item.fields.single.id,
        }))['value'],
        'SYNTHETIC_LOCAL_PRIVATE_VALUE',
      );
      final delivered = await client.execute({
        'command': 'file-fetch',
        'operationId': 'local-fetch',
        'requestId': requestId,
        'itemId': attachment.id,
        'fieldId': attachment.fields.single.id,
      });
      expect(delivered['status'], 'ok');
      final delivery = delivered['delivery'] as Map;
      expect(await File(delivery['path'] as String).readAsString(), '# 合成文件原文');
      expect(
        (await client.execute({
          'command': 'file-release',
          'deliveryId': delivery['deliveryId'],
        }))['status'],
        'ok',
      );

      final proposal = await client.execute({
        'command': 'import-submit',
        'agentName': '本地验收 Agent',
        'title': '新增本地合成资料',
        'purpose': '验证本地提案保存',
        'items': [
          {
            'name': '提案甲',
            'fields': [
              {'name': '说明', 'value': '本地提案甲内容'},
            ],
          },
          {
            'name': '提案乙',
            'fields': [
              {'name': '说明', 'value': '本地提案乙内容'},
            ],
          },
        ],
      });
      expect(proposal['status'], 'pending');
      final submitted = service.owner.importProposals.single;
      await service.owner.confirmImport(
        submitted.id,
        submitted.version,
        submitted.items,
      );
      expect(service.owner.information, hasLength(4));

      final backup = boot.library!.backups!;
      final recovery = await backup.enable();
      await backup.saveRecoveryKeyTo('${root.path}/recovery.txt');
      final backupPath = '${root.path}/本地完整备份.aimbackup';
      await service.owner.exportLibrary(() => backup.exportTo(backupPath));
      final oldToken = profile.deviceToken;
      await boot.close();
      boot.dispose();

      expect(
        (await LocalLibraryConfiguration.open(config.directory)).libraryId,
        config.libraryId,
      );
      boot = bootstrap();
      await boot.start();
      expect(boot.state, DesktopStartupState.ready);
      final reopened = boot.library!.service;
      expect(reopened.owner.information, hasLength(4));
      expect(reopened.owner.credentials.single.id, credential.id);
      expect(keys.creates, 1);
      expect(boot.localConnection!.deviceToken, isNot(oldToken));
      final wrongBoot = AgentClient.remote(
        AgentConnectionProfile.local(
          port: boot.boundPort!,
          deviceToken: oldToken,
          libraryId: config.serverId,
        ),
      );
      expect(
        (await wrongBoot.execute({'command': 'catalog'}))['status'],
        'unauthorized',
      );
      wrongBoot.close();
      final bytes = await File(
        '${config.libraryDirectory}/library.db',
      ).readAsBytes();
      expect(
        utf8.decode(bytes, allowMalformed: true),
        isNot(contains('SYNTHETIC_LOCAL_PASSWORD')),
      );
      expect(bytes.take(15).toList(), isNot(utf8.encode('SQLite format 3')));

      await boot.close();
      boot.dispose();
      final original = await File(
        '${config.libraryDirectory}/library.db',
      ).readAsBytes();
      final missingKeys = _Keys();
      await expectLater(
        openLocalLibrary(config, keyStore: missingKeys),
        throwsA(isA<StorageFailure>()),
      );
      expect(
        await File('${config.libraryDirectory}/library.db').readAsBytes(),
        original,
      );
      expect(missingKeys.creates, 0);

      final restoredConfig = await LocalLibraryConfiguration.open(
        '${root.path}/restored',
      );
      expect(restoredConfig.libraryId, isNot(config.libraryId));
      final restored = await openLocalLibrary(
        restoredConfig,
        keyStore: _Keys(),
      );
      try {
        await restored.service.owner.restoreLibrary(
          () => restored.backups!.restoreFrom(backupPath, recovery),
        );
        expect(restored.service.owner.information, hasLength(4));
        expect(restored.service.owner.credentials.single.id, credential.id);
        expect(
          (await restored.service.owner.history()).grants.every(
            (grant) => !grant.active,
          ),
          true,
        );
      } finally {
        await restored.service.close();
        await restored.close();
      }
    },
  );

  test(
    'formal CLI and Codex discover local configuration and cannot reuse a closed library session',
    () async {
      final root = await Directory.systemTemp.createTemp('chiyo-local-cli-');
      addTearDown(() => root.delete(recursive: true));
      final config = await LocalLibraryConfiguration.open(
        '${root.path}/profile',
      );
      final keys = _Keys();
      var boot = DesktopBootstrap(
        openLibrary: () => openLocalLibrary(config, keyStore: keys),
        platform: NativeDesktopFixture(),
        port: 0,
        localConfiguration: config,
      );
      addTearDown(() => boot.close());
      await boot.start();
      expect(boot.state, DesktopStartupState.ready);
      final item = await boot.library!.service.owner.createInformation(
        '本地 CLI 合成资料',
        '',
        [const FieldInput('正文', '', 'SYNTHETIC_LOCAL_CLI_VALUE')],
      );
      final directory = Directory('../../packages/info_cli').absolute.path;
      final env = {
        'CHIYO_CONNECTION_DIRECTORY': config.directory,
        'CODEX_THREAD_ID': 'local-formal-chat',
      };
      Future<Map<String, dynamic>> invoke(
        String entry,
        Map<String, Object?>? input, [
        List<String> args = const [],
      ]) async {
        final child = await Process.start(
          File(
            '../../.tools/flutter/bin/cache/dart-sdk/bin/dart${Platform.isWindows ? '.exe' : ''}',
          ).absolute.path,
          ['run', 'bin/$entry.dart', ...args],
          workingDirectory: directory,
          environment: env,
        );
        final out = utf8.decoder.bind(child.stdout).join();
        final err = utf8.decoder.bind(child.stderr).join();
        if (input != null) child.stdin.write(jsonEncode(input));
        await child.stdin.close();
        try {
          expect(await child.exitCode.timeout(const Duration(seconds: 30)), 0);
          await err;
          return jsonDecode((await out).trim()) as Map<String, dynamic>;
        } finally {
          child.kill();
        }
      }

      final generic = await invoke('info', {'command': 'capabilities'});
      expect(generic['status'], 'ok');
      final opened = await invoke('codex_hook', null, [
        '--connect',
        '--state-root',
        '${root.path}/state',
      ]);
      final association =
          (jsonDecode(
                    opened['hookSpecificOutput']['additionalContext'] as String,
                  )
                  as Map)['association']
              as String;
      Future<Map<String, dynamic>> command(
        String name, [
        Map<String, Object?> values = const {},
      ]) => invoke('codex_info', {
        'association': association,
        'command': name,
        ...values,
      });
      expect((await command('catalog'))['status'], 'ok');
      final request = await command('request', {
        'operationId': 'local-formal-request',
        'purpose': '核对本机资料',
        'fields': [
          {'itemId': item.id, 'fieldId': item.fields.single.id},
        ],
      });
      expect(request['status'], 'pending');
      final requestId = request['requestId'] as String;
      expect(
        (await command('claim', {'requestId': requestId}))['status'],
        'pending',
      );
      boot.library!.service.owner.approve(requestId, [
        FieldRef(item.id, item.fields.single.id),
      ]);
      expect(
        (await command('claim', {'requestId': requestId}))['status'],
        'ok',
      );
      expect(
        (await command('read', {
          'requestId': requestId,
          'itemId': item.id,
          'fieldId': item.fields.single.id,
        }))['value'],
        'SYNTHETIC_LOCAL_CLI_VALUE',
      );
      final ended = await invoke(
        'codex_hook',
        {'hook_event_name': 'SessionEnd', 'session_id': 'local-formal-chat'},
        ['--state-root', '${root.path}/state'],
      );
      expect(ended['systemMessage'], contains('ended'));
      expect((await command('session-check'))['status'], 'unauthorized');

      final port = boot.boundPort!;
      await boot.close();
      boot.dispose();
      boot = DesktopBootstrap(
        openLibrary: () => openLocalLibrary(config, keyStore: keys),
        platform: NativeDesktopFixture(),
        port: port,
        localConfiguration: config,
      );
      await boot.start();
      expect(boot.state, DesktopStartupState.ready);
      expect((await command('catalog'))['status'], 'unauthorized');
      expect((await invoke('info', {'command': 'catalog'}))['status'], 'ok');
      expect(boot.library!.service.owner.information.single.id, item.id);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
