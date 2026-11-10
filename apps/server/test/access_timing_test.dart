import 'package:info_cli/agent_client.dart';
import 'package:info_core/info_core.dart';
import 'package:info_workspace/approval_transport.dart';
import 'package:info_workspace/settings_transport.dart';
import 'package:info_workspace/workspace_source.dart';
import 'package:test/test.dart';
import 'support/device_credential_fixture.dart';

void main() {
  test(
    'HTTPS and CLI use two-hour defaults, persisted waiting presets and fixed approval deadlines',
    () async {
      var now = DateTime.utc(2026, 11, 11);
      final f = await DeviceCredentialFixture.create(clock: () => now);
      final cli = AgentClient.remote(
        f.profiles.first,
        requireSubmissionMetadata: true,
        sourceAgent: '时间验收 Agent',
        externalChatId: 'synthetic-timing-chat',
      );
      addTearDown(() async {
        cli.close();
        await f.dispose();
      });
      await cli.openLifecycleSession('时间验收');
      final item = await f.runtime.run(
        () => f.runtime.service.owner.createInformation('合成主机', '', [
          const FieldInput('地址', '', 'synthetic.invalid'),
        ]),
      );
      var serial = 0;
      Future<Map<String, dynamic>> request() => cli.execute({
        'command': 'request',
        'operationId': 'timing-${++serial}',
        'purpose': '核对合成地址',
        'fields': [FieldRef(item.id, item.fields.single.id).toJson()],
      });
      Future<WorkspaceApprovalDetail> detail(String id) async =>
          approvalDetailFromJson(
            await f.owner.request('GET', '/v1/owner/approvals/$id'),
          );
      Future<WorkspaceServerPolicy> policy() async =>
          WorkspaceServerPolicy.fromJson(
            await f.owner.request('GET', '/v1/owner/settings'),
          );
      Future<void> waiting(int minutes) async {
        final p = await policy();
        await f.owner.request(
          'POST',
          '/v1/owner/settings/changes',
          WorkspaceServerPolicyChange(
            operationId: 'waiting-${++serial}',
            commandDigest: 'a' * 64,
            generation: p.generation,
            expectedVersion: p.version,
            requestMinutes: minutes,
            retentionDays: p.retentionDays,
          ).json,
        );
      }

      Future<void> approve(String id, {int? minutes}) async {
        final d = await detail(id);
        await f.owner.request(
          'POST',
          '/v1/owner/approvals/decisions',
          approvalChangeToJson(
            WorkspaceApprovalChange(
              operationId: 'approve-${++serial}',
              requestId: id,
              reviewToken: d.reviewToken,
              action: WorkspaceApprovalAction.approve,
              selected: d.scopes.map((s) => s.id),
              fieldMinutes: minutes ?? 120,
              credentialMinutes: minutes ?? 120,
            ),
          ),
        );
      }

      Duration wait(Map<String, dynamic> r) => DateTime.parse(
        r['requestExpiresAt'] as String,
      ).difference(DateTime.parse(r['createdAt'] as String));
      expect((await policy()).requestMinutes, 120);
      final initial = await request();
      expect(wait(initial), const Duration(hours: 2));
      await approve(initial['requestId'] as String);
      final grant = await cli.execute({
        'command': 'claim',
        'requestId': initial['requestId'],
      });
      final fixed = DateTime.parse(grant['expiresAt'] as String);
      expect(fixed, now.add(const Duration(hours: 2)));
      final oldShort = await request();
      await f.runtime.run(
        () => f.runtime.service.owner.approve(oldShort['requestId'] as String, [
          FieldRef(item.id, item.fields.single.id),
        ], lifetime: const Duration(minutes: 15)),
      );
      final shortDeadline = (await cli.execute({
        'command': 'claim',
        'requestId': oldShort['requestId'],
      }))['expiresAt'];
      expect(
        DateTime.parse(shortDeadline as String),
        now.add(const Duration(minutes: 15)),
      );
      final oldPending = await request();
      for (final minutes in [30, 60, 120, 240, 480, 1440]) {
        await waiting(minutes);
        final r = await request();
        expect(wait(r), Duration(minutes: minutes));
        expect(
          (await detail(
            oldPending['requestId'] as String,
          )).request.requestExpiresAt,
          DateTime.parse(oldPending['requestExpiresAt'] as String),
        );
        expect(
          (await cli.execute({
            'command': 'claim',
            'requestId': initial['requestId'],
          }))['expiresAt'],
          fixed.toIso8601String(),
        );
        await f.reopen();
        expect((await policy()).requestMinutes, minutes);
        expect(
          (await detail(r['requestId'] as String)).request.requestExpiresAt,
          DateTime.parse(r['requestExpiresAt'] as String),
        );
      }
      // No setting edit or restart extends an already approved deadline.
      now = DateTime.parse(shortDeadline);
      expect(
        (await cli.execute({
          'command': 'claim',
          'requestId': oldShort['requestId'],
        }))['status'],
        'unauthorized',
      );
      expect(
        (await cli.execute({
          'command': 'claim',
          'requestId': initial['requestId'],
        }))['status'],
        'ok',
      );
      now = fixed;
      expect(
        (await cli.execute({
          'command': 'claim',
          'requestId': initial['requestId'],
        }))['status'],
        'unauthorized',
      );
      // Each new fixed option goes through the real server adapter and survives restart.
      for (final minutes in [120, 240, 480, 1440]) {
        final r = await request();
        await approve(r['requestId'] as String, minutes: minutes);
        final end = now.add(Duration(minutes: minutes));
        await f.reopen();
        expect(
          DateTime.parse(
            (await cli.execute({
                  'command': 'claim',
                  'requestId': r['requestId'],
                }))['expiresAt']
                as String,
          ),
          end,
        );
        now = end.subtract(const Duration(milliseconds: 1));
        expect(
          (await cli.execute({
            'command': 'read',
            'requestId': r['requestId'],
            'itemId': item.id,
            'fieldId': item.fields.single.id,
          }))['status'],
          'ok',
        );
        now = end;
        expect(
          (await cli.execute({
            'command': 'claim',
            'requestId': r['requestId'],
          }))['status'],
          'unauthorized',
        );
      }
    },
  );
}
