import 'package:flutter_test/flutter_test.dart';
import 'package:info_workspace/credential_use_transport.dart';
import 'package:info_workspace/workspace_credentials.dart';

void main() {
  final now = DateTime.utc(2026, 11, 10);
  final history = WorkspaceCredentialUseHistory(
    grantId: 'original-grant',
    credentialName: 'Synthetic SSH key',
    materialVersion: 3,
    delivery: WorkspaceCredentialDelivery.file,
    session: const WorkspaceCredentialSession(
      'original-chat',
      'SSH task',
      'Test Agent',
    ),
    purpose: 'Synthetic retained history',
    expiresAt: null,
    state: '会话已结束',
    operations: [
      WorkspaceCredentialUseOperation(
        'original-operation',
        now,
        '接收计划执行',
        'unknown · execution_unknown · complete',
      ),
    ],
  );
  test(
    'session-bound history keeps its null deadline and original unknown operation',
    () {
      final restored = credentialUseHistoryFromJson(
        credentialUseHistoryToJson(history),
      );
      expect(restored.grantId, history.grantId);
      expect(restored.expiresAt, isNull);
      expect(restored.materialVersion, 3);
      expect(restored.session.id, 'original-chat');
      expect(restored.operations.single.id, 'original-operation');
      expect(restored.operations.single.at, now);
      expect(restored.operations.single.result, startsWith('unknown'));
    },
  );
  test(
    'history rejects private or malformed extra fields rather than silently accepting them',
    () {
      final encoded = credentialUseHistoryToJson(history);
      expect(
        () => credentialUseHistoryFromJson({
          ...encoded,
          'executionCapability': 'private',
        }),
        throwsFormatException,
      );
      expect(
        () => credentialUseHistoryFromJson({...encoded, 'materialVersion': 0}),
        throwsFormatException,
      );
      expect(
        () => credentialUseHistoryFromJson({
          ...encoded,
          'operations': [
            {
              ...(encoded['operations'] as List).single as Map,
              'output': 'private output',
            },
          ],
        }),
        throwsFormatException,
      );
    },
  );
}
