import 'dart:async';
import 'package:flutter/foundation.dart';
import 'workspace_source.dart';

enum WorkspaceSettingsSection {
  appearance('外观', '明亮与黑暗主题'),
  notifications('通知', '访问申请提醒'),
  plugins('插件', '资料模板与专属设置');

  const WorkspaceSettingsSection(this.label, this.description);
  final String label, description;
}

class WorkspaceSettingsController extends ChangeNotifier {
  WorkspaceSettingsController(
    this.source,
    Stream<WorkspaceRecordRef?> changes, {
    required this.onTheme,
  }) {
    _subscription = changes.listen((_) {
      if (!frozen) unawaited(load());
    });
  }
  final WorkspaceSettingsSource source;
  final void Function(WorkspaceTheme) onTheme;
  late final StreamSubscription<WorkspaceRecordRef?> _subscription;
  WorkspaceSettingsSection section = WorkspaceSettingsSection.appearance;
  WorkspacePreferences? value, draft;
  WorkspaceFailure? readFailure, writeFailure;
  String? notice;
  bool loading = false, busy = false, _closed = false;
  int _generation = 0;
  WorkspaceSettingsChange? _command;
  final positions = <WorkspaceSettingsSection, double>{};
  bool get uncertain => writeFailure?.code == 'unknown_outcome';
  bool get frozen => busy || uncertain;
  bool get dirty =>
      draft != null && value != null && !draft!.sameValues(value!);
  bool get conflicted =>
      writeFailure?.code == 'conflict' ||
      draft != null && value != null && draft!.version != value!.version;
  bool get canSave =>
      !frozen && !loading && readFailure == null && dirty && !conflicted;
  void _notify() {
    if (!_closed) notifyListeners();
  }

  void select(WorkspaceSettingsSection target) {
    if (_closed || frozen) return;
    section = target;
    _notify();
  }

  Future<void> load() async {
    if (_closed || frozen) return;
    final generation = ++_generation;
    loading = true;
    readFailure = null;
    _notify();
    try {
      final result = await source.read();
      if (_closed || generation != _generation || frozen) return;
      final keep = dirty;
      value = result;
      if (!keep) draft = result;
      onTheme(result.theme);
    } catch (error) {
      if (!_closed && generation == _generation) {
        readFailure = error is WorkspaceFailure
            ? error
            : const WorkspaceFailure('unavailable', '暂时无法读取设置，请重试。');
      }
    } finally {
      if (!_closed && generation == _generation) {
        loading = false;
        _notify();
      }
    }
  }

  void stage(WorkspacePreferences desired) {
    if (_closed || frozen || value == null || loading || readFailure != null) {
      return;
    }
    draft = desired;
    notice = null;
    if (!conflicted) writeFailure = null;
    _notify();
  }

  Future<void> setTheme(WorkspaceTheme theme) async {
    if (draft == null) return;
    stage(draft!.copyWith(theme: theme));
    await save();
  }

  Future<void> setNotifications(bool enabled) async {
    if (draft == null) return;
    stage(draft!.copyWith(notifications: enabled));
    await save();
  }

  void discard() {
    if (_closed || frozen) return;
    draft = value;
    writeFailure = null;
    notice = '已按当前保存的设置重新核对。';
    _notify();
  }

  WorkspaceSettingsReceipt _check(WorkspaceSettingsReceipt r) {
    final c = _command!;
    if (r.operationId != c.operationId ||
        r.expectedVersion != c.expectedVersion ||
        r.commandDigest != c.digest ||
        r.preferences.version <= c.expectedVersion ||
        !r.preferences.sameValues(c.desired)) {
      throw const WorkspaceFailure('unknown_outcome', '设置回执与原操作不符，请继续核对。');
    }
    return r;
  }

  Future<void> _finished(WorkspaceSettingsReceipt r) async {
    _command = null;
    busy = false;
    writeFailure = null;
    value = draft = r.preferences;
    notice = '设置已保存。';
    onTheme(r.preferences.theme);
    _notify();
    await load();
  }

  Future<void> save() async {
    if (!canSave || _closed) return;
    _command = WorkspaceSettingsChange(
      operationId: workspaceOperationId(),
      expectedVersion: draft!.version,
      desired: draft!,
    );
    busy = true;
    _generation++;
    loading = false;
    writeFailure = null;
    notice = null;
    _notify();
    try {
      final receipt = await source.change(_command!);
      if (!_closed) await _finished(_check(receipt));
    } catch (error) {
      if (!_closed) {
        busy = false;
        writeFailure = error is WorkspaceFailure
            ? error
            : const WorkspaceFailure('unknown_outcome', '保存结果无法确认，请先核对原操作。');
        if (!uncertain) _command = null;
        _notify();
      }
    }
  }

  Future<void> reconcile() async {
    if (_closed || !uncertain || busy || _command == null) return;
    busy = true;
    _notify();
    try {
      final result = await source.receipt(_command!.operationId);
      if (_closed) return;
      if (result == null) {
        busy = false;
        _command = null;
        writeFailure = const WorkspaceFailure(
          'not_submitted',
          '原操作已确认未提交。选择保留，明确保存才会再次提交。',
        );
        _notify();
      } else {
        await _finished(_check(result));
      }
    } catch (_) {
      if (!_closed) {
        busy = false;
        writeFailure = const WorkspaceFailure(
          'unknown_outcome',
          '仍无法确认原设置操作，请继续核对。',
        );
        _notify();
      }
    }
  }

  @override
  void dispose() {
    _closed = true;
    _generation++;
    _subscription.cancel();
    super.dispose();
  }
}
