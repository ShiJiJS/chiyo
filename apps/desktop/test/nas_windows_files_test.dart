@TestOn('windows')
library;

import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/backups.dart';
import 'package:info_desktop/information_files.dart';
import 'package:info_desktop/workspace/remote_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_remote/connection_profile.dart';
import 'package:info_remote/owner_client.dart';
import 'support/native_file_actions_fixture.dart';

class _Http extends HttpOverrides {
  bool loseNextChange = false;
  int changes = 0, lostReplies = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _Client(super.createHttpClient(context), this);
}

class _Client implements HttpClient {
  _Client(this.inner, this.observation);
  final HttpClient inner;
  final _Http observation;
  @override
  Duration? get connectionTimeout => inner.connectionTimeout;
  @override
  set connectionTimeout(Duration? value) => inner.connectionTimeout = value;
  @override
  void close({bool force = false}) => inner.close(force: force);
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    final change = method == 'POST' && url.path == '/v1/owner/files/changes';
    if (change) observation.changes++;
    return _Request(await inner.openUrl(method, url), observation, change);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Unexpected HTTP client operation');
}

class _Request implements HttpClientRequest {
  _Request(this.inner, this.observation, this.change);
  final HttpClientRequest inner;
  final _Http observation;
  final bool change;
  @override
  HttpHeaders get headers => inner.headers;
  @override
  bool get followRedirects => inner.followRedirects;
  @override
  set followRedirects(bool value) => inner.followRedirects = value;
  @override
  void write(Object? value) => inner.write(value);
  @override
  void abort([Object? error, StackTrace? stack]) => inner.abort(error, stack);
  @override
  Future<HttpClientResponse> close() async {
    final response = await inner.close();
    if (change && observation.loseNextChange && response.statusCode == 200) {
      observation.loseNextChange = false;
      observation.lostReplies++;
      await response.drain<void>();
      throw const SocketException('Synthetic lost file reply after NAS commit');
    }
    return response;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Unexpected HTTP request operation');
}

class _Picker implements InformationFilePicker {
  String? path;
  @override
  Future<String?> choose() async => path;
  @override
  Future<String?> saveAs(String name) async => null;
}

// Only the native panel is supplied a controlled path. Staging, publication,
// verification, durable outcomes and cleanup use the production Windows code.
class _Output extends NativeBackupFilePicker {
  String? path;
  int panels = 0;
  @override
  Future<String?> ownerFileOutput(String name) async {
    panels++;
    return path;
  }
}

/// Explicit opt-in against the existing NAS. Only this named development
/// attachment is created/changed. Original records, credentials and old file
/// versions are preserved. Neither connection secrets nor NAS contents print.
void main() {
  const profileDirectory = String.fromEnvironment(
    'CHIYO_NAS_PROFILE_DIRECTORY',
  );
  const name = 'Windows 知予附件说明';
  const firstBody =
      'Windows 知予附件说明\n'
      '附件保存在现有 NAS。替换产生新版本，历史原文继续保留。\n'
      '另存成功后，本机文件由主人保管；系统打开使用可回收的受管副本。\n';
  const secondBody =
      '$firstBody'
      '恢复旧版本会建立新的当前版本，不覆盖历史原文。\n';

  test(
    'existing NAS: Windows file versions, immediate projection, durable saving and managed copies',
    () async {
      final observation = _Http();
      await HttpOverrides.runWithHttpOverrides(() async {
        final previousPlatform = debugDefaultTargetPlatformOverride;
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        final root = await Directory.systemTemp.createTemp('chiyo-nas-files-');
        final picker = _Picker();
        final output = _Output();
        final dispatcher = SyntheticOpenDispatcher();
        RemoteWorkspaceSource? source;
        final profile = (await PrivateConnectionProfileStore(
          profileDirectory,
        ).read())!;
        Future<void> connect() async {
          source = RemoteWorkspaceSource(
            await OwnerClient.connect(
              address: Uri.parse(profile.address),
              token: profile.token,
              expectedServerId: profile.serverId,
              trust: SecurityContext(withTrustedRoots: false)
                ..setTrustedCertificatesBytes(utf8.encode(profile.certificate)),
            ),
            filePicker: picker,
            deviceFilesDirectory: '${root.path}/device',
            outputPicker: output,
            openDispatcher: dispatcher,
          );
          // No health timer: a successful mutation itself must refresh the
          // initialized projection, rather than relying on later polling.
          await source!.cache.synchronize();
        }

        Matcher fails(String code) => throwsA(
          isA<WorkspaceFailure>().having((e) => e.code, 'code', code),
        );
        try {
          await connect();
          final before = await source!.client.information();
          final original = File('${root.path}/windows-guide.txt');
          await original.writeAsString(firstBody, flush: true);
          picker.path = original.path;
          final matches = (await source!.queryRecords(
            const WorkspaceQuery(keyword: name),
          )).items.where((e) => e.name == name).toList();
          expect(matches.length <= 1, true);
          late final WorkspaceRecordRef ref;
          if (matches.isEmpty) {
            final selected = (await source!.files.pick())!;
            final operation = workspaceFileOperationId();
            try {
              ref = await source!.importFile(
                WorkspaceFileImport(
                  operationId: operation,
                  selectionId: selected.selectionId,
                  name: name,
                  description: 'Windows 开发版附件与历史版本使用说明。',
                ),
              );
            } catch (_) {
              // Reconcile only the original operation; never replay a write
              // after an uncertain transport result.
              final receipt = await source!.fileOperationReceipt(operation);
              if (receipt == null) rethrow;
              ref = receipt.record;
            }
            expect(
              (await source!.queryRecords(
                const WorkspaceQuery(keyword: name),
              )).items.any((e) => e.ref == ref),
              true,
            );
          } else {
            ref = matches.single.ref;
          }
          var history = await source!.loadFileHistory(ref, 'file');
          final oldVersion = history.current.ref.version;
          final old = await source!.files.original(ref, 'file', oldVersion);
          final oldBody = utf8.decode(old.bytes);
          expect(oldBody == firstBody || oldBody == secondBody, true);
          final replacement = File('${root.path}/windows-guide-revised.txt');
          final revised = oldBody == firstBody ? secondBody : firstBody;
          await replacement.writeAsString(revised, flush: true);
          picker.path = replacement.path;
          final selected = (await source!.files.pick())!;
          final replaceOperation = workspaceFileOperationId();
          WorkspaceFileRef changed;
          try {
            changed = await source!.changeFile(
              WorkspaceFileChange(
                operationId: replaceOperation,
                record: ref,
                fieldKey: 'file',
                expectedRecordVersion: history.recordVersion,
                expectedFileVersion: oldVersion,
                kind: WorkspaceFileChangeKind.replace,
                selectionId: selected.selectionId,
              ),
            );
          } catch (_) {
            final receipt = await source!.fileOperationReceipt(
              replaceOperation,
            );
            if (receipt?.file == null) rethrow;
            changed = receipt!.file!;
          }
          expect(
            WorkspaceFileRef.fromJson(
              (await source!.readDetail(ref)).values['file'],
            ),
            changed,
          );
          expect((await source!.readFilePreview(ref, 'file')).text, revised);
          final prior = await source!.files.original(ref, 'file', oldVersion);
          expect(prior.bytes, old.bytes);
          expect(prior.sha256, old.sha256);
          history = await source!.loadFileHistory(ref, 'file');
          final restoreOperation = workspaceFileOperationId();
          final beforeRestore = observation.changes;
          observation.loseNextChange = true;
          WorkspaceFileRef restored;
          try {
            restored = await source!.changeFile(
              WorkspaceFileChange(
                operationId: restoreOperation,
                record: ref,
                fieldKey: 'file',
                expectedRecordVersion: history.recordVersion,
                expectedFileVersion: changed.version,
                kind: WorkspaceFileChangeKind.restore,
                restoreVersion: oldVersion,
              ),
            );
          } catch (_) {
            final receipt = await source!.fileOperationReceipt(
              restoreOperation,
            );
            if (receipt?.file == null) rethrow;
            restored = receipt!.file!;
          }
          expect(observation.lostReplies, 1);
          expect(observation.changes, beforeRestore + 1);
          expect(restored.version > changed.version, true);
          expect(
            (await source!.readDetail(ref)).values['file'],
            restored.toJson(),
          );
          expect(
            (await source!.files.original(ref, 'file', null)).bytes,
            old.bytes,
          );
          expect(
            (await source!.files.original(ref, 'file', changed.version)).bytes,
            utf8.encode(revised),
          );
          expect(
            (await source!.fileOperationReceipt(restoreOperation))!.file,
            restored,
          );

          final destination = File('${root.path}/主人另存.txt');
          output.path = destination.path;
          final saveOperation = workspaceFileOperationId();
          expect(
            (await source!.fileAction(
              ref,
              'file',
              restored.version,
              WorkspaceFileAction.saveAs,
              operationId: saveOperation,
            )).completed,
            true,
          );
          expect(await destination.readAsBytes(), old.bytes);
          expect(
            (await source!.fileActionState(ref, 'file')).cleanupPending,
            0,
          );
          final panels = output.panels;
          await source!.dispose();
          source = null;
          await connect();
          await destination.writeAsString('主人另存后修改，不得覆盖。', flush: true);
          expect(
            (await source!.fileOperationReceipt(
              saveOperation,
            ))!.actionCompleted,
            true,
          );
          expect(
            (await source!.fileAction(
              ref,
              'file',
              restored.version,
              WorkspaceFileAction.saveAs,
              operationId: saveOperation,
            )).completed,
            true,
          );
          expect(output.panels, panels);
          await expectLater(
            source!.fileAction(
              ref,
              'file',
              restored.version,
              WorkspaceFileAction.saveAs,
              operationId: workspaceFileOperationId(),
            ),
            fails('not_saved'),
          );
          expect(await destination.readAsString(), '主人另存后修改，不得覆盖。');

          final openOperation = workspaceFileOperationId();
          dispatcher.drop = true;
          expect(
            (await source!.fileAction(
              ref,
              'file',
              restored.version,
              WorkspaceFileAction.open,
              operationId: openOperation,
            )).completed,
            true,
          );
          expect(dispatcher.launches, 1);
          expect(
            await File(dispatcher.leases.single.filePath).readAsBytes(),
            old.bytes,
          );
          expect(
            (await source!.fileOperationReceipt(
              openOperation,
            ))!.actionCompleted,
            true,
          );
          expect(dispatcher.launches, 1);
          await source!.closeOpenFileCopies(ref, 'file');
          expect((await source!.fileActionState(ref, 'file')).openCopies, 0);
          expect(await File(dispatcher.leases.single.filePath).exists(), false);
          expect(await destination.readAsString(), '主人另存后修改，不得覆盖。');

          // Only our explicitly named development item may have changed.
          final after = await source!.client.information();
          final versions = {for (final e in after) e.id: e.version};
          expect(
            before
                .where((e) => e.id != ref.id)
                .every((e) => versions[e.id] == e.version),
            true,
          );
        } finally {
          await source?.dispose();
          debugDefaultTargetPlatformOverride = previousPlatform;
          await root.delete(recursive: true);
        }
      }, observation);
    },
    skip: profileDirectory.isEmpty ? 'Explicit NAS profile required' : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
