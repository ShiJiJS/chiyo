import 'dart:async';
import 'dart:io';
import 'package:info_remote/owner_client.dart';
import 'package:info_remote/agent_connection.dart';
import 'package:test/test.dart';
import 'support/tls_fixture.dart';

void main() {
  test(
    'whole-response deadlines abort a peer that never finishes its body',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'chiyo-stream-timeout-',
      );
      final files = await createTlsFixture(root);
      final tls = SecurityContext()
        ..useCertificateChain(files.certificate)
        ..usePrivateKey(files.privateKey);
      final trust = SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificates(files.ca);
      final server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        tls,
      );
      final timers = <Timer>[];
      server.listen((r) async {
        await r.drain<void>();
        r.response.headers.set(
          'x-chiyo-server-id',
          'synthetic-deadline-server',
        );
        if (r.uri.path == '/v1/server') {
          r.response.write(
            '{"serverId":"synthetic-deadline-server","protocolVersion":1}',
          );
          await r.response.close();
          return;
        }
        r.response.write('{"status":"ok","padding":"');
        await r.response.flush();
        final timer = Timer.periodic(const Duration(milliseconds: 50), (timer) {
          r.response.write(' ');
          unawaited(
            r.response.flush().catchError((Object _) {
              timer.cancel();
            }),
          );
        });
        timers.add(timer);
        unawaited(r.response.done.catchError((Object _) {}));
      });
      final address = Uri.parse('https://127.0.0.1:${server.port}');
      final owner = await OwnerClient.connect(
        address: address,
        token: 'SYNTHETIC',
        trust: trust,
      );
      final agent = AgentConnection(
        AgentConnectionProfile(
          address: address,
          serverId: 'synthetic-deadline-server',
          deviceToken:
              'AAAAAAAAAAAAAAAAAAAAAA.BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB',
          certificate: await File(files.ca).readAsString(),
        ),
      );
      try {
        expect(
          (await agent.call(
            '/capabilities',
            {},
            timeout: const Duration(milliseconds: 150),
          ))['status'],
          'service_unavailable',
        );
        final watch = Stopwatch()..start();
        await expectLater(
          owner.request('GET', '/v1/owner/catalog'),
          throwsA(
            isA<RemoteFailure>().having(
              (e) => e.code,
              'code',
              'server_timeout',
            ),
          ),
        );
        expect(watch.elapsed, lessThan(const Duration(seconds: 20)));
      } finally {
        owner.close();
        agent.close();
        for (final t in timers) {
          t.cancel();
        }
        await server.close(force: true);
        await root.delete(recursive: true);
      }
    },
  );
}
