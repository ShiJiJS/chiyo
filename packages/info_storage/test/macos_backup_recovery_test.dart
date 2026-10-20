@TestOn('mac-os')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:test/test.dart';
import 'backup_setup.dart';

class _Keys implements DatabaseKeyStore {
  List<int>? value;
  @override
  Future<List<int>?> read() async => value == null ? null : List.of(value!);
  @override
  Future<void> create(List<int> key) async => value = List.of(key);
}

Future<void> _removeOwned(Directory directory) async {
  final base = await Directory.systemTemp.resolveSymbolicLinks();
  final actual = await directory.resolveSymbolicLinks();
  if (actual != directory.absolute.path ||
      !actual.startsWith('$base/aim-macos-restore-')) {
    throw StateError('Refusing cleanup outside owned restore fixture');
  }
  await directory.delete(recursive: true);
}

sqlite.Database _raw(String path, List<int> key) {
  final db = sqlite.sqlite3.open(path);
  final hex = key.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  db.execute('PRAGMA key = "x\'$hex\'"');
  return db;
}

void main() {
  late Directory tools;
  late String childPath;
  setUpAll(() async {
    tools = await Directory.systemTemp.createTemp('aim-macos-restore-tools-');
    childPath = '${tools.path}/bundle/bin/macos_restore_child';
    final build = await Process.run(Platform.resolvedExecutable, [
      'build',
      'cli',
      '--target',
      'test/fixtures/macos_restore_child.dart',
      '--output',
      tools.path,
    ]);
    expect(build.exitCode, 0, reason: '${build.stdout}\n${build.stderr}');
    final payload = <Map<String, Object>>[];
    await for (final entry in Directory(
      '${tools.path}/bundle',
    ).list(recursive: true)) {
      if (entry is File) {
        final bytes = await entry.readAsBytes();
        payload.add({
          'path': entry.path.substring('${tools.path}/bundle/'.length),
          'bytes': bytes.length,
          'sha256': sha256.convert(bytes).toString(),
        });
      }
    }
    payload.sort(
      (a, b) => (a['path'] as String).compareTo(b['path'] as String),
    );
    print('MAC_RESTORE_AOT_PAYLOAD=${jsonEncode(payload)}');
  });
  tearDownAll(() async => _removeOwned(tools));

  for (final format in [8, 9]) {
    test(
      'Mac AOT format$format interruption during 80MiB restore rolls back and retries with distinct target key',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'aim-macos-restore-',
        );
        var completed = false;
        // Preserve only the test's own fixture after a failure for diagnosis.
        // No database/recovery key is written by the child or printed.
        addTearDown(() async {
          if (completed) await _removeOwned(root);
        });
        final sourceKeys = _Keys(), targetKeys = _Keys();
        final source = await EncryptedInformationRepository.open(
          '${root.path}/来源 资料',
          sourceKeys,
        );
        final service = InformationService(
          repository: source,
          informationDeliveryFiles: NativeInformationDeliveryFiles(),
        );
        final expected = <InformationItem>[];
        var sourceClosed = false;
        const fileBytes = 8 * 1024 * 1024;
        try {
          for (var index = 1; index <= 10; index++) {
            final input = File('${root.path}/合成 附件 $index.bin');
            await input.writeAsBytes(
              Uint8List(fileBytes)..fillRange(0, fileBytes, index),
            );
            final draft = await service.owner.beginInformationFileDraft();
            try {
              final stage = await service.owner.stageInformationFile(
                draft,
                input.path,
              );
              expected.add(
                await service.owner.commitInformationDraft(
                  draft,
                  'fixture-$index',
                  InformationDraftInput(
                    name: '合成附件 $index',
                    description: 'Mac restore fault acceptance',
                    fields: [
                      InformationDraftField.stagedFile('原文', '', stage.id),
                    ],
                  ),
                ),
              );
            } finally {
              await service.owner.releaseInformationFileDraft(draft);
            }
          }
          final text = await service.owner.createInformation('版本与回收', '', [
            const FieldInput('正文', '', 'synthetic before'),
            const FieldInput('待回收', '', 'synthetic recycle'),
          ]);
          final textRef = FieldRef(text.id, text.fields.first.id);
          await service.owner.correctValue(textRef, 'synthetic after');
          await service.owner.deleteInformation(
            text.id,
            2,
            fieldId: text.fields.last.id,
          );
          await service.owner.createFileCredential(
            name: '合成凭据文件',
            publicPurpose: 'No real external account',
            fileName: 'synthetic.key',
            bytes: [0, 128, 255, 10],
          );
          await service.owner.setRequestLifetime(const Duration(minutes: 23));
          final session = service.agent.openSession('备份前合成会话');
          final fileRef = FieldRef(
            expected.first.id,
            expected.first.fields.single.id,
          );
          final request = service.agent.request(session, '合成读取', [
            textRef,
            fileRef,
          ]);
          service.owner.approve(request.id, [textRef, fileRef]);
          final oldToken = service.agent.claim(session, request.id).token;
          await service.agent.read(oldToken, textRef);
          service.agent.request(session, '不得恢复待审批', [textRef]);
          String? deliveryId;
          if (format == 9) {
            final result = await service.agent.fetchInformationFile(
              session,
              InformationFileFetchInput.fromJson({
                'protocolVersion': 2,
                'command': 'file-fetch',
                'requestId': request.id,
                'itemId': fileRef.itemId,
                'fieldId': fileRef.fieldId,
                'operationId': 'before-backup',
              }),
            );
            deliveryId = (result['delivery'] as Map)['deliveryId'] as String?;
            expect(source.informationFileDeliveries, hasLength(1));
          }
          final recovery = await enableTestBackups(source.backups);
          final backup = File('${root.path}/中文 空格.aimbackup');
          await service.owner.exportLibrary(
            () => source.backups.exportTo(backup.path),
          );
          final beforeHash = sha256
              .convert(await backup.readAsBytes())
              .toString();
          final sourceKeyHash = sha256.convert(sourceKeys.value!).toString();
          await service.close();
          await source.close();
          sourceClosed = true;
          sourceKeys.value!.fillRange(0, sourceKeys.value!.length, 0);
          sourceKeys.value = null;
          final targetPath = '${root.path}/恢复 目标';
          var target = await EncryptedInformationRepository.open(
            targetPath,
            targetKeys,
          );
          final originalService = InformationService(repository: target);
          await originalService.owner.setRequestLifetime(
            const Duration(minutes: 17),
          );
          await originalService.close();
          await target.close();
          expect(
            sha256.convert(targetKeys.value!).toString(),
            isNot(sourceKeyHash),
          );
          final database = File('$targetPath/library.db');
          final baselineBytes = await database.length();
          final targetKeyBefore = List.of(targetKeys.value!);
          final victim = await Process.start(
            childPath,
            [],
            environment: {
              'PATH': '/usr/bin:/bin',
              'TMPDIR': Directory.systemTemp.path,
            },
            includeParentEnvironment: false,
          );
          var running = true;
          addTearDown(() async {
            if (running) {
              victim.kill(ProcessSignal.sigkill);
              await victim.exitCode;
            }
          });
          final stdout = <String>[];
          final ready = Completer<void>();
          final output = victim.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .listen((line) {
                stdout.add(line);
                final message = jsonDecode(line) as Map;
                if (message['phase'] == 'ready') {
                  expect(message['pid'], victim.pid);
                  if (!ready.isCompleted) ready.complete();
                }
              });
          final errors = victim.stderr.transform(utf8.decoder).join();
          int? exit;
          final exited = victim.exitCode.then((code) {
            running = false;
            exit = code;
            if (!ready.isCompleted)
              ready.completeError(
                StateError(
                  'AOT recipient ended before ready ($code): ${stdout.join()}',
                ),
              );
            return code;
          });
          victim.stdin.writeln(
            jsonEncode({
              'directory': targetPath,
              'databaseKey': targetKeys.value,
              'backup': backup.path,
              'recoveryKey': recovery,
            }),
          );
          await victim.stdin.flush();
          await ready.future.timeout(const Duration(seconds: 45));
          final journal = File('${database.path}-journal');
          expect(await journal.exists(), isFalse);
          victim.stdin.writeln('restore');
          await victim.stdin.flush();
          final deadline = DateTime.now().add(const Duration(seconds: 45));
          var wrote = false;
          var growth = 0;
          while (DateTime.now().isBefore(deadline) && running) {
            if (await journal.exists()) {
              try {
                final handle = await journal.open();
                final header = await handle.read(8);
                await handle.close();
                growth = await database.length() - baselineBytes;
                if (header.any((byte) => byte != 0) &&
                    growth >= 4 * 1024 * 1024) {
                  wrote = true;
                  expect(victim.kill(ProcessSignal.sigkill), isTrue);
                  break;
                }
              } on FileSystemException {
                // The transaction may commit between stat and open; that is
                // a missed interruption, never accepted as rollback evidence.
              }
            }
            await Future<void>.delayed(const Duration(milliseconds: 1));
          }
          expect(
            wrote,
            isTrue,
            reason: 'Must interrupt actual uncommitted attachment writes',
          );
          await exited.timeout(const Duration(seconds: 15));
          await victim.stdin.close();
          await output.cancel();
          expect(exit, isNot(0));
          expect(await journal.exists(), isTrue);
          expect(stdout.join(), isNot(contains('restored')));
          expect(await errors, isNot(contains(recovery)));
          // Read directly with SQLCipher BEFORE repository recovery, so an
          // application cleanup cannot conceal a partially restored database.
          final raw = _raw(database.path, targetKeys.value!);
          try {
            expect(
              raw.select('PRAGMA cipher_version').single.values.single,
              isNotEmpty,
            );
            expect(raw.select('PRAGMA user_version').single.values.single, 21);
            expect(
              raw.select('PRAGMA integrity_check').single.values.single,
              'ok',
            );
            for (final table in [
              'information_items',
              'information_attachment_versions',
              'information_file_fields',
              'information_file_stages',
            ]) {
              expect(
                raw.select('SELECT count(*) AS n FROM $table').single['n'],
                0,
              );
            }
          } finally {
            raw.close();
          }
          target = await EncryptedInformationRepository.open(
            targetPath,
            targetKeys,
          );
          final restored = InformationService(
            repository: target,
            informationDeliveryFiles: NativeInformationDeliveryFiles(),
          );
          try {
            expect(restored.owner.information, isEmpty);
            expect(restored.owner.requestLifetime, const Duration(minutes: 17));
            expect(target.informationRevisions, isEmpty);
            expect(target.recycleEntries, isEmpty);
            expect(target.grantHistory, isEmpty);
            expect(target.accessRecords, isEmpty);
            expect(target.informationFileDeliveries, isEmpty);
            final preview = await target.backups.inspect(backup.path, recovery);
            expect(preview.formatVersion, format);
            expect(preview.attachmentCount, 10);
            expect(preview.attachmentBytes, 80 * 1024 * 1024);
            await restored.owner.restoreLibrary(
              () => target.backups.restore(preview),
            );
            expect(restored.owner.information, hasLength(11));
            expect(restored.owner.requestLifetime, const Duration(minutes: 23));
            expect(target.informationRevisions, hasLength(2));
            expect(target.recycleEntries, hasLength(1));
            expect(target.credentialMaterials.single.bytes, [0, 128, 255, 10]);
            expect(
              target.grantHistory.every((record) => !record.active),
              isTrue,
            );
            expect(restored.owner.requests, isEmpty);
            expect(target.accessRecords.single.outcome, AccessOutcome.allowed);
            await expectLater(
              restored.agent.read(oldToken, textRef),
              throwsA(isA<AccessFailure>()),
            );
            if (format == 9) {
              final fact = target.informationFileDeliveries.single;
              expect(fact.runtime, isFalse);
              expect(fact.lease, isNull);
              expect(fact.sessionBinding, isNull);
              if (deliveryId != null) expect(fact.id, deliveryId);
              await expectLater(
                restored.agent.informationFileStatus(session, fact.id),
                throwsA(isA<InformationFileFailure>()),
              );
            }
            for (var index = 0; index < expected.length; index++) {
              final reference = expected[index].fields.single.attachment!;
              for (var offset = 0; offset < fileBytes; offset += 1024 * 1024) {
                final bytes = await target.readInformationAttachmentChunk(
                  reference,
                  offset,
                  1024 * 1024,
                );
                expect(bytes.length, 1024 * 1024);
                expect(bytes.every((byte) => byte == index + 1), isTrue);
              }
            }
            expect(targetKeys.value, targetKeyBefore);
            expect(
              sha256.convert(await backup.readAsBytes()).toString(),
              beforeHash,
            );
            print(
              'MAC_RESTORE_FORMAT_$format: AOT SIGKILL after ${growth ~/ (1024 * 1024)}MiB growth and hot journal; SQLCipher integrity/rollback passed; same-target retry restored 80MiB and no live authority. Synthetic in-memory keys, not Keychain or packaged UI.',
            );
          } finally {
            await restored.close();
            await target.close();
          }
          completed = true;
        } finally {
          if (!sourceClosed) {
            await service.close();
            await source.close();
          }
        }
      },
      timeout: const Timeout(Duration(minutes: 4)),
    );
  }
}
