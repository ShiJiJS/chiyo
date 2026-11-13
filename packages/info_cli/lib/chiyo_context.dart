import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_remote/agent_connection.dart';
import 'package:info_remote/private_connection_files.dart';
import 'agent_client.dart';
import 'codex_association.dart';

class ChiyoContextMismatch extends FormatException {
  const ChiyoContextMismatch() : super('context_mismatch');
}

/// A caller-selected private context, not a global "last chat". Its connection
/// is immutable: a later App mode switch cannot move this chat's approvals.
class ChiyoContext {
  const ChiyoContext({
    required this.chatId,
    required this.agentName,
    required this.secret,
    required this.port,
    this.connection,
    this.endCapability,
  });
  final String chatId, agentName, secret;
  final int port;
  final AgentConnectionProfile? connection;
  final String? endCapability;

  static Future<ChiyoContext> load(
    File file, {
    Map<String, String>? environment,
  }) async {
    final env = environment ?? Platform.environment;
    if (!file.isAbsolute) throw const FormatException('context_unavailable');
    // Existing trusted Codex hooks can hand the same private reference to the
    // unified entry point. A public CODEX_THREAD_ID alone never discovers it.
    Map<String, dynamic>? data;
    try {
      data = await PrivateConnectionFiles.read(file);
    } on Object {
      // Legacy associations protected the parent rather than the file mode.
      // They remain loadable only through their original host-bound verifier.
    }
    if (data?['role'] != 'chiyo-chat' &&
        RegExp(r'[/\\][0-9a-f]{64}\.json$').hasMatch(file.path)) {
      final legacy = await CodexAssociation.load(
        file.path,
        env['CODEX_THREAD_ID'] ?? '',
      );
      return ChiyoContext(
        chatId: legacy.chatId,
        agentName: 'Codex',
        secret: legacy.secret,
        port: legacy.port,
        connection: legacy.connection,
      );
    }
    const allowed = {
      'version',
      'role',
      'chatId',
      'agentName',
      'secret',
      'connection',
      'endCapability',
    };
    if (data == null ||
        data.keys.any((k) => !allowed.contains(k)) ||
        data['version'] != 1 ||
        data['role'] != 'chiyo-chat' ||
        data['chatId'] is! String ||
        !validChatId(data['chatId'] as String) ||
        data['agentName'] is! String ||
        (data['agentName'] as String).trim().isEmpty ||
        (data['agentName'] as String).length > 200 ||
        data['secret'] is! String ||
        !RegExp(
          r'^[A-Za-z0-9_=-]{40,2000}$',
        ).hasMatch(data['secret'] as String) ||
        data['connection'] is! Map ||
        data['endCapability'] != null &&
            (data['endCapability'] is! String ||
                !RegExp(
                  r'^[A-Za-z0-9_=-]{40,2000}$',
                ).hasMatch(data['endCapability'] as String))) {
      throw const FormatException('context_unavailable');
    }
    final expected = env['CHIYO_CHAT_ID'] ?? env['CODEX_THREAD_ID'];
    if (expected != null && expected != data['chatId']) {
      throw const ChiyoContextMismatch();
    }
    final profile = AgentConnectionProfile.fromPrivateJson(
      Map<String, dynamic>.from(data['connection'] as Map),
    );
    return ChiyoContext(
      chatId: data['chatId'] as String,
      agentName: data['agentName'] as String,
      secret: data['secret'] as String,
      port: profile.address.port,
      connection: profile,
      endCapability: data['endCapability'] as String?,
    );
  }

  Future<void> saveNew(File target) async {
    if (!target.isAbsolute ||
        connection == null ||
        !validChatId(chatId) ||
        agentName.trim().isEmpty ||
        agentName.length > 200 ||
        await FileSystemEntity.type(target.path, followLinks: false) !=
            FileSystemEntityType.notFound) {
      throw const FormatException('context_store_unavailable');
    }
    // Never chmod an existing general-purpose directory on the user's behalf.
    final parentType = await FileSystemEntity.type(
      target.parent.path,
      followLinks: false,
    );
    if (parentType != FileSystemEntityType.notFound &&
            parentType != FileSystemEntityType.directory ||
        !Platform.isWindows &&
            parentType == FileSystemEntityType.directory &&
            (await target.parent.stat()).mode & 0xE3F != 0) {
      throw const FormatException('context_store_unavailable');
    }
    if (Platform.isWindows && parentType == FileSystemEntityType.directory) {
      // Verify without changing an existing directory's ACL. The shared writer
      // may adopt app-owned storage, but chat setup cannot adopt any user folder.
      WindowsPrivateFiles.verify(target.parent.path, directory: true);
    }
    await PrivateConnectionFiles.write(target, {
      'version': 1,
      'role': 'chiyo-chat',
      'chatId': chatId,
      'agentName': agentName,
      'secret': secret,
      'connection': connection!.toPrivateJson(),
      if (endCapability != null) 'endCapability': endCapability,
    }, replace: false);
  }

  AgentClient client({Directory? stateDirectory}) => connection == null
      ? AgentClient(
          port,
          sessionSecret: secret,
          sourceAgent: agentName,
          externalChatId: chatId,
          requireSubmissionMetadata: true,
          hostedCredentialExecutions: true,
        )
      : AgentClient.remote(
          connection!,
          sessionSecret: secret,
          sourceAgent: agentName,
          externalChatId: chatId,
          requireSubmissionMetadata: true,
          hostedCredentialExecutions: true,
          deviceFileStateDirectory: stateDirectory,
        );

  Map<String, Object?> get publicStatus => {
    'chatId': chatId,
    'agentName': agentName,
    'mode': connection?.isLocal == false ? 'server' : 'local',
    if (connection != null) 'libraryId': connection!.serverId,
    'approvalLocation': connection?.isLocal == false ? 'server' : 'local-app',
    'executionDevice': Platform.localHostname,
  };
}
