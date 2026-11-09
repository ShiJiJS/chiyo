import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:info_cli/agent_client.dart';
import 'package:info_remote/agent_connection.dart';
import 'package:test/test.dart';
import 'support/tls_fixture.dart';

void main() {
  test(
    'remote CLI tolerates a slow NAS while explicit deadlines stay bounded',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'nas-response-latency-',
      );
      final files = await createTlsFixture(root);
      final tls = SecurityContext()
        ..useCertificateChain(files.certificate)
        ..usePrivateKey(files.privateKey);
      final server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        tls,
      );
      final pending = <Future<void>>[];
      final subscription = server.listen((request) {
        pending.add(() async {
          await request.drain<void>();
          await Future<void>.delayed(
            request.uri.path.endsWith('/bounded')
                ? const Duration(milliseconds: 250)
                : const Duration(seconds: 6),
          );
          request.response.headers.set(
            'x-chiyo-server-id',
            'synthetic-slow-nas',
          );
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'status': 'ok'}));
          await request.response.close();
        }());
      });
      final profile = AgentConnectionProfile(
        address: Uri.parse('https://127.0.0.1:${server.port}'),
        serverId: 'synthetic-slow-nas',
        deviceToken:
            'AAAAAAAAAAAAAAAAAAAAAA.BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB',
        certificate: await File(files.ca).readAsString(),
      );
      final direct = AgentConnection(profile);
      final cli = AgentClient.remote(profile);
      try {
        final replies = await Future.wait([
          direct.call('/capabilities', {}),
          cli.execute({'command': 'catalog'}),
        ]);
        expect(replies.map((r) => r['status']), everyElement('ok'));
        final watch = Stopwatch()..start();
        expect(
          (await direct.call(
            '/bounded',
            {},
            timeout: const Duration(milliseconds: 30),
          ))['status'],
          'service_unavailable',
        );
        expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
        await Future.wait(pending);
      } finally {
        direct.close();
        cli.close();
        await subscription.cancel();
        await server.close(force: true);
        await root.delete(recursive: true);
      }
    },
  );
}
