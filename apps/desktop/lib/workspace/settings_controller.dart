import 'dart:async';
import 'package:flutter/foundation.dart';
import 'workspace_source.dart';

enum WorkspaceSettingsSection {
  appearance('外观', '明亮与黑暗主题'),
  notifications('通知', '访问申请提醒'),
  records('请求与记录', '等待时间与记录保留'),
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
  WorkspaceFailure? retentionFailure;
  WorkspaceRetentionPreview? retentionPreview;
  bool _retentionConfirmed = false;
  bool _preparingRetention = false;
  int _retentionGeneration = 0;
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
      canPrepareSave && (!needsRetentionReview || _retentionConfirmed);
  bool get canPrepareSave =>
      !frozen && !loading && readFailure == null && dirty && !conflicted;
  bool get needsRetentionReview =>
      draft != null &&
      value != null &&
      draft!.retentionDays < value!.retentionDays;
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
    retentionPreview = null;
    retentionFailure = null;
    _retentionConfirmed = false;
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
    retentionPreview = null;
    retentionFailure = null;
    _retentionConfirmed = false;
    notice = '已按当前保存的设置重新核对。';
    _notify();
  }

  Future<void> prepareRetention() async {
    if (_closed || !canPrepareSave || !needsRetentionReview) return;
    busy = true;
    _preparingRetention = true;
    final generation = ++_retentionGeneration;
    _generation++;
    retentionPreview = null;
    retentionFailure = null;
    _retentionConfirmed = false;
    _notify();
    try {
      final p = await source.previewRetention(draft!.retentionDays);
      if (!_closed && generation == _retentionGeneration) {
        if (p.days != draft!.retentionDays ||
            p.token.isEmpty ||
            [
              p.requests,
              p.grants,
              p.operations,
              p.preserved,
            ].any((n) => n < 0)) {
          throw const WorkspaceFailure('invalid_preview', '清理范围无法确认，请重试。');
        }
        retentionPreview = p;
      }
    } catch (error) {
      if (!_closed && generation == _retentionGeneration) {
        retentionFailure = error is WorkspaceFailure
            ? error
            : const WorkspaceFailure('unavailable', '暂时无法读取清理范围，请重试。');
      }
    } finally {
      if (!_closed && generation == _retentionGeneration) {
        busy = false;
        _preparingRetention = false;
        _notify();
      }
    }
  }

  void confirmRetention(WorkspaceRetentionPreview preview) {
    if (_closed || frozen || !identical(preview, retentionPreview)) return;
    _retentionConfirmed = true;
    _notify();
  }

  void cancelRetention() {
    if (_closed || busy && !_preparingRetention) return;
    _retentionGeneration++;
    if (_preparingRetention) busy = false;
    _preparingRetention = false;
    retentionPreview = null;
    _retentionConfirmed = false;
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
    retentionPreview = null;
    _retentionConfirmed = false;
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
      retentionToken: needsRetentionReview ? retentionPreview?.token : null,
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
        if (!uncertain) {
          _command = null;
          // A failed attempt must not silently reuse an earlier cleanup review.
          retentionPreview = null;
          _retentionConfirmed = false;
        }
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
        retentionPreview = null;
        _retentionConfirmed = false;
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
