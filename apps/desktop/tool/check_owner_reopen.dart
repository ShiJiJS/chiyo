// Run only through scripts/qa/check-owner-reopen.py. Each invocation is a
// separate Flutter test process using a disposable SQLCipher library.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/desktop_bootstrap.dart';
import 'package:info_desktop/workspace/owner_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_entries.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import '../test/support/desktop_platform_fixture.dart';

class _SyntheticKeys implements DatabaseKeyStore {
  @override
  Future<List<int>?> read() async => List.generate(32, (i) => i + 1);
  @override
  Future<void> create(List<int> key) async =>
      throw StateError('fixed test key');
}

void main() {
  test('independent owner process and backup round trip', () async {
    final root = Directory(Platform.environment['OWNER_REOPEN_ROOT']!);
    final phase = Platform.environment['OWNER_REOPEN_PHASE']!;
    expect(
      await File('${root.path}/fixture-marker').readAsString(),
      'disposable-owner-reopen-v1',
    );
    expect([
      'seed',
      'edit',
      'read',
      'restore',
      'restored-read',
    ], contains(phase));
    final restored = phase == 'restore' || phase == 'restored-read';
    final libraryPath = '${root.path}/${restored ? 'restored' : 'source'}';
    if (phase != 'seed' && phase != 'restore') {
      expect(await File('$libraryPath/library.db').exists(), isTrue);
    }
    final repo = await EncryptedInformationRepository.open(
      libraryPath,
      _SyntheticKeys(),
    );
    final native = NativeDesktopFixture();
    final bootstrap = DesktopBootstrap(
      port: 0,
      platform: native,
      openLibrary: () async => DesktopLibrary(
        service: core.InformationService(repository: repo),
        backups: repo.backups,
        close: repo.close,
      ),
    );
    await bootstrap.start();
    expect(bootstrap.state, DesktopStartupState.ready);
    expect(bootstrap.boundPort, greaterThan(0));
    var source = OwnerWorkspaceSource(
      owner: bootstrap.library!.service.owner,
      refreshInterval: Duration.zero,
    );
    final stateFile = File('${root.path}/identities.json');
    final state = phase == 'seed'
        ? <String, dynamic>{}
        : jsonDecode(await stateFile.readAsString()) as Map<String, dynamic>;
    WorkspaceRecordRef ref(String type) => WorkspaceRecordRef(
      WorkspaceRecordKind.information,
      state[type]['id'] as String,
    );
    try {
      if (phase == 'seed') {
        expect((await source.loadSummary()).isEmpty, isTrue);
        final directory = await source.changeDirectory(
          WorkspaceDirectoryChange(
            operationId: 'directory',
            expectedVersion: (await source.loadCatalog()).version,
            action: WorkspaceDirectoryAction.create,
            name: '合成目录',
          ),
        );
        final tag = await source.changeClassification(
          WorkspaceTagChange(
            operationId: 'tag',
            expectedVersion: (await source.loadCatalog()).version,
            action: WorkspaceTagAction.create,
            name: '合成标签',
          ),
        );
        state['directory'] = directory!.id;
        state['tag'] = tag.targetId;
        final values = <String, Map<String, Object?>>{
          'generic': {'body': 'synthetic original'},
          'document': {
            'bodyFormat': 'markdown',
            'body': '# synthetic document',
          },
          'profile': {
            'name': '合成人物',
            'education': [
              WorkspaceRepeatedEntry.empty().withText('title', '合成学校').toJson(),
            ],
            'experience': [],
          },
        };
        for (final entry in values.entries) {
          final template = await source.loadTemplate(entry.key);
          final saved = await source.createRecord(
            WorkspaceCreate(
              operationId: 'create-${entry.key}',
              typeId: entry.key,
              name: '合成${entry.key}',
              directoryId: directory.id,
              tagIds: [tag.targetId],
              values: entry.value,
              relations: entry.key == 'document'
                  ? {
                      'related': [ref('generic')],
                    }
                  : {},
              expectedTemplateVersion: template['templateVersion'] as String,
              expectedTemplateDigest: template['packageDigest'] as String,
            ),
          );
          expect(saved, isA<WorkspaceSaved>());
          final detail = (saved as WorkspaceSaved).detail;
          state[entry.key] = {
            'id': detail.record.ref.id,
            'fieldIds': detail.fieldIds,
            'values': detail.values,
          };
        }
      } else {
        if (phase == 'restore') {
          expect((await source.loadSummary()).isEmpty, isTrue);
          final recovery = await File(
            '${root.path}/recovery-secret',
          ).readAsString();
          await bootstrap.library!.service.owner.restoreLibrary(() async {
            await repo.backups.restoreFrom(
              '${root.path}/library.aimbackup',
              recovery,
            );
          });
          expect(source.isCurrentLibrary, isFalse);
          await source.dispose();
          source = OwnerWorkspaceSource(
            owner: bootstrap.library!.service.owner,
            refreshInterval: Duration.zero,
          );
        }
        final catalog = await source.loadCatalog();
        expect(catalog.directories.single.id, state['directory']);
        expect(catalog.tags.single.id, state['tag']);
        for (final type in ['generic', 'document', 'profile']) {
          final detail = await source.readDetail(ref(type));
          expect(detail.fieldIds, state[type]['fieldIds']);
          expect(detail.values, state[type]['values']);
          expect(detail.record.directoryId, state['directory']);
          expect(detail.record.tags.single.id, state['tag']);
          final receipt = await source.recordOperationReceipt('create-$type');
          if (restored) {
            expect(
              receipt,
              isNull,
              reason: 'backup excludes local operation receipts',
            );
          } else {
            expect(receipt!.result.ref, ref(type));
            expect(receipt.result.version, 1);
          }
        }
        final document = await source.readDetail(ref('document'));
        expect(document.relations['related'], [ref('generic')]);
        expect((await source.loadSummary()).records, 3);
        if (phase == 'edit') {
          final old = await source.readDetail(ref('generic'));
          final saved = await source.saveRecord(
            WorkspaceEdit(
              operationId: 'edit-generic',
              record: old.record,
              expectedVersion: 1,
              values: {'body': 'synthetic corrected'},
            ),
          );
          expect(saved, isA<WorkspaceSaved>());
          state['generic']['values'] = (saved as WorkspaceSaved).detail.values;
        } else {
          expect((await source.readDetail(ref('generic'))).version, 2);
          expect(
            (await source.loadRevisions(ref('generic'))).length,
            greaterThanOrEqualTo(1),
          );
          final receipt = await source.recordOperationReceipt('edit-generic');
          expect(receipt?.result.version, restored ? isNull : 2);
        }
        if (phase == 'read') {
          final recovery = await repo.backups.enable();
          await repo.backups.saveRecoveryKeyTo(
            '${root.path}/saved-recovery.txt',
          );
          await File('${root.path}/recovery-secret').writeAsString(recovery);
          await bootstrap.library!.service.owner.exportLibrary(() async {
            await repo.backups.exportTo('${root.path}/library.aimbackup');
          });
        }
      }
      await stateFile.writeAsString(jsonEncode(state));
    } finally {
      await source.dispose();
      await bootstrap.runtime!.quit();
      expect(native.terminated, isTrue);
      expect(bootstrap.library!.service.owner.serviceAvailable, isFalse);
      bootstrap.runtime!.dispose();
      bootstrap.dispose();
    }
    await File('${root.path}/$phase-result.json').writeAsString(
      jsonEncode({
        'phase': phase,
        'pid': pid,
        'passed': true,
        'nativePlatform': 'fixture',
        'storage': 'SQLCipher',
      }),
    );
  });
}
