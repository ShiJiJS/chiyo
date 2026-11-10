import 'package:info_cli/agent_bundle.dart';
import 'package:info_remote/owner_client.dart';
import 'package:info_workspace/agent_sessions.dart';
import 'package:info_workspace/agent_sessions_transport.dart';
import 'workspace_agent_observations.dart';
import 'workspace_source.dart';

class RemoteWorkspaceAgents extends WorkspaceAgentObservations {
  RemoteWorkspaceAgents(
    OwnerClient client, {
    Future<AgentBundleObservation> Function({bool rehash})? readBundle,
  }) : super(
         readSessions: () => _read(client),
         readBundle: readBundle ?? AgentBundle().read,
         independentServer: true,
       );
  static Future<WorkspaceAgentSessions> _read(OwnerClient client) async {
    try {
      return agentSessionsFromJson(
        await client.request('GET', '/v1/owner/agent-sessions'),
      );
    } on RemoteFailure catch (e) {
      throw WorkspaceFailure(e.code, '无法连接资料服务器读取会话，请检查连接后重试。');
    } on FormatException {
      throw const WorkspaceFailure(
        'invalid_observation',
        '服务器返回的会话观察无法确认，请重新检测。',
      );
    }
  }
}
