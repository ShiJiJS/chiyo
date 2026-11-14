import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:info_cli/private_device_state.dart';
import 'package:info_remote/owner_client.dart';
import 'package:info_workspace/history_transport.dart'
    show historyEnvelope, historyText;
import 'package:info_workspace/runtime_transport.dart';
import 'package:info_workspace/server_runtime_observation.dart';
import '../online_desktop_runtime.dart';
import 'workspace_source.dart';

/// Current App actions plus clearly scoped server reports. Never signals a
/// reported PID, reads another device's path, ends chats or stops the server.
class RemoteWorkspaceRuntime implements WorkspaceRuntimeSource {
  RemoteWorkspaceRuntime(
    this.client,
    this.desktop, {
    required this.directory,
    required this.copies,
    required this.preferences,
    required this.changed,
  });
  final OwnerClient client;
  final OnlineDesktopRuntime desktop;
  final String? directory;
  final Future<List<WorkspaceOwnerCopyMaintenance>> Function({bool maintain})
  copies;
  final Future<WorkspacePreferences> Function() preferences;
  final void Function() changed;
  final _instance = workspaceOperationId();
  final _plans = <String, (WorkspaceQuitPreview, String)>{};
  final _results = <String, WorkspaceRuntimeReceipt>{};
  final _unsubmitted =
      <String, (WorkspaceRuntimeChange, WorkspaceQuitPreview?)>{};
  static final _queues = <String, Future<void>>{};
  int _version = 1;
  String? _signature;
  WorkspaceRuntimeStatus? _last;
  WorkspaceServerRuntimeObservation? _remote;
  Directory? _folder;
  final _pending = <Future<void>>{};
  bool _releasing = false, _dispatchingQuit = false;
  Future<void> release() async {
    _releasing = true;
    // Only a runtime command already holding this journal may bypass its own
    // completion. A native/window quit must still drain status/receipt reads.
    if (!_dispatchingQuit) await Future.wait(_pending.toList());
  }

  WorkspaceRuntimePhase get _phase => desktop.shutdownFailed
      ? desktop.resourcesClosed
            ? WorkspaceRuntimePhase.terminationFailed
            : WorkspaceRuntimePhase.saveFailed
      : desktop.closed
      ? WorkspaceRuntimePhase.stopped
      : WorkspaceRuntimePhase.running;
  Future<T> _locked<T>(Future<T> Function() action) {
    // Register ownership before directory setup's first await, too. Closing
    // must not miss an accepted read that has not acquired its file lock yet.
    final done = Completer<void>();
    _pending.add(done.future);
    return _withLock(action).whenComplete(() {
      _pending.remove(done.future);
      done.complete();
    });
  }

  Future<T> _withLock<T>(Future<T> Function() action) async {
    if (directory == null) {
      throw const WorkspaceFailure('unavailable', '本机运行记录目录未就绪。');
    }
    final folder = await privateDeviceDirectory(
      Directory(
        '$directory/runtime/${sha256.convert(utf8.encode(client.serverId))}',
      ),
    );
    _folder = folder;
    final key = folder.path;
    final next = (_queues[key] ?? Future<void>.value()).then((_) async {
      final file = File('$key/runtime.lock');
      await privateDeviceFile(file);
      final lock = await file.open(mode: FileMode.append);
      try {
        await lock.lock(FileLock.exclusive);
        return await action();
      } finally {
        await lock.close();
      }
    });
    final settled = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _queues[key] = settled;
    try {
      return await next;
    } on WorkspaceFailure {
      rethrow;
    } on RemoteFailure catch (e) {
      throw WorkspaceFailure(e.code, '无法读取服务器运行状态，请检查连接后重试。');
    } on Object {
      throw const WorkspaceFailure(
        'unknown_outcome',
        '本机运行操作记录无法核对，请保留原记录后重试。',
      );
    } finally {
      if (identical(_queues[key], settled)) _queues.remove(key);
    }
  }

  File _file(String id) {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(id)) {
      throw const WorkspaceFailure('validation', '运行操作编号无效。');
    }
    return File('${_folder!.path}/${sha256.convert(utf8.encode(id))}.json');
  }

  Future<Map<String, dynamic>?> _record(String id) async {
    final raw = await readPrivateDeviceState(_file(id));
    if (raw == null) return null;
    final r = historyEnvelope(raw, [
      'serverId',
      'instance',
      'change',
      'quit',
      'state',
      'result',
    ]);
    final c = runtimeChangeFromJson(r['change']);
    historyText(r['instance']);
    if (r['serverId'] != client.serverId ||
        c.operationId != id ||
        !const ['pending', 'done', 'not_submitted'].contains(r['state'])) {
      throw const FormatException();
    }
    final quit = r['quit'] == null ? null : quitPreviewFromJson(r['quit']);
    if ((c.action == WorkspaceRuntimeAction.quit) != (quit != null) ||
        quit != null &&
            (quit.token != c.quitToken || quit.version != c.expectedVersion)) {
      throw const FormatException();
    }
    if (r['state'] == 'done') {
      final receipt = runtimeReceiptFromJson(r['result']);
      if (!receipt.matches(c) ||
          jsonEncode(receipt.quitScope?.counts) != jsonEncode(quit?.counts)) {
        throw const FormatException();
      }
    } else if (r['result'] != null) {
      throw const FormatException();
    }
    return r;
  }

  Future<void> _write(
    WorkspaceRuntimeChange c,
    WorkspaceQuitPreview? quit,
    String state, {
    WorkspaceRuntimeReceipt? result,
  }) => writePrivateDeviceState(_file(c.operationId), {
    'wireVersion': 1,
    'serverId': client.serverId,
    'instance': _instance,
    'change': runtimeChangeToJson(c),
    'quit': quit == null ? null : quitPreviewToJson(quit),
    'state': state,
    'result': result == null ? null : runtimeReceiptToJson(result),
  });
  Future<WorkspaceRuntimeStatus> _observe() async {
    if (_releasing ||
        desktop.resourcesClosed ||
        desktop.quitting && desktop.shutdownFailed) {
      if (_last == null) {
        throw const WorkspaceFailure('unavailable', '当前App的连接已关闭。');
      }
      final signature = jsonEncode([
        'app-exit',
        _phase.name,
        desktop.windowHidden,
        desktop.resourcesClosed,
      ]);
      if (signature != _signature) _version++;
      _signature = signature;
      return _last = WorkspaceRuntimeStatus(
        version: _version,
        phase: _phase,
        serviceAvailable: false,
        menuBarAvailable: desktop.availability.tray,
        windowHidden: desktop.windowHidden,
        materials: _last!.materials,
        programs: _last!.programs,
        unconfirmedProcesses: _last!.unconfirmedProcesses,
        copies: _last!.copies,
        ownerCopies: _last!.ownerCopies,
        independentServer: true,
        serviceReason: '当前App连接已关闭。服务器和CLI未被此App停止；列表是退出前的观察。',
      );
    }
    desktop.preferences = await preferences();
    if (_releasing) return _observe();
    final remote = serverRuntimeFromJson(
      await client.request('GET', '/v1/owner/runtime'),
    );
    if (_releasing) return _observe();
    final local = await copies(maintain: false);
    if (_releasing) return _observe();
    final signature = jsonEncode([
      remote.revision,
      _phase.name,
      desktop.windowHidden,
      desktop.availability.tray,
      desktop.availability.notifications.name,
      local.map((c) => c.json).toList(),
    ]);
    if (_signature != null && signature != _signature) _version++;
    _signature = signature;
    _remote = remote;
    return _last = WorkspaceRuntimeStatus(
      version: _version,
      phase: _phase,
      serviceAvailable: true,
      menuBarAvailable: desktop.availability.tray,
      windowHidden: desktop.windowHidden,
      materials: remote.materials,
      programs: remote.programs,
      unconfirmedProcesses: remote.unconfirmedProcesses,
      copies: remote.copies,
      ownerCopies: local,
      independentServer: true,
      serviceReason: '资料服务器已连接。任务状态由运行任务的电脑提供；此App的临时文件在本机管理。',
    );
  }

  @override
  Future<WorkspaceRuntimeStatus> status() =>
      _releasing ? _observe() : _locked(_observe);
  @override
  Future<WorkspaceQuitPreview> previewQuit() => _locked(() async {
    final s = await _observe();
    if (s.closed) throw const WorkspaceFailure('unavailable', '当前App已关闭连接。');
    final p = WorkspaceQuitPreview(
      token: workspaceOperationId(),
      version: s.version,
      sessions: _remote!.sessions,
      grants: _remote!.grants,
      pendingRequests: _remote!.pendingRequests,
      materials: s.pendingMaterialKeys.length,
      copies: s.copies
          .where((c) => c.state != WorkspaceCopyState.released)
          .length,
      ownerCopies: s.ownerCopies.length,
      unconfirmedProcesses: _remote!.unconfirmedProcesses,
    );
    _plans.clear();
    _plans[p.token] = (p, _signature!);
    return p;
  });
  @override
  Future<void> releaseQuit(String token) async {
    _plans.remove(token);
  }

  Future<WorkspaceRuntimeReceipt?> _receipt(String id) async {
    final r = await _record(id);
    if (r == null) {
      if (_unsubmitted[id] case final original?) {
        await _write(original.$1, original.$2, 'not_submitted');
        _unsubmitted.remove(id);
        return null;
      }
      throw const WorkspaceFailure(
        'unknown_outcome',
        '找不到足以确认原结果的运行记录，不能推测原操作未执行。',
      );
    }
    if (r['state'] == 'done') return runtimeReceiptFromJson(r['result']);
    if (r['state'] == 'not_submitted') return null;
    if (_results[id] case final known?) {
      final c = runtimeChangeFromJson(r['change']);
      await _write(
        c,
        r['quit'] == null ? null : quitPreviewFromJson(r['quit']),
        'done',
        result: known,
      );
      return known;
    }
    if (_unsubmitted[id] case final original?) {
      if (r['instance'] != _instance ||
          runtimeChangeFromJson(r['change']).digest != original.$1.digest) {
        throw const FormatException();
      }
      await _write(original.$1, original.$2, 'not_submitted');
      _unsubmitted.remove(id);
      return null;
    }
    // Pending records from an older App lifetime remain unknown. Reopening is
    // a new window lifetime, not proof the earlier native action completed.
    throw const WorkspaceFailure(
      'unknown_outcome',
      '原运行操作结果仍无法确认；不会重复窗口操作、清理或退出。',
    );
  }

  @override
  Future<WorkspaceRuntimeReceipt?> receipt(String id) =>
      _locked(() => _receipt(id));
  @override
  Future<WorkspaceRuntimeReceipt> change(WorkspaceRuntimeChange change) =>
      _locked(() async {
        final c = runtimeChangeFromJson(runtimeChangeToJson(change));
        final old = await _record(c.operationId);
        if (old != null) {
          if (runtimeChangeFromJson(old['change']).digest != c.digest) {
            throw const WorkspaceFailure('operation_conflict', '原操作不能更改内容。');
          }
          final receipt = await _receipt(c.operationId);
          if (receipt != null) return receipt;
          throw const WorkspaceFailure('not_submitted', '原操作已确认未执行，请明确发起新操作。');
        }
        if (desktop.quitting && !desktop.shutdownFailed) {
          throw const WorkspaceFailure('busy', 'App正在退出，请等待原操作。');
        }
        final before = await _observe();
        if (before.version != c.expectedVersion) {
          throw const WorkspaceFailure('conflict', '运行状态已变化，请重新读取。');
        }
        WorkspaceQuitPreview? quit;
        if (c.action == WorkspaceRuntimeAction.quit) {
          final p = _plans[c.quitToken];
          if (p == null ||
              p.$1.version != c.expectedVersion ||
              p.$2 != _signature) {
            throw const WorkspaceFailure('quit_changed', '退出范围已变化，请重新核对。');
          }
          quit = p.$1;
        } else if (c.action == WorkspaceRuntimeAction.finishExit) {
          if (!desktop.shutdownFailed || !desktop.resourcesClosed) {
            throw const WorkspaceFailure('conflict', '当前无需重试系统退出。');
          }
        } else if (before.phase != WorkspaceRuntimePhase.running) {
          throw const WorkspaceFailure('unavailable', '当前App已进入退出流程。');
        }
        _unsubmitted[c.operationId] = (c, quit);
        await _write(c, quit, 'pending');
        _unsubmitted.remove(c.operationId);
        var checked = 0, released = 0, retained = 0;
        try {
          switch (c.action) {
            case WorkspaceRuntimeAction.checkMaterials:
              checked = before.maintenanceCount;
            case WorkspaceRuntimeAction.checkAttachments:
              checked = before.ownerCopies.length;
              final remaining = await copies(maintain: true);
              retained = before.ownerCopies
                  .where((e) => remaining.any((r) => r.id == e.id))
                  .length;
              released = checked - retained;
            case WorkspaceRuntimeAction.hideWindow:
              if (!await desktop.hideWindow()) {
                await _write(c, quit, 'not_submitted');
                throw const WorkspaceFailure(
                  'menu_bar_unavailable',
                  '关闭方式或菜单状态已变化，窗口保持可见。',
                );
              }
            case WorkspaceRuntimeAction.showWindow:
              await desktop.showWindow();
            case WorkspaceRuntimeAction.quit:
            case WorkspaceRuntimeAction.finishExit:
              // A native quit may have begun during observation/publication.
              // Let that quit drain this operation instead of awaiting it back.
              if (desktop.quitting && !desktop.shutdownFailed) {
                throw const WorkspaceFailure('busy', 'App正在退出，请等待原操作。');
              }
              _dispatchingQuit = true;
              try {
                await desktop.quit();
              } finally {
                _dispatchingQuit = false;
              }
          }
          final after = await _observe();
          if (c.action == WorkspaceRuntimeAction.checkMaterials) {
            retained = before.pendingMaterialKeys
                .intersection(after.pendingMaterialKeys)
                .length;
          }
          if (_version <= c.expectedVersion) _version = c.expectedVersion + 1;
          final result = WorkspaceRuntimeReceipt(
            operationId: c.operationId,
            commandDigest: c.digest,
            action: c.action,
            expectedVersion: c.expectedVersion,
            version: _version,
            phase: after.phase,
            windowHidden: after.windowHidden,
            checked: checked,
            released: released,
            retained: retained,
            quitScope: quit,
          );
          if (!result.matches(c)) {
            throw const FormatException('Invalid native result');
          }
          _results[c.operationId] = result;
          await _write(c, quit, 'done', result: result);
          changed();
          return result;
        } on WorkspaceFailure catch (e) {
          if (e.code == 'menu_bar_unavailable') rethrow;
          throw const WorkspaceFailure('unknown_outcome', '运行操作结果待核对，请不要重复提交。');
        } on Object {
          throw const WorkspaceFailure('unknown_outcome', '运行操作结果待核对，请不要重复提交。');
        }
      });
}
