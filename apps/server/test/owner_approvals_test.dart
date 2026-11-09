import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_server/agent_devices.dart';
import 'package:info_server/mounted_database_key_store.dart';
import 'package:info_server/online_server.dart';
import 'package:info_server/server_configuration.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_workspace/approval_transport.dart';
import 'package:info_workspace/workspace_approvals.dart';
import 'package:test/test.dart';
import 'support/tls_fixture.dart';

void main() {
  test(
    'normal HTTPS owner reviews approve, reject, revoke and reconcile exact decisions',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'chiyo-owner-approvals-',
      );
      addTearDown(() => root.delete(recursive: true));
      await initializeServerSecrets('${root.path}/secrets');
      final fixture = await createTlsFixture(root);
      final tls = SecurityContext()
        ..useCertificateChain(fixture.certificate)
        ..usePrivateKey(fixture.privateKey);
      final trust = SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificates(fixture.ca);
      final owner = base64Url
          .encode(await File('${root.path}/secrets/owner.token').readAsBytes())
          .replaceAll('=', '');
      final repo = await EncryptedInformationRepository.openOnline(
        '${root.path}/data',
        MountedDatabaseKeyStore('${root.path}/secrets/database.key'),
      );
      final runtime = await OnlineInformationRuntime.open(repository: repo);
      final devices = AgentDeviceRegistry(repo);
      final server = await OnlineServer.start(
        runtime: runtime,
        devices: devices,
        tls: tls,
        ownerToken: owner,
        serverId: 'synthetic-approval-server',
      );
      final client = HttpClient(context: trust);
      addTearDown(() async {
        client.close(force: true);
        await server.close();
        await runtime.close();
        await repo.close();
      });
      Future<(int, Map<String, dynamic>)> call(
        String method,
        String path,
        String token, [
        Object? body,
      ]) async {
        final request = await client.openUrl(
          method,
          Uri.parse('https://127.0.0.1:${server.port}$path'),
        );
        request.headers.set('authorization', 'Bearer $token');
        if (body != null) {
          request.headers.contentType = ContentType.json;
          request.write(jsonEncode(body));
        }
        final response = await request.close();
        return (
          response.statusCode,
          jsonDecode(await utf8.decoder.bind(response).join())
              as Map<String, dynamic>,
        );
      }

      Future<Map<String, dynamic>> agent(
        String path,
        String token,
        Map<String, Object?> body,
      ) async {
        final result = await call('POST', '/v1/agent$path', token, body);
        expect(result.$1, 200);
        return result.$2;
      }

      final item = await runtime.run(
        () => runtime.service.owner.createInformation(
          'Synthetic server',
          'Public description',
          [
            const FieldInput('Host', 'Public label', 'PRIVATE_SYNTHETIC_HOST'),
            const FieldInput('Account', '', 'PRIVATE_SYNTHETIC_ACCOUNT'),
          ],
        ),
      );
      final device = await devices.enroll('enroll', 'Synthetic CLI');
      final session = await agent('/session/lifecycle', device.bearer, {
        'chatLabel': 'Synthetic owner review chat',
      });
      final sessionSecret = session['sessionSecret'] as String;
      final observationBefore = (await call(
        'GET',
        '/v1/server',
        owner,
      )).$2['workspaceObservation'];
      final requested = await agent('/request', device.bearer, {
        'sessionSecret': sessionSecret,
        'purpose': 'Read only approved field',
        'operationId': 'request-once',
        'fields': [
          for (final f in item.fields) {'itemId': item.id, 'fieldId': f.id},
        ],
      });
      final id = requested['requestId'] as String;
      final observationAfter = (await call(
        'GET',
        '/v1/server',
        owner,
      )).$2['workspaceObservation'];
      expect(observationAfter, isNot(observationBefore));
      for (final path in [
        '/v1/owner/approvals/$id',
        '/v1/owner/approvals/operations/approval',
      ]) {
        expect((await call('GET', path, device.bearer)).$1, 401);
      }
      final query = await call(
        'POST',
        '/v1/owner/approvals/query',
        owner,
        approvalQueryToJson(const WorkspaceApprovalQuery()),
      );
      expect(query.$1, 200);
      expect(approvalResultsFromJson(query.$2).pending, 1);
      final detailJson = (await call(
        'GET',
        '/v1/owner/approvals/$id',
        owner,
      )).$2;
      final detail = approvalDetailFromJson(detailJson);
      expect(detail.scopes, hasLength(2));
      for (final forbidden in [
        'PRIVATE_SYNTHETIC_',
        sessionSecret,
        session['endCapability'] as String,
      ]) {
        expect(jsonEncode(detailJson), isNot(contains(forbidden)));
        expect(jsonEncode(query.$2), isNot(contains(forbidden)));
      }
      final stale = WorkspaceApprovalChange(
        operationId: 'stale',
        requestId: id,
        reviewToken: detail.reviewToken,
        action: WorkspaceApprovalAction.approve,
        selected: [detail.scopes.first.id],
      );
      await runtime.run(
        () => runtime.service.owner.correctValue(
          FieldRef(item.id, item.fields.first.id),
          'PRIVATE_CORRECTED',
        ),
      );
      expect(
        (await call(
          'POST',
          '/v1/owner/approvals/decisions',
          owner,
          approvalChangeToJson(stale),
        )).$2['error'],
        'conflict',
      );
      expect(
        (await call(
          'GET',
          '/v1/owner/approvals/operations/stale',
          owner,
        )).$2['error'],
        'operation_not_found',
      );
      final current = approvalDetailFromJson(
        (await call('GET', '/v1/owner/approvals/$id', owner)).$2,
      );
      final change = WorkspaceApprovalChange(
        operationId: 'approval',
        requestId: id,
        reviewToken: current.reviewToken,
        action: WorkspaceApprovalAction.approve,
        selected: [current.scopes.first.id],
        fieldMinutes: 5,
      );
      expect(
        (await call(
          'POST',
          '/v1/owner/approvals/decisions',
          device.bearer,
          approvalChangeToJson(change),
        )).$1,
        401,
      );
      final committed = await call(
        'POST',
        '/v1/owner/approvals/decisions',
        owner,
        approvalChangeToJson(change),
      );
      expect(committed.$1, 200);
      expect(
        approvalReceiptFromJson(committed.$2).commandDigest,
        change.digest,
      );
      expect(
        (await call(
          'POST',
          '/v1/owner/approvals/decisions',
          owner,
          approvalChangeToJson(change),
        )).$2,
        committed.$2,
      );
      expect(
        (await call(
          'GET',
          '/v1/owner/approvals/operations/approval',
          owner,
        )).$2,
        committed.$2,
      );
      final grant = await agent('/claim', device.bearer, {
        'sessionSecret': sessionSecret,
        'requestId': id,
      });
      final read = {
        'token': grant['token'],
        'itemId': item.id,
        'fieldId': item.fields.first.id,
      };
      expect(
        (await agent('/read', device.bearer, read))['value'],
        'PRIVATE_CORRECTED',
      );
      expect(
        (await call('POST', '/v1/agent/read', device.bearer, {
          ...read,
          'fieldId': item.fields.last.id,
        })).$1,
        401,
      );
      final approved = approvalDetailFromJson(
        (await call('GET', '/v1/owner/approvals/$id', owner)).$2,
      );
      expect(approved.approved, {current.scopes.first.id});
      expect(
        jsonEncode(approvalDetailToJson(approved)),
        isNot(contains(grant['token'] as String)),
      );
      final revoke = WorkspaceApprovalChange(
        operationId: 'revoke',
        requestId: id,
        reviewToken: approved.reviewToken,
        action: WorkspaceApprovalAction.revoke,
      );
      expect(
        (await call(
          'POST',
          '/v1/owner/approvals/decisions',
          owner,
          approvalChangeToJson(revoke),
        )).$1,
        200,
      );
      expect(
        (await call('POST', '/v1/agent/read', device.bearer, read)).$1,
        401,
      );
      final second = await agent('/request', device.bearer, {
        'sessionSecret': sessionSecret,
        'purpose': 'Request to reject',
        'fields': [
          {'itemId': item.id, 'fieldId': item.fields.first.id},
        ],
      });
      final secondId = second['requestId'] as String;
      final secondDetail = approvalDetailFromJson(
        (await call('GET', '/v1/owner/approvals/$secondId', owner)).$2,
      );
      final deny = WorkspaceApprovalChange(
        operationId: 'deny',
        requestId: secondId,
        reviewToken: secondDetail.reviewToken,
        action: WorkspaceApprovalAction.deny,
      );
      expect(
        (await call(
          'POST',
          '/v1/owner/approvals/decisions',
          owner,
          approvalChangeToJson(deny),
        )).$1,
        200,
      );
      expect(
        (await call('POST', '/v1/agent/claim', device.bearer, {
          'sessionSecret': sessionSecret,
          'requestId': secondId,
        })).$2['error'],
        'denied',
      );
      expect(repo.grantHistory, hasLength(1));
    },
  );
}
