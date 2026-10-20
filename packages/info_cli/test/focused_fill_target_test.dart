import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:info_cli/agent_client.dart';
import 'package:info_core/agent_server.dart';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

class _Repository extends MemoryInformationRepository {
  int reads = 0;
  @override
  List<CredentialMaterial> get credentialMaterials {
    reads++;
    return super.credentialMaterials;
  }
}

class _Discovery implements FocusedFillDiscoveryDriver {
  int inspections = 0, preparations = 0;
  Completer<void>? gate;
  final entered = Completer<void>();
  FocusedFillTarget result = FocusedFillTarget.ready(
    FocusedFillApplication.fromJson({
      'executable': r'C:\Synthetic\Browser.exe',
      'sha256': 'a' * 64,
    }),
  );
  @override
  Future<FocusedFillTarget> inspectTarget() async {
    inspections++;
    if (!entered.isCompleted) entered.complete();
    await gate?.future;
    return result;
  }

  @override
  Future<PreparedFocusedFill> prepare(FocusedFillApplication a) async {
    preparations++;
    throw const CredentialUseFailure('unsupported_target');
  }
}

Future<(_Repository, _Discovery, InformationService, AgentServer, AgentClient)>
_fixture({bool enabled = true}) async {
  final repo = _Repository(), driver = _Discovery();
  final service = InformationService(
    repository: repo,
    focusedFillDriver: driver,
  );
  final server = await AgentServer.start(
    service.agent,
    port: 0,
    enableReusableCredentialUse: true,
    enableFocusedFill: enabled,
  );
  final client = AgentClient(server.port);
  addTearDown(() async {
    client.close();
    await server.close();
    await service.close();
  });
  return (repo, driver, service, server, client);
}

void main() {
  test(
    'safe discovery needs a private session and never reads material or grants input',
    () async {
      final (repo, driver, service, _, client) = await _fixture();
      expect(
        (await client.execute({'command': 'focus-target'}))['errorCode'],
        'session_required',
      );
      expect(driver.inspections, 0);
      await client.execute({
        'command': 'session',
        'chatLabel': 'Synthetic focus discovery',
      });
      final result = await client.execute({'command': 'focus-target'});
      expect(result, {
        'protocolVersion': 2,
        'status': 'ok',
        'targetState': 'ready',
        'application': {
          'executable': r'C:\Synthetic\Browser.exe',
          'sha256': 'a' * 64,
        },
      });
      expect(driver.inspections, 1);
      expect(driver.preparations, 0);
      expect(repo.reads, 0);
      expect(service.owner.credentialUseRequests, isEmpty);
    },
  );
  test('ended sessions cannot obtain delayed discovery results', () async {
    final (_, driver, service, _, client) = await _fixture();
    await client.execute({
      'command': 'session',
      'chatLabel': 'Synthetic ending session',
    });
    driver.gate = Completer<void>();
    final pending = client.execute({'command': 'focus-target'});
    await driver.entered.future;
    service.agent.endSession(client.sessionSecret!);
    driver.gate!.complete();
    final result = await pending;
    expect(result['errorCode'], 'session_required');
    expect(result.containsKey('application'), false);
  });
  test(
    'unsupported target is explicit and raw native errors are not projected',
    () async {
      final (_, driver, _, _, client) = await _fixture();
      await client.execute({
        'command': 'session',
        'chatLabel': 'Synthetic unsupported focus',
      });
      for (final code in ['desktop_locked', 'SURPRISE_PRIVATE_NATIVE_DETAIL']) {
        driver.result = FocusedFillTarget.refused(code);
        final result = await client.execute({'command': 'focus-target'});
        expect(result['targetState'], 'refused');
        expect(
          result['errorCode'],
          code == 'desktop_locked' ? code : 'unsupported_target',
        );
        expect(jsonEncode(result), isNot(contains('SURPRISE_PRIVATE')));
        expect(result.containsKey('application'), false);
      }
    },
  );
  test(
    'query refuses v1, secret text, HWND and executable overrides before inspection',
    () async {
      final (_, driver, _, _, client) = await _fixture();
      await client.execute({
        'command': 'session',
        'chatLabel': 'Synthetic invalid discovery',
      });
      for (final query in [
        {'command': 'focus-target', 'protocolVersion': 1},
        {'command': 'focus-target', 'password': 'SYNTHETIC_NOT_ECHOED'},
        {'command': 'focus-target', 'hwnd': 123},
        {
          'command': 'focus-target',
          'application': {'executable': r'C:\Other.exe'},
        },
      ]) {
        final result = await client.execute(query);
        expect(result['status'], 'invalid_request');
        expect(jsonEncode(result), isNot(contains('SYNTHETIC_NOT_ECHOED')));
      }
      expect(driver.inspections, 0);
    },
  );
  test('discovery remains gated off along with production fill', () async {
    final (_, driver, _, _, client) = await _fixture(enabled: false);
    await client.execute({
      'command': 'session',
      'chatLabel': 'Synthetic disabled discovery',
    });
    expect(
      (await client.execute({'command': 'focus-target'}))['errorCode'],
      'unsupported_capability',
    );
    expect(driver.inspections, 0);
  });
  test('public target parser rejects private or extra provider properties', () {
    final public = FocusedFillTarget.ready(
      FocusedFillApplication.fromJson({
        'executable': r'C:\Fixture.exe',
        'sha256': 'b' * 64,
      }),
    ).toJson();
    for (final extra in ['pid', 'provider', 'value', 'hwnd', 'runtimeId']) {
      expect(
        () => FocusedFillTarget.fromJson({...public, extra: 'not-public'}),
        throwsA(isA<CredentialUseFailure>()),
      );
    }
  });
  final broker = Platform.environment['ISSUE35_NATIVE_BROKER'];
  test(
    'actual native broker rejects malformed bounded frames without input or raw output',
    () async {
      for (final defect in ['too-large', 'version', 'opcode', 'truncated']) {
        final p = await Process.start(broker!, ['--broker-v1']);
        final output = p.stdout.toList(), errors = p.stderr.toList();
        Uint8List body = Uint8List(38)..[0] = 1;
        if (defect == 'version') body[0] = 2;
        if (defect == 'opcode') body[1] = 255;
        final header = ByteData(4)
          ..setUint32(
            0,
            defect == 'too-large' ? 16385 : body.length,
            Endian.little,
          );
        p.stdin.add(header.buffer.asUint8List());
        if (defect != 'truncated') p.stdin.add(body);
        await p.stdin.close();
        expect(
          await p.exitCode.timeout(const Duration(seconds: 4)),
          64,
          reason: defect,
        );
        expect(await output, isEmpty);
        expect(await errors, isEmpty);
      }
    },
    skip: broker == null || !Platform.isWindows,
  );
}
