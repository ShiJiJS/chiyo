// Real version probes/default hosted workers. Only the probe-return timing is
// paused by QA so an owned tool can be replaced after its identity was frozen.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:info_cli/agent_client.dart';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/desktop_bootstrap.dart';
import 'package:info_desktop/desktop_runtime.dart';
import 'package:info_desktop/main.dart';

class _Keys implements DatabaseKeyStore {
  @override
  Future<List<int>?> read() async => List.filled(32, 121);
  @override
  Future<void> create(List<int> key) async =>
      throw StateError('Existing QA key');
}

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

Future<void> until(FutureOr<bool> Function() done, String phase) async {
  stdout.writeln('TOOL_VERSION_PHASE=$phase');
  final deadline = DateTime.now().add(const Duration(minutes: 20));
  while (!await done()) {
    check(DateTime.now().isBefore(deadline), 'Observation deadline: $phase');
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final env = Platform.environment, owner = env['MAC_TOOL_VERSION_OWNER']!;
  final mode = env['MAC_TOOL_VERSION_MODE']!;
  check({'exercise', 'reopen'}.contains(mode), 'QA mode');
  final root = env['MAC_TOOL_VERSION_ROOT'] == null
      ? await Directory.systemTemp.createTemp('aim-tool-version-')
      : Directory(env['MAC_TOOL_VERSION_ROOT']!);
  final canonical = await root.resolveSymbolicLinks();
  check(
    canonical.startsWith(
      '${await Directory.systemTemp.resolveSymbolicLinks()}/aim-tool-version-',
    ),
    'Owned root',
  );
  final marker = File('$canonical/.qa-owner');
  if (mode == 'exercise') await marker.writeAsString(owner);
  check(await marker.readAsString() == owner, 'Foreign root');
  stdout.writeln('TOOL_VERSION_ROOT=$canonical');
  final report = File('$canonical/$mode.json');
  final facts = <String, Object?>{
    'mode': mode,
    'complete': false,
    'systemKeychainUsed': false,
  };
  Future<void> save() => report.writeAsString(jsonEncode(facts), flush: true);
  final mutable = env['MAC_TOOL_VERSION_MUTABLE']!,
      upgraded = env['MAC_TOOL_VERSION_UPGRADED']!;
  final control = File('$canonical/qa-control.json');
  Future<bool> controlIs(String action) async {
    if (!await control.exists()) return false;
    final data = jsonDecode(await control.readAsString()) as Map;
    return data['owner'] == owner && data['action'] == action;
  }

  var armed = false, flutterErrors = 0, closes = 0;
  FlutterError.onError = (details) {
    flutterErrors++;
    FlutterError.presentError(details);
  };
  final bootstrap = DesktopBootstrap(
    port: 0,
    platform: NativeDesktopPlatform(),
    openLibrary: () async {
      final repo = await EncryptedInformationRepository.open(
        '$canonical/library',
        _Keys(),
      );
      return DesktopLibrary(
        service: InformationService(
          repository: repo,
          credentialExecutableInspector: (path, receiver) async {
            final actual = await inspectCredentialExecutable(path, receiver);
            if (armed && path == mutable) {
              armed = false;
              facts['raceFrozenIdentity'] = actual.toJson();
              facts['barrier'] = 'replace-owned-tool-after-production-probe';
              await save();
              await until(
                () => controlIs('replaced'),
                'supervisor-replaces-owned-tool',
              );
            }
            return actual;
          },
        ),
        close: () async {
          await repo.close();
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
    runApp(DesktopLauncher(bootstrap: bootstrap));
    final service = bootstrap.library!.service;
    if (mode == 'reopen') {
      final previous =
          jsonDecode(await File('$canonical/exercise.json').readAsString())
              as Map;
      final records = service.owner.credentialExecutions;
      final expected = previous['executions'] as List;
      check(
        records.length == 4 && expected.length == 4,
        'Wrong persisted count',
      );
      for (final dynamic old in expected) {
        final record = records.singleWhere((r) => r.id == old['executionId']);
        check(
          record.state == old['executionState'] &&
              record.exitCode == old['exitCode'] &&
              record.errorCode == old['errorCode'],
          'Persisted result differs',
        );
      }
      facts['preservedExecutions'] = expected;
      facts['credentialRequestCount'] =
          service.owner.credentialUseRequests.length;
      check(
        service.owner.credentialUseRequests.length == 2,
        'Unsupported request created history',
      );
    } else {
      var credential = await service.owner.createStringCredential(
        name: 'Mac 工具版本合成验收',
        publicPurpose: '无效合成 Token，仅预期 GitHub HTTP401',
        secret: 'ghp_FICTIONAL_VERSION_QA_INVALID_20261022',
      );
      credential = await service.owner.updateCredentialMetadata(
        credential.id,
        credential.revision,
        name: credential.name,
        publicPurpose: credential.publicPurpose,
        privateNote: '',
        suggestedBinding: 'gh_token',
        discoverable: true,
      );
      final client = AgentClient(
        bootstrap.boundPort!,
        hostedCredentialExecutions: true,
      );
      final commands = <Map<String, Object?>>[],
          executions = <Map<String, Object?>>[];
      facts.addAll({'commands': commands, 'executions': executions});
      Map<String, Object?> plan(String tool) => {
        'receiver': 'gh_token',
        'executable': tool,
        'argv': ['api', 'user', '--method', 'GET'],
        'cwd': canonical,
        'env': {
          'GH_TOKEN': {'secret': 'fixture'},
        },
      };
      Future<Map<String, dynamic>> call(Map<String, Object?> input) async {
        final output = await client.execute(input);
        commands.add({'input': input, 'output': output});
        await save();
        return output;
      }

      Future<Map<String, dynamic>> request(String purpose, String tool) =>
          call({
            'command': 'request-use',
            'protocolVersion': 2,
            'purpose': purpose,
            'credentials': [
              {'alias': 'fixture', 'credentialId': credential.id, 'version': 1},
            ],
            'launch': plan(tool),
          });
      Future<String> approveInUI(String purpose) async {
        final response = await request(purpose, mutable);
        check(response['status'] == 'pending', 'Request failed');
        final id = response['requestId'] as String;
        facts['waitingForActualApproval'] = purpose;
        await save();
        await until(
          () =>
              service.owner.credentialUseRequests
                  .singleWhere((r) => r.id == id)
                  .decidedAt !=
              null,
          'actual-ui-$purpose',
        );
        check(
          service.owner.credentialUseRequests
              .singleWhere((r) => r.id == id)
              .credentialApproved,
          'Not approved',
        );
        facts.remove('waitingForActualApproval');
        await save();
        return id;
      }

      Future<Map<String, Object?>> execute(
        String requestId,
        String operation, {
        bool expectChanged = false,
      }) async {
        final command = {
          'command': 'run-use',
          'protocolVersion': 2,
          'requestId': requestId,
          'operationId': operation,
          'launch': plan(mutable),
        };
        final accepted = await call(command);
        check(accepted['status'] == 'accepted', 'Not accepted: $accepted');
        final id = accepted['executionId'] as String;
        Map<String, dynamic> status = {};
        await until(() async {
          status = await client.execute({
            'command': 'execution-status',
            'executionId': id,
          });
          return {
            'exited',
            'prepare_failed',
            'start_failed',
          }.contains(status['executionState']);
        }, 'operation-$operation');
        final raw = await client.execute({
          'command': 'execution-output',
          'executionId': id,
        });
        final text = utf8.decode([
          for (final dynamic c in raw['chunks'] as List)
            ...base64Decode(c['dataBase64'] as String),
        ], allowMalformed: true);
        final record = <String, Object?>{
          'operation': operation,
          'executionId': id,
          'executionState': status['executionState'],
          'processStarted': status['processStarted'],
          'exitCode': status['exitCode'],
          'errorCode': status['errorCode'],
          'output': text,
        };
        executions.add(record);
        await save();
        check(!text.contains('ghp_FICTIONAL_VERSION_QA'), 'Token in output');
        if (expectChanged) {
          check(
            status['executionState'] == 'prepare_failed' &&
                status['errorCode'] == 'executable_changed' &&
                status['processStarted'] == false &&
                status['exitCode'] == null,
            'Changed tool was not refused: $record',
          );
        } else {
          check(
            status['executionState'] == 'exited' &&
                status['exitCode'] == 1 &&
                status['processStarted'] == true &&
                text.contains('HTTP 401'),
            'Not actual authentication rejection: $record',
          );
        }
        await until(() async {
          final cleaned = await client.execute({
            'command': 'cleanup-use',
            'executionId': id,
          });
          record['cleanupState'] = cleaned['cleanupState'];
          return cleaned['cleanupState'] == 'not_needed';
        }, 'cleanup-$operation');
        final repeated = await call(command);
        check(
          repeated['duplicate'] == true && repeated['executionId'] == id,
          'Operation replayed',
        );
        record['duplicateStable'] = true;
        await save();
        return command;
      }

      try {
        await client.execute({
          'command': 'session',
          'chatLabel': 'Mac 工具版本合成验收',
        });
        final first = await approveInUI('Mac 版本基线');
        final deadline = service.owner.credentialUseRequests
            .singleWhere((r) => r.id == first)
            .credentialExpiresAt;
        await execute(first, 'version-baseline');
        try {
          await inspectCredentialExecutable(upgraded, 'gh_token');
          throw StateError('Untested upgraded tool accepted');
        } on CredentialUseFailure catch (error) {
          check(
            error.code == 'unsupported_tool_version',
            'Wrong direct rejection',
          );
          facts['actualUpgradedProbe'] = error.code;
        }
        final badOperation = await call({
          'command': 'run-use',
          'protocolVersion': 2,
          'requestId': first,
          'operationId': 'version-unclaimed-retry',
          'launch': plan(upgraded),
        });
        check(
          badOperation['errorCode'] == 'unsupported_tool_version' &&
              badOperation['operationClaimed'] == false,
          'Unsupported operation claimed',
        );
        final badRequest = await request('未验收的新 GH 版本', upgraded);
        check(
          badRequest['errorCode'] == 'unsupported_tool_version',
          'Unsupported request accepted',
        );
        check(
          service.owner.credentialExecutions.length == 1 &&
              service.owner.credentialUseRequests.length == 1,
          'Unsupported attempt created facts',
        );
        await execute(first, 'version-unclaimed-retry');
        armed = true;
        final raceCommand = await execute(
          first,
          'version-image-race',
          expectChanged: true,
        );
        facts['barrier'] = 'restore-supported-tool';
        await save();
        await until(
          () => controlIs('restored'),
          'supervisor-restores-supported-tool',
        );
        final repeated = await call(raceCommand);
        check(
          repeated['duplicate'] == true &&
              repeated['executionId'] == executions.last['executionId'] &&
              repeated['errorCode'] == 'executable_changed',
          'Failed operation was replayed after restore',
        );
        check(
          service.owner.credentialUseRequests
                  .singleWhere((r) => r.id == first)
                  .credentialExpiresAt ==
              deadline,
          'First grant deadline moved',
        );
        facts['firstGrantDeadlineUnchanged'] = true;
        await service.owner.revokeCredentialUse(first);
        final revoked = await call({
          'command': 'run-use',
          'protocolVersion': 2,
          'requestId': first,
          'operationId': 'version-after-revoke',
          'launch': plan(mutable),
        });
        check(
          revoked['errorCode'] == 'grant_revoked' &&
              revoked['operationClaimed'] == false,
          'Revoked grant accepted',
        );
        final fresh = await approveInUI('Mac 恢复支持版本后重审');
        await execute(fresh, 'version-fresh-recheck');
        await service.owner.revokeCredentialUse(fresh);
        check(
          service.owner.credentialExecutions.length == 4,
          'Wrong operation count',
        );
        facts['credentialRequestCount'] =
            service.owner.credentialUseRequests.length;
      } finally {
        client.close();
      }
    }
    facts['complete'] = true;
    await save();
    stdout.writeln('TOOL_VERSION_COMPLETE=$mode');
  } catch (error) {
    facts.addAll({'failed': true, 'error': error.toString()});
    await save();
    stderr.writeln('TOOL_VERSION_FAILED=$error');
    await bootstrap.runtime?.stop();
    exit(1);
  }
}
