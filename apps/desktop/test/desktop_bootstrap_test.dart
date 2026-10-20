import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/desktop_bootstrap.dart';
import 'package:info_desktop/desktop_runtime.dart';
import 'package:info_desktop/main.dart';
import 'support/desktop_platform_fixture.dart';

void main() {
  testWidgets(
    'Mac key failure remains actionable and retry/quit never starts an endpoint',
    (tester) async {
      final native = NativeDesktopFixture();
      var opens = 0;
      final bootstrap = DesktopBootstrap(
        platform: native,
        openLibrary: () async {
          opens++;
          throw const StorageFailure('key_unavailable');
        },
      );
      await tester.runAsync(bootstrap.start);
      await tester.pumpWidget(DesktopLauncher(bootstrap: bootstrap));
      expect(find.textContaining('系统钥匙串'), findsOneWidget);
      expect(find.textContaining('原版本导出备份'), findsOneWidget);
      await tester.tap(find.text('重试启动'));
      await tester.pumpAndSettle();
      expect(opens, 2);
      expect(bootstrap.state, DesktopStartupState.failed);
      expect(bootstrap.boundPort, isNull);
      expect(bootstrap.library, isNull);
      await native.events!(DesktopEvent.quit);
      expect(native.terminated, isTrue);
    },
    skip: !Platform.isMacOS,
  );

  test(
    'quit works when library opening failed before runtime initialization',
    () async {
      final native = NativeDesktopFixture();
      final bootstrap = DesktopBootstrap(
        platform: native,
        openLibrary: () async => throw StateError('key_unavailable'),
      );
      await bootstrap.start();
      expect(bootstrap.state, DesktopStartupState.failed);
      expect(bootstrap.runtime, isNull);
      await native.events!(DesktopEvent.quit);
      expect(native.terminated, isTrue);
    },
  );

  test(
    'quit during opening waits for startup and closes owned resources once',
    () async {
      final native = NativeDesktopFixture();
      final opening = Completer<DesktopLibrary>();
      final entered = Completer<void>();
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      var closed = 0;
      final bootstrap = DesktopBootstrap(
        port: 0,
        platform: native,
        openLibrary: () {
          entered.complete();
          return opening.future;
        },
      );
      final start = bootstrap.start();
      await entered.future;
      final quit = native.events!(DesktopEvent.quit);
      await Future<void>.delayed(Duration.zero);
      expect(native.terminated, isFalse);
      opening.complete(
        DesktopLibrary(
          service: service,
          close: () async {
            closed++;
          },
        ),
      );
      await start;
      await quit;
      expect(native.terminated, isTrue);
      expect(closed, 1);
      bootstrap.runtime!.dispose();
    },
  );

  for (final event in [DesktopEvent.closeWindow, DesktopEvent.quit]) {
    test('cleaned startup failure still handles native $event', () async {
      final repository = TransientAuditRepository();
      final native = NativeDesktopFixture();
      var libraryClosed = false;
      final bootstrap = DesktopBootstrap(
        port: 0,
        platform: native,
        openLibrary: () async {
          final service = InformationService(repository: repository);
          final item = await service.owner.createInformation('Server', '', [
            const FieldInput('Host', '', 'fictional.invalid'),
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
      expect(bootstrap.cleanupPending, isFalse);
      expect(libraryClosed, isTrue);
      expect(bootstrap.runtime, isNull);
      expect(
        repository.grantHistory.single.events.last.kind,
        GrantEventKind.applicationClosed,
      );
      await native.events!(event);
      expect(native.terminated, isTrue);
    });
  }

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
      final native = NativeDesktopFixture()..hidden = true;
      var libraryClosed = false;
      var opened = 0;
      final bootstrap = DesktopBootstrap(
        port: 0,
        platform: native,
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
      expect(native.hidden, isFalse);
      await native.events!(DesktopEvent.closeWindow);
      await expectLater(
        native.events!(DesktopEvent.quit),
        throwsA(isA<AccessFailure>()),
      );
      expect(native.terminated, isFalse);
      expect(libraryClosed, isFalse);
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
      await native.events!(DesktopEvent.closeWindow);
      expect(native.hidden, isTrue);
      expect(native.terminated, isFalse);
      await native.events!(DesktopEvent.openApprovals);
      expect(native.hidden, isFalse);
      await native.events!(DesktopEvent.quit);
      expect(native.terminated, isTrue);
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

class TransientAuditRepository extends MemoryInformationRepository {
  int writes = 0;
  @override
  Future<void> saveGrantHistory(GrantHistory history) async {
    // The first write and startup retry fail; cleanup can save both facts.
    if (writes++ < 2) throw StateError('temporarily unavailable');
    await super.saveGrantHistory(history);
  }
}
