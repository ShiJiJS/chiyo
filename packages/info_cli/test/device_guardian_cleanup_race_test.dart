@TestOn('windows')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:info_cli/device_information_files.dart';
import 'package:info_cli/private_device_state.dart';
import 'package:info_core/info_core.dart';
import 'package:info_remote/agent_connection.dart';
import 'package:test/test.dart';
import '../../../apps/server/test/support/tls_fixture.dart';

void main() {
  final worker = Platform.environment['CHIYO_NATIVE_GUARDIAN_CHECK'];
  test(
    'actual AOT guardian never regresses an acknowledged cleanup when periodic and explicit release queue together',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'chiyo-guardian-race-',
      );
      final fixture = await createTlsFixture(root);
      final tls = SecurityContext()
        ..useCertificateChain(fixture.certificate)
        ..usePrivateKey(fixture.privateKey);
      final server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        tls,
      );
      final profile = AgentConnectionProfile(
        address: Uri.parse('https://127.0.0.1:${server.port}'),
        deviceToken:
            '${base64Url.encode(List.filled(16, 3)).replaceAll('=', '')}.${base64Url.encode(List.filled(32, 7)).replaceAll('=', '')}',
        serverId: 'synthetic-guardian-race',
        certificate: await File(fixture.ca).readAsString(),
      );
      final bytes = utf8.encode('Only this synthetic copy may be delivered.');
      final manifest = <String, dynamic>{
        'deliveryId': 'synthetic-delivery',
        'operationId': 'synthetic-operation',
        'requestId': 'synthetic-request',
        'itemId': 'synthetic-item',
        'fieldId': 'synthetic-field',
        'fieldVersion': 1,
        'attachmentId': 'synthetic-attachment',
        'attachmentVersion': 1,
        'fileName': 'note.txt',
        'mediaType': 'text/plain',
        'byteLength': bytes.length,
        'sha256': sha256.convert(bytes).toString(),
        'expiresAt': DateTime.now()
            .toUtc()
            .add(const Duration(minutes: 2))
            .toIso8601String(),
        'cleanupCapability': base64Url
            .encode(List.filled(32, 11))
            .replaceAll('=', ''),
        'deviceDelivery': true,
      };
      final watchEntered = Completer<void>(), releaseWatch = Completer<void>();
      var armed = false, discardCalls = 0;
      server.listen((request) async {
        await request.drain<void>();
        final action = request.uri.pathSegments.last;
        var state = 'ready';
        if (action == 'watch' && armed) {
          if (!watchEntered.isCompleted) watchEntered.complete();
          await releaseWatch.future;
          state = 'cleanup_pending';
        }
        if (action == 'discard') {
          discardCalls++;
          state = 'released';
        }
        request.response.headers.set('x-chiyo-server-id', profile.serverId);
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'protocolVersion': 2,
            'status': 'ok',
            'delivery': {...manifest, 'state': state},
            if (action == 'download') 'bytes': base64Encode(bytes),
          }),
        );
        await request.response.close();
      });
      final directory = await privateDeviceDirectory(
        Directory('${root.path}/journal'),
      );
      final files = DeviceInformationFiles(
        profile,
        directory,
        workerExecutable: worker,
      );
      final journal = File(
        '${directory.path}/${sha256.convert(utf8.encode('synthetic-delivery'))}.json',
      );
      Map<String, dynamic>? local;
      try {
        final delivered = await files.fetch(
          'synthetic-session',
          {
            'protocolVersion': 2,
            'command': 'file-fetch',
            'requestId': manifest['requestId'],
            'itemId': manifest['itemId'],
            'fieldId': manifest['fieldId'],
            'operationId': manifest['operationId'],
          },
          {
            'status': 'ok',
            'delivery': {...manifest, 'state': 'preparing'},
          },
        );
        expect(delivered['status'], 'ok');
        final path = (delivered['delivery'] as Map)['path'] as String;
        expect(await File(path).readAsBytes(), bytes);
        local = (await readPrivateDeviceState(journal))!;
        armed = true;
        await watchEntered.future.timeout(const Duration(seconds: 10));
        // The periodic watcher is blocked inside its serialized action. Queue
        // the independent explicit release before allowing its terminal reply.
        final released = files.release('synthetic-session', {
          'status': 'ok',
          'delivery': {...manifest, 'state': 'cleanup_pending'},
        });
        await Future<void>.delayed(const Duration(milliseconds: 500));
        releaseWatch.complete();
        expect(
          (await released.timeout(const Duration(seconds: 15)))['status'],
          'ok',
        );
        final result = (await readPrivateDeviceState(journal))!;
        expect(result['phase'], 'released');
        expect(result['lease'], isNull);
        expect(discardCalls, 1);
        expect(await File(path).exists(), false);
      } finally {
        if (!releaseWatch.isCompleted) releaseWatch.complete();
        final saved = await readPrivateDeviceState(journal);
        final guardian = saved ?? local;
        if (guardian != null) {
          final process = guardian['workerPid'] as int;
          final identity = guardian['workerIdentity'] as String;
          for (
            var n = 0;
            n < 30 &&
                CredentialProcessIdentity.isActive(process, identity) == true;
            n++
          ) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          final held = CredentialProcessIdentity.capture(process);
          try {
            if (held?.value == identity &&
                CredentialProcessIdentity.isActive(process, identity) == true) {
              Process.killPid(process);
            }
          } finally {
            held?.close();
          }
          if (guardian['lease'] is Map) {
            await NativeInformationDeliveryFiles().cleanup(
              InformationDeliveryLease.fromPrivateJson(
                Map<String, dynamic>.from(guardian['lease'] as Map),
              ),
            );
          }
        }
        await server.close(force: true);
        await root.delete(recursive: true);
      }
    },
    skip: worker == null
        ? 'Explicit AOT guardian path and OpenSSL required'
        : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
