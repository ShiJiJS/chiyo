import 'dart:convert';
import 'dart:io';
import 'package:info_cli/agent_client.dart';
import 'package:info_cli/device_focused_fill_host.dart';
import 'package:info_core/info_core.dart';
import 'package:info_remote/automatic_connection.dart';
import 'package:test/test.dart';
import 'support/device_credential_fixture.dart';

const secret = 'Synthetic password😀 more than sixteen units';
final application = FocusedFillApplication.fromJson({
  'executable': '/on-executing-device/Browser',
  'sha256': 'a' * 64,
});

class Driver implements FocusedFillDiscoveryDriver {
  String? refusal;
  bool mismatch = false;
  int prepares = 0, closes = 0;
  final batches = <List<int>>[];
  Future<FocusedFillBatchResult> Function(int)? onBatch;
  @override
  Future<FocusedFillTarget> inspectTarget() async => refusal == null
      ? FocusedFillTarget.ready(application)
      : FocusedFillTarget.refused(refusal);
  @override
  Future<PreparedFocusedFill> prepare(FocusedFillApplication requested) async {
    prepares++;
    if (refusal != null) throw CredentialUseFailure(refusal!);
    return Prepared(
      this,
      mismatch
          ? FocusedFillApplication.fromJson({
              'executable': '/different/Browser',
              'sha256': 'b' * 64,
            })
          : requested,
    );
  }
}

class Prepared implements PreparedFocusedFill {
  Prepared(this.driver, this.application);
  final Driver driver;
  @override
  final FocusedFillApplication application;
  bool closed = false;
  @override
  Future<FocusedFillBatchResult> sendBatch(List<int> units) async {
    if (closed) throw StateError('closed');
    driver.batches.add(List.of(units));
    return await driver.onBatch?.call(driver.batches.length) ??
        const FocusedFillBatchResult(FocusedFillState.sent);
  }

  @override
  Future<void> close() async {
    if (!closed) {
      closed = true;
      driver.closes++;
    }
  }
}

class Fixture {
  Fixture(
    this.server,
    this.directory,
    this.driver,
    this.session,
    this.client,
    this.credentialId,
  );
  final DeviceCredentialFixture server;
  final Directory directory;
  final Driver driver;
  final String session, credentialId;
  final AgentClient client;
  DeviceFocusedFillHost? host;
  late String requestId;
  static Future<Fixture> create({
    String? loseFirstPath,
    DateTime Function()? clock,
  }) async {
    final server = await DeviceCredentialFixture.create(
      loseFirstPath: loseFirstPath,
      clock: clock,
    );
    final directory = Directory('${server.root.path}/app-private');
    await AutomaticConnectionStore(
      directory.path,
    ).publish({'mode': 'server'}, server.profiles.first);
    final driver = Driver();
    final chat = await server.agents.first.call('/session/lifecycle', {
      'chatLabel': 'Synthetic remote password field',
    });
    final c = await server.runtime.run(() async {
      final raw = await server.runtime.service.owner.createStringCredential(
        name: 'Synthetic password',
        publicPurpose: '',
        secret: secret,
      );
      return server.runtime.service.owner.updateCredentialMetadata(
        raw.id,
        raw.revision,
        name: raw.name,
        publicPurpose: '',
        privateNote: '',
        suggestedBinding: 'password',
        discoverable: true,
      );
    });
    final session = chat['sessionSecret'] as String;
    final f = Fixture(
      server,
      directory,
      driver,
      session,
      AgentClient.remote(
        server.profiles.first,
        sessionSecret: session,
        focusedFillHostDirectory: directory,
      ),
      c.id,
    );
    addTearDown(() async {
      f.client.close();
      await f.host?.close();
      await server.dispose();
    });
    return f;
  }

  Future<void> start() async => host = await DeviceFocusedFillHost.start(
    directory: directory,
    driver: driver,
  );
  Map<String, dynamic> request() => {
    'protocolVersion': 2,
    'command': 'request-use',
    'purpose': 'Synthetic form login',
    'credentials': [
      {'alias': 'password', 'credentialId': credentialId, 'version': 1},
    ],
    'fill': FocusedFillPlan(application, 'Synthetic login').toJson(),
  };
  Map<String, dynamic> operation(String id, {bool status = false}) => {
    'protocolVersion': 2,
    'command': status ? 'fill-status' : 'fill-use',
    'requestId': requestId,
    'operationId': id,
  };
  Future<void> approve() async {
    final result = await client.execute(request());
    expect(result['status'], 'pending', reason: '$result');
    requestId = result['requestId'] as String;
    await server.runtime.run(
      () => server.runtime.service.owner.decideCredentialUse(
        requestId,
        approveCredential: true,
      ),
    );
  }

  Future<Map<String, dynamic>> settle(String id) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (true) {
      final result = await client.execute(operation(id, status: true));
      if (result['fillState'] != 'checking') return result;
      if (DateTime.now().isAfter(deadline))
        throw StateError('Synthetic fill did not settle');
      await Future<void>.delayed(const Duration(milliseconds: 15));
    }
  }
}

void publicResult(Map<String, dynamic> result) {
  expect(jsonEncode(result), isNot(contains(secret)));
  for (final name in [
    'materialBase64',
    'fillCapability',
    'deviceToken',
    'characterCount',
    'secret',
  ]) {
    expect(result, isNot(contains(name)));
  }
}

void main() {
  test(
    'HTTPS NAS grant fills through running matching App; public results contain no secret or proof',
    () async {
      final f = await Fixture.create();
      expect(
        (await f.client.execute({'command': 'capabilities'}))['capabilities'],
        isNot(contains('credential-focused-fill.v1')),
      );
      expect(
        (await f.client.execute({'command': 'focus-target'}))['status'],
        'service_unavailable',
      );
      await f.start();
      expect(
        (await f.client.execute({'command': 'capabilities'}))['capabilities'],
        contains('credential-focused-fill.v1'),
      );
      expect(
        (await f.client.execute({'command': 'focus-target'}))['application'],
        application.toJson(),
      );
      await f.approve();
      expect(f.driver.batches, isEmpty);
      final claim = await f.client.execute(f.operation('normal'));
      publicResult(claim);
      expect(claim['operationClaimed'], true);
      final result = await f.settle('normal');
      publicResult(result);
      expect(result['fillState'], 'sent');
      expect(String.fromCharCodes(f.driver.batches.expand((b) => b)), secret);
      final count = f.driver.batches.length;
      expect(
        (await f.client.execute(f.operation('normal')))['duplicate'],
        true,
      );
      expect(f.driver.batches.length, count);
      expect(
        (await f.client.execute(f.operation('later')))['operationClaimed'],
        true,
      );
      expect((await f.settle('later'))['fillState'], 'sent');
      final different = DeviceFocusedFillClient(
        f.server.profiles.last,
        directory: f.directory,
      );
      expect(
        (await different.execute(f.session, {
          'command': 'focus-target',
          'protocolVersion': 2,
        }))['errorCode'],
        'session_unavailable',
      );
      await AutomaticConnectionStore(
        f.directory.path,
      ).publish({'mode': 'local'}, null);
      expect(
        (await f.client.execute({'command': 'capabilities'}))['capabilities'],
        isNot(contains('credential-focused-fill.v1')),
      );
      await f.host!.close();
      f.host = null;
      expect(
        (await f.client.execute(
          f.operation('normal', status: true),
        ))['fillState'],
        'sent',
      );
    },
  );
  test(
    'native unavailable is absent from capability; prepared mismatch cannot send; confirmed refusal releases slots',
    () async {
      final f = await Fixture.create();
      f.driver.refusal = 'access_denied';
      await f.start();
      expect(
        (await f.client.execute({'command': 'capabilities'}))['capabilities'],
        isNot(contains('credential-focused-fill.v1')),
      );
      f.driver.refusal = null;
      await f.approve();
      f.driver.mismatch = true;
      await f.client.execute(f.operation('mismatch'));
      final mismatch = await f.settle('mismatch');
      expect(mismatch['fillState'], 'refused');
      expect(mismatch['errorCode'], 'application_changed');
      expect(f.driver.batches, isEmpty);
      f.driver.mismatch = false;
      f.driver.onBatch = (_) async => const FocusedFillBatchResult(
        FocusedFillState.refused,
        'input_rejected',
      );
      await f.client.execute(f.operation('refused'));
      expect((await f.settle('refused'))['fillState'], 'refused');
      f.driver.onBatch = null;
      await f.client.execute(f.operation('after-refused'));
      expect((await f.settle('after-refused'))['fillState'], 'sent');
    },
  );
  test(
    'revoke between native batches stops next batch and retains partial attention',
    () async {
      final f = await Fixture.create();
      await f.start();
      await f.approve();
      f.driver.onBatch = (n) async {
        if (n == 1)
          await f.server.runtime.run(
            () =>
                f.server.runtime.service.owner.revokeCredentialUse(f.requestId),
          );
        return const FocusedFillBatchResult(FocusedFillState.sent);
      };
      await f.client.execute(f.operation('revoked'));
      final result = await f.settle('revoked');
      expect(result['fillState'], 'partial');
      expect(result['errorCode'], 'grant_revoked');
      expect(f.driver.batches.length, 1);
      publicResult(result);
    },
  );
  for (final point in ['begin', 'material', 'finish']) {
    test(
      'lost $point response never replays material or native input',
      () async {
        var now = DateTime.utc(2026, 11, 12);
        final f = await Fixture.create(
          loseFirstPath: '/v1/agent/credential-use/device/fill/$point',
          clock: () => now,
        );
        await f.start();
        await f.approve();
        final first = await f.client.execute(f.operation('lost'));
        publicResult(first);
        if (point == 'begin') {
          expect(first['errorCode'], 'fill_unknown');
          expect(first['operationClaimed'], true);
          expect(f.driver.batches, isEmpty);
          now = now.add(const Duration(seconds: 31));
        }
        final result = await f.settle('lost');
        expect(
          result['fillState'],
          point == 'begin'
              ? 'unknown'
              : point == 'material'
              ? 'refused'
              : 'sent',
        );
        final count = f.driver.batches.length;
        publicResult(await f.client.execute(f.operation('lost')));
        expect(f.driver.batches.length, count);
        expect(f.server.claimPosts, 1);
        if (point == 'begin') {
          expect(
            (await f.client.execute(f.operation('blocked')))['errorCode'],
            'fill_needs_attention',
          );
          await f.server.runtime.run(
            () => f.server.runtime.service.owner
                .acknowledgeFocusedFillAttention(result['fillId'] as String),
          );
          await f.client.execute(f.operation('reviewed'));
          expect((await f.settle('reviewed'))['fillState'], 'sent');
        }
      },
    );
  }
  test(
    'pending operation survives encrypted NAS reopen as unknown without second claim',
    () async {
      final f = await Fixture.create();
      await f.start();
      await f.approve();
      final claim = await f.server.agents.first.call(
        '/credential-use/device/fill/begin',
        {'sessionSecret': f.session, ...f.operation('restart')},
      );
      expect(claim['fillCapability'], isA<String>());
      await f.server.reopen();
      expect(
        (await f.client.execute(
          f.operation('restart', status: true),
        ))['fillState'],
        'unknown',
      );
      expect(
        (await f.client.execute(f.operation('restart')))['duplicate'],
        true,
      );
      expect(f.driver.batches, isEmpty);
      expect(
        (await f.server.agents.last.call('/credential-use/device/fill/status', {
          'sessionSecret': f.session,
          ...f.operation('restart', status: true),
        }))['status'],
        'unauthorized',
      );
    },
  );
}
