import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/main.dart';
import 'package:info_desktop/backups.dart';
import 'package:sqlite3/sqlite3.dart';

class _Files extends BackupFilePicker {
  const _Files(this.root);
  final String root;
  @override
  Future<String?> recoveryKeyOutput() async => '$root/recovery.txt';
  @override
  Future<String?> backupOutput() async => '$root/export.aimbackup';
  @override
  Future<String?> backupInput() async => '$root/export.aimbackup';
  @override
  Future<String?> recoveryKeyInput() async => '$root/recovery.txt';
}

Future<void> _wait(WidgetTester tester, Finder finder) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  do {
    await tester.pumpAndSettle();
    if (finder.evaluate().isNotEmpty) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  } while (DateTime.now().isBefore(deadline));
  expect(finder, findsWidgets);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'schema13 DPAPI upgrade, explicit native field conversion and encrypted credential recovery work after removing the source key',
    (tester) async {
      final root = await Directory.systemTemp.createTemp('aim-native-backup-');
      final keys = WindowsDatabaseKeyStore('${root.path}/source/key.dpapi');
      var repo = await EncryptedInformationRepository.open(
        '${root.path}/source',
        keys,
      );
      var service = InformationService(repository: repo);
      try {
        final item = await service.owner
            .createInformation('Native synthetic server', '', [
              const FieldInput('Access token', '', 'synthetic-native-v1'),
              const FieldInput('Host', '', 'synthetic.invalid'),
            ]);
        final ref = FieldRef(item.id, item.fields.first.id),
            host = FieldRef(item.id, item.fields.last.id);
        final version = (await service.owner.correctValue(
          ref,
          'synthetic-native-v2',
        )).version;
        final originalKey = (await keys.read())!;
        await service.close();
        await repo.close();
        // Deliberate encrypted legacy fixture. No user database or profile.
        final legacy = sqlite3.open('${root.path}/source/library.db');
        legacy.execute(
          'PRAGMA key = "x\'${originalKey.map((v) => v.toRadixString(16).padLeft(2, '0')).join()}\'"',
        );
        for (final table in [
          'ssh_host_trust',
          'credential_executions',
          'credential_use_requests',
          'credential_materials',
          'managed_credentials',
        ]) {
          legacy.execute('DROP TABLE $table');
        }
        legacy.execute('PRAGMA user_version = 13');
        legacy.close();
        repo = await EncryptedInformationRepository.open(
          '${root.path}/source',
          keys,
        );
        service = InformationService(repository: repo);
        expect(service.owner.information.single.id, item.id);
        expect(service.owner.information.single.version, version);
        expect(service.owner.information.single.fields.first.id, ref.fieldId);
        final session = service.agent.openSession('Native synthetic reader'),
            request = service.agent.request(session, 'Synthetic only', [
              ref,
              host,
            ]);
        service.owner.approve(request.id, [ref, host]);
        final proof = service.agent.claim(session, request.id).token;
        final file = await service.owner.createFileCredential(
          name: 'Native synthetic file',
          publicPurpose: '',
          fileName: 'synthetic.key',
          bytes: [0, 128, 255, 10],
        );
        final files = _Files(root.path);
        await tester.pumpWidget(
          InformationApp(
            key: UniqueKey(),
            service: service,
            port: 0,
            backups: repo.backups,
            backupFiles: files,
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('nav-1')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Native synthetic server').first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('转换旧秘密字段'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('migration-field')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Access token').last);
        await tester.pumpAndSettle();
        expect(find.textContaining('1 项读取授权'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('migration-confirm')));
        await _wait(tester, find.textContaining('已建立托管凭据并关闭旧读取路径'));
        expect(service.owner.information.single.fields.single.id, host.fieldId);
        expect(await service.agent.read(proof, host), 'synthetic.invalid');
        await expectLater(
          service.agent.read(proof, ref),
          throwsA(isA<AccessFailure>()),
        );
        final convertedId = service.owner.credentials
            .singleWhere((c) => c.form == CredentialForm.string)
            .id;
        await tester.tap(find.byKey(const ValueKey('nav-4')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('settings-section-backups')),
        );
        await _wait(tester, find.text('导出加密备份'));
        await tester.tap(find.text('导出加密备份'));
        await _wait(tester, find.text('创建恢复密钥'));
        await tester.tap(find.text('创建恢复密钥'));
        await _wait(tester, find.text('保存恢复密钥文件'));
        await tester.tap(find.text('保存恢复密钥文件'));
        await _wait(tester, find.text('恢复密钥已另存'));
        await tester.ensureVisible(find.text('导出加密备份').last);
        await tester.tap(find.text('导出加密备份').last);
        await _wait(tester, find.text('加密备份已导出。'));
        await tester.pumpWidget(const SizedBox.shrink());
        await service.close();
        await repo.close();
        await File(keys.path).delete();
        expect(await keys.read(), isNull);
        final freshKeys = WindowsDatabaseKeyStore(
          '${root.path}/target/key.dpapi',
        );
        repo = await EncryptedInformationRepository.open(
          '${root.path}/target',
          freshKeys,
        );
        service = InformationService(repository: repo);
        expect(await freshKeys.read(), isNot(originalKey));
        await tester.pumpWidget(
          InformationApp(
            key: UniqueKey(),
            service: service,
            port: 0,
            backups: repo.backups,
            backupFiles: files,
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('nav-4')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('settings-section-backups')),
        );
        await _wait(tester, find.text('导出加密备份'));
        await tester.tap(find.text('查看恢复步骤'));
        await _wait(tester, find.byKey(const ValueKey('backup-select-file')));
        await tester.tap(find.byKey(const ValueKey('backup-select-file')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('backup-select-key')));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('检查备份与恢复密钥'));
        await tester.tap(find.text('检查备份与恢复密钥'));
        await _wait(tester, find.text('恢复预览'));
        expect(find.textContaining('凭据对象 2 项'), findsOneWidget);
        await tester.ensureVisible(find.text('确认恢复到空库'));
        await tester.tap(find.text('确认恢复到空库'));
        await _wait(tester, find.text('资料已恢复，请到“信息库”查看。Agent 需要重新申请访问。'));
        expect(service.owner.information.single.id, item.id);
        expect(service.owner.information.single.fields.single.id, host.fieldId);
        expect(service.owner.credential(convertedId).linkedItemIds, [item.id]);
        expect(service.owner.credential(convertedId).discoverable, isFalse);
        expect(
          repo.credentialMaterials
              .singleWhere((m) => m.credentialId == file.id)
              .bytes,
          [0, 128, 255, 10],
        );
        expect(
          (await service.owner.history()).grants.every((g) => !g.active),
          isTrue,
        );
        await expectLater(
          service.agent.read(proof, host),
          throwsA(isA<AccessFailure>()),
        );
        expect(await repo.backups.recoveryKey(), isNull);
        debugPrint(
          'D9_NATIVE_VERIFIED schema13 encrypted DPAPI upgrade preserves identities; UI field conversion and complete credential backup; source key removed; UI restore with fresh DPAPI key; no old authority. Synthetic only; injected file picker, no OS dialog or notification acceptance.',
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await service.close();
        await repo.close();
        final parent = (await Directory.systemTemp.resolveSymbolicLinks())
            .toLowerCase();
        final actual = await root.resolveSymbolicLinks();
        if (actual.toLowerCase() != root.absolute.path.toLowerCase() ||
            !actual.toLowerCase().startsWith(
              '$parent${Platform.pathSeparator}',
            ) ||
            !root.uri.pathSegments
                .where((p) => p.isNotEmpty)
                .last
                .startsWith('aim-native-backup-')) {
          throw StateError(
            'Refusing fixture cleanup outside owned temporary root',
          );
        }
        await root.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
