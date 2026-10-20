import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/desktop_bootstrap.dart';
import 'support/desktop_platform_fixture.dart';
import 'support/information_attachment_fixture.dart';

void main() {
  test(
    'Windows bootstrap announces actual file support after startup reconciliation, and runtime retries held copies without fetching again',
    () async {
      var now = DateTime.utc(2026, 10, 19);
      final f = await AttachmentUiFixture.create(clock: () => now);
      final native = NativeDesktopFixture();
      final bootstrap = DesktopBootstrap(
        port: 0,
        platform: native,
        openLibrary: () async =>
            DesktopLibrary(service: f.service, close: () async {}),
      );
      try {
        final session = f.service.agent.openSession('启动前的领取');
        final ref = FieldRef(f.item.id, f.item.fields.last.id);
        final request = f.service.agent.request(session, '读取简历', [ref]);
        f.owner.approve(request.id, [ref]);
        await f.owner.retryAuditStorage();
        await f.fetch(session, request.id, 'before-bootstrap');
        now = now.add(const Duration(hours: 9));
        f.driver.blocked = true;
        await bootstrap.start();
        expect(bootstrap.state, DesktopStartupState.ready);
        expect(
          f.owner.informationFileDeliveries.single.state,
          'cleanup_pending',
        );
        expect(bootstrap.runtime!.informationDeliveryCleanupFailed, isTrue);
        final client = HttpClient();
        try {
          final outgoing = await client.post(
            '127.0.0.1',
            bootstrap.boundPort!,
            '/capabilities',
          );
          outgoing.headers.contentType = ContentType.json;
          outgoing.write('{}');
          final response = await outgoing.close();
          expect(response.statusCode, 200);
          final capabilities =
              jsonDecode(await response.transform(utf8.decoder).join())
                  as Map<String, dynamic>;
          expect(
            capabilities['capabilities'],
            contains('information-attachments.v1'),
          );
        } finally {
          client.close(force: true);
        }
        f.driver.blocked = false;
        await bootstrap.runtime!.reconcileInformationFiles();
        expect(f.driver.bodies, isEmpty);
        expect(f.driver.sequence, 1);
        expect(f.owner.informationFileDeliveries.single.state, 'expired');
        expect(bootstrap.runtime!.informationDeliveryCleanupFailed, isFalse);
        expect(bootstrap.runtime!.attachmentCleanupFailed, isFalse);
      } finally {
        if (bootstrap.runtime case final runtime?) {
          await runtime.stop();
          runtime.dispose();
        }
        bootstrap.dispose();
        await f.close();
      }
    },
    skip: !Platform.isWindows,
  );
}
