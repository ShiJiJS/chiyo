import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/desktop_bootstrap.dart';
import 'package:info_desktop/main.dart';
import 'support/desktop_platform_fixture.dart';

void main() {
  test(
    'occupied startup port retains failed audit writes until cleanup can finish',
    () async {
      final occupied = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(occupied.close);
      final repository = FailingAuditRepository();
      var libraryClosed = false;
      final bootstrap = DesktopBootstrap(
        port: occupied.port,
        platform: NativeDesktopFixture(),
        openLibrary: () async {
          final service = InformationService(repository: repository);
          final item = await service.owner.createInformation('Server', '', [
            const FieldInput('Host', '', 'private.invalid'),
          ]);
          final ref = FieldRef(item.id, item.fields.single.id);
          final request = service.agent.request(
            service.agent.openSession('chat'),
            'host',
            [ref],
          );
          service.owner.approve(request.id, [ref]);
          return DesktopLibrary(
            service: service,
            close: () async {
              libraryClosed = true;
            },
          );
        },
      );
      await bootstrap.start();
      expect(bootstrap.state, DesktopStartupState.failed);
      expect(bootstrap.runtime, isNull);
      expect(bootstrap.cleanupPending, isTrue);
      expect(libraryClosed, isFalse);
      repository.failing = false;
      // The port remains occupied, so this also exercises successful cleanup
      // followed by an ordinary startup failure with no retained resources.
      await bootstrap.start();
      expect(bootstrap.state, DesktopStartupState.failed);
      expect(bootstrap.cleanupPending, isFalse);
      expect(bootstrap.library, isNull);
      expect(libraryClosed, isTrue);
      expect(
        repository.grantHistory.every(
          (h) => h.events.last.kind == GrantEventKind.applicationClosed,
        ),
        isTrue,
      );
    },
  );

  testWidgets(
    'startup error stays visible when saving audit facts also fails',
    (tester) async {
      final repository = FailingAuditRepository();
      final bootstrap = DesktopBootstrap(
        port: 0,
        platform: NativeDesktopFixture(),
        openLibrary: () async {
          final service = InformationService(repository: repository);
          final item = await service.owner.createInformation('Server', '', [
            const FieldInput('Host', '', 'private.invalid'),
          ]);
          final ref = FieldRef(item.id, item.fields.single.id);
          final request = service.agent.request(
            service.agent.openSession('chat'),
            'host',
            [ref],
          );
          service.owner.approve(request.id, [ref]);
          return DesktopLibrary(service: service, close: () async {});
        },
      );
      await tester.runAsync(bootstrap.start);
      await tester.pumpWidget(DesktopLauncher(bootstrap: bootstrap));
      expect(find.textContaining('记录尚未保存'), findsOneWidget);
      expect(find.text('重试保存并启动'), findsOneWidget);
      expect(tester.takeException(), isNull);
      repository.failing = false;
      await tester.runAsync(() async {
        await bootstrap.runtime?.quit();
      });
    },
  );

  test(
    'failed startup keeps unsaved facts, stops its server and retries before reopening the library',
    () async {
      final repository = FailingAuditRepository();
      var libraryClosed = false;
      var opened = 0;
      final bootstrap = DesktopBootstrap(
        port: 0,
        platform: NativeDesktopFixture(),
        openLibrary: () async {
          if (opened++ > 0) expect(libraryClosed, isTrue);
          libraryClosed = false;
          final service = InformationService(repository: repository);
          if (opened == 1) {
            final item = await service.owner.createInformation('Server', '', [
              const FieldInput('Host', '', 'private.invalid'),
            ]);
            final ref = FieldRef(item.id, item.fields.single.id);
            final session = service.agent.openSession('startup chat');
            final request = service.agent.request(session, 'host', [ref]);
            service.owner.approve(request.id, [ref]);
            await expectLater(
              service.agent.read(
                service.agent.claim(session, request.id).token,
                ref,
              ),
              throwsA(
                isA<AccessFailure>().having(
                  (e) => e.status,
                  'status',
                  'audit_unavailable',
                ),
              ),
            );
          }
          return DesktopLibrary(
            service: service,
            close: () async {
              expect(
                repository.grantHistory.single.events.last.kind,
                GrantEventKind.applicationClosed,
              );
              libraryClosed = true;
            },
          );
        },
      );
      // Even failed-startup resources are retained until the test repairs storage.
      addTearDown(() async {
        repository.failing = false;
        await bootstrap.runtime?.quit();
      });
      await expectLater(bootstrap.start(), completes);
      expect(bootstrap.state, DesktopStartupState.failed);
      expect(bootstrap.cleanupPending, isTrue);
      expect(libraryClosed, isFalse);
      expect(repository.grantHistory, isEmpty);
      final failedPort = bootstrap.boundPort!;
      await expectLater(
        Socket.connect(InternetAddress.loopbackIPv4, failedPort),
        throwsA(isA<SocketException>()),
      );
      await bootstrap.start();
      expect(bootstrap.state, DesktopStartupState.failed);
      expect(opened, 1);
      expect(libraryClosed, isFalse);
      repository.failing = false;
      await bootstrap.start();
      expect(bootstrap.state, DesktopStartupState.ready);
      expect(opened, 2);
      expect(
        repository.grantHistory.single.events.last.kind,
        GrantEventKind.applicationClosed,
      );
      expect(
        repository.accessRecords.single.outcome,
        AccessOutcome.auditUnavailable,
      );
      expect(bootstrap.cleanupPending, isFalse);
    },
  );
}

class FailingAuditRepository extends MemoryInformationRepository {
  bool failing = true;
  @override
  Future<void> saveGrantHistory(GrantHistory history) async {
    if (failing) throw StateError('storage unavailable');
    await super.saveGrantHistory(history);
  }
}
