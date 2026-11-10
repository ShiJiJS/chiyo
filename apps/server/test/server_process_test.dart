import 'dart:convert';
import 'dart:io';
import 'package:info_server/server_configuration.dart';
import 'package:info_storage/info_storage.dart';
import 'package:test/test.dart';
import 'support/tls_fixture.dart';

void main() {
  test(
    'separate process reopens data and cannot replace initialized identities',
    () async {
      final root = await Directory.systemTemp.createTemp('chiyo-process-');
      addTearDown(() => root.delete(recursive: true));
      final secrets = '${root.path}/secrets';
      await initializeServerSecrets(secrets);
      final keyBefore = await File('$secrets/database.key').readAsBytes();
      await expectLater(
        initializeServerSecrets(secrets),
        throwsA(isA<StorageFailure>()),
      );
      expect(await File('$secrets/database.key').readAsBytes(), keyBefore);
      final tls = await createTlsFixture(root);
      await Process.run('chmod', ['600', tls.privateKey]);
      final config = File('${root.path}/server.json');
      await config.writeAsString(
        jsonEncode({
          'dataDirectory': 'data',
          'secretsDirectory': 'secrets',
          'tlsCertificate': tls.certificate,
          'tlsPrivateKey': tls.privateKey,
          'port': 0,
        }),
      );
      final configInput =
          jsonDecode(await config.readAsString()) as Map<String, dynamic>;
      expect((await ServerConfiguration.read(config.path)).readCacheMiB, 128);
      for (final size in [32, 512]) {
        await config.writeAsString(
          jsonEncode({...configInput, 'readCacheMiB': size}),
        );
        expect(
          (await ServerConfiguration.read(config.path)).readCacheMiB,
          size,
        );
      }
      for (final size in [null, 0, 31, 513, 128.5, '128', true]) {
        await config.writeAsString(
          jsonEncode({...configInput, 'readCacheMiB': size}),
        );
        await expectLater(
          ServerConfiguration.read(config.path),
          throwsFormatException,
        );
      }
      await config.writeAsString(jsonEncode(configInput));
      final token = base64Url
          .encode(await File('$secrets/owner.token').readAsBytes())
          .replaceAll('=', '');
      final trusted = SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificates(tls.ca);
      Process? process;
      var diagnostics = <String>[];
      Future<Map<String, dynamic>> start() async {
        diagnostics = [];
        final binary = Platform.environment['CHIYO_TEST_SERVER_BINARY'];
        process = await Process.start(binary ?? Platform.resolvedExecutable, [
          if (binary == null) ...['run', 'bin/server.dart'],
          'serve',
          config.path,
        ], workingDirectory: Directory.current.path);
        process!.stderr.transform(utf8.decoder).listen(diagnostics.add);
        final ready = await process!.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first
            .timeout(const Duration(seconds: 60));
        return jsonDecode(ready) as Map<String, dynamic>;
      }

      Future<void> stop() async {
        final p = process;
        process = null;
        if (p == null) return;
        p.kill(ProcessSignal.sigterm);
        try {
          expect(
            await p.exitCode.timeout(const Duration(seconds: 15)),
            0,
            reason: diagnostics.join(),
          );
        } finally {
          p.kill(ProcessSignal.sigkill);
        }
      }

      Future<Map<String, dynamic>> call(
        int port,
        String method,
        String path, [
        Object? body,
      ]) async {
        final client = HttpClient(context: trusted);
        try {
          final request = await client.openUrl(
            method,
            Uri.parse('https://127.0.0.1:$port$path'),
          );
          request.headers.set('authorization', 'Bearer $token');
          if (body != null) {
            request.headers.contentType = ContentType.json;
            request.write(jsonEncode(body));
          }
          final response = await request.close();
          expect(response.statusCode, 200);
          return jsonDecode(await utf8.decoder.bind(response).join())
              as Map<String, dynamic>;
        } finally {
          client.close(force: true);
        }
      }

      try {
        final first = await start();
        expect(first['state'], 'ready');
        final input = {
          'name': 'Process fixture',
          'description': 'synthetic',
          'fields': [
            {'name': 'Address', 'description': '', 'text': 'process.invalid'},
          ],
        };
        final receipt = await call(
          first['port'] as int,
          'POST',
          '/v1/owner/saves/process-save',
          input,
        );
        await stop();
        final second = await start();
        expect(second['serverId'], first['serverId']);
        expect(
          await call(
            second['port'] as int,
            'GET',
            '/v1/owner/operations/process-save',
          ),
          receipt,
        );
        expect(
          await call(
            second['port'] as int,
            'POST',
            '/v1/owner/saves/process-save',
            input,
          ),
          receipt,
        );
        final items =
            (await call(
                  second['port'] as int,
                  'GET',
                  '/v1/owner/information',
                ))['items']
                as List;
        expect(items, hasLength(1));
        expect(items.single['fields'][0]['value'], 'process.invalid');
        final update = {
          'name': 'Updated process record',
          'description': 'synthetic update',
          'itemId': items.single['id'],
          'baseVersion': items.single['version'],
          'fields': [
            {
              'fieldId': items.single['fields'][0]['id'],
              'name': 'Address',
              'description': '',
              'text': 'updated.process.invalid',
            },
          ],
        };
        final updated = await call(
          second['port'] as int,
          'POST',
          '/v1/owner/saves/update-save',
          update,
        );
        expect(updated['version'], 2);
        expect(
          await call(
            second['port'] as int,
            'POST',
            '/v1/owner/saves/update-save',
            update,
          ),
          updated,
        );
        final after =
            (await call(
                  second['port'] as int,
                  'GET',
                  '/v1/owner/information',
                ))['items']
                as List;
        expect(after.single['id'], items.single['id']);
        expect(after.single['fields'][0]['value'], 'updated.process.invalid');
        expect(diagnostics.join().contains(token), isFalse);
      } finally {
        await stop();
      }
    },
  );
}
