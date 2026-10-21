// Actual tool-directory panels and saved security scopes; synthetic library.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:info_cli/agent_client.dart';
import 'package:info_core/info_core.dart';
import 'package:info_core/macos_tool_probe.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/desktop_bootstrap.dart';
import 'package:info_desktop/desktop_runtime.dart';
import 'package:info_desktop/main.dart';
import 'package:info_desktop/tool_directory_access.dart';

class _Keys implements DatabaseKeyStore {
  @override
  Future<List<int>?> read() async => List.filled(32, 117);
  @override
  Future<void> create(List<int> key) async =>
      throw StateError('Existing QA key');
}

class _Platform extends NativeDesktopPlatform {
  Future<void> Function()? beforeTerminate;
  @override
  Future<void> terminate() async {
    await beforeTerminate?.call();
    await super.terminate();
  }
}

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

Future<void> until(FutureOr<bool> Function() done, String phase) async {
  stdout.writeln('MAC_TOOLS_PHASE=$phase');
  final deadline = DateTime.now().add(const Duration(minutes: 25));
  while (!await done()) {
    check(DateTime.now().isBefore(deadline), 'Actual tools UI deadline');
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final env = Platform.environment;
  final mode = env['MAC_TOOLS_MODE'];
  final owner = env['MAC_TOOLS_OWNER'];
  check(
    Platform.isMacOS &&
        {'choose', 'reopen', 'remove', 'denied', 'bundled'}.contains(mode),
    'QA mode',
  );
  check(owner != null && RegExp(r'^[a-f0-9]{32}$').hasMatch(owner), 'QA owner');
  final supplied = env['MAC_TOOLS_ROOT'];
  final root = supplied == null
      ? await Directory.systemTemp.createTemp('aim-mac-tools-')
      : Directory(supplied);
  final canonical = await root.resolveSymbolicLinks();
  final temp = await Directory.systemTemp.resolveSymbolicLinks();
  check(canonical.startsWith('$temp/aim-mac-tools-'), 'Owned QA root');
  final marker = File('$canonical/.qa-owner');
  if (supplied == null) {
    await marker.writeAsString(owner!);
  } else {
    check(await marker.readAsString() == owner, 'Foreign QA root');
  }
  stdout.writeln('MAC_TOOLS_ROOT=$canonical');
  final report = File('$canonical/$mode-result.json');
  final facts = <String, Object?>{'mode': mode, 'complete': false};
  Future<void> save() => report.writeAsString(jsonEncode(facts), flush: true);
  final gh = env['MAC_TOOLS_GH']!, aws = env['MAC_TOOLS_AWS']!;
  final platform = _Platform();
  var closes = 0, flutterErrors = 0;
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    flutterErrors++;
    previous?.call(details);
  };
  final bootstrap = DesktopBootstrap(
    port: 0,
    platform: platform,
    openLibrary: () async {
      final repository = await EncryptedInformationRepository.open(
        '$canonical/library',
        _Keys(),
      );
      return DesktopLibrary(
        service: InformationService(repository: repository),
        close: () async {
          await repository.close();
          closes++;
        },
      );
    },
  );
  platform.beforeTerminate = () async {
    check(
      facts['complete'] == true && flutterErrors == 0,
      'Premature or faulty UI quit',
    );
    facts.addAll({
      'nativeTerminationRequested': true,
      'libraryCloses': closes,
      'flutterErrors': flutterErrors,
    });
    await save();
  };
  try {
    await bootstrap.start();
    check(bootstrap.state == DesktopStartupState.ready, 'Startup failed');
    runApp(DesktopLauncher(bootstrap: bootstrap));
    final access = const NativeToolDirectoryAccess();
    final initial = await access.read();
    check(!initial.storageUnavailable, 'Bookmark storage unavailable');
    facts['initialDirectories'] = initial.directories
        .map((d) => {'id': d.id, 'path': d.path, 'available': d.available})
        .toList();
    Future<List<Map<String, Object?>>> readability() async {
      final rows = <Map<String, Object?>>[];
      for (final tool in [gh, aws]) {
        try {
          final handle = await File(tool).open();
          await handle.close();
          rows.add({'tool': tool == gh ? 'gh' : 'aws', 'readable': true});
        } on FileSystemException catch (e) {
          rows.add({
            'tool': tool == gh ? 'gh' : 'aws',
            'readable': false,
            'errno': e.osError?.errorCode,
          });
        }
      }
      return rows;
    }

    if (mode == 'choose' || mode == 'denied') {
      check(initial.directories.isEmpty, 'Expected no saved tools');
      final denied = await readability();
      facts['withoutScope'] = denied;
      check(
        denied.every((r) => r['readable'] == false && r['errno'] == 1),
        'External tools unexpectedly accessible',
      );
    }
    await save();
    if (mode == 'choose') {
      await until(
        () async =>
            (await access.read()).directories
                .where((d) => d.available)
                .length ==
            2,
        'choose-both-directories-in-actual-settings',
      );
    }
    if (mode != 'denied') {
      final selected = await access.read();
      if (mode != 'bundled') {
        check(
          selected.directories.length == 2 &&
              selected.directories.every((d) => d.available),
          'Saved tool scopes unavailable',
        );
        final expected = {File(gh).parent.parent.path, File(aws).parent.path};
        check(
          selected.directories.map((d) => d.path).toSet().containsAll(expected),
          'Wrong selected tool directories',
        );
      } else {
        check(
          selected.directories.isEmpty,
          'Bundled probe must not use scopes',
        );
      }
      final identities = <Map<String, Object?>>[];
      facts['withScope'] = await readability();
      facts['inspectedTools'] = identities;
      await save();
      for (final entry in [(gh, 'gh_token'), (aws, 'aws_shared_credentials')]) {
        try {
          final identity = await inspectCredentialExecutable(
            entry.$1,
            entry.$2,
          );
          identities.add({
            'receiver': entry.$2,
            'path': identity.path,
            'bytes': identity.byteLength,
            'digest': identity.sha256,
          });
        } on CredentialUseFailure catch (error) {
          final diagnostic = <String, Object?>{
            'receiver': entry.$2,
            'errorCode': error.code,
            'fieldPath': error.fieldPath,
          };
          facts['versionFailure'] = diagnostic;
          // Version-only public stdout/stderr; never any credential material.
          final probe = await Directory(
            '$canonical/version-diagnostic',
          ).create();
          try {
            final result =
                await probeMacOsToolVersion(entry.$1, '--version', probe.path, {
                  'HOME': probe.path,
                  'PATH': '/usr/bin:/bin',
                  'LANG': 'C.UTF-8',
                  'TMPDIR': probe.path,
                });
            diagnostic.addAll({
              'exitCode': result.exitCode,
              'stdout': result.stdout,
              'stderr': result.stderr,
            });
          } on ProcessException catch (failure) {
            diagnostic.addAll({
              'processErrno': failure.errorCode,
              'processMessage': failure.message,
            });
          } on Object catch (failure) {
            diagnostic['diagnosticError'] = failure.runtimeType.toString();
          }
          await save();
          rethrow;
        }
        await save();
      }
      facts['inspectedTools'] = identities;
      facts['restoredDirectories'] = selected.directories
          .map((d) => {'id': d.id, 'path': d.path, 'available': d.available})
          .toList();
      await save();
    }
    if (mode == 'choose' || mode == 'bundled') {
      final service = bootstrap.library!.service;
      final client = AgentClient(bootstrap.boundPort!);
      final capabilities = await client.execute({'command': 'capabilities'});
      check(
        (capabilities['capabilities'] as List).contains('credential-tools.v1'),
        'Missing production tool discovery',
      );
      final discovered = capabilities['credentialTools'] as List;
      for (final entry in [(gh, 'gh_token'), (aws, 'aws_shared_credentials')]) {
        if (mode == 'bundled') {
          check(
            discovered.any(
              (row) =>
                  row['receiver'] == entry.$2 &&
                  row['available'] == true &&
                  row['executable'] == entry.$1,
            ),
            'Production discovery differs from actual launch path',
          );
        }
      }
      facts['publicToolDiscovery'] = discovered;
      final executions = <Map<String, Object?>>[];
      final port = env['MAC_TOOLS_RECEIVER_PORT']!;
      final awsArgs = [
        'sts',
        'get-caller-identity',
        '--region',
        'us-east-1',
        '--endpoint-url',
        'http://127.0.0.1:$port',
        '--output',
        'json',
        '--no-cli-pager',
      ];
      Map<String, Object?> plan(String receiver, List<String> argv) => {
        'receiver': receiver,
        'executable': receiver == 'gh_token' ? gh : aws,
        'argv': argv,
        'cwd': canonical,
        'env': receiver == 'gh_token'
            ? {
                'GH_TOKEN': {'secret': 'fixture'},
              }
            : {
                'AWS_SHARED_CREDENTIALS_FILE': {'file': 'fixture'},
              },
      };
      await client.execute({'command': 'session', 'chatLabel': 'Mac 外部工具合成验收'});
      Future<String> request(
        String name,
        String receiver,
        String secret,
        List<String> argv,
      ) async {
        var credential = receiver == 'gh_token'
            ? await service.owner.createStringCredential(
                name: name,
                publicPurpose: '合成工具验收，不是实际账号',
                secret: secret,
              )
            : await service.owner.createFileCredential(
                name: name,
                publicPurpose: '仅回环 SigV4 测试接收端',
                fileName: 'credentials',
                bytes: utf8.encode(
                  '[default]\naws_access_key_id=TEST_ACCESS_ONLY\naws_secret_access_key=$secret\n',
                ),
              );
        credential = await service.owner.updateCredentialMetadata(
          credential.id,
          credential.revision,
          name: name,
          publicPurpose: credential.publicPurpose,
          privateNote: '',
          suggestedBinding: receiver,
          discoverable: true,
        );
        final response = await client.execute({
          'command': 'request-use',
          'protocolVersion': 2,
          'purpose': name,
          'credentials': [
            {'alias': 'fixture', 'credentialId': credential.id, 'version': 1},
          ],
          'launch': plan(receiver, argv),
        });
        check(
          response['status'] == 'pending',
          'Tool request failed: ${response['errorCode']}',
        );
        final id = response['requestId'] as String;
        await until(
          () =>
              service.owner.credentialUseRequests
                  .singleWhere((r) => r.id == id)
                  .decidedAt !=
              null,
          'approve-$receiver-in-actual-ui',
        );
        check(
          service.owner.credentialUseRequests
              .singleWhere((r) => r.id == id)
              .credentialApproved,
          'Credential was not approved',
        );
        return id;
      }

      Future<String> execute(
        String id,
        String receiver,
        String operation,
        List<String> argv,
        int exit,
      ) async {
        final deadline = service.owner.credentialUseRequests
            .singleWhere((r) => r.id == id)
            .credentialExpiresAt;
        final command = {
          'command': 'run-use',
          'protocolVersion': 2,
          'requestId': id,
          'operationId': operation,
          'launch': plan(receiver, argv),
        };
        final accepted = await client.execute(command);
        check(
          accepted['status'] == 'accepted',
          'Execution not accepted: ${accepted['errorCode']}',
        );
        await client.drainCredentialExecutions();
        final execution = accepted['executionId'] as String;
        await until(() async {
          final status = await client.execute({
            'command': 'execution-status',
            'executionId': execution,
          });
          return status['executionState'] == 'exited';
        }, 'actual-$receiver-exit');
        var status = await client.execute({
          'command': 'execution-status',
          'executionId': execution,
        });
        check(
          status['exitCode'] == exit,
          'Unexpected tool exit: ${status['exitCode']} ${status['errorCode']}',
        );
        if (receiver != 'gh_token') {
          await until(() async {
            status = await client.execute({
              'command': 'cleanup-use',
              'executionId': execution,
            });
            return status['cleanupState'] == 'complete';
          }, 'actual-material-cleanup');
        }
        final output = await client.execute({
          'command': 'execution-output',
          'executionId': execution,
        });
        final text = utf8.decode([
          for (final dynamic chunk in output['chunks'] as List)
            ...base64Decode(chunk['dataBase64'] as String),
        ], allowMalformed: true);
        check(
          !text.contains('SYNTHETIC_NOT_A_REAL_SECRET') &&
              !text.contains('WRONG_SYNTHETIC_SECRET') &&
              !text.contains('ghp_FICTIONAL_NATIVE'),
          'Secret in output',
        );
        final repeated = await client.execute(command);
        check(
          repeated['duplicate'] == true && repeated['executionId'] == execution,
          'Operation replayed',
        );
        check(
          service.owner.credentialUseRequests
                  .singleWhere((r) => r.id == id)
                  .credentialExpiresAt ==
              deadline,
          'Grant expiry moved',
        );
        executions.add({
          'receiver': receiver,
          'operation': operation,
          'exitCode': exit,
          'executionId': execution,
          'duplicateStable': true,
          'deadlineUnchanged': true,
          'cleanupState': status['cleanupState'],
          'outputSecretsAbsent': true,
        });
        facts['executions'] = executions;
        await save();
        return text;
      }

      try {
        final good = await request(
          'Mac AWS 合成签名读写',
          'aws_shared_credentials',
          'SYNTHETIC_NOT_A_REAL_SECRET',
          awsArgs,
        );
        check(
          (await execute(
            good,
            'aws_shared_credentials',
            'aws-identity',
            awsArgs,
            0,
          )).contains('LOCALFIXTURE'),
          'Wrong AWS caller',
        );
        final flags = awsArgs.skip(2).toList();
        await execute(good, 'aws_shared_credentials', 'aws-write', [
          'ssm',
          'put-parameter',
          '--name',
          '/fixture/example',
          '--value',
          'public-fixture-value',
          '--type',
          'String',
          ...flags,
        ], 0);
        check(
          (await execute(good, 'aws_shared_credentials', 'aws-read', [
            'ssm',
            'get-parameter',
            '--name',
            '/fixture/example',
            ...flags,
          ], 0)).contains('public-fixture-value'),
          'AWS write/read mismatch',
        );
        final wrong = await request(
          'Mac AWS 错误合成秘密',
          'aws_shared_credentials',
          'WRONG_SYNTHETIC_SECRET',
          awsArgs,
        );
        await execute(wrong, 'aws_shared_credentials', 'aws-wrong', [
          'ssm',
          'get-parameter',
          '--name',
          '/fixture/example',
          ...flags,
        ], 254);
        final ghArgs = ['api', 'user', '--method', 'GET'];
        final token = await request(
          'Mac GH 合成 Token 预期 401',
          'gh_token',
          'ghp_FICTIONAL_NATIVE_TOKEN_INVALID_20261021',
          ghArgs,
        );
        check(
          (await execute(
            token,
            'gh_token',
            'gh-invalid',
            ghArgs,
            1,
          )).contains('HTTP 401'),
          'Network failure is not GH authentication evidence',
        );
      } finally {
        client.close();
      }
    }
    if (mode == 'remove') {
      await until(
        () async => (await access.read()).directories.isEmpty,
        'remove-both-saved-directories-in-actual-ui',
      );
      facts['directoriesRemovedInUI'] = true;
    }
    facts['complete'] = true;
    await save();
    stdout.writeln('MAC_TOOLS_RESULT=PASS:$mode');
    if (mode == 'choose' || mode == 'remove' || mode == 'bundled') {
      await Future<void>.delayed(const Duration(minutes: 25));
      throw StateError('Actual inspection quit deadline');
    }
    await bootstrap.runtime!.quit();
  } catch (error) {
    facts.addAll({
      'failed': true,
      'errorType': error.runtimeType.toString(),
      if (error is CredentialUseFailure) 'errorCode': error.code,
      if (error is StateError) 'checkFailure': error.message,
    });
    await save();
    stderr.writeln('MAC_TOOLS_FAILED=${error.runtimeType}');
    await bootstrap.runtime?.stop();
    exit(1);
  }
}
