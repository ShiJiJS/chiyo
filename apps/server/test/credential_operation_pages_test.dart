import 'dart:convert';
import 'package:info_core/info_core.dart';
import 'package:info_remote/owner_client.dart';
import 'package:info_workspace/approval_transport.dart';
import 'package:info_workspace/workspace_source.dart';
import 'package:test/test.dart';
import '../../../packages/info_workspace/test_support/operation_history.dart';
import 'support/device_credential_fixture.dart';

void main() {
  test(
    'HTTPS owner details and pages share exact bounded SQLCipher metadata without changing grants or acquiring material',
    () async {
      final at = DateTime.utc(2026, 11, 14);
      final f = await DeviceCredentialFixture.create(clock: () => at);
      addTearDown(f.dispose);
      for (final program in [false, true]) {
        final history = OperationHistoryFixture(f.runtime.service, f.repo, at);
        await f.runtime.run(() => history.open(program: program, count: 61));
        final path =
            '/v1/owner/credential-batches/${Uri.encodeComponent(history.request.id)}';
        final raw = await f.owner.request(
          'GET',
          '/v1/owner/approvals/details/${Uri.encodeComponent(history.request.id)}',
        );
        expect(raw['version'], 5);
        var detail = approvalDetailFromJson(raw);
        expect(detail.operationsTotal, 61);
        expect(
          detail.batchOperations.length + detail.programOperations.length,
          25,
        );
        final originalReview = detail.reviewToken;
        final firstCursor = detail.operationsCursor!;
        final page = WorkspaceCredentialOperationPage.fromJson(
          await f.owner.request('POST', '$path/operations/query', {
            'cursor': firstCursor,
            'limit': 17,
          }),
        );
        expect(page.length, 17);
        detail = detail.withOperationPage(page);
        expect(
          detail.batchOperations.length + detail.programOperations.length,
          42,
        );
        expect(detail.reviewToken, originalReview);
        final repeated = await f.owner.request(
          'POST',
          '$path/operations/query',
          {'cursor': firstCursor, 'limit': 17},
        );
        expect(
          jsonEncode(repeated).contains('NEVER-PAGE-THIS-MATERIAL'),
          false,
        );
        expect(
          (repeated[program ? 'programs' : 'batches'] as List).map(
            (o) => o['operationId'],
          ),
          page.keys.map((key) => key.$2),
        );
        await expectLater(
          f.owner.request('POST', '$path/operations/query', {
            'cursor': CredentialOperationCursor(
              'another-request',
              program,
              at,
              'op-000024',
            ).encode(),
            'limit': 25,
          }),
          throwsA(
            isA<RemoteFailure>().having((e) => e.code, 'code', 'invalid_query'),
          ),
        );
        while (detail.operationsCursor != null) {
          detail = detail.withOperationPage(
            WorkspaceCredentialOperationPage.fromJson(
              await f.owner.request('POST', '$path/operations/query', {
                'cursor': detail.operationsCursor,
                'limit': 25,
              }),
            ),
          );
        }
        expect(
          detail.batchOperations.length + detail.programOperations.length,
          61,
        );
        final rawBatch = await f.owner.request('GET', path);
        expect(rawBatch['operationTotal'], 61);
        expect(
          (rawBatch[program ? 'programOperations' : 'operations'] as List)
              .length,
          25,
        );
        expect(
          f.runtime.service.owner.credentialBatches
              .singleWhere((r) => r.id == history.request.id)
              .decisions,
          hasLength(1),
        );
      }
    },
  );
}
