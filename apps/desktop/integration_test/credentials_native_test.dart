import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/main.dart' as app;
import 'package:info_desktop/credential_files.dart';
import 'support/isolated_desktop.dart';

class FixturePicker implements CredentialFilePicker {
  FixturePicker(this.path, this.native);
  final String path;
  final bool native;
  int count = 0;
  bool pending = false;
  @override
  Future<SelectedCredentialFile?> choose() async {
    count++;
    pending = true;
    debugPrint('D5_PICKER_READY $count source=$path native=$native');
    try {
      final result = native
          ? await const NativeCredentialFilePicker().choose()
          : count == 1
          ? null
          : await readCredentialFile(path);
      debugPrint(
        'D5_PICKER_DONE $count selected=${result != null} native=$native',
      );
      return result;
    } finally {
      pending = false;
    }
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'isolated Windows credential file copy links catalog and fixed version lifecycle',
    (tester) async {
      final fixture = await IsolatedDesktopFixture.start(
        prepareLibrary: (service) async {
          await service.owner.createInformation(
            'Deployment record',
            'Synthetic',
            const [FieldInput('Directory', '', '/fictional/deploy')],
          );
        },
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await fixture.close();
      });
      final owner = fixture.service.owner;
      final source = File('${fixture.root.path}/synthetic-private.key');
      await source.writeAsString('FICTIONAL-NATIVE-FILE-7103', flush: true);
      const native = bool.fromEnvironment(
        'NATIVE_CREDENTIAL_PICKER',
        defaultValue: false,
      );
      final picker = FixturePicker(source.path, native);
      await tester.pumpWidget(
        app.InformationApp(
          service: fixture.service,
          port: fixture.port,
          runtime: fixture.bootstrap.runtime,
          backups: fixture.bootstrap.library!.backups,
          credentialFiles: picker,
        ),
      );
      await tester.pumpAndSettle();
      debugPrint(
        'D5_NATIVE_VIEW physical=${tester.view.physicalSize} dpr=${tester.view.devicePixelRatio} logical=${tester.view.physicalSize / tester.view.devicePixelRatio}',
      );
      Future<void> tap(Finder finder) async {
        await tester.ensureVisible(finder);
        await tester.pumpAndSettle();
        await tester.tap(finder);
        await tester.pumpAndSettle();
      }

      Future<void> input(String key, String text) async {
        final f = find.byKey(ValueKey(key));
        await tester.ensureVisible(f);
        await tester.pumpAndSettle();
        await tester.enterText(f, text);
        await tester.pumpAndSettle();
      }

      Future<void> waitPicker() async {
        final watch = Stopwatch()..start();
        while (picker.pending && watch.elapsed < const Duration(minutes: 4)) {
          await tester.pump();
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 200)),
          );
        }
        expect(
          picker.pending,
          isFalse,
          reason: 'Native picker must complete before continuing.',
        );
        await tester.pumpAndSettle();
      }

      await tap(find.byKey(const ValueKey('nav-1')));
      await tap(find.byKey(const ValueKey('library-credentials-mode')));
      await tap(find.byKey(const ValueKey('new-credential')));
      await input('credential-name', 'Native token');
      await input('credential-secret', 'FICTIONAL-NATIVE-TOKEN-7103');
      await tap(find.byKey(const ValueKey('save-credential')));
      var token = owner.credentials.single;
      expect(token.discoverable, isFalse);
      expect(fixture.service.agent.credentialCatalog().credentials, isEmpty);
      await tap(find.byKey(const ValueKey('credential-metadata')));
      await tap(find.byKey(const ValueKey('credential-discoverable')));
      await tap(find.byKey(const ValueKey('save-credential-management')));
      await tap(find.byKey(const ValueKey('new-credential')));
      await tap(find.byKey(const ValueKey('credential-form-file')));
      await input('credential-name', 'Native file key');
      await tap(find.byKey(const ValueKey('choose-credential-file')));
      await waitPicker();
      expect(owner.credentials.length, 1);
      expect(find.text('未选择任何文件'), findsOneWidget);
      await tap(find.byKey(const ValueKey('choose-credential-file')));
      await waitPicker();
      expect(find.text('synthetic-private.key'), findsOneWidget);
      await tap(find.byKey(const ValueKey('save-credential')));
      var key = owner.credentials.firstWhere(
        (c) => c.form == CredentialForm.file,
      );
      expect(key.byteLength, 26);
      await source.writeAsString('CHANGED', flush: true);
      await source.delete();
      for (final item in owner.information) {
        await tap(find.text('信息').first);
        await tap(find.byKey(ValueKey(item.id)));
        await tap(find.text('管理关联'));
        await tap(find.byKey(ValueKey('credential-link-${key.id}')));
        await tap(find.byKey(const ValueKey('credential-save-links')));
        expect(owner.credentialsForInformation(item.id).single.id, key.id);
        await tap(find.byKey(const ValueKey('library-credentials-mode')));
      }
      expect(owner.informationForCredential(key.id).length, 2);
      await tap(find.byKey(ValueKey('credential-row-${key.id}')));
      await tap(find.byKey(const ValueKey('credential-metadata')));
      await tap(find.byKey(const ValueKey('credential-discoverable')));
      await tap(find.byKey(const ValueKey('save-credential-management')));
      const dart = String.fromEnvironment(
        'DART_EXECUTABLE',
        defaultValue: 'dart',
      );
      const cliDirectory = String.fromEnvironment(
        'CLI_DIRECTORY',
        defaultValue: '../../packages/info_cli',
      );
      final cli = await Process.start(dart, [
        'run',
        'bin/info.dart',
        '--port',
        '${fixture.port}',
      ], workingDirectory: cliDirectory);
      final lines = StreamIterator(
        cli.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );
      final errors = cli.stderr.transform(utf8.decoder).join();
      addTearDown(() async {
        await cli.stdin.close();
        cli.kill();
        await lines.cancel();
      });
      cli.stdin.writeln('{"command":"credential-catalog"}');
      expect(
        await lines.moveNext().timeout(const Duration(seconds: 20)),
        isTrue,
      );
      final catalog = jsonDecode(lines.current) as Map<String, dynamic>;
      expect((catalog['credentials'] as List).length, 2);
      expect(lines.current, isNot(contains('FICTIONAL-')));
      expect(lines.current, isNot(contains('synthetic-private.key')));
      expect(lines.current, isNot(contains(fixture.root.path)));
      await cli.stdin.close();
      expect(await cli.exitCode, 0);
      expect(await errors, isEmpty);
      await tap(find.byKey(ValueKey('credential-row-${token.id}')));
      token = owner.credential(token.id);
      final generation = token.useGeneration;
      await tap(find.text('更换版本'));
      await input('credential-new-secret', 'FICTIONAL-NATIVE-ROTATED-7103');
      await tap(find.byKey(const ValueKey('save-credential-management')));
      expect(owner.credential(token.id).version, 2);
      expect(
        () => owner.checkCredentialEligibility(
          token.id,
          1,
          useGeneration: generation,
        ),
        throwsA(isA<AccessFailure>()),
      );
      await tap(find.text('停用'));
      await tap(find.byKey(const ValueKey('save-credential-management')));
      await tap(find.text('启用'));
      await tap(find.byKey(const ValueKey('save-credential-management')));
      expect(
        () => owner.checkCredentialEligibility(
          token.id,
          2,
          useGeneration: generation,
        ),
        throwsA(isA<AccessFailure>()),
      );
      await tap(find.byKey(ValueKey('credential-row-${key.id}')));
      await tap(find.text('删除'));
      await tap(find.byKey(const ValueKey('save-credential-management')));
      expect(owner.credentials.where((c) => c.id == key.id), isEmpty);
      await tap(find.text('凭据回收站'));
      await tap(find.text('恢复').last);
      await tap(find.byKey(const ValueKey('save-credential-management')));
      key = owner.credential(key.id);
      expect(key.version, 2);
      expect(key.enabled, isFalse);
      expect(key.linkedItemIds.length, 2);
      await tester.pumpWidget(const SizedBox());
      await fixture.bootstrap.runtime!.stop();
      final reopened = await EncryptedInformationRepository.open(
        fixture.root.path,
        WindowsDatabaseKeyStore('${fixture.root.path}/database-key.dpapi'),
      );
      final reopenedService = InformationService(repository: reopened);
      try {
        expect(reopenedService.owner.credentials.length, 2);
        expect(reopenedService.owner.credential(key.id).enabled, isFalse);
        final bytes = (reopened as CredentialRepository).credentialMaterials
            .where((m) => m.credentialId == key.id && m.version == 2)
            .single
            .bytes;
        expect(utf8.decode(bytes), 'FICTIONAL-NATIVE-FILE-7103');
        expect(await source.exists(), isFalse);
      } finally {
        await reopenedService.close();
        await reopened.close();
      }
      debugPrint(
        'D5_NATIVE_VERIFIED nativePicker=$native: UI string/file independent copy, two information links, real CLI public catalog, monotonic fixed-version guard, disabled fresh restore and SQLCipher/DPAPI reopen',
      );
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
