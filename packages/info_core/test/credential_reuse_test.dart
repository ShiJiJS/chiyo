import 'package:info_core/info_core.dart';
import 'package:test/test.dart';
import 'credential_use_test.dart' show tokenRequest;

void main() {
  test(
    'v2 authorization records its protocol instead of silently becoming a v1 permit',
    () async {
      final (service, _, request) = await tokenRequest(protocolVersion: 2);
      addTearDown(service.close);
      await service.owner.decideCredentialUse(
        request.id,
        approveCredential: true,
      );
      final stored = service.owner.credentialUseRequests.single.toStorageJson();
      expect(stored['protocolVersion'], 2);
      expect(
        CredentialUseRequest.fromJson(
          stored,
        ).toStorageJson()['protocolVersion'],
        2,
      );
      expect(stored['attemptConsumed'], isFalse);
    },
  );

  test('unknown protocol version is explicitly refused', () {
    expect(
      () => CredentialUseInput.fromJson({'protocolVersion': 3}),
      throwsA(
        isA<CredentialUseFailure>().having(
          (e) => e.code,
          'code',
          'unsupported_protocol',
        ),
      ),
    );
  });

  test(
    'an explicit null or non-integer protocol cannot silently select v1',
    () {
      for (final version in [null, 2.0, '2', true, 0, -1]) {
        expect(
          () => CredentialUseInput.fromJson({'protocolVersion': version}),
          throwsA(
            isA<CredentialUseFailure>().having(
              (e) => e.code,
              'code',
              'unsupported_protocol',
            ),
          ),
        );
      }
    },
  );

  test('v2 permission cannot enter the legacy one-shot consume path', () async {
    final (service, session, request) = await tokenRequest(protocolVersion: 2);
    addTearDown(service.close);
    await service.owner.decideCredentialUse(
      request.id,
      approveCredential: true,
    );
    await expectLater(
      service.agent.consumeCredentialUse(session, request.id),
      throwsA(
        isA<CredentialUseFailure>().having(
          (e) => e.code,
          'code',
          'operation_required',
        ),
      ),
    );
    expect(service.owner.credentialUseRequests.single.attemptConsumed, isFalse);
    expect(service.owner.credentialExecutions, isEmpty);
  });
}
