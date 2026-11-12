import 'package:info_core/info_core.dart';
import 'package:info_core/server_state.dart';
import 'package:test/test.dart';
import 'online_runtime_failure_test.dart' show FaultingServerRepository;

class ReplyLossRepository extends FaultingServerRepository {
  bool loseCommitReply = false;
  @override
  Future<ServerStateSnapshot> commitServerState(
    ServerStateSnapshot expected,
    Map<String, Object?> payload,
  ) async {
    final saved = await super.commitServerState(expected, payload);
    if (loseCommitReply) {
      throw StateError('Synthetic private checkpoint reply loss');
    }
    return saved;
  }
}

void main() {
  for (final committed in [false, true]) {
    test(
      'private material checkpoint failure withholds response and cannot redeliver after reopen; committed=$committed',
      () async {
        final repo = ReplyLossRepository();
        var runtime = await OnlineInformationRuntime.open(repository: repo);
        var service = runtime.service;
        final credential = await runtime.run(() async {
          final c = await service.owner.createStringCredential(
            name: 'Synthetic',
            publicPurpose: '',
            secret: 'SYNTHETIC_CHECKPOINT_SECRET',
          );
          return service.owner.updateCredentialMetadata(
            c.id,
            c.revision,
            name: c.name,
            publicPurpose: '',
            privateNote: '',
            suggestedBinding: 'password',
            discoverable: true,
          );
        });
        final session = await runtime.run(
          () => service.agent.openSession('Synthetic checkpoint fill'),
        );
        const device = 'synthetic_device_12345';
        final input = FocusedFillInput.fromJson({
          'protocolVersion': 2,
          'command': 'request-use',
          'purpose': 'Synthetic',
          'credentials': [
            {'alias': 'password', 'credentialId': credential.id, 'version': 1},
          ],
          'fill': {
            'targetHint': '',
            'application': {
              'executable': '/foreign-device/Browser',
              'sha256': 'a' * 64,
            },
          },
        });
        final request = await runtime.run(
          () => service.agent.requestDeviceFocusedFill(device, session, input),
        );
        await runtime.run(
          () => service.owner.decideCredentialUse(
            request.id,
            approveCredential: true,
          ),
        );
        final operation = FocusedFillOperationInput.fromJson({
          'protocolVersion': 2,
          'command': 'fill-use',
          'requestId': request.id,
          'operationId': 'checkpoint',
        });
        final claim = await runtime.run(
          () =>
              service.agent.beginDeviceFocusedFill(device, session, operation),
        );
        repo.failCommit = !committed;
        repo.loseCommitReply = committed;
        var published = false;
        await expectLater(
          runtime
              .run(
                () => service.agent.claimDeviceFocusedFillMaterial(
                  device,
                  claim['fillId'] as String,
                  claim['fillCapability'] as String,
                  input.fill.application,
                ),
              )
              .then((_) {
                published = true;
              }),
          throwsStateError,
        );
        expect(published, false);
        expect(runtime.isAvailable, false);
        await runtime.close();
        repo.failCommit = false;
        repo.loseCommitReply = false;
        runtime = await OnlineInformationRuntime.open(repository: repo);
        service = runtime.service;
        addTearDown(runtime.close);
        expect(
          (await runtime.run(
            () => service.agent.deviceFocusedFillStatus(
              device,
              session,
              operation,
            ),
          ))['fillState'],
          'unknown',
        );
        await expectLater(
          runtime.run(
            () => service.agent.claimDeviceFocusedFillMaterial(
              device,
              claim['fillId'] as String,
              claim['fillCapability'] as String,
              input.fill.application,
            ),
          ),
          throwsA(isA<CredentialUseFailure>()),
        );
        final duplicate = await runtime.run(
          () =>
              service.agent.beginDeviceFocusedFill(device, session, operation),
        );
        expect(duplicate['duplicate'], true);
        expect(duplicate.containsKey('fillCapability'), false);
        expect(duplicate.containsKey('materialBase64'), false);
      },
    );
  }
}
