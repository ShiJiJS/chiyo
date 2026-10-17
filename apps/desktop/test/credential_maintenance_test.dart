import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/desktop_runtime.dart';
import 'package:info_desktop/main.dart';
import 'support/desktop_platform_fixture.dart';
import 'support/credential_maintenance_fixture.dart';

void main() {
  testWidgets(
    'runtime tick preserves failed expired credential material and clears its real notice after retry',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var now = DateTime.utc(2026, 10, 1);
      final repository = MaintenanceRepository();
      final service = InformationService(
        repository: repository,
        clock: () => now,
      );
      var credential = await service.owner.createStringCredential(
        name: 'Synthetic token',
        publicPurpose: 'API',
        secret: 'fictional-old',
      );
      credential = await service.owner.rotateStringCredential(
        credential.id,
        credential.revision,
        'fictional-current',
      );
      final runtime = DesktopRuntime(
        service: service,
        platform: NativeDesktopFixture(),
        closeServer: () async {},
        closeRepository: () async {},
      );
      await runtime.start();
      await tester.pumpWidget(
        InformationApp(service: service, port: 0, runtime: runtime),
      );
      await tester.pumpAndSettle();
      expect(runtime.credentialCleanupFailed, isFalse);
      expect(repository.credentialMaterials.length, 2);
      repository.fail = true;
      now = now.add(const Duration(days: 30));
      await tester.pump(const Duration(minutes: 1));
      await tester.pumpAndSettle();
      expect(runtime.credentialCleanupFailed, isTrue);
      expect(repository.credentialMaterials.map((m) => m.version), [1, 2]);
      expect(
        find.text('凭据旧版本与回收内容的到期清理暂时失败，请检查存储。超期内容无法恢复，应用会再次尝试清理。'),
        findsOneWidget,
      );
      await expectLater(
        service.owner.restoreCredentialVersion(
          credential.id,
          credential.revision,
          1,
        ),
        throwsA(
          isA<AccessFailure>().having(
            (e) => e.status,
            'status',
            'credential_material_purged',
          ),
        ),
      );
      service.owner.checkCredentialEligibility(credential.id, 2);
      repository.fail = false;
      await tester.pump(const Duration(minutes: 1));
      await tester.pumpAndSettle();
      expect(runtime.credentialCleanupFailed, isFalse);
      expect(repository.credentialMaterials.map((m) => m.version), [2]);
      expect(find.textContaining('凭据旧版本与回收内容的到期清理暂时失败'), findsNothing);
      expect(repository.attempts, 4);
      service.owner.checkCredentialEligibility(credential.id, 2);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(runtime.quit);
    },
  );
}
