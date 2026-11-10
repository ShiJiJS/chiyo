import 'dart:convert';
import 'package:info_core/info_core.dart';
import 'package:info_remote/owner_client.dart';
import 'package:info_workspace/credential_use_transport.dart';
import 'package:test/test.dart';
import 'support/device_credential_fixture.dart';

void main() {
  test(
    'authenticated records retain their original approval and history after encrypted restart without material',
    () async {
      final fixture = await DeviceCredentialFixture.create();
      addTearDown(fixture.dispose);
      final operation = await fixture.tokenOperation();
      final id = operation['requestId'] as String;
      final ref = fixture
          .runtime
          .service
          .owner
          .credentialUseRequests
          .single
          .credentialId;
      Future<String> records() async {
        final requests = await fixture.owner.request(
          'GET',
          '/v1/owner/credentials/$ref/requests',
        );
        final history = await fixture.owner.request(
          'GET',
          '/v1/owner/credentials/$ref/history',
        );
        expect(
          credentialUseRequestFromJson(
            (requests['requests'] as List).single,
          ).id,
          id,
        );
        expect(
          credentialUseHistoryFromJson(
            (history['history'] as List).single,
          ).grantId,
          id,
        );
        final encoded = jsonEncode([requests, history]);
        for (final secret in [
          'SYNTHETIC_LOST_CLAIM_TOKEN',
          'sessionSecret',
          'executionCapability',
          'deviceToken',
        ]) {
          expect(encoded, isNot(contains(secret)));
        }
        return encoded;
      }

      final before = await records();
      await fixture.reopen();
      expect(await records(), before);
      await expectLater(
        OwnerClient.connect(
          address: fixture.owner.address,
          token: fixture.profiles.first.deviceToken,
          trust: fixture.trust,
        ),
        throwsA(
          isA<RemoteFailure>().having((e) => e.code, 'code', 'unauthorized'),
        ),
      );
    },
  );
}
