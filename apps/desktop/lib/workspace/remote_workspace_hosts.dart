import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:info_remote/owner_client.dart';
import 'package:info_workspace/host_transport.dart';
import '../information_files.dart';
import 'host_file_selection.dart';
import 'workspace_source.dart';

/// The original SSH trust UI uses owner-only metadata/receipts from the shared
/// projection. The selected file is read on this device, never at a server path.
class RemoteWorkspaceHosts implements WorkspaceHostSource {
  RemoteWorkspaceHosts(
    this.client, {
    required this.changed,
    this.picker = const NativeInformationFilePicker(),
  });
  final OwnerClient client;
  final void Function() changed;
  final InformationFilePicker picker;
  final _selections = <String, ({String name, int length, String digest})>{};
  bool _closed = false;
  void _check() {
    if (_closed) throw const WorkspaceFailure('unavailable', '主机记录窗口已关闭。');
  }

  Future<T> _run<T>(
    Future<T> Function() action, {
    bool mutation = false,
  }) async {
    _check();
    try {
      return await action();
    } on RemoteFailure catch (e) {
      if (const {
        'conflict',
        'scope_changed',
        'unavailable',
        'not_found',
        'selection_unavailable',
        'selection_expired',
        'selection_busy',
        'operation_conflict',
        'invalid_ssh_known_hosts',
        'invalid_request',
        'unauthorized',
        'server_changed',
        'library_changed',
      }.contains(e.code)) {
        throw WorkspaceFailure(e.code, switch (e.code) {
          'unauthorized' => '连接身份无效，请重新连接。',
          'server_changed' || 'library_changed' => '服务器或资料库已变化，请重新连接。',
          'conflict' ||
          'scope_changed' ||
          'operation_conflict' => '主机记录、文件或插件已变化，请重新核对原操作。',
          'invalid_ssh_known_hosts' || 'invalid_request' => '主机记录格式不受支持，请核对文件。',
          _ => '当前文件预览或主机操作已不可用，请重新打开。',
        });
      }
      throw WorkspaceFailure(
        mutation ? 'unknown_outcome' : 'unavailable',
        mutation ? '主机操作结果尚未确认，请先核对原操作。' : '暂时无法读取服务器主机记录，请重试。',
      );
    } on FormatException {
      throw WorkspaceFailure(
        mutation ? 'unknown_outcome' : 'unsupported',
        '服务器主机记录格式不受支持，请更新应用后重试。',
      );
    }
  }

  Future<WorkspaceHostFile?> pick() async {
    _check();
    final selected = await selectHostFile(picker);
    _check();
    return selected == null ? null : stage(selected.name, selected.bytes);
  }

  WorkspaceHostFile _uploaded(Map<String, dynamic> value) {
    if (value.length != 2 ||
        value['version'] != 1 ||
        !value.containsKey('file')) {
      throw const FormatException();
    }
    return hostFileFromJson(value['file']);
  }

  Future<WorkspaceHostFile> stage(
    String name,
    List<int> bytes,
  ) => _run(() async {
    final op = workspaceOperationId();
    final digest = sha256.convert(bytes).toString(), length = bytes.length;
    WorkspaceHostFile selected;
    try {
      selected = _uploaded(
        await client.request('POST', '/v1/owner/ssh-hosts/inputs', {
          'version': 1,
          'operationId': op,
          'name': name,
          'bytes': base64Encode(bytes),
        }),
      );
    } on RemoteFailure catch (e) {
      if (!const {
        'connection_closed',
        'server_timeout',
        'server_unavailable',
        'invalid_response',
        'response_too_large',
      }.contains(e.code)) {
        rethrow;
      }
      // Query exactly this upload, never create another selection on timeout.
      selected = _uploaded(
        await client.request('GET', '/v1/owner/ssh-hosts/inputs/$op'),
      );
    }
    if (_closed) {
      try {
        await client.request(
          'DELETE',
          '/v1/owner/ssh-hosts/selections/${Uri.encodeComponent(selected.selectionId)}',
        );
      } on Object {
        /* Server expiry releases a disconnected selection. */
      }
      _check();
    }
    if (selected.name != name || selected.byteLength != length) {
      throw const FormatException();
    }
    _selections[selected.selectionId] = (
      name: name,
      length: length,
      digest: digest,
    );
    return selected;
  }, mutation: true);

  Future<(List<WorkspaceHostIdentity>, WorkspaceHostImportStatus?)>
  _catalog() async {
    final j = await client.request('GET', '/v1/owner/ssh-hosts');
    if (j.length != 3 ||
        j['version'] != 1 ||
        j['hosts'] is! List ||
        !j.containsKey('imported')) {
      throw const FormatException();
    }
    return (
      (j['hosts'] as List).map(hostIdentityFromJson).toList(),
      j['imported'] == null ? null : hostImportStatusFromJson(j['imported']),
    );
  }

  @override
  Future<List<WorkspaceHostIdentity>> load() =>
      _run(() async => (await _catalog()).$1);
  @override
  Future<WorkspaceHostImportStatus?> importedFile() =>
      _run(() async => (await _catalog()).$2);
  @override
  Future<WorkspaceHostIdentity> read(WorkspaceHostTarget target) =>
      _run(() async {
        final j = await client.request('POST', '/v1/owner/ssh-hosts/read', {
          'version': 1,
          'target': hostTargetToJson(target),
        });
        if (j.length != 2 || j['version'] != 1 || !j.containsKey('host')) {
          throw const FormatException();
        }
        return hostIdentityFromJson(j['host']);
      });
  @override
  Future<WorkspaceHostImportPreview> previewImport(String selectionId) =>
      _run(() async {
        final j = await client.request(
          'GET',
          '/v1/owner/ssh-hosts/previews/${Uri.encodeComponent(selectionId)}',
        );
        if (j.length != 2 || j['version'] != 1 || !j.containsKey('preview')) {
          throw const FormatException();
        }
        final preview = hostImportPreviewFromJson(j['preview']);
        final selected = _selections[selectionId];
        if (selected == null ||
            preview.file.selectionId != selectionId ||
            preview.file.name != selected.name ||
            preview.file.byteLength != selected.length ||
            preview.digest != selected.digest) {
          throw const WorkspaceFailure('conflict', '服务器预览与这次选择的文件不符，请重新选择。');
        }
        return preview;
      });
  @override
  Future<void> releaseImport(String selectionId) => _run(() async {
    final j = await client.request(
      'DELETE',
      '/v1/owner/ssh-hosts/selections/${Uri.encodeComponent(selectionId)}',
    );
    if (j['status'] != 'released') throw const FormatException();
    _selections.remove(selectionId);
  });
  @override
  Future<WorkspaceHostImportReceipt> importFile(
    WorkspaceHostImportChange change,
  ) => _run(() async {
    final result = hostImportReceiptFromJson(
      await client.request(
        'POST',
        '/v1/owner/ssh-hosts/imports',
        hostImportChangeToJson(change),
      ),
    );
    if (!result.matches(change)) throw const FormatException();
    _selections.remove(change.preview.file.selectionId);
    changed();
    return result;
  }, mutation: true);
  @override
  Future<WorkspaceHostImportReceipt?> importReceipt(String id) => _run(
    () async {
      try {
        return hostImportReceiptFromJson(
          await client.request(
            'GET',
            '/v1/owner/ssh-hosts/import-operations/${Uri.encodeComponent(id)}',
          ),
        );
      } on RemoteFailure catch (e) {
        if (e.code == 'operation_not_found') return null;
        rethrow;
      }
    },
  );
  @override
  Future<WorkspaceHostReceipt> change(WorkspaceHostChange change) =>
      _run(() async {
        final result = hostReceiptFromJson(
          await client.request(
            'POST',
            '/v1/owner/ssh-hosts/changes',
            hostChangeToJson(change),
          ),
        );
        if (result.operationId != change.operationId ||
            result.action != change.action ||
            result.identityId != change.reviewed.identityId ||
            result.targetKey != change.reviewed.target.key ||
            result.expectedVersion != change.reviewed.version ||
            result.expectedPluginVersion != change.reviewed.pluginVersion ||
            result.expectedRecordVersion != change.reviewed.recordVersion) {
          throw const FormatException();
        }
        changed();
        return result;
      }, mutation: true);
  @override
  Future<WorkspaceHostReceipt?> receipt(String id) => _run(() async {
    try {
      return hostReceiptFromJson(
        await client.request(
          'GET',
          '/v1/owner/ssh-hosts/operations/${Uri.encodeComponent(id)}',
        ),
      );
    } on RemoteFailure catch (e) {
      if (e.code == 'operation_not_found') return null;
      rethrow;
    }
  });
  Future<void> dispose() async {
    _closed = true;
    for (final id in _selections.keys.toList()) {
      try {
        await client.request(
          'DELETE',
          '/v1/owner/ssh-hosts/selections/${Uri.encodeComponent(id)}',
        );
      } on Object {
        /* Bounded server staging expires when disconnected. */
      }
    }
    _selections.clear();
  }
}
