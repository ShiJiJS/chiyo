import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

class _Repository extends MemoryInformationRepository
    implements AdditionalApprovalRepository {
  final receipts = <String, InformationApprovalReceipt>{};
  bool failBefore = false,
      loseReply = false,
      failRead = false,
      failReadAfterWrite = false;
  @override
  Future<InformationApprovalReceipt?> additionalApprovalReceipt(
    String id,
  ) async {
    if (failRead) throw StateError('synthetic read unavailable');
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
      failRead = failReadAfterWrite;
      throw StateError('synthetic rollback');
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
      failRead = failReadAfterWrite;
      throw StateError('synthetic lost reply');
    }
  }
}

void main() {
  for (final committed in [false, true]) {
    test(
      'mixed revoke unknown result blocks reads until exact receipt resolves committed=$committed',
      () async {
        final repo = _Repository();
        final service = InformationService(
          repository: repo,
          credentialExecutableInspector: (p, r) async =>
              ExecutableIdentity(p, 10, 100, 'sha256:fixture'),
        );
        addTearDown(service.close);
        final c = await service.owner.createStringCredential(
          name: '合成凭据',
          publicPurpose: '',
          secret: 'SYNTHETIC',
        );
        await service.owner.updateCredentialMetadata(
          c.id,
          c.revision,
          name: c.name,
          publicPurpose: '',
          privateNote: '',
          suggestedBinding: 'GH_TOKEN',
          discoverable: true,
        );
        final item = await service.owner.createInformation('合成资料', '', [
          const FieldInput('字段', '', 'SYNTHETIC-FIELD'),
        ]);
        final field = FieldRef(item.id, item.fields.single.id),
            session = service.agent.openSession('合成聊天');
        final r = await service.agent.requestCredentialUse(
          session,
          CredentialUseInput.fromJson({
            'protocolVersion': 2,
            'command': 'request-use',
            'purpose': '合成撤销',
            'credentials': [
              {'alias': 'token', 'credentialId': c.id, 'version': c.version},
            ],
            'readFields': [field.toJson()],
            'launch': {
              'receiver': 'gh_token',
              'executable': Platform.resolvedExecutable,
              'argv': ['api', 'user', '--method', 'GET'],
              'cwd': Directory.current.path,
              'env': {
                'GH_TOKEN': {'secret': 'token'},
              },
            },
          }),
        );
        await service.owner.decideCredentialUse(
          r.id,
          approveCredential: false,
          fields: [field],
        );
        final bearer = service.agent.claim(session, r.id).token;
        expect(await service.agent.read(bearer, field), 'SYNTHETIC-FIELD');
        repo.failBefore = !committed;
        repo.loseReply = committed;
        repo.failReadAfterWrite = true;
        final result = service.owner.performAdditionalApproval(
          operationId: 'revoke-original',
          requestId: r.id,
          kind: 'credential',
          action: InformationApprovalAction.revoke,
          reviewToken: 'a' * 64,
          commandDigest: 'b' * 64,
          validate: () {},
          decide: () => service.owner.revokeCredentialRequest(r.id),
        );
        await expectLater(result, throwsA(isA<CredentialUseFailure>()));
        await expectLater(
          service.agent.read(bearer, field),
          throwsA(isA<AccessFailure>()),
        );
        await expectLater(
          service.owner.additionalApprovalReceipt('revoke-original'),
          throwsA(isA<StateError>()),
        );
        repo.failBefore = false;
        repo.loseReply = false;
        repo.failRead = false;
        final receipt = await service.owner.additionalApprovalReceipt(
          'revoke-original',
        );
        expect(receipt != null, committed);
        if (committed) {
          await expectLater(
            service.agent.read(bearer, field),
            throwsA(isA<AccessFailure>()),
          );
        } else {
          expect(await service.agent.read(bearer, field), 'SYNTHETIC-FIELD');
        }
        if (committed) {
          final unknown = await service.agent.requestCredentialUse(
            session,
            CredentialUseInput.fromJson(r.toRequestInputJson()),
          );
          repo.loseReply = true;
          repo.failReadAfterWrite = true;
          await expectLater(
            service.owner.performAdditionalApproval(
              operationId: 'unknown-approve',
              requestId: unknown.id,
              kind: 'credential',
              action: InformationApprovalAction.approve,
              reviewToken: 'a' * 64,
              commandDigest: 'b' * 64,
              validate: () {},
              decide: () => service.owner.decideCredentialUse(
                unknown.id,
                approveCredential: true,
                fields: [field],
              ),
            ),
            throwsA(isA<CredentialUseFailure>()),
          );
          final saved = service.owner.credentialUseRequests.singleWhere(
            (v) => v.id == unknown.id,
          );
          expect(service.owner.credentialGrantState(saved), 'revoked');
          expect(service.owner.credentialUseDecisionUnconfirmed(saved), true);
          repo.failRead = false;
          expect(
            await service.owner.additionalApprovalReceipt('unknown-approve'),
            isNotNull,
          );
          // Metadata readback is not a second approval or an authority activation.
          expect(service.owner.credentialGrantState(saved), 'revoked');
          await expectLater(
            Future<void>.sync(
              () => service.owner.checkCredentialUseEligibility(saved),
            ),
            throwsA(isA<CredentialUseFailure>()),
          );
          expect(service.owner.credentialFieldGrantState(saved), 'revoked');
          final confirmed = await service.agent.requestCredentialUse(
            session,
            CredentialUseInput.fromJson(r.toRequestInputJson()),
          );
          repo.failReadAfterWrite = false;
          await service.owner.performAdditionalApproval(
            operationId: 'resolved-in-original-call',
            requestId: confirmed.id,
            kind: 'credential',
            action: InformationApprovalAction.approve,
            reviewToken: 'a' * 64,
            commandDigest: 'b' * 64,
            validate: () {},
            decide: () => service.owner.decideCredentialUse(
              confirmed.id,
              approveCredential: true,
              fields: [field],
            ),
          );
          expect(
            await service.agent.read(
              service.agent.claim(session, confirmed.id).token,
              field,
            ),
            'SYNTHETIC-FIELD',
          );
        }
      },
    );
  }
}
