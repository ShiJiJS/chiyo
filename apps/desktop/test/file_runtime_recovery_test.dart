import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/desktop_runtime.dart';
import 'support/desktop_platform_fixture.dart';
import 'support/file_approval_fixture.dart';

void main() {
  test(
    'desktop startup cleans registered terminal materials without restarting the consumed command',
    () async {
      final fixture = await fileApprovalFixture('aws_shared_credentials');
      final service = fixture.$1;
      addTearDown(service.close);
      await service.owner.decideCredentialUse(
        fixture.$3.id,
        approveCredential: true,
      );
      final material = await service.agent.consumeCredentialUse(
        fixture.$2,
        fixture.$3.id,
      );
      await service.agent.reportCredentialExecution(
        CredentialExecutionReport(
          executionId: material.executionId,
          executionCapability: material.executionCapability,
          state: 'prepare_failed',
          errorCode: 'material_prepare_failed',
          finishedAt: DateTime.now().toUtc(),
        ),
      );
      final runtime = DesktopRuntime(
        service: service,
        platform: NativeDesktopFixture(),
        closeServer: () async {},
        closeRepository: () async {},
      );
      addTearDown(() async {
        try {
          await service.owner.cleanupCredentialExecution(material.executionId);
        } finally {
          await runtime.stop();
        }
      });
      await runtime.start();
      expect(await Directory(material.materialLease!.path).exists(), isFalse);
      expect(
        service.owner.credentialExecutions.single.cleanupState,
        'complete',
      );
      expect(service.owner.credentialExecutions.single.state, 'prepare_failed');
      expect(
        service.owner.credentialUseRequests.single.attemptConsumed,
        isTrue,
      );
    },
    skip: !Platform.isWindows && !Platform.isMacOS,
  );
}
