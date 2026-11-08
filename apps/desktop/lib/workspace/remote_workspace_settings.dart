import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:info_cli/private_device_state.dart';
import 'package:info_remote/owner_client.dart';
import 'package:info_workspace/history_transport.dart' show historyEnvelope;
import 'package:info_workspace/settings_transport.dart';
import 'workspace_source.dart';

class _Pending {
  _Pending(this.change, this.policy);
  final WorkspaceSettingsChange change;
  final WorkspaceServerPolicyChange? policy;
  Map<String, Object?> get json => {
    'wireVersion': 1,
    'change': settingsChangeToJson(change),
    'policy': policy?.json,
  };
  factory _Pending.decode(Object? raw) {
    final b = historyEnvelope(raw, ['change', 'policy']);
    final c = settingsChangeFromJson(b['change']);
    final p = b['policy'] == null
        ? null
        : WorkspaceServerPolicyChange.fromJson(b['policy']);
    if (p != null &&
        (p.operationId != c.operationId ||
            p.commandDigest != c.digest ||
            p.requestMinutes != c.desired.requestMinutes ||
            p.retentionDays != c.desired.retentionDays ||
            p.retentionToken != c.retentionToken)) {
      throw const FormatException('Invalid original settings');
    }
    return _Pending(c, p);
  }
}

class _State {
  _State(this.preferences, this.policy, [this.pending]);
  final WorkspacePreferences preferences;
  final WorkspaceServerPolicy policy;
  final _Pending? pending;
  Map<String, dynamic> encode(String server) => {
    'wireVersion': 1,
    'serverId': server,
    'preferences': preferencesToJson(preferences),
    'policy': policy.json,
    'pending': pending?.json,
  };
  factory _State.decode(Object? raw, String server) {
    final b = historyEnvelope(raw, [
      'serverId',
      'preferences',
      'policy',
      'pending',
    ]);
    final prefs = preferencesFromJson(b['preferences']);
    final p = WorkspaceServerPolicy.fromJson(b['policy']);
    final pending = b['pending'] == null ? null : _Pending.decode(b['pending']);
    if (b['serverId'] != server ||
        prefs.requestMinutes != p.requestMinutes ||
        prefs.retentionDays != p.retentionDays ||
        pending != null &&
            (pending.change.expectedVersion != prefs.version ||
                pending.policy != null &&
                    (pending.policy!.generation != p.generation ||
                        pending.policy!.expectedVersion != p.version))) {
      throw const FormatException('Invalid device settings');
    }
    return _State(prefs, p, pending);
  }
}

/// Device preferences and exact operation metadata only, using the existing
/// private atomic JSON writer. No information library, secrets or management
/// Token are stored here. All server changes use the original Owner policy API.
class RemoteWorkspaceSettings
    implements WorkspaceSettingsSource, WorkspaceSettingsRecovery {
  RemoteWorkspaceSettings(
    this.client, {
    required this.directory,
    required this.changed,
  });
  final OwnerClient client;
  final String? directory;
  final void Function() changed;
  static final _queues = <String, Future<void>>{};
  final _attempts = <String, _Pending>{};
  bool _closed = false;
  Future<void> _last = Future.value();
  Directory? _folder;
  Directory get _root => _folder!;
  File get _stateFile => File('${_root.path}/state.json');
  File get _identityFile => File('${_root.path}/identity.json');
  File _operation(String id) => File(
    '${_root.path}/operation-${sha256.convert(utf8.encode(policyOperationId(id)))}.json',
  );
  Future<T> _lock<T>(Future<T> Function() action) async {
    if (_closed || directory == null) {
      throw const WorkspaceFailure('settings_unavailable', '本机设置目录未就绪。');
    }
    final root = await privateDeviceDirectory(
      Directory(
        '$directory/settings/${sha256.convert(utf8.encode(client.serverId))}',
      ),
    );
    _folder = root;
    final key = root.path;
    final next = (_queues[key] ?? Future<void>.value()).then((_) async {
      if (_closed) {
        throw const WorkspaceFailure('settings_unavailable', '本机设置已关闭。');
      }
      final file = File('$key/settings.lock');
      await privateDeviceFile(file);
      final handle = await file.open(mode: FileMode.append);
      try {
        await handle.lock(FileLock.exclusive);
        return await action();
      } finally {
        await handle.close();
      }
    });
    final settled = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _queues[key] = _last = settled;
    try {
      return await next;
    } on WorkspaceFailure {
      rethrow;
    } on RemoteFailure catch (e) {
      throw _failure(e);
    } on Object {
      throw const WorkspaceFailure(
        'settings_unavailable',
        '本机设置记录无法核对，请保留原记录后重试。',
      );
    } finally {
      if (identical(_queues[key], settled)) _queues.remove(key);
    }
  }

  Future<void> dispose() async {
    _closed = true;
    await _last;
  }

  WorkspaceFailure _failure(RemoteFailure e) => switch (e.code) {
    'conflict' || 'operation_conflict' => const WorkspaceFailure(
      'conflict',
      '设置已变化，请重新读取后核对。',
    ),
    'retention_changed' || 'invalid_retention' => const WorkspaceFailure(
      'retention_changed',
      '清理范围已变化，请重新预览并确认。',
    ),
    'invalid_preferences' ||
    'invalid_request' => const WorkspaceFailure('validation', '设置内容无效，请核对选择。'),
    'library_changed' => const WorkspaceFailure(
      'library_changed',
      '资料库已替换，原设置操作不能继续，请重新读取。',
    ),
    'not_submitted' => const WorkspaceFailure(
      'not_submitted',
      '原操作已确认未提交，请明确发起新的保存。',
    ),
    'unauthorized' => const WorkspaceFailure(
      'unauthorized',
      '连接身份无效，请重新填写 Token。',
    ),
    _ => const WorkspaceFailure('unavailable', '无法连接服务器读取设置，请稍后重试。'),
  };
  Future<void> _put(File file, Map<String, dynamic> value) async {
    try {
      await writePrivateDeviceState(file, value);
    } on Object {
      throw const WorkspaceFailure('unknown_outcome', '本机设置保存结果需要核对，请勿重新提交。');
    }
  }

  Future<void> _write(_State s) => _put(_stateFile, s.encode(client.serverId));
  Future<WorkspaceServerPolicy> _currentPolicy() async =>
      WorkspaceServerPolicy.fromJson(
        await client.request('GET', '/v1/owner/settings'),
      );
  Future<_State> _load(WorkspaceServerPolicy current) async {
    final identity = await readPrivateDeviceState(_identityFile);
    if (identity != null &&
        (identity.length != 2 ||
            identity['format'] != 1 ||
            identity['serverId'] != client.serverId)) {
      throw const FormatException('Wrong settings binding');
    }
    final raw = await readPrivateDeviceState(_stateFile);
    if (raw == null) {
      if (identity != null) {
        throw const FormatException('Missing original settings');
      }
      final s = _State(
        WorkspacePreferences(
          requestMinutes: current.requestMinutes,
          retentionDays: current.retentionDays,
        ),
        current,
      );
      await _write(s);
      await _put(_identityFile, {'format': 1, 'serverId': client.serverId});
      return s;
    }
    final s = _State.decode(raw, client.serverId);
    if (identity == null) {
      await _put(_identityFile, {'format': 1, 'serverId': client.serverId});
    }
    return s;
  }

  Future<_State> _refresh(_State s, WorkspaceServerPolicy p) async {
    if (s.policy.generation != p.generation) {
      if (s.pending case final pending?) {
        final old = await _readRecord(pending.change.operationId);
        if (old?['status'] != 'not_submitted') {
          await _record(pending, 'library_changed', unpublished: true);
        }
      }
      final next = _State(
        s.preferences.copyWith(
          version: s.preferences.version + 1,
          requestMinutes: p.requestMinutes,
          retentionDays: p.retentionDays,
        ),
        p,
      );
      await _write(next);
      return next;
    }
    if (p.version < s.policy.version) {
      throw const WorkspaceFailure(
        'settings_unavailable',
        '服务器设置版本无法核对，请保留原记录后重试。',
      );
    }
    if (s.pending != null) return s;
    if (jsonEncode(s.policy.json) == jsonEncode(p.json)) return s;
    final next = _State(
      s.preferences.copyWith(
        version: s.preferences.version + 1,
        requestMinutes: p.requestMinutes,
        retentionDays: p.retentionDays,
      ),
      p,
    );
    await _write(next);
    return next;
  }

  @override
  Future<WorkspacePreferences> read() => _lock(() async {
    final p = await _currentPolicy();
    return (await _refresh(await _load(p), p)).preferences;
  });
  @override
  Future<WorkspaceSettingsChange?> pendingChange() => _lock(() async {
    final p = await _currentPolicy();
    return (await _refresh(await _load(p), p)).pending?.change;
  });

  Future<Map<String, dynamic>?> _readRecord(String id) async {
    final raw = await readPrivateDeviceState(_operation(id));
    if (raw == null) return null;
    final b = historyEnvelope(raw, [
      'serverId',
      'pending',
      'status',
      'receipt',
      'serverReceipt',
    ]);
    final pending = _Pending.decode(b['pending']);
    if (b['serverId'] != client.serverId ||
        pending.change.operationId != id ||
        !const [
          'ready',
          'not_submitted',
          'library_changed',
        ].contains(b['status'])) {
      throw const FormatException('Invalid settings operation');
    }
    if (b['status'] == 'ready') {
      final r = settingsReceiptFromJson(b['receipt']);
      final c = pending.change;
      if (r.operationId != id ||
          r.commandDigest != c.digest ||
          r.expectedVersion != c.expectedVersion ||
          !r.preferences.sameValues(c.desired)) {
        throw const FormatException('Wrong settings result');
      }
      if (pending.policy != null) {
        if (!WorkspaceServerPolicyReceipt.fromJson(
          b['serverReceipt'],
        ).matches(pending.policy!)) {
          throw const FormatException('Wrong policy result');
        }
      } else if (b['serverReceipt'] != null) {
        throw const FormatException('Unexpected policy result');
      }
    } else if (b['receipt'] != null || b['serverReceipt'] != null) {
      throw const FormatException('Unexpected settings result');
    }
    return b;
  }

  Future<void> _record(
    _Pending pending,
    String status, {
    WorkspaceServerPolicyReceipt? server,
    bool unpublished = false,
  }) async {
    final c = pending.change;
    final result = status == 'ready'
        ? WorkspaceSettingsReceipt(
            operationId: c.operationId,
            commandDigest: c.digest,
            expectedVersion: c.expectedVersion,
            preferences: c.desired.copyWith(version: c.expectedVersion + 1),
          )
        : null;
    final value = <String, dynamic>{
      'wireVersion': 1,
      'serverId': client.serverId,
      'pending': pending.json,
      'status': status,
      'receipt': result == null ? null : settingsReceiptToJson(result),
      'serverReceipt': server?.json,
    };
    final old = await _readRecord(c.operationId);
    if (old != null) {
      final original = _Pending.decode(old['pending']);
      if (original.change.digest != c.digest ||
          original.change.expectedVersion != c.expectedVersion) {
        throw const FormatException('Conflicting settings command');
      }
      if (jsonEncode(old) == jsonEncode(value)) return;
      if (!(unpublished &&
          status == 'library_changed' &&
          old['status'] == 'ready')) {
        throw const FormatException('Conflicting settings outcome');
      }
    }
    await _put(_operation(c.operationId), value);
  }

  Future<WorkspaceSettingsReceipt?> _finish(
    _State state,
    Map<String, dynamic> record,
  ) async {
    final pending = _Pending.decode(record['pending']);
    final c = pending.change;
    final matching = state.pending?.change.operationId == c.operationId;
    if (matching &&
        (state.pending!.change.digest != c.digest ||
            state.preferences.version != c.expectedVersion)) {
      throw const FormatException('Wrong pending settings');
    }
    if (record['status'] != 'ready') {
      if (matching) await _write(_State(state.preferences, state.policy));
      if (record['status'] == 'library_changed') {
        throw const WorkspaceFailure(
          'library_changed',
          '资料库已替换，原设置操作不能继续，请重新读取。',
        );
      }
      _attempts.remove(c.operationId);
      return null;
    }
    final receipt = settingsReceiptFromJson(record['receipt']);
    if (matching) {
      final policy = pending.policy == null
          ? state.policy
          : WorkspaceServerPolicyReceipt.fromJson(
              record['serverReceipt'],
            ).policy;
      await _write(_State(receipt.preferences, policy));
      changed();
    } else if (state.preferences.version <= c.expectedVersion) {
      throw const FormatException('Missing original publication');
    }
    _attempts.remove(c.operationId);
    return receipt;
  }

  Future<WorkspaceSettingsReceipt?> _reconcile(_State s, String id) async {
    final record = await _readRecord(id);
    if (record != null) return _finish(s, record);
    var pending = s.pending;
    if (pending == null) {
      pending = _attempts[id];
      if (pending == null ||
          s.preferences.version != pending.change.expectedVersion ||
          pending.policy != null &&
              (pending.policy!.generation != s.policy.generation ||
                  pending.policy!.expectedVersion != s.policy.version)) {
        throw const WorkspaceFailure(
          'unknown_outcome',
          '找不到足以确认原结果的设置记录，请保留现场后重试。',
        );
      }
      await _write(_State(s.preferences, s.policy, pending));
      s = _State(s.preferences, s.policy, pending);
    }
    if (pending.change.operationId != id) {
      throw const WorkspaceFailure('unknown_outcome', '另一份设置仍待核对，不能推测原操作没有保存。');
    }
    WorkspaceServerPolicyReceipt? server;
    if (pending.policy case final p?) {
      try {
        server = WorkspaceServerPolicyReceipt.fromJson(
          await client.request(
            'GET',
            '/v1/owner/settings/operations/${p.generation}/${p.operationId}',
          ),
        );
        if (!server.matches(p)) {
          throw const FormatException('Wrong original policy');
        }
      } on RemoteFailure catch (e) {
        if (e.code != 'operation_not_found') rethrow;
      }
    }
    await _record(
      pending,
      server == null ? 'not_submitted' : 'ready',
      server: server,
    );
    return _finish(s, (await _readRecord(id))!);
  }

  @override
  Future<WorkspaceSettingsReceipt?> receipt(String operationId) =>
      _lock(() async {
        final p = await _currentPolicy();
        final s = await _refresh(await _load(p), p);
        return _reconcile(s, policyOperationId(operationId));
      });
  @override
  Future<WorkspaceSettingsReceipt> change(
    WorkspaceSettingsChange change,
  ) => _lock(() async {
    // Strict round trip validates the local input before any durable action.
    final c = settingsChangeFromJson(settingsChangeToJson(change));
    final p = await _currentPolicy();
    final original = await _load(p);
    final s = await _refresh(original, p);
    final record = await _readRecord(c.operationId);
    if (record != null) {
      if (_Pending.decode(record['pending']).change.digest != c.digest) {
        throw const WorkspaceFailure('conflict', '原操作不能保存另一份设置。');
      }
      final r = await _finish(s, record);
      if (r != null) return r;
      throw const WorkspaceFailure('not_submitted', '原操作已确认未提交，请明确发起新的保存。');
    }
    if (s.pending != null) {
      throw const WorkspaceFailure('unknown_outcome', '还有原设置操作待核对，请勿重复保存。');
    }
    if (s.preferences.version != c.expectedVersion) {
      throw const WorkspaceFailure('conflict', '设置已变化，请重新读取后核对。');
    }
    final policyChanged =
        c.desired.requestMinutes != p.requestMinutes ||
        c.desired.retentionDays != p.retentionDays;
    if (!policyChanged && c.retentionToken != null) {
      throw const WorkspaceFailure('validation', '清理预览与本次设置不符，请重新核对。');
    }
    final pending = _Pending(
      c,
      policyChanged
          ? WorkspaceServerPolicyChange(
              operationId: c.operationId,
              commandDigest: c.digest,
              generation: p.generation,
              expectedVersion: p.version,
              requestMinutes: c.desired.requestMinutes,
              retentionDays: c.desired.retentionDays,
              retentionToken: c.retentionToken,
            )
          : null,
    );
    _attempts[c.operationId] = pending;
    await _write(_State(s.preferences, s.policy, pending));
    WorkspaceServerPolicyReceipt? server;
    if (pending.policy case final command?) {
      try {
        server = WorkspaceServerPolicyReceipt.fromJson(
          await client.request(
            'POST',
            '/v1/owner/settings/changes',
            command.json,
          ),
        );
        if (!server.matches(command)) {
          throw const FormatException('Wrong policy receipt');
        }
      } on RemoteFailure catch (e) {
        if (const [
          'conflict',
          'operation_conflict',
          'retention_changed',
          'invalid_retention',
          'invalid_preferences',
          'invalid_request',
          'unauthorized',
          'not_submitted',
        ].contains(e.code)) {
          await _record(pending, 'not_submitted');
          await _finish(
            _withPending(s, pending),
            (await _readRecord(c.operationId))!,
          );
          throw _failure(e);
        }
        throw const WorkspaceFailure(
          'unknown_outcome',
          '服务器设置保存结果需要核对，请勿重复提交。',
        );
      } on Object {
        throw const WorkspaceFailure(
          'unknown_outcome',
          '服务器设置保存结果需要核对，请勿重复提交。',
        );
      }
    }
    await _record(pending, 'ready', server: server);
    return (await _finish(
      _withPending(s, pending),
      (await _readRecord(c.operationId))!,
    ))!;
  });
  _State _withPending(_State s, _Pending p) =>
      _State(s.preferences, s.policy, p);
  @override
  Future<WorkspaceRetentionPreview> previewRetention(int days) => _lock(
    () async {
      final p = await _currentPolicy();
      final s = await _refresh(await _load(p), p);
      if (s.pending != null) {
        throw const WorkspaceFailure('unknown_outcome', '原设置操作待核对，暂不能重新确认清理。');
      }
      return retentionPreviewFromJson(
        await client.request('POST', '/v1/owner/settings/retention-preview', {
          'wireVersion': 1,
          'generation': p.generation,
          'days': days,
        }),
      );
    },
  );
  @override
  Future<WorkspaceNotificationPreview> notificationPreview() => _lock(() async {
    final b = historyEnvelope(
      await client.request('GET', '/v1/owner/settings/notification-preview'),
      ['requestId', 'title', 'description'],
    );
    if (b['requestId'] != null && b['requestId'] is! String ||
        b['title'] is! String ||
        b['description'] is! String) {
      throw const FormatException('Invalid notification metadata');
    }
    return WorkspaceNotificationPreview(
      requestId: b['requestId'] as String?,
      title: b['title'] as String,
      description: b['description'] as String,
    );
  });
}
