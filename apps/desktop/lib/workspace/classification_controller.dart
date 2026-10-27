import 'dart:async';
import 'package:flutter/foundation.dart';
import 'workspace_source.dart';

class WorkspaceClassificationRow {
  const WorkspaceClassificationRow(this.id, this.name, this.path, this.count);
  final String id, name, path;
  final int count;
}

class ClassificationController extends ChangeNotifier {
  ClassificationController(this.source) {
    _changes = source.changes.listen((_) => unawaited(load()));
  }
  final WorkspaceSource source;
  late final StreamSubscription<WorkspaceRecordRef?> _changes;
  WorkspaceCatalog? catalog;
  WorkspaceFailure? failure;
  WorkspaceClassificationKind kind = WorkspaceClassificationKind.directory;
  String keyword = '', notice = '';
  int offset = 0, _generation = 0;
  double scrollOffset = 0;
  static const limit = 20;
  bool loading = false, _closed = false;
  String? _pendingReveal;
  Future<void>? _latestRead;
  List<WorkspaceClassificationRow> get allRows {
    final c = catalog;
    if (c == null) return [];
    String path(WorkspaceDirectory d) {
      final names = [d.name], visited = <String>{d.id};
      var parent = d.parentId;
      while (parent != null && visited.add(parent)) {
        final p = c.directories.where((x) => x.id == parent).firstOrNull;
        if (p == null) break;
        names.insert(0, p.name);
        parent = p.parentId;
      }
      return names.join(' / ');
    }

    final result = kind == WorkspaceClassificationKind.directory
        ? [
            for (final d in c.directories)
              if (!['all', 'unfiled'].contains(d.id))
                WorkspaceClassificationRow(
                  d.id,
                  d.name,
                  path(d),
                  c.directoryCounts[d.id] ?? 0,
                ),
          ]
        : [
            for (final t in c.tags)
              WorkspaceClassificationRow(
                t.id,
                t.name,
                t.name,
                c.tagCounts[t.id] ?? 0,
              ),
          ];
    result.sort((a, b) {
      final n = a.path.compareTo(b.path);
      return n != 0 ? n : a.id.compareTo(b.id);
    });
    return result;
  }

  List<WorkspaceClassificationRow> get filtered => allRows
      .where((r) => r.path.toLowerCase().contains(keyword.trim().toLowerCase()))
      .toList();
  List<WorkspaceClassificationRow> get rows =>
      filtered.skip(offset).take(limit).toList();
  int get total => filtered.length;
  void _notify() {
    if (!_closed) notifyListeners();
  }

  Future<void> load({String? reveal}) {
    if (_closed) return Future.value();
    if (reveal != null) _pendingReveal = reveal;
    final read = _read();
    _latestRead = read;
    return _settle(read);
  }

  Future<void> _settle(Future<void> read) async {
    await read;
    while (!_closed && _latestRead != read) {
      read = _latestRead!;
      await read;
    }
  }

  Future<void> _read() async {
    if (_closed) return;
    final generation = ++_generation;
    loading = true;
    failure = null;
    _notify();
    try {
      final next = await source.loadCatalog();
      if (_closed || generation != _generation) return;
      catalog = next;
      final reveal = _pendingReveal;
      if (reveal != null) {
        if (!filtered.any((r) => r.id == reveal) &&
            allRows.any((r) => r.id == reveal)) {
          keyword = '';
          notice = '已清除搜索以显示刚保存的分类。';
        }
        _pendingReveal = null;
        final index = filtered.indexWhere((r) => r.id == reveal);
        if (index >= 0) {
          offset = index ~/ limit * limit;
          scrollOffset = 0;
        }
      }
      offset = total == 0 ? 0 : offset.clamp(0, (total - 1) ~/ limit * limit);
    } catch (error) {
      if (!_closed && generation == _generation) {
        failure = error is WorkspaceFailure
            ? error
            : const WorkspaceFailure('unavailable', '暂时无法读取目录和标签，请重试。');
      }
    } finally {
      if (!_closed && generation == _generation) {
        loading = false;
        _notify();
      }
    }
  }

  void select(WorkspaceClassificationKind target) {
    _pendingReveal = null;
    scrollOffset = 0;
    kind = target;
    offset = 0;
    keyword = '';
    notice = '';
    _notify();
  }

  void search(String value) {
    _pendingReveal = null;
    scrollOffset = 0;
    keyword = value;
    offset = 0;
    notice = '';
    _notify();
  }

  void page(int next) {
    _pendingReveal = null;
    scrollOffset = 0;
    offset = total == 0 ? 0 : next.clamp(0, (total - 1) ~/ limit * limit);
    _notify();
  }

  @override
  void dispose() {
    _closed = true;
    _generation++;
    _changes.cancel();
    super.dispose();
  }
}

/// A shared directory/tag editor. The caller retains the modal (and root lock)
/// while a write is uncertain; only its exact original receipt can resolve it.
class ClassificationEditController extends ChangeNotifier {
  ClassificationEditController(
    this.source,
    this.catalog, {
    required this.kind,
    required this.action,
    this.targetId,
    String initialName = '',
    String? initialParent,
  }) : name = initialName,
       parent = initialParent;
  final WorkspaceSource source;
  WorkspaceCatalog catalog;
  final WorkspaceClassificationKind kind;
  final String action;
  final String? targetId;
  String name;
  String? parent;
  bool dirty = false, busy = false, reading = false, _closed = false;
  int _generation = 0;
  WorkspaceFailure? failure;
  WorkspaceTagRemovalPreview? removal;
  WorkspaceClassificationChange? _command;
  WorkspaceClassificationReceipt? receipt;
  bool get deleting => action == 'delete';
  bool get uncertain => failure?.code == 'unknown_outcome';
  bool get frozen => busy || uncertain;
  bool get tag => kind == WorkspaceClassificationKind.tag;
  bool get canSave =>
      receipt == null &&
      !frozen &&
      !reading &&
      (tag ||
          parent == null ||
          catalog.directories.any((d) => d.id == parent)) &&
      !{
        'conflict',
        'operation_conflict',
        'not_found',
      }.contains(failure?.code) &&
      (!tag || !deleting || removal != null);
  void _notify() {
    if (!_closed) notifyListeners();
  }

  void edit({String? name, String? parent, bool changeParent = false}) {
    if (frozen || receipt != null) return;
    if (name != null) this.name = name;
    if (changeParent) this.parent = parent;
    dirty = true;
    if (failure?.code != 'conflict') failure = null;
    _notify();
  }

  Future<void> readRemoval() async {
    if (_closed || frozen || reading || !tag || !deleting) return;
    final generation = ++_generation;
    reading = true;
    removal = null;
    failure = null;
    _notify();
    try {
      final p = await source.previewTagRemoval(targetId!);
      if (_closed || generation != _generation) return;
      if (p.tagId != targetId ||
          p.catalogVersion != catalog.version ||
          p.affectedCount < 0 ||
          p.token.isEmpty) {
        throw const WorkspaceFailure('conflict', '标签或影响范围已变化，请重新读取后核对。');
      }
      removal = p;
    } catch (error) {
      if (!_closed && generation == _generation) {
        failure = error is WorkspaceFailure
            ? error
            : const WorkspaceFailure('unavailable', '暂时无法读取标签影响范围。');
      }
    } finally {
      if (!_closed && generation == _generation) {
        reading = false;
        _notify();
      }
    }
  }

  Future<void> reload() async {
    if (_closed || frozen) return;
    final generation = ++_generation;
    reading = true;
    _notify();
    try {
      final c = await source.loadCatalog();
      if (_closed || generation != _generation) return;
      catalog = c;
      removal = null;
      if (targetId != null &&
          (tag
              ? !c.tags.any((t) => t.id == targetId)
              : !c.directories.any((d) => d.id == targetId))) {
        throw const WorkspaceFailure('not_found', '原分类已移除，不能操作同名的新分类。');
      }
      if (parent != null && !c.directories.any((d) => d.id == parent)) {
        failure = const WorkspaceFailure(
          'parent_unavailable',
          '原上级目录已移除，草稿保留，请明确选择新的上级目录。',
          fieldErrors: {'parent': '请选择现存目录或明确改为顶层目录。'},
        );
      } else {
        failure = const WorkspaceFailure('review', '已重新读取；草稿保留，请核对后再保存。');
      }
    } catch (error) {
      if (!_closed && generation == _generation) {
        failure = error is WorkspaceFailure
            ? error
            : const WorkspaceFailure('unavailable', '暂时无法重新读取分类。');
      }
    } finally {
      if (!_closed && generation == _generation) {
        reading = false;
        _notify();
      }
    }
    if (!_closed && tag && deleting && failure?.code == 'review') {
      await readRemoval();
    }
  }

  WorkspaceClassificationReceipt _check(WorkspaceClassificationReceipt r) {
    if (!r.matches(_command!)) {
      throw const WorkspaceFailure('unknown_outcome', '分类回执与原操作不符，请继续核对。');
    }
    return r;
  }

  Future<void> save() async {
    if (_closed || !canSave) return;
    _command = tag
        ? WorkspaceTagChange(
            operationId: workspaceOperationId(),
            expectedVersion: catalog.version,
            action: WorkspaceTagAction.values.byName(action),
            tagId: targetId,
            name: name,
            removalToken: removal?.token,
          )
        : WorkspaceDirectoryChange(
            operationId: workspaceOperationId(),
            expectedVersion: catalog.version,
            action: WorkspaceDirectoryAction.values.byName(action),
            directoryId: targetId,
            name: name,
            parentId: parent,
          );
    busy = true;
    failure = null;
    _notify();
    try {
      final r = await source.changeClassification(_command!);
      if (!_closed) {
        receipt = _check(r);
        dirty = false;
      }
    } catch (error) {
      if (!_closed) {
        failure = error is WorkspaceFailure
            ? error
            : const WorkspaceFailure('unknown_outcome', '分类保存结果无法确认，请核对原操作。');
        if (!uncertain) _command = null;
      }
    } finally {
      if (!_closed) {
        busy = false;
        _notify();
      }
    }
  }

  Future<void> reconcile() async {
    if (_closed || busy || !uncertain || _command == null) return;
    busy = true;
    _notify();
    try {
      final r = await source.classificationOperationReceipt(
        _command!.operationId,
      );
      if (_closed) return;
      if (r == null) {
        _command = null;
        failure = const WorkspaceFailure(
          'not_submitted',
          '原操作已确认未提交，草稿保留；明确保存才会再次提交。',
        );
      } else {
        receipt = _check(r);
        dirty = false;
        failure = null;
      }
    } catch (_) {
      if (!_closed) {
        failure = const WorkspaceFailure(
          'unknown_outcome',
          '仍无法确认原分类操作，请继续核对。',
        );
      }
    } finally {
      if (!_closed) {
        busy = false;
        _notify();
      }
    }
  }

  @override
  void dispose() {
    _closed = true;
    _generation++;
    super.dispose();
  }
}
