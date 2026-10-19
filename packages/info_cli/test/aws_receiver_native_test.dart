import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';
import 'support/runtime_harness.dart';

const access = 'TEST_ACCESS_ONLY';
const secret = 'SYNTHETIC_NOT_A_REAL_SECRET';
List<int> mac(List<int> key, String value) =>
    Hmac(sha256, key).convert(utf8.encode(value)).bytes;

/// Independent receiver verifies a full SigV4 signature. A returned HTTP200 or
/// matching access-key name alone never counts as authentication success.
bool authenticates(HttpRequest request, List<int> body) {
  try {
    final auth = request.headers.value('authorization')!;
    final scheme = auth.substring(0, auth.indexOf(' '));
    final parts = {
      for (final part in auth.substring(auth.indexOf(' ') + 1).split(','))
        part.trim().split('=').first: part.trim().substring(
          part.trim().indexOf('=') + 1,
        ),
    };
    final credential = parts['Credential']!.split('/');
    if (scheme != 'AWS4-HMAC-SHA256' ||
        credential.length != 5 ||
        credential[0] != access ||
        credential[2] != 'us-east-1' ||
        !{'ssm', 'sts'}.contains(credential[3]) ||
        credential[4] != 'aws4_request') {
      return false;
    }
    final signed = parts['SignedHeaders']!;
    final names = signed.split(';');
    if ((names.toList()..sort()).join(';') != signed ||
        !names.contains('host') ||
        !names.contains('x-amz-date')) {
      return false;
    }
    final headers = names
        .map(
          (n) =>
              '$n:${request.headers.value(n)!.trim().replaceAll(RegExp(r'\s+'), ' ')}\n',
        )
        .join();
    final timestamp = request.headers.value('x-amz-date')!;
    if (timestamp.substring(0, 8) != credential[1]) return false;
    final query =
        request.uri.queryParametersAll.entries
            .expand(
              (e) => e.value.map(
                (v) =>
                    '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(v)}',
              ),
            )
            .toList()
          ..sort();
    final canonical = [
      request.method,
      request.uri.path.isEmpty ? '/' : request.uri.path,
      query.join('&'),
      headers,
      signed,
      sha256.convert(body).toString(),
    ].join('\n');
    final scope = credential.skip(1).join('/');
    final signing = mac(
      mac(
        mac(mac(utf8.encode('AWS4$secret'), credential[1]), credential[2]),
        credential[3],
      ),
      'aws4_request',
    );
    final expected = mac(
      signing,
      [
        scheme,
        timestamp,
        scope,
        sha256.convert(utf8.encode(canonical)).toString(),
      ].join('\n'),
    ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return expected == parts['Signature'];
  } on Object {
    return false;
  }
}

void main() {
  final executable = Platform.environment['D7_AWS_EXE'];
  for (final protocol in [1, 2]) {
    test(
      'v$protocol real AWS CLI uses only approved static file credentials for signed reads and writes, and rejects the wrong secret',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        var valid = 0, invalid = 0;
        final parameters = <String, String>{};
        final handling = server.listen((request) async {
          final body = await request.fold<List<int>>(
            [],
            (b, c) => b..addAll(c),
          );
          final authenticated = authenticates(request, body);
          request.response.headers.contentType = ContentType(
            'application',
            'x-amz-json-1.1',
            charset: 'utf-8',
          );
          if (!authenticated) {
            invalid++;
            request.response.statusCode = 403;
            request.response.write(
              jsonEncode({
                '__type': 'UnrecognizedClientException',
                'message': 'Synthetic signature rejected',
              }),
            );
          } else {
            valid++;
            final action = request.headers
                .value('x-amz-target')
                ?.split('.')
                .last;
            if (action == 'PutParameter') {
              final input =
                  jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
              parameters[input['Name'] as String] = input['Value'] as String;
              request.response.write(
                jsonEncode({'Version': 1, 'Tier': 'Standard'}),
              );
            } else if (action == 'GetParameter') {
              final input =
                  jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
              request.response.write(
                jsonEncode({
                  'Parameter': {
                    'Name': input['Name'],
                    'Type': 'String',
                    'Value': parameters[input['Name']],
                    'Version': 1,
                  },
                }),
              );
            } else {
              request.response.headers.contentType = ContentType('text', 'xml');
              request.response.write(
                '<GetCallerIdentityResponse xmlns="https://sts.amazonaws.com/doc/2011-06-15/"><GetCallerIdentityResult><Arn>arn:aws:iam::000000000000:user/fixture</Arn><UserId>LOCALFIXTURE</UserId><Account>000000000000</Account></GetCallerIdentityResult><ResponseMetadata><RequestId>synthetic-request</RequestId></ResponseMetadata></GetCallerIdentityResponse>',
              );
            }
          }
          await request.response.close();
        });
        addTearDown(() async {
          await server.close(force: true);
          await handling.cancel();
        });
        final h = await RuntimeHarness.create(
          executablePath: executable!,
          inspectTool: true,
          enableReusableCredentialUse: protocol == 2,
          fileBytes: utf8.encode(
            '[default]\naws_access_key_id=$access\naws_secret_access_key=$secret\n',
          ),
        );
        addTearDown(h.close);
        final reusableRequests = <RuntimeHarness, String>{};
        var operationNumber = 0;
        Future<Map<String, dynamic>> run(
          RuntimeHarness harness,
          List<String> argv,
          int expectedExit,
        ) async {
          final fullArgv = <Object?>[
            ...argv,
            '--region',
            'us-east-1',
            '--endpoint-url',
            'http://127.0.0.1:${server.port}',
            '--output',
            'json',
            '--no-cli-pager',
          ];
          final request = protocol == 2 && reusableRequests.containsKey(harness)
              ? reusableRequests[harness]!
              : await harness.approve(
                  argv: fullArgv,
                  protocolVersion: protocol,
                );
          if (protocol == 2) reusableRequests[harness] = request;
          final approved = harness.service.owner.credentialUseRequests
              .singleWhere((r) => r.id == request);
          final deadline = approved.credentialExpiresAt;
          final call = <String, dynamic>{
            'protocolVersion': protocol,
            'command': 'run-use',
            'requestId': request,
            if (protocol == 2) ...{
              'operationId': 'aws-${++operationNumber}',
              'launch': {
                ...Map<String, dynamic>.from(
                  approved.toRequestInputJson()['launch'] as Map,
                ),
                'argv': fullArgv,
              },
            },
          };
          final result = await harness.client.execute(call);
          expect(result['status'], 'accepted', reason: jsonEncode(result));
          await harness.client.drainCredentialExecutions();
          if (protocol == 2) {
            final duplicate = await harness.client.execute(call);
            expect(duplicate['duplicate'], isTrue);
            expect(duplicate['executionId'], result['executionId']);
            expect(
              harness.service.owner.credentialUseRequests
                  .singleWhere((r) => r.id == request)
                  .credentialExpiresAt,
              deadline,
            );
            expect(
              harness.service.owner.credentialGrantState(
                harness.service.owner.credentialUseRequests.singleWhere(
                  (r) => r.id == request,
                ),
              ),
              'available',
            );
          }
          final status = await harness.client.execute({
            'command': 'execution-status',
            'executionId': result['executionId'],
          });
          if (status['executionState'] != 'exited') {
            final diagnostic = await harness.client.execute({
              'command': 'execution-output',
              'executionId': result['executionId'],
              'cursor': 0,
              'limit': 16,
            });
            final errors = utf8.decode([
              for (final dynamic c in (diagnostic['chunks'] as List? ?? []))
                if (c['stream'] == 'stderr')
                  ...base64Decode(c['dataBase64'] as String),
            ], allowMalformed: true);
            fail(
              'Synthetic local AWS receiver: ${jsonEncode(status)}; worker stderr: $errors',
            );
          }
          expect(
            status['executionState'],
            'exited',
            reason: jsonEncode(status),
          );
          expect(status['exitCode'], expectedExit);
          final cleaned = await harness.waitForMaterialCleanup(
            result['executionId'] as String,
          );
          expect(cleaned['exitCode'], expectedExit);
          expect(cleaned['cleanupState'], 'complete');
          final response = await harness.client.execute({
            'command': 'execution-output',
            'executionId': result['executionId'],
          });
          final bytes = (response['chunks'] as List)
              .where((c) => c['stream'] == 'stdout')
              .expand<int>((c) => base64Decode(c['dataBase64'] as String))
              .toList();
          return expectedExit == 0
              ? jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>
              : {};
        }

        expect(
          (await run(h, ['sts', 'get-caller-identity'], 0))['UserId'],
          'LOCALFIXTURE',
        );
        expect(
          (await run(h, [
            'ssm',
            'put-parameter',
            '--name',
            '/fixture/example',
            '--value',
            'public-fixture-value',
            '--type',
            'String',
          ], 0))['Version'],
          1,
        );
        expect(
          ((await run(h, [
                'ssm',
                'get-parameter',
                '--name',
                '/fixture/example',
              ], 0))['Parameter']
              as Map)['Value'],
          'public-fixture-value',
        );
        final wrong = await RuntimeHarness.create(
          executablePath: executable,
          inspectTool: true,
          enableReusableCredentialUse: protocol == 2,
          fileBytes: utf8.encode(
            '[default]\naws_access_key_id=$access\naws_secret_access_key=WRONG_SYNTHETIC_SECRET\n',
          ),
        );
        addTearDown(wrong.close);
        await run(wrong, [
          'ssm',
          'get-parameter',
          '--name',
          '/fixture/example',
        ], 254);
        if (protocol == 2) {
          expect(h.service.owner.credentialUseRequests, hasLength(1));
          expect(h.service.owner.credentialExecutions, hasLength(3));
          expect(wrong.service.owner.credentialUseRequests, hasLength(1));
        }
        expect(valid, 3);
        expect(invalid, 1);
      },
      skip: !Platform.isWindows || executable == null,
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }
}
