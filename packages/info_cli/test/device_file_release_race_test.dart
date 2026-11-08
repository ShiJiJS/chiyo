import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:info_cli/device_information_files.dart';
import 'package:info_core/info_core.dart';
import 'package:info_remote/agent_connection.dart';
import 'package:test/test.dart';

void main() {
  test(
    'release accepts only acknowledged physical cleanup if the guardian closes its socket first',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'device-release-race-',
      );
      final journal = File(
        '${root.path}/${sha256.convert(utf8.encode('delivery'))}.json',
      );
      const session = 'synthetic-session';
      final profile = AgentConnectionProfile(
        address: Uri.parse('https://127.0.0.1:1'),
        deviceToken:
            '${base64Url.encode(List.filled(16, 3)).replaceAll('=', '')}.${base64Url.encode(List.filled(32, 7)).replaceAll('=', '')}',
        serverId: 'synthetic-server',
      );
      final scope = sha256
          .convert(
            utf8.encode(
              '${profile.serverId}\n${profile.deviceToken}\n$session',
            ),
          )
          .toString();
      final identity = CredentialProcessIdentity.capture(pid)!;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final manifest = {
        'deliveryId': 'delivery',
        'operationId': 'operation',
        'requestId': 'request',
        'itemId': 'item',
        'fieldId': 'field',
        'fieldVersion': 1,
        'attachmentId': 'attachment',
        'attachmentVersion': 1,
        'fileName': 'synthetic.txt',
        'mediaType': 'text/plain',
        'byteLength': 1,
        'sha256': sha256.convert([0]).toString(),
        'expiresAt': '2099-01-01T00:00:00.000Z',
        'cleanupCapability': 'synthetic-private-cleanup-proof',
      };
      var record = <String, dynamic>{
        'scope': scope,
        'manifest': manifest,
        'phase': 'ready',
        'lease': {'synthetic': true},
        'workerPid': pid,
        'workerIdentity': identity.value,
        'port': server.port,
        'controlCapability': 'synthetic-control',
      };
      var mode = 'cleaned', controls = 0;
      Future<void> write() =>
          journal.writeAsString(jsonEncode(record), flush: true).then((_) {});
      await journal.create();
      expect(
        (await Process.run('/bin/chmod', ['600', journal.path])).exitCode,
        0,
      );
      server.listen((request) async {
        controls++;
        await request.drain<void>();
        expect(
          request.headers.value('authorization'),
          'Bearer synthetic-control',
        );
        record = {
          ...record,
          'lease': null,
          'phase': mode == 'unknown' ? 'cleanup_pending' : 'released',
          if (mode == 'other') 'scope': 'different-scope',
        };
        await write();
        (await request.response.detachSocket(writeHeaders: false)).destroy();
      });
      final files = DeviceInformationFiles(profile, root);
      final response = <String, dynamic>{
        'status': 'ok',
        'delivery': {'deliveryId': 'delivery', 'state': 'cleanup_pending'},
      };
      try {
        for (final testMode in ['cleaned', 'unknown', 'other']) {
          mode = testMode;
          record = {
            ...record,
            'scope': scope,
            'phase': 'ready',
            'lease': {'synthetic': true},
          };
          await write();
          final result = await files.release(session, response);
          expect(result['status'], mode == 'cleaned' ? 'ok' : 'failed');
          if (mode != 'cleaned')
            expect(result['errorCode'], 'delivery_unknown');
        }
        expect(controls, 3);
        record = {...record, 'scope': scope, 'phase': 'expired', 'lease': null};
        await write();
        expect((await files.release(session, response))['status'], 'ok');
        expect(controls, 3);
      } finally {
        identity.close();
        await server.close(force: true);
        await root.delete(recursive: true);
      }
    },
    testOn: 'mac-os',
  );
}
