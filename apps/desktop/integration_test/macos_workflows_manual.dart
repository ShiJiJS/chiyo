import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:info_cli/agent_client.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/desktop_runtime.dart';
import 'package:info_desktop/main.dart';
import 'support/isolated_desktop.dart';

// Ordinary application binding for Computer Use acceptance. No widget-test
// binding, simulated UI actions, production profile, or production Keychain.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!Platform.isMacOS) throw StateError('macOS only');
  const key = String.fromEnvironment('SYNTHETIC_SSH_KEY');
  const host = String.fromEnvironment('SYNTHETIC_SSH_HOST');
  const port = String.fromEnvironment('SYNTHETIC_SSH_PORT');
  if ([key, host, port].any((v) => v.isEmpty)) {
    throw StateError('Use scripts/qa/macos-workflows.py --live');
  }
  final fixture = await IsolatedDesktopFixture.start(
    platform: NativeDesktopPlatform(),
    informationDeliveryFiles: NativeInformationDeliveryFiles(),
  );
  final owner = fixture.service.owner;
  final client = AgentClient(fixture.port);
  void check(bool value, String message) {
    if (!value) throw StateError(message);
  }

  Future<void> until(FutureOr<bool> Function() done, String phase) async {
    debugPrint('MAC_QA_PHASE=$phase');
    final deadline = DateTime.now().add(const Duration(minutes: 10));
    while (!await done()) {
      if (!DateTime.now().isBefore(deadline)) {
        throw StateError('Native acceptance timed out: $phase');
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  try {
    const original = [0, 255, 37, 80, 68, 70, 10];
    final source = File('${fixture.root.path}/synthetic-简历.pdf');
    await source.writeAsBytes(original);
    final draft = await owner.beginInformationFileDraft();
    final stage = await owner.stageInformationFile(
      draft,
      source.path,
      mediaType: 'application/pdf',
    );
    final item = await owner.commitInformationDraft(
      draft,
      'synthetic-fixture',
      InformationDraftInput(
        name: 'Mac 合成简历',
        description: '独立原生界面验收用合成附件',
        fields: [InformationDraftField.stagedFile('简历', '', stage.id)],
      ),
    );
    await owner.releaseInformationFileDraft(draft);
    final field = item.fields.single;
    await owner.configureSshKnownHosts(
      '合成 localhost',
      utf8.encode('[127.0.0.1]:$port $host\n'),
    );
    var credential = await owner.createFileCredential(
      name: 'Mac 合成 SSH 私钥',
      publicPurpose: '仅本机测试服务',
      fileName: 'synthetic_ed25519',
      bytes: base64Decode(key),
    );
    credential = await owner.updateCredentialMetadata(
      credential.id,
      credential.revision,
      name: credential.name,
      publicPurpose: credential.publicPurpose,
      privateNote: '',
      suggestedBinding: 'ssh_key',
      discoverable: true,
    );
    await client.execute({'command': 'session', 'chatLabel': 'Mac 普通应用原生验收'});
    Map<String, Object?> launch(String executable) => {
      'receiver': 'ssh_identity',
      'executable': '/usr/bin/ssh',
      'argv': [
        '-T',
        '-o',
        'BatchMode=yes',
        '-i',
        {'file': 'ssh_key'},
        '-p',
        port,
        'fixture@127.0.0.1',
        executable,
      ],
      'cwd': fixture.root.path,
      'env': <String, Object?>{},
    };
    final request = await client.execute({
      'command': 'request-use',
      'protocolVersion': 2,
      'purpose': '合成凭据与普通附件验收',
      'credentials': [
        {'alias': 'ssh_key', 'credentialId': credential.id, 'version': 1},
      ],
      'launch': launch('/usr/bin/true'),
      'readFields': [FieldRef(item.id, field.id).toJson()],
    });
    check(request['status'] == 'pending', 'Request was not pending');
    final requestId = request['requestId'] as String;
    debugPrint('MAC_QA_ROOT=${fixture.root.path}');
    debugPrint('MAC_QA_REQUEST=$requestId');
    runApp(
      InformationApp(
        service: fixture.service,
        port: fixture.port,
        runtime: fixture.bootstrap.runtime,
      ),
    );
    await until(
      () => owner.credentialUseRequests.single.decidedAt != null,
      'approve-in-ordinary-application',
    );
    check(
      owner.credentialGrantState(owner.credentialUseRequests.single) ==
          'available',
      'Credential grant unavailable',
    );
    for (final entry in [
      ('first', '/usr/bin/true', 0),
      ('second', '/usr/bin/false', 1),
    ]) {
      final command = {
        'command': 'run-use',
        'protocolVersion': 2,
        'requestId': requestId,
        'operationId': entry.$1,
        'launch': launch(entry.$2),
      };
      final accepted = await client.execute(command);
      check(accepted['status'] == 'accepted', 'Execution was not accepted');
      final id = accepted['executionId'] as String;
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (true) {
        final status = await client.execute({
          'command': 'execution-status',
          'executionId': id,
        });
        if (status['executionState'] == 'exited' &&
            status['cleanupState'] == 'complete') {
          check(status['exitCode'] == entry.$3, 'Unexpected SSH exit code');
          debugPrint('MAC_QA_EXECUTION=$id,exit=${entry.$3},cleanup=complete');
          break;
        }
        check(DateTime.now().isBefore(deadline), 'Worker did not finish');
        await client.execute({'command': 'cleanup-use', 'executionId': id});
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      check(
        (await client.execute(command))['duplicate'] == true,
        'Duplicate replayed',
      );
    }
    check(
      owner.credentialExecutions.map((e) => e.jobName).toSet().length == 2,
      'Executions shared process group',
    );
    final fetch = {
      'command': 'file-fetch',
      'requestId': requestId,
      'itemId': item.id,
      'fieldId': field.id,
      'operationId': 'original',
    };
    final delivered = await client.execute(fetch);
    check(delivered['status'] == 'ok', 'File fetch failed');
    final copy = delivered['delivery'] as Map;
    check(
      base64Encode(await File(copy['path'] as String).readAsBytes()) ==
          base64Encode(original),
      'Delivered bytes changed',
    );
    check(
      ((await client.execute(fetch))['delivery'] as Map)['deliveryId'] ==
          copy['deliveryId'],
      'Duplicate file fetch changed identity',
    );
    final released = await client.execute({
      'command': 'file-release',
      'deliveryId': copy['deliveryId'],
    });
    check(
      (released['delivery'] as Map)['state'] == 'released' &&
          !await File(copy['path'] as String).exists(),
      'Delivery not released',
    );
    debugPrint('MAC_QA_FILE=original-matched,duplicate-stable,released');
    await until(
      () => owner.credentialUseRequests.single.revokedAt != null,
      'inspect-execution-receipt-and-revoke-credential-in-ui',
    );
    final denied = await client.execute({
      'command': 'run-use',
      'protocolVersion': 2,
      'requestId': requestId,
      'operationId': 'after-revoke',
      'launch': launch('/usr/bin/true'),
    });
    check(
      denied['errorCode'] == 'grant_revoked' &&
          owner.credentialExecutions.length == 2,
      'Credential revocation failed',
    );
    final independent = await client.execute({
      ...fetch,
      'operationId': 'independent-file',
    });
    check(
      independent['status'] == 'ok',
      'Credential revocation also revoked field',
    );
    final independentCopy = independent['delivery'] as Map;
    check(
      base64Encode(
            await File(independentCopy['path'] as String).readAsBytes(),
          ) ==
          base64Encode(original),
      'Independent copy changed',
    );
    final fieldGrant = (await owner.history()).grants.singleWhere(
      (g) => g.requestId == requestId,
    );
    debugPrint('MAC_QA_FIELD_GRANT=${fieldGrant.id}');
    await until(
      () async => !(await owner.history()).grants
          .singleWhere((g) => g.id == fieldGrant.id)
          .active,
      'revoke-independent-field-in-ui',
    );
    await owner.reconcileInformationFileDeliveries();
    check(
      !await File(independentCopy['path'] as String).exists(),
      'Revoked copy remains',
    );
    check(
      (await client.execute({
            ...fetch,
            'operationId': 'after-field-revoke',
          }))['errorCode'] ==
          'not_authorized',
      'Field revocation failed',
    );
    debugPrint(
      'MAC_QA_RESULT=PASS,ordinary-binding,real-ui-approval,two-ssh-exits-and-cleanup,file-fetch-release,duplicate-not-replayed,independent-ui-revocations',
    );
    await until(
      File('${fixture.root.path}/finish-qa').existsSync,
      'inspect-final-history',
    );
  } finally {
    client.close();
    runApp(const SizedBox());
    await fixture.close();
  }
  exit(0);
}
