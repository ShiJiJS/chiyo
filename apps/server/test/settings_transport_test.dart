import 'package:info_workspace/settings_transport.dart';
import 'package:test/test.dart';

void main() {
  test(
    'shared policy wire excludes device settings and raw keys, preserves legacy read values and rejects invalid saves/cleanup counts',
    () {
      final p = WorkspaceServerPolicy(
        generation: 'a' * 43,
        version: 3,
        requestMinutes: 47,
        retentionDays: 90,
      );
      expect(WorkspaceServerPolicy.fromJson(p.json).requestMinutes, 47);
      for (final field in [
        'theme',
        'notifications',
        'background',
        'token',
        'databaseKey',
      ]) {
        expect(
          () => WorkspaceServerPolicy.fromJson({...p.json, field: 'SYNTHETIC'}),
          throwsFormatException,
        );
      }
      final c = WorkspaceServerPolicyChange(
        operationId: 'synthetic-policy',
        commandDigest: 'b' * 64,
        generation: p.generation,
        expectedVersion: p.version,
        requestMinutes: 60,
        retentionDays: 90,
      );
      expect(
        WorkspaceServerPolicyChange.fromJson(c.json).operationId,
        c.operationId,
      );
      expect(
        WorkspaceServerPolicyChange.fromJson({
          ...c.json,
          'requestMinutes': 47,
        }).requestMinutes,
        47,
      );
      expect(
        () => WorkspaceServerPolicyChange.fromJson({
          ...c.json,
          'commandDigest': 'wrong',
        }),
        throwsFormatException,
      );
      final r = WorkspaceServerPolicyReceipt(
        operationId: c.operationId,
        commandDigest: c.commandDigest,
        expectedVersion: 3,
        policy: WorkspaceServerPolicy(
          generation: p.generation,
          version: 4,
          requestMinutes: 60,
          retentionDays: 90,
        ),
      );
      expect(WorkspaceServerPolicyReceipt.fromJson(r.json).matches(c), isTrue);
      expect(
        () => WorkspaceServerPolicyReceipt.fromJson({
          ...r.json,
          'expectedVersion': 4,
        }),
        throwsFormatException,
      );
      final preview = {
        'wireVersion': 1,
        'token': 'synthetic-plan',
        'days': 30,
        'cutoff': '2026-01-01T00:00:00.000Z',
        'requests': 1,
        'grants': 2,
        'operations': 3,
        'preserved': 4,
      };
      expect(retentionPreviewFromJson(preview).operations, 3);
      expect(
        () => retentionPreviewFromJson({...preview, 'grants': -1}),
        throwsFormatException,
      );
      expect(
        () => retentionPreviewFromJson({
          ...preview,
          'cutoff': '2026-01-01T08:00:00+08:00',
        }),
        throwsFormatException,
      );
      expect(
        () => retentionPreviewFromJson({...preview, 'bytes': 'SYNTHETIC'}),
        throwsFormatException,
      );
    },
  );
}
