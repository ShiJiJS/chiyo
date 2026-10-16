import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/agent_server.dart';
import 'package:info_core/info_core.dart';
import 'package:info_cli/agent_client.dart';
import 'package:info_desktop/desktop_runtime.dart';

import 'support/desktop_platform_fixture.dart';

void main() {
  test(
    'background startup purges expired recycle content before accepting owner use',
    () async {
      var now = DateTime.utc(2026, 10, 16);
      final service = InformationService.fictional(clock: () => now);
      final entry = await service.owner.deleteInformation('demo-server', 1);
      now = now.add(const Duration(days: 30));
      final runtime = DesktopRuntime(
        service: service,
        platform: NativeDesktopFixture(),
        closeServer: () async {},
        closeRepository: () async {},
      );
      await runtime.start();
      expect(service.owner.recycleFacts.last.kind, RecycleFactKind.purged);
      now = now.subtract(const Duration(days: 1));
      await expectLater(
        service.owner.restoreRecycled(entry.id),
        throwsA(isA<AccessFailure>()),
      );
      await runtime.quit();
    },
  );
  test(
    'full quit waits for audit writes and preserves the open library if flush fails',
    () async {
      final repository = FailingHistoryRepository();
      final service = InformationService(repository: repository);
      final item = await service.owner.createInformation(
        'Server',
        'Description',
        [const FieldInput('Host', 'Address', 'fictional.invalid')],
      );
      final session = service.agent.openSession('chat');
      final field = FieldRef(item.id, item.fields.single.id);
      final request = service.agent.request(session, 'Address', [field]);
      service.owner.approve(request.id, [field]);
      final native = NativeDesktopFixture();
      var libraryClosed = false;
      final runtime = DesktopRuntime(
        service: service,
        platform: native,
        closeServer: () async {},
        closeRepository: () async {
          libraryClosed = true;
        },
      );
      await runtime.start();
      await runtime.quit();
      expect(libraryClosed, isFalse);
      expect(native.terminated, isFalse);
      expect(runtime.shutdownFailed, isTrue);
      expect(
        () => service.agent.openSession('new'),
        throwsA(isA<AccessFailure>()),
      );
      repository.failing = false;
      await runtime.quit();
      expect(libraryClosed, isTrue);
      expect(native.terminated, isTrue);
      expect(
        repository.grantHistory.single.events.last.kind,
        GrantEventKind.applicationClosed,
      );
    },
  );
  test(
    'failed notification delivery retains the request and reports its unavailable state',
    () async {
      final service = InformationService.fictional();
      final native = NativeDesktopFixture()..deliveryAvailable = false;
      final runtime = DesktopRuntime(
        service: service,
        platform: native,
        closeServer: () async {},
        closeRepository: () async {},
      );
      await runtime.start();
      final session = service.agent.openSession('test chat');
      final request = service.agent.request(session, 'Need address', [
        const FieldRef('demo-server', 'host'),
      ]);
      await Future<void>.delayed(Duration.zero);
      expect(
        runtime.availability.notifications,
        NotificationAvailability.unavailable,
      );
      expect(service.agent.status(session, request.id)['status'], 'pending');
      await runtime.quit();
    },
  );

  test(
    'new requests arriving during native startup notify once; polling and reopening never repeat',
    () async {
      final service = InformationService.fictional();
      final server = await AgentServer.start(service.agent, port: 0);
      final ready = Completer<void>();
      final native = NativeDesktopFixture()..initialization = ready.future;
      final runtime = DesktopRuntime(
        service: service,
        platform: native,
        closeServer: server.close,
        closeRepository: () async {},
      );
      final starting = runtime.start();
      final client = AgentClient(server.port);
      addTearDown(client.close);
      await client.execute({'command': 'session', 'chatLabel': 'private chat'});
      final request = await client.execute({
        'command': 'request',
        'purpose': 'private purpose',
        'fields': [
          {'itemId': 'demo-server', 'fieldId': 'host'},
        ],
      });
      ready.complete();
      await starting;
      await Future<void>.delayed(Duration.zero);
      expect(native.notices, ['new_request']);
      final id = request['requestId'];
      await client.execute({'command': 'status', 'requestId': id});
      await client.execute({
        'command': 'wait',
        'requestId': id,
        'timeoutMs': 0,
      });
      await native.events!(DesktopEvent.openApprovals);
      expect(runtime.openApprovalsRevision, 1);
      expect(native.notices, ['new_request']);
      await runtime.quit();
    },
  );

  test(
    'hiding keeps approved CLI access; full quit stops it and invalidates old capabilities',
    () async {
      final service = InformationService.fictional();
      final server = await AgentServer.start(service.agent, port: 0);
      final native = NativeDesktopFixture();
      var dataClosed = false;
      final runtime = DesktopRuntime(
        service: service,
        platform: native,
        closeServer: server.close,
        closeRepository: () async {
          dataClosed = true;
        },
      );
      await runtime.start();
      final client = AgentClient(server.port);
      addTearDown(client.close);
      await client.execute({'command': 'session', 'chatLabel': 'private chat'});
      final request = await client.execute({
        'command': 'request',
        'purpose': 'private purpose',
        'fields': [
          {'itemId': 'demo-server', 'fieldId': 'host'},
        ],
      });
      final id = request['requestId'] as String;
      service.owner.approve(id, [const FieldRef('demo-server', 'host')]);
      await client.execute({'command': 'claim', 'requestId': id});
      await native.events!(DesktopEvent.closeWindow);
      expect(native.hidden, isTrue);
      expect(
        await client.execute({
          'command': 'read',
          'requestId': id,
          'itemId': 'demo-server',
          'fieldId': 'host',
        }),
        {'status': 'ok', 'value': 'demo.example.invalid'},
      );
      await native.events!(DesktopEvent.quit);
      expect(dataClosed, isTrue);
      expect(native.terminated, isTrue);
      expect(
        (await client.execute({
          'command': 'status',
          'requestId': id,
        }))['status'],
        'service_unavailable',
      );
      final fresh = InformationService.fictional();
      addTearDown(fresh.close);
      expect(
        () => fresh.agent.status(client.sessionSecret!, id),
        throwsA(isA<AccessFailure>()),
      );
    },
  );
}

class FailingHistoryRepository extends MemoryInformationRepository {
  bool failing = true;
  @override
  Future<void> saveGrantHistory(GrantHistory history) async {
    if (failing) throw StateError('storage unavailable');
    return super.saveGrantHistory(history);
  }
}
