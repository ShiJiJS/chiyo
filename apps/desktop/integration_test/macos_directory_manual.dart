// Actual owner directory panels and saved OS scopes; no system Keychain calls.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:info_cli/agent_client.dart';
import 'package:info_cli/macos_bundled_tools.dart';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/desktop_bootstrap.dart';
import 'package:info_desktop/desktop_runtime.dart';
import 'package:info_desktop/tool_directory_access.dart';
import 'package:info_desktop/tool_directory_settings.dart';
import 'package:info_desktop/ui.dart';

class _Keys implements DatabaseKeyStore {
  @override
  Future<List<int>?> read() async => List.filled(32, 119);
  @override
  Future<void> create(List<int> key) async =>
      throw StateError('Existing QA key');
}

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

Future<void> until(FutureOr<bool> Function() predicate, String phase) async {
  stdout.writeln('DIRECTORY_PHASE=$phase');
  final deadline = DateTime.now().add(const Duration(minutes: 20));
  while (!await predicate()) {
    check(DateTime.now().isBefore(deadline), 'UI deadline: $phase');
    await Future<void>.delayed(const Duration(milliseconds: 150));
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final env = Platform.environment;
  final mode = env['MAC_DIRECTORY_MODE']!;
  check(
    {
      'choose',
      'reopen',
      'change',
      'reopen-changed',
      'remove',
      'denied',
    }.contains(mode),
    'QA mode',
  );
  final root = env['MAC_DIRECTORY_ROOT'] == null
      ? await Directory.systemTemp.createTemp('aim-directory-')
      : Directory(env['MAC_DIRECTORY_ROOT']!);
  final canonical = await root.resolveSymbolicLinks();
  final temporary = await Directory.systemTemp.resolveSymbolicLinks();
  check(
    canonical.startsWith('$temporary/aim-directory-'),
    'QA root outside sandbox temp',
  );
  final marker = File('$canonical/.qa-owner');
  if (mode == 'choose') await marker.writeAsString(env['MAC_DIRECTORY_OWNER']!);
  check(
    await marker.readAsString() == env['MAC_DIRECTORY_OWNER'],
    'Foreign fixture',
  );
  stdout.writeln('DIRECTORY_ROOT=$canonical');
  final report = File('$canonical/$mode.json');
  final facts = <String, Object?>{
    'mode': mode,
    'complete': false,
    'systemKeychainUsed': false,
    'credentialApproval':
        'synthetic QA owner API; directory selection uses production UI and actual NSOpenPanel',
  };
  Future<void> save() => report.writeAsString(jsonEncode(facts), flush: true);
  var closes = 0, flutterErrors = 0;
  FlutterError.onError = (details) {
    flutterErrors++;
    FlutterError.presentError(details);
  };
  final bootstrap = DesktopBootstrap(
    port: 0,
    platform: NativeDesktopPlatform(),
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
          facts.addAll({
            'libraryCloses': closes,
            'flutterErrors': flutterErrors,
          });
          await save();
        },
      );
    },
  );
  try {
    await bootstrap.start();
    check(bootstrap.state == DesktopStartupState.ready, 'Bootstrap failed');
    runApp(
      MaterialApp(
        theme: informationTheme(),
        home: const Scaffold(
          body: SingleChildScrollView(
            padding: EdgeInsets.all(24),
            child: ToolDirectorySettings(),
          ),
        ),
      ),
    );
    const access = NativeToolDirectoryAccess();
    final paths = [env['MAC_DIRECTORY_READ']!, env['MAC_DIRECTORY_WRITE']!];
    Future<List<Map<String, Object?>>> snapshot() async => [
      for (final d in (await access.read()).directories)
        {
          'id': d.id,
          'path': d.path,
          'permission': d.permission.name,
          'available': d.available,
        },
    ];
    Future<void> expectRanges({bool changed = false}) async {
      final rows = await snapshot();
      check(rows.length == 2, 'Expected two selected directories');
      for (var i = 0; i < 2; i++) {
        final row = rows.singleWhere((d) => d['path'] == paths[i]);
        check(
          row['available'] == true &&
              row['permission'] ==
                  ((i == 1) != changed ? 'readWrite' : 'readOnly'),
          'Wrong persisted range',
        );
      }
      facts['directories'] = rows;
    }

    Future<List<Map<String, Object?>>> probes(String phase) async {
      final result = <Map<String, Object?>>[];
      for (var i = 0; i < paths.length; i++) {
        final row = <String, Object?>{'directory': i};
        try {
          row['read'] =
              await File('${paths[i]}/对象 名称.txt').readAsString() ==
              'fixture-object';
        } on FileSystemException catch (e) {
          row.addAll({'read': false, 'readErrno': e.osError?.errorCode});
        }
        try {
          final output = File('${paths[i]}/$phase-写入.txt');
          await output.writeAsString('fixture-$phase', flush: true);
          check(
            await output.readAsString() == 'fixture-$phase',
            'Write bytes differ',
          );
          await output.delete();
          row['write'] = true;
        } on FileSystemException catch (e) {
          row.addAll({'write': false, 'writeErrno': e.osError?.errorCode});
        }
        result.add(row);
      }
      return result;
    }

    facts['initialDirectories'] = await snapshot();
    if (mode == 'choose' || mode == 'denied') {
      check(
        (await access.read()).directories.isEmpty,
        'Expected no saved entries',
      );
      final denied = await probes('unselected');
      facts['withoutScope'] = denied;
      check(
        denied.every(
          (r) =>
              r['read'] == false &&
              r['readErrno'] == 1 &&
              r['write'] == false &&
              r['writeErrno'] == 1,
        ),
        'Unselected path accessible',
      );
    }
    await save();
    if (mode == 'choose') {
      await until(
        () async => (await access.read()).directories.length == 2,
        'select-read-and-write-directories-in-production-ui',
      );
      await expectRanges();
      facts['initialSessionAccess'] = await probes('initial-session');
    } else if (mode == 'change') {
      await expectRanges();
      await until(() async {
        final rows = await snapshot();
        return rows.length == 2 &&
            rows.any(
              (r) => r['path'] == paths[0] && r['permission'] == 'readWrite',
            ) &&
            rows.any(
              (r) => r['path'] == paths[1] && r['permission'] == 'readOnly',
            );
      }, 'reselect-both-ranges-in-production-ui');
      await expectRanges(changed: true);
    } else if (mode == 'reopen' || mode == 'reopen-changed') {
      final changed = mode == 'reopen-changed';
      await expectRanges(changed: changed);
      final result = await probes(mode);
      facts['restoredFilesystem'] = result;
      for (var i = 0; i < 2; i++) {
        final writable = (i == 1) != changed;
        check(
          result[i]['read'] == true &&
              result[i]['write'] == writable &&
              (writable || result[i]['writeErrno'] == 1),
          'OS restored range differs',
        );
      }
      final service = bootstrap.library!.service;
      var credential = await service.owner.createFileCredential(
        name: 'Mac Directory QA $mode',
        publicPurpose: 'Synthetic loopback only',
        fileName: 'credentials',
        bytes: utf8.encode(
          '[default]\naws_access_key_id=TEST_ACCESS_ONLY\naws_secret_access_key=SYNTHETIC_NOT_A_REAL_SECRET\n',
        ),
      );
      credential = await service.owner.updateCredentialMetadata(
        credential.id,
        credential.revision,
        name: credential.name,
        publicPurpose: credential.publicPurpose,
        privateNote: '',
        suggestedBinding: 'aws_shared_credentials',
        discoverable: true,
      );
      final aws = (await MacBundledTools().read()).singleWhere(
        (t) => t.receiver == 'aws_shared_credentials',
      );
      check(aws.available && aws.executable != null, 'Missing bundled AWS');
      final read = paths[changed ? 1 : 0], write = paths[changed ? 0 : 1];
      final client = AgentClient(
        bootstrap.boundPort!,
        hostedCredentialExecutions: true,
      );
      try {
        await client.execute({
          'command': 'session',
          'chatLabel': 'Synthetic directory scope QA',
        });
        Map<String, Object?> plan(String target) => {
          'receiver': 'aws_shared_credentials',
          'executable': aws.executable,
          'argv': [
            's3api',
            'get-object',
            '--bucket',
            'fixture-bucket',
            '--key',
            'file://$read/对象 名称.txt',
            '--region',
            'us-east-1',
            '--endpoint-url',
            'http://127.0.0.1:${env['MAC_DIRECTORY_PORT']}',
            '--no-cli-pager',
            target,
          ],
          'cwd': write,
          'env': {
            'AWS_SHARED_CREDENTIALS_FILE': {'file': 'fixture'},
          },
        };
        final firstPlan = plan('$write/$mode-aws.bin');
        final requested = await client.execute({
          'command': 'request-use',
          'protocolVersion': 2,
          'purpose': 'Synthetic persisted directory read/write',
          'credentials': [
            {'alias': 'fixture', 'credentialId': credential.id, 'version': 1},
          ],
          'launch': firstPlan,
        });
        check(
          requested['status'] == 'pending',
          'Request rejected: ${requested['errorCode']}',
        );
        final id = requested['requestId'] as String;
        await service.owner.decideCredentialUse(id, approveCredential: true);
        final deadline = service.owner.credentialUseRequests
            .singleWhere((r) => r.id == id)
            .credentialExpiresAt;
        final executions = <Map<String, Object?>>[];
        facts['executions'] = executions;
        for (final entry in [
          ('write', firstPlan, 0),
          ('read-only-target', plan('$read/$mode-aws.bin'), 255),
        ]) {
          final command = {
            'command': 'run-use',
            'protocolVersion': 2,
            'requestId': id,
            'operationId': entry.$1,
            'launch': entry.$2,
          };
          final accepted = await client.execute(command);
          check(
            accepted['status'] == 'accepted',
            'Operation rejected: ${accepted['errorCode']}',
          );
          final execution = accepted['executionId'] as String;
          Map<String, dynamic> status = {};
          await until(() async {
            status = await client.execute({
              'command': 'execution-status',
              'executionId': execution,
            });
            return status['executionState'] == 'exited' ||
                status['executionState'] == 'start_failed';
          }, '$mode-${entry.$1}-worker');
          final output = await client.execute({
            'command': 'execution-output',
            'executionId': execution,
          });
          final text = utf8.decode([
            for (final dynamic c in output['chunks'] as List)
              ...base64Decode(c['dataBase64'] as String),
          ], allowMalformed: true);
          final record = <String, Object?>{
            'operation': entry.$1,
            'executionId': execution,
            'executionState': status['executionState'],
            'exitCode': status['exitCode'],
            'output': text,
          };
          executions.add(record);
          await save();
          check(status['exitCode'] == entry.$3, 'Wrong AWS exit: $record');
          if (entry.$3 == 0) {
            final bytes = await File('$write/$mode-aws.bin').readAsBytes();
            record.addAll({
              'bytes': bytes.length,
              'dataBase64': base64Encode(bytes),
            });
            check(
              bytes.length == 2009 &&
                  record['dataBase64'] == env['MAC_DIRECTORY_PAYLOAD_BASE64'],
              'AWS bytes differ',
            );
            await File('$write/$mode-aws.bin').delete();
          } else {
            check(text.contains('[Errno 1]'), 'Missing actual EPERM evidence');
          }
          await until(() async {
            final cleaned = await client.execute({
              'command': 'cleanup-use',
              'executionId': execution,
            });
            record['cleanupState'] = cleaned['cleanupState'];
            return cleaned['cleanupState'] == 'complete';
          }, 'material-cleanup');
          final repeated = await client.execute(command);
          check(
            repeated['duplicate'] == true &&
                repeated['executionId'] == execution,
            'Operation replayed',
          );
          check(
            service.owner.credentialUseRequests
                    .singleWhere((r) => r.id == id)
                    .credentialExpiresAt ==
                deadline,
            'Deadline moved',
          );
          record.addAll({'duplicateStable': true, 'deadlineUnchanged': true});
        }
        await service.owner.revokeCredentialUse(id);
      } finally {
        client.close();
      }
    } else if (mode == 'remove') {
      await expectRanges(changed: true);
      await until(
        () async => (await access.read()).directories.isEmpty,
        'forget-both-directories-in-production-ui',
      );
      facts['removedInUI'] = true;
    }
    facts['complete'] = true;
    await save();
    stdout.writeln('DIRECTORY_COMPLETE=$mode');
  } catch (error) {
    facts.addAll({'failed': true, 'error': error.toString()});
    await save();
    stderr.writeln('DIRECTORY_FAILED=$error');
    await bootstrap.runtime?.stop();
    exit(1);
  }
}
