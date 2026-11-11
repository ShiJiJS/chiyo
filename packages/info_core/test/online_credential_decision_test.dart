import 'dart:convert';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';
import 'online_runtime_failure_test.dart' show FaultingServerRepository;

class DecisionRepository extends FaultingServerRepository
    implements AdditionalApprovalRepository {
  final receipts = <String, InformationApprovalReceipt>{};
  bool failBefore = false, loseReply = false, failRead = false;
  @override
  Future<InformationApprovalReceipt?> additionalApprovalReceipt(
    String id,
  ) async {
    if (failRead) throw StateError('Synthetic receipt read failed');
    return receipts[id];
  }

  @override
  Future<int> additionalApprovalRevision(String id) async =>
      receipts.values.where((r) => r.requestId == id).length;
  @override
  Future<void> commitCredentialRuntime(
    List<CredentialUseRequest> requests,
    List<CredentialExecution> executions, {
    GrantHistory? fieldGrant,
    RequestHistory? fieldRequest,
    void Function()? validate,
  }) async {
    final op = pendingAdditionalApproval;
    if (op != null && failBefore) {
      failRead = true;
      throw StateError('Synthetic rollback');
    }
    validate?.call();
    final receipt = op?.complete(op.command.requestId, op.kind, 1);
    await super.commitCredentialRuntime(
      requests,
      executions,
      fieldGrant: fieldGrant,
      fieldRequest: fieldRequest,
      validate: validate,
    );
    if (receipt != null) receipts[receipt.operationId] = receipt;
    if (op != null && loseReply) {
      failRead = true;
      throw StateError('Synthetic lost commit reply');
    }
  }
}

void main() {
  for (final committed in [false, true]) {
    for (final revoke in [false, true]) {
      for (final terminal
          in committed && !revoke
              ? ['none', 'ended', 'disabled', 'rotated', 'expired']
              : revoke
              ? ['none', 'ended', 'expired']
              : ['none']) {
        test(
          'original uncertain ${revoke ? 'revoke' : 'approval'} survives restart; committed=$committed, terminal=$terminal',
          () async {
            final repo = DecisionRepository();
            var now = DateTime.utc(2026, 11, 8);
            var runtime = await OnlineInformationRuntime.open(
              repository: repo,
              clock: () => now,
            );
            addTearDown(() => runtime.close());
            final c = await runtime.run(() async {
              final c = await runtime.service.owner.createStringCredential(
                name: 'Synthetic',
                publicPurpose: '',
                secret: 'SYNTHETIC_TOKEN',
              );
              return runtime.service.owner.updateCredentialMetadata(
                c.id,
                c.revision,
                name: c.name,
                publicPurpose: '',
                privateNote: '',
                suggestedBinding: 'GH_TOKEN',
                discoverable: true,
              );
            });
            final item = await runtime.run(
              () => runtime.service.owner.createInformation('Synthetic', '', [
                const FieldInput('Allowed', '', 'SYNTHETIC_ALLOWED'),
                const FieldInput('Outside', '', 'SYNTHETIC_OUTSIDE'),
              ]),
            );
            final fields = item.fields
                .map((f) => FieldRef(item.id, f.id))
                .toList();
            final session = await runtime.run(
              () => runtime.service.agent.openSession('Synthetic chat'),
            );
            final input = CredentialUseInput.fromJson({
              'protocolVersion': 2,
              'command': 'request-use',
              'purpose': 'Synthetic',
              'credentials': [
                {'alias': 'token', 'credentialId': c.id, 'version': c.version},
              ],
              'readFields': fields.map((f) => f.toJson()).toList(),
              'launch': {
                'receiver': 'gh_token',
                'executable': '/device/gh',
                'argv': ['api', 'user'],
                'cwd': '/device/work',
                'env': {
                  'GH_TOKEN': {'secret': 'token'},
                },
              },
            }, allowPortableLaunchPaths: true);
            final prepared = DeviceCredentialLaunch.fromPrivateJson({
              'version': 1,
              'planHash': input.launch.planHash,
              'executable': {
                'path': input.launch.path,
                'byteLength': 1,
                'modifiedMicros': 1,
                'sha256': 'sha256:${'a' * 64}',
              },
              'cwd': input.launch.cwd,
            });
            final r = await runtime.run(
              () => runtime.service.agent.requestDeviceCredentialUse(
                'synthetic_device_12345',
                session,
                input,
                prepared,
              ),
            );
            Future<void> approve() => runtime.service.owner.decideCredentialUse(
              r.id,
              approveCredential: true,
              fields: [fields.first],
              fieldLifetime: const Duration(hours: 4),
            );
            ClaimedGrant? original;
            if (revoke) {
              await runtime.run(approve);
              original = await runtime.run(
                () => runtime.service.agent.claim(session, r.id),
              );
            }
            repo.failBefore = !committed;
            repo.loseReply = committed;
            await expectLater(
              runtime.run(
                () => runtime.service.owner.performAdditionalApproval(
                  operationId: 'original-decision',
                  requestId: r.id,
                  kind: 'credential',
                  action: revoke
                      ? InformationApprovalAction.revoke
                      : InformationApprovalAction.approve,
                  reviewToken: 'a' * 64,
                  commandDigest: 'b' * 64,
                  validate: () {},
                  decide: revoke
                      ? () =>
                            runtime.service.owner.revokeCredentialRequest(r.id)
                      : approve,
                ),
              ),
              throwsA(isA<CredentialUseFailure>()),
            );
            final payload = jsonEncode(repo.snapshot.payload);
            expect(payload, contains('original-decision'));
            expect(payload, isNot(contains('SYNTHETIC_TOKEN')));
            expect(
              runtime.service.owner.credentialUseDecisionUnconfirmed(
                runtime.service.owner.credentialUseRequests.single,
              ),
              true,
            );
            await expectLater(
              runtime.run(() => runtime.service.agent.claim(session, r.id)),
              throwsA(anyOf(isA<AccessFailure>(), isA<CredentialUseFailure>())),
            );
            if (original != null) {
              await expectLater(
                runtime.run(
                  () =>
                      runtime.service.agent.read(original!.token, fields.first),
                ),
                throwsA(isA<AccessFailure>()),
              );
            }
            await runtime.close();
            now = now.add(const Duration(minutes: 2));
            // Missing receipts must not contradict a committed fact or turn
            // history into permission, even if the private intent is valid.
            if (committed && terminal == 'none') {
              final savedReceipt = repo.receipts.remove('original-decision')!;
              final snapshot = jsonEncode(repo.snapshot.payload);
              repo.failRead = false;
              await expectLater(
                OnlineInformationRuntime.open(
                  repository: repo,
                  clock: () => now,
                ),
                throwsFormatException,
              );
              expect(jsonEncode(repo.snapshot.payload), snapshot);
              repo.receipts['original-decision'] = savedReceipt;
              repo.failRead = true;
            }
            // Receipt storage remains unavailable across a real runtime recreation.
            runtime = await OnlineInformationRuntime.open(
              repository: repo,
              clock: () => now,
            );
            expect(
              runtime.service.owner.credentialUseDecisionUnconfirmed(
                runtime.service.owner.credentialUseRequests.single,
              ),
              true,
            );
            await expectLater(
              runtime.run(() => runtime.service.agent.claim(session, r.id)),
              throwsA(anyOf(isA<AccessFailure>(), isA<CredentialUseFailure>())),
            );
            if (terminal == 'ended') {
              await runtime.run(
                () => runtime.service.agent.endSession(session),
              );
            } else if (terminal == 'disabled') {
              final current = repo.managedCredentials.single;
              await runtime.run(
                () => runtime.service.owner.setCredentialEnabled(
                  current.id,
                  current.revision,
                  false,
                ),
              );
            } else if (terminal == 'rotated') {
              final current = repo.managedCredentials.single;
              await runtime.run(
                () => runtime.service.owner.rotateStringCredential(
                  current.id,
                  current.revision,
                  'SYNTHETIC_REPLACED',
                ),
              );
            } else if (terminal == 'expired') {
              now = now.add(const Duration(hours: 4));
            }
            if (terminal != 'none') {
              await runtime.close();
              runtime = await OnlineInformationRuntime.open(
                repository: repo,
                clock: () => now,
              );
              expect(
                runtime.service.owner.credentialUseDecisionUnconfirmed(
                  runtime.service.owner.credentialUseRequests.single,
                ),
                true,
              );
            }
            repo.failRead = false;
            repo.failBefore = false;
            repo.loseReply = false;
            final receipt = await runtime.run(
              () => runtime.service.owner.additionalApprovalReceipt(
                'original-decision',
              ),
            );
            expect(receipt != null, committed);
            expect(
              runtime.service.owner.credentialUseDecisionUnconfirmed(
                runtime.service.owner.credentialUseRequests.single,
              ),
              false,
            );
            final intent =
                (repo.snapshot.payload['textRuntime']
                        as Map)['credentialRuntime']
                    as Map;
            expect(intent['decisions'], isEmpty);
            expect(repo.receipts.length, committed ? 1 : 0);
            final active = revoke ? !committed : committed;
            if (terminal != 'none') {
              final state = runtime.service.owner.credentialGrantState(
                runtime.service.owner.credentialUseRequests.single,
              );
              expect(state, isNot('available'));
              if (terminal == 'ended') {
                expect(repo.grantHistory.single.active, false);
                expect(
                  repo.grantHistory.single.events.last.kind,
                  revoke && committed
                      ? GrantEventKind.revoked
                      : GrantEventKind.ended,
                );
              }
              if (terminal == 'ended' || terminal == 'expired') {
                await expectLater(
                  runtime.run(() => runtime.service.agent.claim(session, r.id)),
                  throwsA(
                    anyOf(isA<AccessFailure>(), isA<CredentialUseFailure>()),
                  ),
                );
              }
              await runtime.close();
              runtime = await OnlineInformationRuntime.open(
                repository: repo,
                clock: () => now,
              );
              expect(
                runtime.service.owner.credentialGrantState(
                  runtime.service.owner.credentialUseRequests.single,
                ),
                isNot('available'),
              );
            } else if (active) {
              final grant = await runtime.run(
                () => runtime.service.agent.claim(session, r.id),
              );
              expect(grant.fields, [fields.first]);
              expect(
                grant.expiresAt,
                DateTime.utc(2026, 11, 8).add(const Duration(hours: 4)),
              );
              if (original != null) expect(grant.token, original.token);
              expect(
                await runtime.run(
                  () => runtime.service.agent.read(grant.token, fields.first),
                ),
                'SYNTHETIC_ALLOWED',
              );
              await expectLater(
                runtime.run(
                  () => runtime.service.agent.read(grant.token, fields.last),
                ),
                throwsA(isA<AccessFailure>()),
              );
              expect(
                runtime.service.owner.credentialGrantState(
                  runtime.service.owner.credentialUseRequests.single,
                ),
                'available',
              );
              // Receipt readback and reopen do not extend either original deadline.
              now = DateTime.utc(2026, 11, 8).add(const Duration(minutes: 121));
              await runtime.close();
              runtime = await OnlineInformationRuntime.open(
                repository: repo,
                clock: () => now,
              );
              expect(
                runtime.service.owner.credentialGrantState(
                  runtime.service.owner.credentialUseRequests.single,
                ),
                'expired',
              );
              expect(
                await runtime.run(
                  () => runtime.service.agent.read(grant.token, fields.first),
                ),
                'SYNTHETIC_ALLOWED',
              );
            } else {
              await expectLater(
                runtime.run(() => runtime.service.agent.claim(session, r.id)),
                throwsA(
                  anyOf(isA<AccessFailure>(), isA<CredentialUseFailure>()),
                ),
              );
            }
          },
        );
      }
    }
  }
}
