import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_server/mounted_database_key_store.dart';
import 'package:info_server/online_server.dart';
import 'package:info_storage/info_storage.dart';
import 'package:test/test.dart';

void main() {
  test(
    'TLS owner saves survive a fresh connection and a full host reopen',
    () async {
      final root = await Directory.systemTemp.createTemp('chiyo-https-');
      addTearDown(() => root.delete(recursive: true));
      final cert = '${root.path}/certificate.pem';
      final privateKey = '${root.path}/tls.key';
      final ca = '${root.path}/ca.pem';
      final caKey = '${root.path}/ca.key';
      final csr = '${root.path}/server.csr';
      final extensions = File('${root.path}/server.ext');
      await extensions.writeAsString(
        'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=IP:127.0.0.1,DNS:localhost\n',
      );
      Future<void> openssl(List<String> args) async {
        final result = await Process.run('openssl', args);
        expect(
          result.exitCode,
          0,
          reason: 'Synthetic TLS certificate generation',
        );
      }

      await openssl([
        'req',
        '-x509',
        '-newkey',
        'rsa:2048',
        '-nodes',
        '-days',
        '1',
        '-keyout',
        caKey,
        '-out',
        ca,
        '-subj',
        '/CN=Chiyo synthetic CA',
        '-addext',
        'basicConstraints=critical,CA:TRUE',
        '-addext',
        'keyUsage=critical,keyCertSign,cRLSign',
      ]);
      await openssl([
        'req',
        '-new',
        '-newkey',
        'rsa:2048',
        '-nodes',
        '-keyout',
        privateKey,
        '-out',
        csr,
        '-subj',
        '/CN=localhost',
      ]);
      await openssl([
        'x509',
        '-req',
        '-in',
        csr,
        '-CA',
        ca,
        '-CAkey',
        caKey,
        '-CAcreateserial',
        '-days',
        '1',
        '-extfile',
        extensions.path,
        '-out',
        cert,
      ]);
      final tls = SecurityContext()
        ..useCertificateChain(cert)
        ..usePrivateKey(privateKey);
      final trusted = SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificates(ca);
      final key = File('${root.path}/database.key');
      await key.writeAsBytes(List.generate(32, (i) => i + 1));
      expect((await Process.run('chmod', ['600', key.path])).exitCode, 0);
      final keys = MountedDatabaseKeyStore(key.path);
      final token = base64Url.encode(List.filled(32, 19)).replaceAll('=', '');
      var repo = await EncryptedInformationRepository.open(
        '${root.path}/data',
        keys,
      );
      var service = InformationService(repository: repo);
      var server = await OnlineServer.start(
        service: service,
        tls: tls,
        ownerToken: token,
        serverId: 'synthetic-server-0001',
      );
      var client = HttpClient(context: trusted);
      Future<(int, Map<String, dynamic>)> call(
        String method,
        String path, {
        Object? body,
        String? bearer,
        String? origin,
      }) async {
        final request = await client.openUrl(
          method,
          Uri.parse('https://127.0.0.1:${server.port}$path'),
        );
        request.headers.set('authorization', 'Bearer ${bearer ?? token}');
        if (origin != null) request.headers.set('origin', origin);
        if (body != null) {
          request.headers.contentType = ContentType.json;
          request.write(jsonEncode(body));
        }
        final response = await request.close();
        return (
          response.statusCode,
          jsonDecode(await utf8.decoder.bind(response).join())
              as Map<String, dynamic>,
        );
      }

      final input = {
        'name': '合成资料',
        'description': 'HTTPS 保存验证',
        'fields': [
          {
            'name': '地址',
            'description': '',
            'text': 'private.synthetic.invalid',
          },
        ],
      };
      try {
        expect(
          (await call(
            'GET',
            '/v1/owner/information',
            bearer: 'agent-only-identity',
          )).$1,
          401,
        );
        expect(
          (await call(
            'GET',
            '/v1/owner/information',
            origin: 'https://example.invalid',
          )).$1,
          401,
        );
        final untrusted = HttpClient();
        try {
          await expectLater(
            untrusted.getUrl(
              Uri.parse('https://127.0.0.1:${server.port}/v1/server'),
            ),
            throwsA(isA<HandshakeException>()),
          );
        } finally {
          untrusted.close(force: true);
        }
        final saved = await call(
          'POST',
          '/v1/owner/saves/first-save',
          body: input,
        );
        expect(saved.$1, 200);
        expect(
          (await call('POST', '/v1/owner/saves/first-save', body: input)).$2,
          saved.$2,
        );
        expect(
          (await call(
            'POST',
            '/v1/owner/saves/first-save',
            body: {...input, 'name': 'changed'},
          )).$1,
          409,
        );
        client.close(force: true);
        await server.close();
        await service.close();
        await repo.close();
        repo = await EncryptedInformationRepository.open(
          '${root.path}/data',
          keys,
        );
        service = InformationService(repository: repo);
        server = await OnlineServer.start(
          service: service,
          tls: tls,
          ownerToken: token,
          serverId: 'synthetic-server-0001',
        );
        client = HttpClient(context: trusted);
        expect(
          (await call('GET', '/v1/owner/operations/first-save')).$2,
          saved.$2,
        );
        expect(
          (await call('POST', '/v1/owner/saves/first-save', body: input)).$2,
          saved.$2,
        );
        final items =
            (await call('GET', '/v1/owner/information')).$2['items'] as List;
        expect(items, hasLength(1));
        expect(items.single['fields'][0]['value'], 'private.synthetic.invalid');
        expect(
          (await call('GET', '/v1/server')).$2['serverId'],
          'synthetic-server-0001',
        );
      } finally {
        client.close(force: true);
        await server.close();
        await service.close();
        await repo.close();
      }
    },
  );
}
