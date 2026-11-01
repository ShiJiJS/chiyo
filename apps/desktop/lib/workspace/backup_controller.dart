import 'dart:async';
import 'package:flutter/foundation.dart';
import 'workspace_source.dart';

enum WorkspaceBackupMode { export, restore }

class BackupController extends ChangeNotifier {
  BackupController(this.source, Stream<WorkspaceRecordRef?> changes) {
    _changes = changes.listen((_) {
      revealedKey = null;
      if (!frozen) unawaited(load());
    });
  }
  final WorkspaceBackupSource source;
  late final StreamSubscription<WorkspaceRecordRef?> _changes;
  WorkspaceBackupStatus? value;
  WorkspaceFailure? readFailure, failure;
  WorkspaceBackupPreview? preview;
  WorkspaceBackupResource? keyOutput, archiveOutput, archiveInput, keyInput;
  WorkspaceBackupReceipt? result;
  String? revealedKey, cleanupNotice;
  bool loading = false, busy = false, choosing = false, _closed = false;
  int _generation = 0;
  WorkspaceBackupChange? _command;
  WorkspaceBackupCounts? _expectedRestore;
  bool get uncertain => failure?.code == 'unknown_outcome';
  bool get frozen => busy || uncertain;
  bool get available =>
      !frozen && !loading && readFailure == null && value != null;
  bool get canInspect =>
      available &&
      value!.recipientEmpty &&
      archiveInput != null &&
      keyInput != null;
  bool get canRestore => available && preview != null && value!.recipientEmpty;
  void _notify() {
    if (!_closed) notifyListeners();
  }

  WorkspaceFailure _readError(Object e, String message) =>
      e is WorkspaceFailure && e.code != 'unknown_outcome'
      ? e
      : WorkspaceFailure('unavailable', message);
  Future<void> load() async {
    if (_closed || frozen) return;
    final generation = ++_generation;
    loading = true;
    readFailure = null;
    _notify();
    try {
      final next = await source.status();
      if (!_closed && generation == _generation && !frozen) {
        value = next;
        if (next.pending != null) {
          _command = next.pending!.command;
          _expectedRestore = next.pending!.restoreCounts;
          failure = const WorkspaceFailure(
            'unknown_outcome',
            '上次备份操作尚未确认，请核对原操作；不会自动重新执行。',
          );
        }
      }
    } catch (error) {
      if (!_closed && generation == _generation) {
        readFailure = _readError(error, '备份服务暂时不可用，请重试。');
      }
    } finally {
      if (!_closed && generation == _generation) {
        loading = false;
        _notify();
      }
    }
  }

  void begin() {
    if (frozen || _closed) return;
    failure = null;
    result = null;
    revealedKey = null;
    cleanupNotice = null;
    _notify();
  }

  Future<void> toggleKey() async {
    if (_closed || !available || !value!.keyCreated) return;
    if (revealedKey != null) {
      revealedKey = null;
      _notify();
      return;
    }
    busy = true;
    failure = null;
    _notify();
    try {
      final text = await source.revealRecoveryKey();
      if (!_closed) revealedKey = text;
    } catch (error) {
      if (!_closed) failure = _readError(error, '恢复密钥暂时不可读。');
    } finally {
      if (!_closed) {
        busy = false;
        _notify();
      }
    }
  }

  Future<void> _release() async {
    final token = preview?.token;
    preview = null;
    if (token != null) {
      try {
        await source.releasePreview(token);
      } catch (_) {
        cleanupNotice = '检查未提交恢复，临时资源仍待清理；可稍后重试清理。';
      }
    }
  }

  Future<void> pick(
    WorkspaceBackupPick kind,
    WorkspaceBackupPicker picker,
  ) async {
    if (_closed || !available) return;
    busy = true;
    choosing = true;
    failure = null;
    _generation++;
    loading = false;
    _notify();
    try {
      final selected = await picker(kind);
      if (_closed || selected == null) return;
      if (selected.kind != kind ||
          selected.id.isEmpty ||
          selected.version < 1 ||
          selected.name.isEmpty ||
          selected.name.length > 4000) {
        throw const WorkspaceFailure('invalid_selection', '文件选择无法确认，请重新选择。');
      }
      if (kind == WorkspaceBackupPick.archiveInput ||
          kind == WorkspaceBackupPick.keyInput) {
        await _release();
      }
      if (_closed) return;
      switch (kind) {
        case WorkspaceBackupPick.keyOutput:
          keyOutput = selected;
        case WorkspaceBackupPick.archiveOutput:
          archiveOutput = selected;
        case WorkspaceBackupPick.archiveInput:
          archiveInput = selected;
        case WorkspaceBackupPick.keyInput:
          keyInput = selected;
      }
      result = null;
    } catch (error) {
      if (!_closed) failure = _readError(error, '文件选择未完成，原选择保留。');
    } finally {
      if (!_closed) {
        busy = false;
        choosing = false;
        _notify();
        await load();
      }
    }
  }

  Future<void> inspect() async {
    if (_closed || !canInspect) return;
    busy = true;
    failure = null;
    result = null;
    revealedKey = null;
    _generation++;
    loading = false;
    _notify();
    try {
      await _release();
      final p = await source.inspect(archiveInput!, keyInput!);
      if (_closed) {
        await source.releasePreview(p.token);
        return;
      }
      if (p.token.isEmpty ||
          !p.archive.same(archiveInput!) ||
          !p.key.same(keyInput!) ||
          !p.counts.valid ||
          p.formatLabel.isEmpty) {
        await source.releasePreview(p.token);
        throw const WorkspaceFailure('invalid_preview', '备份检查结果与选择不符，请重新检查。');
      }
      preview = p;
    } catch (error) {
      if (!_closed) failure = _readError(error, '备份检查未完成，当前信息库未改变。');
    } finally {
      if (!_closed) {
        busy = false;
        _notify();
        await load();
      }
    }
  }

  WorkspaceBackupReceipt _check(WorkspaceBackupReceipt r) {
    if (!r.matches(_command!) ||
        _command!.action == WorkspaceBackupAction.restore &&
            (_expectedRestore == null ||
                r.counts == null ||
                !r.counts!.same(_expectedRestore!))) {
      throw const WorkspaceFailure('unknown_outcome', '回执与原备份操作不符，请继续核对原操作。');
    }
    return r;
  }

  Future<void> _finish(WorkspaceBackupReceipt r) async {
    result = r;
    _command = null;
    _expectedRestore = null;
    failure = null;
    busy = false;
    revealedKey = null;
    if (r.action == WorkspaceBackupAction.restore) preview = null;
    if (r.action == WorkspaceBackupAction.cleanup) cleanupNotice = null;
    if (r.action == WorkspaceBackupAction.saveKey) keyOutput = null;
    if (r.action == WorkspaceBackupAction.export) archiveOutput = null;
    _notify();
    await load();
  }

  Future<void> write(WorkspaceBackupAction action) async {
    if (_closed || !available) return;
    final status = value!;
    if (action == WorkspaceBackupAction.enableKey && status.keyCreated ||
        action == WorkspaceBackupAction.saveKey &&
            (!status.keyCreated || keyOutput == null) ||
        action == WorkspaceBackupAction.export &&
            (!status.keySaved || archiveOutput == null) ||
        action == WorkspaceBackupAction.restore && !canRestore ||
        action == WorkspaceBackupAction.cleanup && status.cleanupCount == 0) {
      return;
    }
    _command = WorkspaceBackupChange(
      operationId: workspaceOperationId(),
      action: action,
      expectedVersion: status.version,
      selection: switch (action) {
        WorkspaceBackupAction.saveKey => keyOutput,
        WorkspaceBackupAction.export => archiveOutput,
        WorkspaceBackupAction.restore => archiveInput,
        _ => null,
      },
      previewToken: action == WorkspaceBackupAction.restore
          ? preview!.token
          : null,
    );
    _expectedRestore = action == WorkspaceBackupAction.restore
        ? preview!.counts
        : null;
    busy = true;
    failure = null;
    result = null;
    revealedKey = null;
    _generation++;
    loading = false;
    _notify();
    try {
      final r = await source.change(_command!);
      if (!_closed) await _finish(_check(r));
    } catch (error) {
      if (!_closed) {
        busy = false;
        failure = error is WorkspaceFailure
            ? error
            : const WorkspaceFailure('unknown_outcome', '备份操作结果未知，请核对原操作。');
        if (!uncertain) {
          _command = null;
          _expectedRestore = null;
          if ({
            'backup_changed',
            'recipient_not_empty',
            'conflict',
          }.contains(failure?.code)) {
            await _release();
          }
        }
        _notify();
        if (!uncertain) await load();
      }
    }
  }

  Future<void> reconcile() async {
    if (_closed || !uncertain || busy || _command == null) return;
    busy = true;
    _notify();
    try {
      final r = await source.receipt(_command!.operationId);
      if (_closed) return;
      if (r == null) {
        _command = null;
        _expectedRestore = null;
        failure = const WorkspaceFailure(
          'not_submitted',
          '原操作已确认未提交；选择保留，明确提交才会再次操作。',
        );
        busy = false;
        _notify();
        await load();
      } else {
        await _finish(_check(r));
      }
    } catch (error) {
      if (!_closed) {
        busy = false;
        if (_command?.action == WorkspaceBackupAction.cleanup &&
            error is WorkspaceFailure &&
            error.code == 'cleanup_pending') {
          _command = null;
          _expectedRestore = null;
          failure = error;
          _notify();
          await load();
          return;
        }
        failure = const WorkspaceFailure(
          'unknown_outcome',
          '仍无法确认原备份操作，请继续核对。',
        );
        _notify();
      }
    }
  }

  Future<bool> closeFlow() async {
    if (_closed || frozen) return false;
    busy = true;
    _notify();
    await _release();
    if (_closed) return false;
    keyOutput = archiveOutput = archiveInput = keyInput = null;
    revealedKey = null;
    busy = false;
    _notify();
    await load();
    return true;
  }

  @override
  void dispose() {
    _closed = true;
    _generation++;
    revealedKey = null;
    _changes.cancel();
    super.dispose();
  }
}
