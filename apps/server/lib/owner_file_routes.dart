import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_workspace/file_transport.dart';
import 'package:info_workspace/form_transport.dart';
import 'package:info_workspace/owner_workspace_form_save.dart';
import 'package:info_workspace/workspace_information_codec.dart';
import 'package:info_workspace/owner_workspace_legacy_templates.dart';
import 'package:info_workspace/owner_file_stages.dart';
import 'package:info_workspace/owner_workspace_file_changes.dart';
import 'package:info_workspace/owner_workspace_file_reads.dart';
import 'package:info_workspace/workspace_source.dart';
import 'package:info_workspace/workspace_transport.dart';
import 'owner_library.dart';

/// Owner-only transport handles. Bytes stay in the existing encrypted staging
/// transaction; no local client path or server filesystem path is a wire value.
final class OwnerFileRoutes {
  OwnerFileRoutes(this.library, {Duration Function()? elapsed})
    : stages = OwnerWorkspaceFileStages(library.owner),
      reads = OwnerWorkspaceFileReads(library.owner, library),
      _elapsed = elapsed ?? _monotonicClock() {
    changes = OwnerWorkspaceFileChanges(library.owner, library, stages, (_) {});
  }
  final OnlineOwnerLibrary library;
  final OwnerWorkspaceFileStages stages;
  final OwnerWorkspaceFileReads reads;
  late final OwnerWorkspaceFileChanges changes;
  late final legacy = OwnerWorkspaceLegacyTemplates(
    library.owner,
    library.plugins,
  );
  static const stagingLifetime = Duration(minutes: 30);
  static Duration Function() _monotonicClock() {
    final watch = Stopwatch()..start();
    return () => watch.elapsed;
  }

  final Duration Function() _elapsed;
  final _uploads =
      <
        String,
        ({String digest, WorkspaceFileCandidate candidate, Duration until})
      >{};
  final _cancelled = <String, Duration>{};
  Future<void> dispose() => stages.dispose();

  bool get needsCleanup {
    final now = _elapsed();
    return _uploads.values.any((v) => v.until <= now) ||
        _cancelled.values.any((until) => until <= now);
  }

  /// Transport staging has the same 30 minute lifetime as Agent uploads. This
  /// does not expire a saved file, proposal, operation receipt or access grant.
  /// Called in the host's serialized queue, including when the client vanished.
  Future<void> cleanup() async {
    final now = _elapsed();
    for (final entry in _uploads.entries.toList()) {
      if (entry.value.until > now) continue;
      await stages.release(entry.value.candidate.selectionId);
      _uploads.remove(entry.key);
    }
    _cancelled.removeWhere((_, until) => until <= now);
  }

  Future<void> _cancel(String op) async {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(op)) {
      throw const FormatException();
    }
    if (_cancelled.length >= 512 && !_cancelled.containsKey(op)) {
      throw const WorkspaceFailure('capacity', '待清理的文件上传记录较多，请稍后重试。');
    }
    _cancelled[op] = _elapsed() + stagingLifetime;
    final found = _uploads[op];
    if (found != null) await stages.release(found.candidate.selectionId);
  }

  Map<String, Object?> _uploaded(
    WorkspaceFileCandidate candidate,
    String digest,
  ) {
    // A released or committed selection never silently becomes a new stage.
    final selected = stages.selection(candidate.selectionId);
    return {
      'candidate': fileCandidateToJson(candidate),
      'sha256': selected.stage.sha256,
      'inputHash': digest,
    };
  }

  Future<Map<String, Object?>> upload(Map<String, dynamic> body) async {
    if (body.length != 4 ||
        body.keys.any(
          (k) => !const {
            'operationId',
            'originalName',
            'mediaType',
            'bytes',
          }.contains(k),
        ))
      throw const FormatException();
    final op = body['operationId'] as String,
        name = body['originalName'] as String,
        type = body['mediaType'] as String,
        encoded = body['bytes'] as String;
    if (_cancelled.containsKey(op)) {
      throw const WorkspaceFailure('selection_expired', '这次文件上传已取消，请重新选择。');
    }
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(op) ||
        encoded.length > ((core.informationFileByteLimit + 2) ~/ 3) * 4)
      throw const FormatException();
    final bytes = base64Decode(encoded);
    if (bytes.length > core.informationFileByteLimit)
      throw const FormatException();
    final digest = sha256
        .convert(
          utf8.encode(
            jsonEncode([name, type, sha256.convert(bytes).toString()]),
          ),
        )
        .toString();
    final prior = _uploads[op];
    if (prior != null) {
      if (prior.digest != digest)
        throw const WorkspaceFailure('operation_conflict', '原操作编号不能用于其他文件。');
      return _uploaded(prior.candidate, digest);
    }
    if (_uploads.length >= 512)
      throw const WorkspaceFailure('capacity', '待清理的文件上传记录较多，请稍后重试。');
    final selected = await stages.stage(
      (draft) => library.owner.stageInformationBytes(
        draft,
        originalName: name,
        mediaType: type,
        bytes: Uint8List.fromList(bytes),
      ),
    );
    _uploads[op] = (
      digest: digest,
      candidate: selected,
      until: _elapsed() + stagingLifetime,
    );
    return _uploaded(selected, digest);
  }

  Future<(int, Object)> dispatch(
    String method,
    List<String> path,
    Map<String, dynamic>? body,
  ) async {
    await cleanup();
    if (path.length == 4 &&
        path.last == 'legacy-templates' &&
        method == 'GET') {
      return (
        200,
        {'items': (await legacy.load()).map(legacyTemplateToJson).toList()},
      );
    }
    if (path.length == 5 && path[3] == 'legacy-templates' && method == 'GET') {
      return (200, legacyTemplateToJson(await legacy.read(path.last)));
    }
    if (path.length == 6 &&
        path[3] == 'legacy-templates' &&
        path.last == 'convert' &&
        method == 'POST') {
      if (body!.length != 1) throw const FormatException();
      final c = await legacy.prepareConversion(
        path[4],
        body['expectedVersion'] as int,
      );
      return (
        200,
        {
          'selectionId': c.selectionId,
          'filename': c.filename,
          'byteLength': c.byteLength,
        },
      );
    }
    if (path.length == 4 && path.last == 'release' && method == 'POST') {
      if (body!.length != 2) throw const FormatException();
      final selections = (body['selections'] as List).cast<String>(),
          uploads = (body['uploads'] as List).cast<String>();
      if (selections.length > 32 || uploads.length > 1) {
        throw const FormatException();
      }
      for (final op in uploads) {
        await _cancel(op);
      }
      for (final id in selections) {
        await stages.release(id);
      }
      return (200, {'status': 'released'});
    }
    if (path.length == 4 && path.last == 'forms' && method == 'POST') {
      final c = workspaceCreateFromJson(body!);
      final command = WorkspaceInformationCodec().createCommand(c);
      final prior = await library.owner.informationRecordReceipt(c.operationId);
      if (prior != null) {
        if (prior.command?.digest != command.digest ||
            prior.command?.typeId != command.typeId) {
          throw const WorkspaceFailure('operation_conflict', '原操作编号不能用于其他内容。');
        }
        return (200, prior.toJson());
      }
      final Map<String, Object?> definition;
      if (c.legacyTemplateId != null) {
        final template = await legacy.read(c.legacyTemplateId!);
        if (c.typeId != 'generic' ||
            template.version != c.expectedLegacyVersion) {
          throw const WorkspaceFailure('conflict', '旧版模板已变化，请重新打开表单。');
        }
        definition = template.definition;
      } else {
        final active = library.templates[c.typeId];
        if (c.expectedLegacyVersion != null ||
            active == null ||
            active['templateVersion'] != c.expectedTemplateVersion ||
            active['packageDigest'] != c.expectedTemplateDigest) {
          throw const WorkspaceFailure('conflict', '资料模板已变化，请重新打开表单。');
        }
        definition = active;
      }
      final receipt = await OwnerWorkspaceFormSave(
        library.owner,
        stages,
      ).create(c, definition);
      return (200, receipt.toJson());
    }
    if (path.length == 4 && path.last == 'uploads' && method == 'POST')
      return (200, await upload(body!));
    if (path.length == 5 && path[3] == 'uploads' && method == 'GET') {
      final found = _uploads[path.last];
      return found == null
          ? (404, {'error': 'operation_not_found'})
          : (200, _uploaded(found.candidate, found.digest));
    }
    if (path.length == 5 && path[3] == 'uploads' && method == 'DELETE') {
      await _cancel(path.last);
      return (200, {'status': 'cancelled'});
    }
    if (path.length == 5 && path[3] == 'selections' && method == 'DELETE') {
      await stages.release(path.last);
      return (200, {'status': 'released'});
    }
    if (path.length == 4 && path.last == 'import' && method == 'POST') {
      final c = fileImportFromJson(body!);
      final ref = await changes.importFile(c);
      return (
        200,
        {
          'record': recordRefToJson(ref),
          'receipt': fileReceiptToJson((await changes.receipt(c.operationId))!),
        },
      );
    }
    if (path.length == 4 && path.last == 'changes' && method == 'POST') {
      final c = fileChangeFromJson(body!);
      await changes.change(c);
      return (200, fileReceiptToJson((await changes.receipt(c.operationId))!));
    }
    if (path.length == 5 && path[3] == 'operations' && method == 'GET') {
      final result = await changes.receipt(path.last);
      return result == null
          ? (404, {'error': 'operation_not_found'})
          : (200, fileReceiptToJson(result));
    }
    if (path.length == 4 &&
        method == 'POST' &&
        const {'history', 'read'}.contains(path.last)) {
      if (body!.keys.any(
        (k) => !{
          'record',
          'fieldKey',
          if (path.last == 'read') 'version',
        }.contains(k),
      ))
        throw const FormatException();
      final record = recordRefFromJson(body['record']),
          key = body['fieldKey'] as String;
      if (path.last == 'history')
        return (200, fileHistoryToJson(await reads.history(record, key)));
      return (
        200,
        fileOriginalToJson(
          await reads.read(record, key, version: body['version'] as int?),
        ),
      );
    }
    return (404, {'error': 'not_found'});
  }
}
