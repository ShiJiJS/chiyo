import 'dart:async';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';
import 'focused_fill_test.dart' show fixture, code;

void main() {
  test(
    'busy does not queue an operation for an unknown future foreground target',
    () async {
      final f = await fixture();
      f.driver.preparation = Completer<void>();
      final second = await f.service.agent.requestFocusedFill(
        f.session,
        FocusedFillInput.fromJson(f.input()),
      );
      await f.service.owner.decideCredentialUse(
        second.id,
        approveCredential: true,
      );
      await f.service.agent.startFocusedFill(f.session, f.operation('first'));
      await expectLater(
        f.service.agent.startFocusedFill(
          f.session,
          f.operation('second', second.id),
        ),
        code('busy'),
      );
      expect(f.repo.focusedFillOperations.length, 1);
      f.driver.preparation!.complete();
      await f.service.drainFocusedFills();
      await f.service.agent.startFocusedFill(
        f.session,
        f.operation('second', second.id),
      );
      await f.service.drainFocusedFills();
      expect(f.driver.prepares, 2);
    },
  );
  test(
    'grant changes at transaction validation prevent any native preparation',
    () async {
      final f = await fixture();
      f.repo.beforeValidate = () => f.service.agent.endSession(f.session);
      await expectLater(
        f.service.agent.startFocusedFill(f.session, f.operation()),
        code('grant_revoked'),
      );
      expect(f.repo.focusedFillOperations, isEmpty);
      expect(f.driver.prepares, 0);
      expect(f.repo.materialReads, 0);
    },
  );
  test(
    'command and fill modes cannot consume each other or reuse an operation ID',
    () async {
      final f = await fixture();
      await f.run('shared-fill');
      final command = await f.service.agent.requestCredentialUse(
        f.session,
        CredentialUseInput.fromJson({
          'protocolVersion': 2,
          'command': 'request-use',
          'purpose': 'Synthetic command',
          'credentials': [
            {'alias': 'token', 'credentialId': f.credential.id, 'version': 1},
          ],
          'launch': {
            'receiver': 'gh_token',
            'executable': Platform.resolvedExecutable,
            'argv': ['api', 'user'],
            'cwd': Directory.current.path,
            'env': {
              'GH_TOKEN': {'secret': 'token'},
            },
          },
          'readFields': [],
        }),
      );
      await f.service.owner.decideCredentialUse(
        command.id,
        approveCredential: true,
      );
      CredentialOperationInput operation(String requestId, String id) =>
          CredentialOperationInput.fromJson({
            'protocolVersion': 2,
            'command': 'run-use',
            'requestId': requestId,
            'operationId': id,
            'launch': command.toRequestInputJson()['launch'],
          });
      expect(
        () => f.service.agent.credentialUseOperationStatus(
          f.session,
          operation(command.id, 'shared-fill'),
        ),
        code('operation_conflict'),
      );
      await expectLater(
        f.service.agent.startFocusedFill(
          f.session,
          f.operation('wrong-mode', command.id),
        ),
        code('scope_not_approved'),
      );
      await expectLater(
        f.service.agent.beginCredentialUseOperation(
          f.session,
          operation(f.request.id, 'wrong-command'),
        ),
        code('scope_not_approved'),
      );
      await f.service.agent.beginCredentialUseOperation(
        f.session,
        operation(command.id, 'shared-command'),
      );
      await expectLater(
        f.service.agent.startFocusedFill(
          f.session,
          f.operation('shared-command'),
        ),
        code('operation_conflict'),
      );
      expect(f.repo.credentialExecutions.length, 1);
      expect(f.driver.prepares, 1);
    },
  );
  test(
    'retention removes ended fill operations with their request and counts them in the preview',
    () async {
      final f = await fixture();
      await f.run();
      f.now = f.now.add(const Duration(days: 100));
      final preview = await f.service.owner.previewAuditRetention(30);
      expect(preview.credentialRequests, 1);
      expect(preview.credentialExecutions, 1);
      await f.service.owner.pruneCredentialUseHistory();
      expect(f.repo.focusedFillOperations, isEmpty);
      expect(f.repo.credentialUseRequests, isEmpty);
    },
  );
  test(
    'unresolved unknown history is retained and owner review does not revive an expired grant',
    () async {
      final f = await fixture();
      f.driver.onBatch = (_, _) async =>
          throw StateError('synthetic response loss');
      final result = await f.run();
      final expiry =
          f.service.owner.credentialUseRequests.single.credentialExpiresAt;
      f.now = f.now.add(const Duration(days: 100));
      expect(
        (await f.service.owner.previewAuditRetention(30)).credentialRequests,
        0,
      );
      await f.service.owner.pruneCredentialUseHistory();
      expect(f.repo.focusedFillOperations.length, 1);
      await f.service.owner.acknowledgeFocusedFillAttention(
        result['fillId']! as String,
      );
      await expectLater(
        f.service.agent.startFocusedFill(f.session, f.operation('expired')),
        code('grant_expired'),
      );
      expect(
        f.service.owner.credentialUseRequests.single.credentialExpiresAt,
        expiry,
      );
      f.now = f.now.add(const Duration(days: 100));
      await f.service.owner.pruneCredentialUseHistory();
      expect(f.repo.focusedFillOperations, isEmpty);
    },
  );
  test(
    'closing during a native wait cancels and drains without sending another batch',
    () async {
      final f = await fixture();
      final entered = Completer<void>(), release = Completer<void>();
      f.driver.onBatch = (_, _) async {
        entered.complete();
        await release.future;
        return const FocusedFillBatchResult(FocusedFillState.sent);
      };
      await f.service.agent.startFocusedFill(f.session, f.operation());
      await entered.future;
      final closed = f.service.close();
      final secondClose = f.service.close();
      release.complete();
      await Future.wait([closed, secondClose]);
      expect(f.driver.closes, 1);
      expect(f.driver.batches.length, 1);
      expect(
        f.repo.focusedFillOperations.single.state,
        FocusedFillState.partial,
      );
      expect(f.service.agent.focusedFillAvailable, isFalse);
    },
  );
  test(
    'restore stops input and an old task cannot overwrite an identically named restored history record',
    () async {
      final f = await fixture();
      final entered = Completer<void>(), release = Completer<void>();
      f.driver.onBatch = (_, _) async {
        entered.complete();
        await release.future;
        return const FocusedFillBatchResult(FocusedFillState.sent);
      };
      await f.service.agent.startFocusedFill(f.session, f.operation());
      await entered.future;
      await f.service.owner.restoreLibrary(() async {
        expect(f.driver.closes, 1);
        final archived = f.repo.focusedFillOperations.single.changed({
          'fillState': 'unknown',
          'errorCode': 'fill_unknown',
          'finishedAt': f.now.toIso8601String(),
          'restoredAt': f.now.toIso8601String(),
        });
        await f.repo.commitFocusedFillRuntime(f.repo.credentialUseRequests, [
          archived,
        ]);
        return true;
      });
      release.complete();
      await f.service.drainFocusedFills();
      expect(f.driver.batches.length, 1);
      expect(
        f.repo.focusedFillOperations.single.state,
        FocusedFillState.unknown,
      );
      expect(f.repo.focusedFillOperations.single.restoredAt, f.now);
    },
  );
  test(
    'the application inspector compares real bytes without launching the target',
    () async {
      final folder = await Directory.systemTemp.createTemp(
        'focused-application-',
      );
      final file = File('${folder.path}/browser.exe');
      await file.writeAsString('synthetic executable bytes');
      addTearDown(() async {
        await file.delete();
        await folder.delete();
      });
      final application = FocusedFillApplication.fromJson({
        'executable': file.absolute.path,
        'sha256': sha256.convert(await file.readAsBytes()).toString(),
      });
      final inspected = await inspectFocusedFillApplication(application);
      expect(inspected.sha256, application.sha256);
      await file.writeAsString('changed synthetic bytes');
      await expectLater(
        inspectFocusedFillApplication(application),
        code('application_changed'),
      );
    },
    skip: !Platform.isWindows,
  );
}
