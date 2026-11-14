import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_desktop/workspace/owner_workspace_source.dart';
import '../../../packages/info_core/test_support/operation_history.dart';

void main() {
  for (final program in [false, true]) {
    test(
      'unchanged ${program ? 'program' : 'fill'} history does not refresh the workspace as time passes',
      () async {
        var now = DateTime.utc(2026, 11, 14);
        final repo = core.MemoryInformationRepository();
        final service = core.InformationService(
          repository: repo,
          clock: () => now,
        );
        final history = OperationHistoryFixture(service, repo, now);
        await history.open(program: program, count: 1);
        final source = OwnerWorkspaceSource(
          owner: service.owner,
          refreshInterval: Duration.zero,
        );
        var changes = 0;
        final subscription = source.changes.listen((_) => changes++);
        Future<void> poll() async {
          source.refreshFromOwner();
          await Future<void>.delayed(Duration.zero);
        }

        try {
          for (var i = 0; i < 3; i++) {
            now = now.add(const Duration(seconds: 1));
            await poll();
          }
          expect(
            changes,
            0,
            reason:
                'Read timestamps are not changes to stored or effective state',
          );
          await history.append('pending-operation', finish: false);
          await poll();
          expect(changes, 1);
          now = now.add(const Duration(seconds: 1));
          await poll();
          expect(changes, 1);
          now = now.add(const Duration(minutes: 1));
          await poll();
          expect(
            changes,
            2,
            reason:
                'An elapsed execution deadline still changes effective state',
          );
          now = now.add(const Duration(seconds: 1));
          await poll();
          expect(changes, 2);
        } finally {
          await subscription.cancel();
          await source.dispose();
          await service.close();
        }
      },
    );
  }
}
