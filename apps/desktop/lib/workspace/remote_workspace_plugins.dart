import 'dart:convert';
import 'package:info_remote/owner_client.dart';
import 'package:info_workspace/plugin_transport.dart';
import '../information_files.dart';
import 'owner_plugin_picker.dart';
import 'owner_workspace_plugins.dart';
import 'workspace_source.dart';

/// Selection stays on this device; the server owns installed definitions and
/// persistent mutation receipts. The existing plugin UI consumes this seam.
class RemoteWorkspacePlugins implements WorkspacePluginSource {
  RemoteWorkspacePlugins(
    this.client, {
    required this.changed,
    this.picker = const NativeTemplatePackagePicker(),
  });
  final OwnerClient client;
  final void Function() changed;
  final InformationFilePicker picker;

  Future<T> _run<T>(
    Future<T> Function() action, {
    bool mutation = false,
  }) async {
    try {
      return await action();
    } on RemoteFailure catch (e) {
      if (const {
        'conflict',
        'already_installed',
        'package_version_conflict',
        'definition_identity_conflict',
        'builtin_package',
        'invalid_package',
        'selection_changed',
        'selection_busy',
        'validation',
        'operation_conflict',
        'library_changed',
        'not_found',
        'invalid_request',
        'unauthorized',
        'server_changed',
      }.contains(e.code)) {
        throw WorkspaceFailure(e.code, switch (e.code) {
          'conflict' => '插件目录已变化，请重新预览。',
          'already_installed' => '同一版本与内容已经安装。',
          'package_version_conflict' => '同一版本的内容不同，不能覆盖。',
          'definition_identity_conflict' => '字段形态变化须使用新的字段身份。',
          'builtin_package' => '内置包可以停用，不能移除。',
          'selection_changed' => '原插件预览已失效，请重新选择。',
          'unauthorized' => '连接身份无效，请重新连接。',
          'server_changed' || 'library_changed' => '服务器或资料库已变化，请重新连接。',
          _ => '插件操作未完成，请核对插件格式和原操作。',
        });
      }
      throw WorkspaceFailure(
        mutation ? 'unknown_outcome' : 'unavailable',
        mutation ? '插件操作结果尚未确认，请先核对原操作。' : '暂时无法读取服务器插件，请重试。',
      );
    } on FormatException {
      throw WorkspaceFailure(
        mutation ? 'unknown_outcome' : 'unsupported',
        '服务器插件格式不受支持，请更新应用后重试。',
      );
    } on TypeError {
      throw WorkspaceFailure(
        mutation ? 'unknown_outcome' : 'unsupported',
        '服务器插件格式不受支持，请更新应用后重试。',
      );
    } on ArgumentError {
      throw WorkspaceFailure(
        mutation ? 'unknown_outcome' : 'unsupported',
        '服务器插件格式不受支持，请更新应用后重试。',
      );
    }
  }

  Future<WorkspacePluginCandidate?> pick() async {
    final input = await readTemplatePackage(picker);
    if (input == null) return null;
    return stage(input.filename, input.bytes);
  }

  Future<WorkspacePluginCandidate> stage(String filename, List<int> bytes) =>
      _run(() async {
        final value = await client.request('POST', '/v1/owner/plugins/stage', {
          'filename': filename,
          'bytes': base64Encode(bytes),
        });
        return WorkspacePluginCandidate(
          value['selectionId'] as String,
          value['filename'] as String,
          value['byteLength'] as int,
        );
      });

  @override
  Future<WorkspacePluginCatalog> load() => _run(
    () async =>
        pluginCatalogFromJson(await client.request('GET', '/v1/owner/plugins')),
  );

  @override
  Future<WorkspacePluginPreview> previewInstall(String selectionId) => _run(
    () async => pluginPreviewFromJson(
      await client.request(
        'GET',
        '/v1/owner/plugins/previews/${Uri.encodeComponent(selectionId)}',
      ),
    ),
  );

  @override
  Future<void> releaseCandidate(String selectionId) => _run(() async {
    await client.request(
      'DELETE',
      '/v1/owner/plugins/selections/${Uri.encodeComponent(selectionId)}',
    );
  });

  @override
  Future<WorkspacePluginCandidate> prepareUpdate(
    WorkspacePluginUpdate update,
    int catalogVersion,
  ) async => throw const WorkspaceFailure(
    'not_found',
    '当前服务器没有提供该内置更新；外部更新请重新选择插件文件。',
  );

  @override
  Future<WorkspacePluginReceipt> change(WorkspacePluginChange change) =>
      _run(() async {
        final receipt = pluginReceiptFromJson(
          await client.request(
            'POST',
            '/v1/owner/plugins/changes',
            pluginChangeToJson(change),
          ),
        );
        changed();
        return receipt;
      }, mutation: true);

  @override
  Future<WorkspacePluginReceipt?> receipt(String operationId) => _run(() async {
    try {
      return pluginReceiptFromJson(
        await client.request(
          'GET',
          '/v1/owner/plugins/operations/${Uri.encodeComponent(operationId)}',
        ),
      );
    } on RemoteFailure catch (e) {
      if (e.code == 'operation_not_found') return null;
      rethrow;
    }
  });
}
