import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';
import 'support/runtime_harness.dart';

void main() {
  final executable = Platform.environment['D6_GH_EXE'];
  for (final protocol in [1, 2]) {
    test(
      'v$protocol actual gh rejects the injected synthetic Token without falling back to user authentication',
      () async {
        final h = await RuntimeHarness.create(
          executablePath: executable!,
          inspectTool: true,
          enableReusableCredentialUse: protocol == 2,
        );
        addTearDown(h.close);
        String? reusable;
        DateTime? deadline;
        final facts = <Map<String, dynamic>>[];
        for (final endpoint in ['user', 'user/repos']) {
          final argv = ['api', endpoint, '--method', 'GET'];
          final id =
              reusable ??
              await h.approve(argv: argv, protocolVersion: protocol);
          final approved = h.service.owner.credentialUseRequests.singleWhere(
            (r) => r.id == id,
          );
          if (protocol == 2) {
            reusable = id;
            deadline ??= approved.credentialExpiresAt;
          }
          final input = <String, dynamic>{
            'protocolVersion': protocol,
            'command': 'run-use',
            'requestId': id,
            if (protocol == 2) ...{
              'operationId': 'github-${endpoint.replaceAll('/', '-')}',
              'launch': {
                ...Map<String, dynamic>.from(
                  approved.toRequestInputJson()['launch'] as Map,
                ),
                'argv': argv,
              },
            },
          };
          final result = await h.client.execute(input);
          expect(result['status'], 'accepted', reason: jsonEncode(result));
          facts.add(result);
          await h.client.drainCredentialExecutions();
          final status = await h.client.execute({
            'command': 'execution-status',
            'executionId': result['executionId'],
          });
          facts.add(status);
          expect(status['executionState'], 'exited');
          expect(status['exitCode'], 1);
          expect(status['cleanupState'], 'not_needed');
          final output = await h.client.execute({
            'command': 'execution-output',
            'executionId': result['executionId'],
          });
          facts.add(output);
          final text = utf8.decode([
            for (final dynamic chunk in output['chunks'] as List)
              ...base64Decode(chunk['dataBase64'] as String),
          ], allowMalformed: true);
          expect(
            text,
            contains('HTTP 401'),
            reason:
                'A network failure is not authentication evidence; only the synthetic Token is supplied.',
          );
          expect(text, isNot(contains('synthetic-token')));
          if (protocol == 2) {
            final repeated = await h.client.execute(input);
            expect(repeated['duplicate'], isTrue);
            expect(repeated['executionId'], result['executionId']);
            expect(
              h.service.owner.credentialUseRequests.single.credentialExpiresAt,
              deadline,
            );
            expect(
              h.service.owner.credentialGrantState(
                h.service.owner.credentialUseRequests.single,
              ),
              'available',
            );
          }
        }
        expect(h.service.owner.credentialExecutions, hasLength(2));
        expect(
          h.service.owner.credentialUseRequests,
          hasLength(protocol == 2 ? 1 : 2),
        );
        expect(jsonEncode(facts), isNot(contains('synthetic-token')));
      },
      skip: (!Platform.isWindows && !Platform.isMacOS) || executable == null,
      timeout: const Timeout(Duration(seconds: 90)),
    );
  }
}
