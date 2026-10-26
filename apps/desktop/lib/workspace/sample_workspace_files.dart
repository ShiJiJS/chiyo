import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'workspace_files.dart';
import 'workspace_records.dart';

typedef WorkspaceAssetReader = Future<Uint8List> Function(String asset);

const sampleFileDefinition = <String, Object?>{
  'id': 'file',
  'name': '文件',
  'icon': 'file',
  'fields': [
    {'key': 'file', 'label': '文件', 'type': 'file'},
  ],
  'sections': [
    {
      'kind': 'fields',
      'title': '文件',
      'keys': ['file'],
    },
    {'kind': 'relations', 'title': '关联资料', 'key': 'related'},
  ],
  'relations': [
    {'key': 'related', 'label': '关联资料', 'targetTemplates': <String>[]},
  ],
};

class _FileEntry {
  const _FileEntry(this.ref, this.assetId, this.createdAt, [this.filename]);
  final WorkspaceFileRef ref;
  final String assetId;
  final DateTime createdAt;
  final String? filename;
}

/// Owns sample file facts and approved resource loading. No filesystem, OS
/// execution or production adapter import. Record transactions stay in source.
class SampleWorkspaceFiles {
  SampleWorkspaceFiles(this.readAsset);
  final WorkspaceAssetReader? readAsset;
  final _files = <String, List<_FileEntry>>{};
  final _initial = <String, List<_FileEntry>>{};
  final _owners = <String, WorkspaceRecordRef>{};
  final _initialOwners = <String, WorkspaceRecordRef>{};
  Future<Map<String, dynamic>>? _catalog;
  static const _prefix = 'assets/zhiyu_files/';
  final _aliases = <String, String>{};
  void aliasField(WorkspaceRecordRef ref, String key, String original) {
    _aliases['${ref.key}/$key'] = _aliases['${ref.key}/$original'] ?? original;
  }

  String _id(WorkspaceRecordRef ref, String key) =>
      'sample-attachment:${base64Url.encode(utf8.encode(jsonEncode([ref.kind.name, ref.id, _aliases['${ref.key}/$key'] ?? key]))).replaceAll('=', '')}';

  WorkspaceFileRef seed(
    WorkspaceRecordRef owner,
    String key,
    DateTime date,
    String filename, {
    bool twoVersions = false,
    String assetId = 'unknown',
  }) {
    final id = _id(owner, key);
    final entries = [
      if (twoVersions)
        _FileEntry(
          WorkspaceFileRef(id, 1),
          'pdf-v1',
          date.subtract(const Duration(days: 2)),
        ),
      _FileEntry(
        WorkspaceFileRef(id, twoVersions ? 2 : 1),
        assetId,
        date,
        filename,
      ),
    ];
    _files[id] = List.of(entries);
    _initial[id] = List.of(entries);
    _owners[id] = owner;
    _initialOwners[id] = owner;
    return entries.last.ref;
  }

  WorkspaceFileRef importFile(
    WorkspaceRecordRef owner,
    String key,
    String selectionId,
    DateTime date,
  ) {
    final ref = WorkspaceFileRef(_id(owner, key), 1);
    _files[ref.id] = [_FileEntry(ref, selectionId, date)];
    _owners[ref.id] = owner;
    return ref;
  }

  void reset() {
    _aliases.clear();
    _files
      ..clear()
      ..addAll({for (final e in _initial.entries) e.key: List.of(e.value)});
    _owners
      ..clear()
      ..addAll(_initialOwners);
  }

  void clear() {
    _aliases.clear();
    _files.clear();
    _initial.clear();
    _owners.clear();
    _initialOwners.clear();
  }

  void forget(WorkspaceRecordRef owner) {
    _files.removeWhere((key, _) => _owners[key] == owner);
    _owners.removeWhere((_, value) => value == owner);
  }

  Future<Uint8List> _load(String name, {String? expectedHash}) async {
    if (readAsset == null ||
        !RegExp(r'^[a-zA-Z0-9._-]+$').hasMatch(name) ||
        name.contains('..')) {
      throw const WorkspaceFailure('preview_unavailable', '文件预览服务不可用。');
    }
    try {
      final bytes = await readAsset!('$_prefix$name');
      if (bytes.length > 100 * 1024 * 1024 ||
          (expectedHash != null &&
              sha256.convert(bytes).toString() != expectedHash)) {
        throw const WorkspaceFailure('preview_unavailable', '文件内容校验失败，请重新读取。');
      }
      return bytes;
    } on WorkspaceFailure {
      rethrow;
    } catch (_) {
      throw const WorkspaceFailure('preview_unavailable', '文件内容暂时无法读取，请重试。');
    }
  }

  Future<Map<String, dynamic>> _manifest() => _catalog ??= () async {
    try {
      final value =
          jsonDecode(utf8.decode(await _load('manifest.json')))
              as Map<String, dynamic>;
      return {
        for (final file in value['files'] as List) file['id'] as String: file,
      };
    } catch (_) {
      _catalog = null;
      throw const WorkspaceFailure('preview_unavailable', '文件索引暂时无法读取，请重试。');
    }
  }();
  Future<WorkspaceFileCandidate> candidate(String selectionId) async {
    final row = (await _manifest())[selectionId] as Map<String, dynamic>?;
    if (row == null) {
      throw const WorkspaceFailure('not_found', '选择的文件已失效，请重新选择。');
    }
    return WorkspaceFileCandidate(
      selectionId,
      row['filename'] as String,
      row['mediaType'] as String,
      row['byteLength'] as int,
    );
  }

  Future<List<WorkspaceFileCandidate>> choices() async => [
    for (final key in (await _manifest()).keys) await candidate(key),
  ];
  Future<void> verifySelection(String selectionId) async {
    final row = (await _manifest())[selectionId] as Map<String, dynamic>?;
    if (row == null) throw const WorkspaceFailure('not_found', '选择的文件已失效。');
    final bytes = await _load(
      row['asset'] as String,
      expectedHash: row['sha256'] as String,
    );
    if (bytes.length != row['byteLength']) {
      throw const WorkspaceFailure('preview_unavailable', '文件大小校验失败。');
    }
  }

  Future<void> verifyVersion(
    WorkspaceDetail detail,
    String key,
    int version,
  ) async {
    final ref = WorkspaceFileRef.fromJson(detail.values[key]);
    await verifySelection(
      _entry(detail.record.ref, key, WorkspaceFileRef(ref.id, version)).assetId,
    );
  }

  _FileEntry _entry(
    WorkspaceRecordRef owner,
    String key,
    WorkspaceFileRef ref,
  ) {
    if (owner.kind != WorkspaceRecordKind.information ||
        ref.id != _id(owner, key)) {
      throw const WorkspaceFailure('not_found', '文件引用不属于当前资料。');
    }
    return _files[ref.id]
            ?.where((e) => e.ref.version == ref.version)
            .firstOrNull ??
        (throw const WorkspaceFailure('not_found', '文件版本已不可用。'));
  }

  Future<WorkspaceFileVersion> metadata(
    WorkspaceRecordRef owner,
    String key,
    WorkspaceFileRef ref,
  ) async {
    final e = _entry(owner, key, ref),
        c = await candidate(_entry(owner, key, ref).assetId);
    return WorkspaceFileVersion(
      ref: e.ref,
      filename: e.filename ?? c.filename,
      mediaType: c.mediaType,
      byteLength: c.byteLength,
      createdAt: e.createdAt,
    );
  }

  Future<WorkspaceFileHistory> history(
    WorkspaceDetail detail,
    String key,
  ) async {
    final current = WorkspaceFileRef.fromJson(detail.values[key]);
    _entry(detail.record.ref, key, current);
    return WorkspaceFileHistory(
      recordVersion: detail.version,
      current: await metadata(detail.record.ref, key, current),
      versions: [
        for (final e in _files[current.id]!.reversed)
          await metadata(detail.record.ref, key, e.ref),
      ],
    );
  }

  Future<WorkspaceFilePreview> preview(
    WorkspaceDetail detail,
    String key, {
    int? version,
    int page = 0,
  }) async {
    final current = WorkspaceFileRef.fromJson(detail.values[key]);
    final ref = WorkspaceFileRef(current.id, version ?? current.version);
    final row =
        (await _manifest())[_entry(detail.record.ref, key, ref).assetId]
            as Map<String, dynamic>;
    final file = await metadata(detail.record.ref, key, ref);
    if (page < 0) throw const WorkspaceFailure('invalid_request', '页码无效。');
    if (file.mediaType == 'application/octet-stream') {
      if (page != 0) throw const WorkspaceFailure('invalid_request', '页码无效。');
      return WorkspaceFilePreview(
        file: file,
        kind: WorkspaceFilePreviewKind.unsupported,
      );
    }
    final bytes = await _load(
      row['asset'] as String,
      expectedHash: row['sha256'] as String,
    );
    if (file.mediaType == 'text/plain') {
      if (page != 0) throw const WorkspaceFailure('invalid_request', '页码无效。');
      return WorkspaceFilePreview(
        file: file,
        kind: WorkspaceFilePreviewKind.text,
        text: utf8.decode(bytes),
      );
    }
    if (file.mediaType == 'image/png') {
      if (page != 0) throw const WorkspaceFailure('invalid_request', '页码无效。');
      return _imagePreview(file, bytes);
    }
    final pages = row['pages'] as List;
    if (page >= pages.length) {
      throw const WorkspaceFailure('invalid_request', '页码超出范围。');
    }
    final pixels = await _load(
      pages[page]['asset'] as String,
      expectedHash: pages[page]['sha256'] as String,
    );
    return _imagePreview(
      file,
      pixels,
      page: page,
      pageCount: pages.length,
      text: pages[page]['text'] as String? ?? '',
    );
  }

  WorkspaceFilePreview _imagePreview(
    WorkspaceFileVersion file,
    Uint8List pixels, {
    int page = 0,
    int pageCount = 1,
    String text = '',
  }) {
    if (pixels.length < 24 ||
        base64.encode(pixels.sublist(0, 8)) != 'iVBORw0KGgo=' ||
        ascii.decode(pixels.sublist(12, 16), allowInvalid: true) != 'IHDR') {
      throw const WorkspaceFailure('preview_unavailable', '预览图像格式无效。');
    }
    final header = ByteData.sublistView(pixels);
    final width = header.getUint32(16), height = header.getUint32(20);
    if (width < 1 || height < 1 || width > 16384 || height > 16384) {
      throw const WorkspaceFailure('preview_unavailable', '预览图像尺寸无效。');
    }
    return WorkspaceFilePreview(
      file: file,
      kind: WorkspaceFilePreviewKind.image,
      page: page,
      pageCount: pageCount,
      image: pixels,
      text: text,
      pixelWidth: width,
      pixelHeight: height,
    );
  }

  WorkspaceFileRef next(WorkspaceDetail detail, String key) {
    final current = WorkspaceFileRef.fromJson(detail.values[key]);
    _entry(detail.record.ref, key, current);
    return WorkspaceFileRef(
      current.id,
      _files[current.id]!.last.ref.version + 1,
    );
  }

  Future<void> validateChange(
    WorkspaceDetail detail,
    WorkspaceFileChange change,
  ) async {
    final current = WorkspaceFileRef.fromJson(detail.values[change.fieldKey]);
    _entry(detail.record.ref, change.fieldKey, current);
    if (current.version != change.expectedFileVersion ||
        detail.version != change.expectedRecordVersion) {
      throw const WorkspaceFailure('conflict', '资料或文件已更新，请重新读取并核对。');
    }
    if (change.kind == WorkspaceFileChangeKind.replace) {
      if (change.selectionId == null || change.restoreVersion != null) {
        throw const WorkspaceFailure('invalid_request', '请重新选择文件。');
      }
      await candidate(change.selectionId!);
      await verifySelection(change.selectionId!);
    } else {
      if (change.restoreVersion == null || change.selectionId != null) {
        throw const WorkspaceFailure('invalid_request', '请选择要恢复的文件版本。');
      }
      _entry(
        detail.record.ref,
        change.fieldKey,
        WorkspaceFileRef(current.id, change.restoreVersion!),
      );
    }
  }

  void commitChange(
    WorkspaceDetail detail,
    WorkspaceFileChange change,
    DateTime now,
  ) {
    final ref = next(detail, change.fieldKey);
    final original = change.kind == WorkspaceFileChangeKind.restore
        ? _entry(
            detail.record.ref,
            change.fieldKey,
            WorkspaceFileRef(ref.id, change.restoreVersion!),
          )
        : null;
    _files[ref.id]!.add(
      _FileEntry(
        ref,
        original?.assetId ?? change.selectionId!,
        now,
        original?.filename,
      ),
    );
  }

  Map<String, Object?> restoredValues(
    WorkspaceDetail old,
    WorkspaceDetail? current, {
    Map<String, Object?>? values,
  }) => {
    ...?values,
    if (values == null) ...old.values,
    for (final field in workspaceFields(old))
      if (field['type'] == 'file')
        field['key'] as String: _restoredRef(
          old,
          current,
          field['key'] as String,
        ).toJson(),
  };
  WorkspaceFileRef _restoredRef(
    WorkspaceDetail old,
    WorkspaceDetail? current,
    String key,
  ) {
    final oldRef = WorkspaceFileRef.fromJson(old.values[key]);
    _entry(old.record.ref, key, oldRef);
    if (current != null &&
        workspaceFields(current).any(
          (f) =>
              f['type'] == 'file' &&
              current.values[f['key']] is Map &&
              WorkspaceFileRef.fromJson(current.values[f['key']]) == oldRef,
        )) {
      return oldRef;
    }
    return WorkspaceFileRef(oldRef.id, _files[oldRef.id]!.last.ref.version + 1);
  }

  void commitRestore(
    WorkspaceDetail old,
    WorkspaceDetail restored,
    DateTime now,
  ) {
    final planned = <_FileEntry>[];
    for (final field in workspaceFields(old)) {
      if (field['type'] != 'file') continue;
      final key = field['key'] as String,
          target = WorkspaceFileRef.fromJson(restored.values[field['key']]);
      final original = _entry(
        old.record.ref,
        key,
        WorkspaceFileRef.fromJson(old.values[key]),
      );
      if (target == original.ref) continue;
      if (target.version != _files[target.id]!.last.ref.version + 1) {
        throw const WorkspaceFailure('conflict', '文件版本已更新，请重新读取。');
      }
      planned.add(_FileEntry(target, original.assetId, now, original.filename));
    }
    for (final entry in planned) {
      _files[entry.ref.id]!.add(entry);
    }
  }
}
