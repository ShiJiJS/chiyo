import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_remote/owner_client.dart';
import 'package:info_server/owner_host_routes.dart';
import 'package:info_workspace/host_transport.dart';
import 'package:info_workspace/workspace_source.dart';
import 'package:test/test.dart';
import '../../../packages/info_core/test/fixtures/ssh_session_fixture.dart'
    show knownHostBytes;
import 'support/device_credential_fixture.dart';

void main() {
  test(
    'normal HTTPS owner imports, reviews, revokes and confirms shared SSH trust with persistent exact receipts',
    () async {
      final f = await DeviceCredentialFixture.create();
      addTearDown(f.dispose);
      final initial = await f.owner.request('GET', '/v1/server');
      final body = <String, dynamic>{
        'version': 1,
        'operationId': 'host-upload',
        'name': 'synthetic-known_hosts',
        'bytes': base64Encode(knownHostBytes()),
      };
      final first = await f.owner.request(
        'POST',
        '/v1/owner/ssh-hosts/inputs',
        body,
      );
      final selected = hostFileFromJson(first['file']);
      expect(
        (await f.owner.request(
          'POST',
          '/v1/owner/ssh-hosts/inputs',
          body,
        ))['file'],
        first['file'],
      );
      await expectLater(
        f.owner.request('POST', '/v1/owner/ssh-hosts/inputs', {
          ...body,
          'name': 'another-file',
        }),
        throwsA(
          isA<RemoteFailure>().having(
            (e) => e.code,
            'code',
            'operation_conflict',
          ),
        ),
      );
      expect(f.runtime.service.owner.sshKnownHosts, isNull);
      final rawPreview =
          (await f.owner.request(
                'GET',
                '/v1/owner/ssh-hosts/previews/${selected.selectionId}',
              ))['preview']
              as Map<String, dynamic>;
      final preview = hostImportPreviewFromJson(rawPreview);
      expect(preview.file.name, 'synthetic-known_hosts');
      expect(preview.entries.single.pattern, '[test.beichen.example]:2222');
      expect(preview.entries.single.fingerprint, startsWith('SHA256:'));
      final forged = {
        ...rawPreview,
        'entries': [
          {
            ...(rawPreview['entries'] as List).single as Map<String, dynamic>,
            'fingerprint': 'SHA256:WRONG_REVIEW',
          },
        ],
      };
      await expectLater(
        f.owner.request('POST', '/v1/owner/ssh-hosts/imports', {
          'version': 1,
          'operationId': 'forged-import',
          'preview': forged,
        }),
        throwsA(isA<RemoteFailure>().having((e) => e.code, 'code', 'conflict')),
      );
      expect(f.runtime.service.owner.sshKnownHosts, isNull);
      final change = WorkspaceHostImportChange('import-host', preview);
      final committed = hostImportReceiptFromJson(
        await f.owner.request(
          'POST',
          '/v1/owner/ssh-hosts/imports',
          hostImportChangeToJson(change),
        ),
      );
      expect(committed.matches(change), true);
      final repeat = await f.owner.request(
        'POST',
        '/v1/owner/ssh-hosts/imports',
        hostImportChangeToJson(change),
      );
      expect(
        hostImportReceiptFromJson(repeat).result.version,
        committed.result.version,
      );
      final catalog = await f.owner.request('GET', '/v1/owner/ssh-hosts');
      final identity = hostIdentityFromJson((catalog['hosts'] as List).single);
      expect(identity.state, WorkspaceHostState.trusted);
      expect(
        hostImportStatusFromJson(catalog['imported']).digest,
        preview.digest,
      );
      expect(
        (await f.owner.request('GET', '/v1/server'))['workspaceObservation'],
        isNot(initial['workspaceObservation']),
      );
      final revoke = WorkspaceHostChange(
        operationId: 'revoke-host',
        action: WorkspaceHostAction.revoke,
        reviewed: identity,
      );
      final revoked = hostReceiptFromJson(
        await f.owner.request(
          'POST',
          '/v1/owner/ssh-hosts/changes',
          hostChangeToJson(revoke),
        ),
      );
      expect(revoked.action, WorkspaceHostAction.revoke);
      final current = hostIdentityFromJson(
        (await f.owner.request('POST', '/v1/owner/ssh-hosts/read', {
          'version': 1,
          'target': hostTargetToJson(identity.target),
        }))['host'],
      );
      expect(current.state, WorkspaceHostState.revoked);
      await expectLater(
        f.owner.request(
          'POST',
          '/v1/owner/ssh-hosts/changes',
          hostChangeToJson(
            WorkspaceHostChange(
              operationId: 'stale-confirm',
              action: WorkspaceHostAction.confirm,
              reviewed: identity,
            ),
          ),
        ),
        throwsA(isA<RemoteFailure>().having((e) => e.code, 'code', 'conflict')),
      );
      final confirm = WorkspaceHostChange(
        operationId: 'confirm-host',
        action: WorkspaceHostAction.confirm,
        reviewed: current,
      );
      final confirmed = hostReceiptFromJson(
        await f.owner.request(
          'POST',
          '/v1/owner/ssh-hosts/changes',
          hostChangeToJson(confirm),
        ),
      );
      expect(confirmed.version, greaterThan(revoked.version));
      final http = HttpClient(context: f.trust);
      try {
        final request = await http.getUrl(
          f.owner.address.resolve('/v1/owner/ssh-hosts'),
        );
        request.headers.set(
          'authorization',
          'Bearer ${f.profiles.first.deviceToken}',
        );
        final response = await request.close();
        expect(response.statusCode, 401);
        final rejected = await response.transform(utf8.decoder).join();
        expect(rejected, isNot(contains(preview.entries.single.fingerprint)));
      } finally {
        http.close(force: true);
      }
      expect(jsonEncode(catalog), isNot(contains('bytesBase64')));
      await f.reopen();
      final reopened = hostIdentityFromJson(
        ((await f.owner.request('GET', '/v1/owner/ssh-hosts'))['hosts'] as List)
            .single,
      );
      expect(reopened.state, WorkspaceHostState.trusted);
      expect(reopened.version, confirmed.version);
      final importReceipt = hostImportReceiptFromJson(
        await f.owner.request(
          'GET',
          '/v1/owner/ssh-hosts/import-operations/import-host',
        ),
      );
      expect(importReceipt.matches(change), true);
      expect(
        hostReceiptFromJson(
          await f.owner.request(
            'GET',
            '/v1/owner/ssh-hosts/operations/confirm-host',
          ),
        ).version,
        confirmed.version,
      );
      await expectLater(
        f.owner.request('GET', '/v1/owner/ssh-hosts/inputs/absent'),
        throwsA(
          isA<RemoteFailure>().having(
            (e) => e.code,
            'code',
            'selection_not_found',
          ),
        ),
      );
    },
  );

  test(
    'Host staging expires without changing trust and strict DTOs reject private fields or missing review data',
    () async {
      final f = await DeviceCredentialFixture.create();
      addTearDown(f.dispose);
      var elapsed = Duration.zero;
      final routes = OwnerHostRoutes(
        f.runtime.service.owner,
        elapsed: () => elapsed,
      );
      addTearDown(routes.dispose);
      final upload = await f.runtime.run(
        () => routes.upload({
          'version': 1,
          'operationId': 'expire-host',
          'name': 'synthetic-known_hosts',
          'bytes': base64Encode(knownHostBytes()),
        }),
      );
      final file = hostFileFromJson(upload['file']);
      final preview = await routes.source.previewImport(file.selectionId);
      final j = hostImportPreviewToJson(preview);
      expect(
        () => hostImportPreviewFromJson({...j, 'secret': 'forbidden'}),
        throwsFormatException,
      );
      final missing = Map<String, Object?>.from(j)..remove('entries');
      expect(() => hostImportPreviewFromJson(missing), throwsFormatException);
      elapsed = const Duration(minutes: 31);
      expect(routes.needsCleanup, true);
      await routes.cleanup();
      await expectLater(
        routes.source.previewImport(file.selectionId),
        throwsA(
          isA<WorkspaceFailure>().having(
            (e) => e.code,
            'code',
            'selection_unavailable',
          ),
        ),
      );
      expect(f.runtime.service.owner.sshKnownHosts, isNull);
      await expectLater(
        f.owner.request('GET', '/v1/owner/ssh-hosts/operations/absent'),
        throwsA(
          isA<RemoteFailure>().having(
            (e) => e.code,
            'code',
            'operation_not_found',
          ),
        ),
      );
    },
  );
}
