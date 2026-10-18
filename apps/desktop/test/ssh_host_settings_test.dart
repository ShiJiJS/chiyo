import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/settings.dart';
import 'package:info_desktop/credential_files.dart';
import 'package:info_desktop/backups.dart';
import 'package:info_desktop/ui.dart';
import 'support/file_approval_fixture.dart' show knownHostBytes;

class _Hosts implements CredentialFilePicker {
  @override
  Future<SelectedCredentialFile?> choose() async =>
      SelectedCredentialFile('confirmed-known-hosts', knownHostBytes());
}

void main() {
  testWidgets(
    'selected known_hosts stays inactive until explicit confirmation, then can be removed with a separate confirmation',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = (await tester.runAsync(
        () async =>
            InformationService(repository: MemoryInformationRepository()),
      ))!;
      addTearDown(service.close);
      Future<void> tap(String label) async {
        await tester.runAsync(() async {
          await tester.tap(find.text(label));
          await Future<void>.delayed(Duration.zero);
        });
        await tester.pumpAndSettle();
      }

      await tester.pumpWidget(
        MaterialApp(
          theme: informationTheme(),
          home: Scaffold(
            body: SettingsPage(
              owner: service.owner,
              files: const NativeBackupFilePicker(),
              sshHostFiles: _Hosts(),
              initialSection: SettingsSection.sshHosts,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tap('导入主机记录');
      expect(service.owner.sshKnownHosts, isNull);
      expect(
        find.textContaining('[test.beichen.example]:2222'),
        findsOneWidget,
      );
      await tap('返回核对');
      expect(service.owner.sshKnownHosts, isNull);
      await tap('导入主机记录');
      await tap('确认并启用');
      expect(service.owner.sshKnownHosts!.name, 'confirmed-known-hosts');
      await tap('清除主机记录');
      expect(service.owner.sshKnownHosts, isNotNull);
      await tap('确认清除');
      expect(service.owner.sshKnownHosts, isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
