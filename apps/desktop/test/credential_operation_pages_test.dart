import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_workspace/approval_transport.dart';
import 'package:info_workspace/owner_workspace_approvals.dart';
import 'package:info_workspace/owner_workspace_credential_batches.dart';
import 'package:info_workspace/workspace_source.dart';
import 'package:info_desktop/workspace/approvals_controller.dart';
import 'package:info_desktop/workspace/operation_pages_footer.dart';
import 'package:info_desktop/workspace/zhiyu_theme.dart';
import '../../../packages/info_core/test_support/operation_history.dart';

class _Delayed extends OwnerWorkspaceApprovals {
  _Delayed({required super.owner});
  Completer<WorkspaceCredentialOperationPage>? delayed;
  Future<WorkspaceCredentialOperationPage>? reading;
  @override
  Future<WorkspaceCredentialOperationPage> operationPage(
    String id, {
    String? cursor,
    int limit = 25,
  }) => reading =
      delayed?.future ?? super.operationPage(id, cursor: cursor, limit: limit);
}

void main() {
  for (final program in [false, true]) {
    test(
      'more than 1000 ${program ? 'program' : 'fill'} facts load in stable bounded pages, including equal timestamps and new front insertions',
      () async {
        final at = DateTime.utc(2026, 11, 14),
            repo = core.MemoryInformationRepository();
        final service = core.InformationService(
          repository: repo,
          clock: () => at,
        );
        addTearDown(service.close);
        final f = OperationHistoryFixture(service, repo, at);
        await f.open(program: program, count: 1005);
        final source = OwnerWorkspaceCredentialBatches(service.owner);
        var detail = source.read(f.request.id);
        expect(detail.operationsTotal, 1005);
        expect(
          detail.programOperations.length + detail.batchOperations.length,
          25,
        );
        expect(
          () => approvalDetailToJson(detail, version: 4),
          throwsA(isA<WorkspaceFailure>()),
        );
        detail = approvalDetailFromJson(
          Map<String, dynamic>.from(approvalDetailToJson(detail, version: 5)),
        );
        expect(detail.operationsCursor, isNotNull);
        final wrong = CredentialOperationCursor(
          'other-request',
          program,
          at,
          'op-000024',
        ).encode();
        expect(
          () => source.operationPage(f.request.id, cursor: wrong),
          throwsA(isA<WorkspaceFailure>()),
        );
        await f.append('a-newer'); // Same timestamp, before the first page.
        var pages = 0;
        while (detail.operationsCursor != null) {
          final page = WorkspaceCredentialOperationPage.fromJson(
            Map<String, dynamic>.from(
              source
                  .operationPage(f.request.id, cursor: detail.operationsCursor)
                  .toJson(),
            ),
          );
          expect(page.length, lessThanOrEqualTo(25));
          final wrongOrder = {
            ...page.toJson(),
            (program ? 'programs' : 'batches'):
                (program
                        ? page.programs.map((o) => o.toJson())
                        : page.batches.map((o) => o.toJson()))
                    .toList()
                    .reversed
                    .toList(),
          };
          if (page.length > 1) {
            expect(
              () => WorkspaceCredentialOperationPage.fromJson(wrongOrder),
              throwsFormatException,
            );
          }
          detail = detail.withOperationPage(page);
          if (++pages > 50) fail('Pagination did not terminate');
        }
        final ids = {
          ...detail.batchOperations.map((o) => o.operationId),
          ...detail.programOperations.map((o) => o.operationId),
        };
        expect(ids, {
          for (var i = 0; i < 1005; i++) 'op-${i.toString().padLeft(6, '0')}',
        });
        expect(ids.contains('a-newer'), false);
        expect(
          source
              .read(f.request.id)
              .programOperations
              .map((o) => o.operationId)
              .followedBy(
                source
                    .read(f.request.id)
                    .batchOperations
                    .map((o) => o.operationId),
              )
              .first,
          'a-newer',
        );
      },
    );
  }
  testWidgets(
    'load-more shows a bounded count and a late page cannot replace another selected request',
    (tester) async {
      final at = DateTime.utc(2026, 11, 14),
          repo = core.MemoryInformationRepository();
      final service = core.InformationService(
        repository: repo,
        clock: () => at,
      );
      addTearDown(service.close);
      final a = OperationHistoryFixture(service, repo, at),
          b = OperationHistoryFixture(service, repo, at);
      await tester.runAsync(() async {
        await a.open(program: true, count: 55);
        await b.open(program: false, count: 1);
      });
      final source = _Delayed(owner: service.owner);
      final controller = ApprovalsController(source, const Stream.empty());
      addTearDown(controller.dispose);
      await tester.runAsync(() => controller.open(a.request.id));
      await tester.pumpWidget(
        MaterialApp(
          theme: zhiyuTheme(Brightness.light),
          home: Scaffold(
            body: AnimatedBuilder(
              animation: controller,
              builder: (c, _) => OperationPagesFooter(controller: controller),
            ),
          ),
        ),
      );
      expect(find.text('加载较早记录（已显示25/55次）'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('load-older-credential-operations')),
      );
      await tester.runAsync(() => source.reading!);
      await tester.pumpAndSettle();
      expect(controller.detail!.programOperations, hasLength(50));
      expect(find.text('加载较早记录（已显示50/55次）'), findsOneWidget);
      final cursorBeforeQuery = controller.detail!.operationsCursor;
      await tester.runAsync(
        () => controller.refreshProgramOperation(
          controller.detail!.programOperations.first.operationId,
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.detail!.operationsCursor, cursorBeforeQuery);
      expect(find.text('加载较早记录（已显示50/55次）'), findsOneWidget);
      await tester.runAsync(() async {
        source.delayed = Completer();
        final pending = controller.loadMoreOperations();
        final oldCursor = controller.detail!.operationsCursor;
        final stale = OwnerWorkspaceCredentialBatches(
          service.owner,
        ).operationPage(a.request.id, cursor: oldCursor);
        await controller.open(b.request.id);
        source.delayed!.complete(stale);
        await pending;
      });
      expect(controller.detail!.request.id, b.request.id);
      expect(controller.detail!.programOperations, isEmpty);
      expect(controller.readingOperationPage, false);
    },
  );
}
