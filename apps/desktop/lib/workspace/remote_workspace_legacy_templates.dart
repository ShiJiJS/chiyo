import 'package:info_remote/owner_client.dart';
import 'package:info_workspace/form_transport.dart';
import 'workspace_source.dart';

/// Existing legacy templates remain form aids, not new plugin file types.
class RemoteWorkspaceLegacyTemplates implements WorkspaceLegacyTemplateSource {
  RemoteWorkspaceLegacyTemplates(this.client);
  final OwnerClient client;
  Future<T> _read<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on RemoteFailure catch (e) {
      throw WorkspaceFailure(e.code, switch (e.code) {
        'not_found' => '旧版模板已不存在。',
        'conflict' => '旧版模板已变化，请重新读取。',
        _ => '暂时无法读取服务器模板，请重试。',
      });
    } on FormatException {
      throw const WorkspaceFailure('unsupported', '服务器模板格式不受支持，请更新应用后重试。');
    }
  }

  @override
  Future<List<WorkspaceLegacyTemplate>> load() => _read(
    () async => [
      for (final v
          in (await client.request(
                'GET',
                '/v1/owner/files/legacy-templates',
              ))['items']
              as List)
        legacyTemplateFromJson(v),
    ],
  );
  @override
  Future<WorkspaceLegacyTemplate> read(String id) => _read(
    () async => legacyTemplateFromJson(
      await client.request(
        'GET',
        '/v1/owner/files/legacy-templates/${Uri.encodeComponent(id)}',
      ),
    ),
  );
}
