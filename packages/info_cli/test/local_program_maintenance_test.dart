@TestOn('mac-os || windows')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:info_cli/agent_client.dart';
import 'package:info_cli/private_device_state.dart';
import 'package:info_core/info_core.dart';
import 'package:info_remote/agent_connection.dart';
import 'package:test/test.dart';

void main() {
  test(
    'ordinary local queries recover a dead program supervisor without replaying or deleting live material',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'chiyo-local-journal-',
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final profile = AgentConnectionProfile.local(
        port: server.port,
        deviceToken: '${'d' * 22}.${'s' * 43}',
        libraryId: 'synthetic-local-library',
      );
      final calls = <String>[];
      final reports = <Map<String, dynamic>>[];
      final subscription = server.listen((request) async {
        calls.add(request.uri.path);
        expect(
          request.headers.value('authorization'),
          'Bearer ${profile.deviceToken}',
        );
        final body =
            jsonDecode(await utf8.decoder.bind(request).join())
                as Map<String, dynamic>;
        if (request.uri.path.endsWith('/report')) reports.add(body);
        request.response.headers.contentType = ContentType.json;
        request.response.headers.set('x-chiyo-server-id', profile.serverId);
        request.response.write(
          jsonEncode({
            'status': 'ok',
            if (request.uri.path == '/catalog') 'items': [],
          }),
        );
        await request.response.close();
      });
      final helper = File('${root.path}/supervisor.dart');
      await helper.writeAsString(
        "import 'dart:io'; Future<void> main() async { stdout.writeln('ready'); await stdin.drain<void>(); }",
      );
      final process = await Process.start(Platform.resolvedExecutable, [
        helper.path,
      ]);
      final errors = utf8.decoder.bind(process.stderr).join();
      expect(
        await utf8.decoder
            .bind(process.stdout)
            .transform(const LineSplitter())
            .first,
        'ready',
      );
      final identity = CredentialProcessIdentity.capture(process.pid)!;
      final folder = await privateDeviceDirectory(
        Directory('${root.path}/credential-executions'),
      );
      final execution = 'e' * 43;
      final journal = File(
        '${folder.path}/${sha256.convert(utf8.encode(execution))}.json',
      );
      final lease = ManagedCredentialFiles.reserve(
        ManagedCredentialFiles.create(),
        ['credential-b1.bin'],
      );
      final file = File('${lease.path}/credential-b1.bin');
      final job = CredentialProcessJob.nameFor('j' * 32);
      final client = AgentClient.remote(
        profile,
        deviceFileStateDirectory: Directory('${root.path}/device-files'),
      );
      addTearDown(() async {
        client.close();
        identity.close();
        await process.stdin.close();
        await process.exitCode.timeout(const Duration(seconds: 10));
        await subscription.cancel();
        await server.close(force: true);
        ManagedCredentialFiles.cleanup(lease);
        await root.delete(recursive: true);
      });
      ManagedCredentialFiles.write(
        lease,
        'credential-b1.bin',
        Uint8List.fromList(utf8.encode('SYNTHETIC-LOCAL-MATERIAL')),
      );
      await writePrivateDeviceState(journal, {
        'version': 2,
        'kind': 'program',
        'deviceScope': sha256
            .convert(utf8.encode('${profile.serverId}\n${profile.deviceToken}'))
            .toString(),
        'executionId': execution,
        'executionCapability': 'c' * 43,
        'jobName': job,
        'supervisorPid': process.pid,
        'supervisorIdentity': identity.value,
        'workerPid': null,
        'workerIdentity': null,
        'lease': lease.toPrivateJson(),
        'report': null,
        'cleaned': false,
      });
      expect((await client.execute({'command': 'catalog'}))['status'], 'ok');
      expect(calls, ['/catalog']);
      expect(await file.readAsString(), 'SYNTHETIC-LOCAL-MATERIAL');
      expect((await readPrivateDeviceState(journal))!['cleaned'], false);
      await process.stdin.close();
      expect(await process.exitCode.timeout(const Duration(seconds: 10)), 0);
      expect(await errors, isEmpty);
      expect(
        CredentialProcessIdentity.isActive(process.pid, identity.value),
        false,
      );
      expect(CredentialProcessJob.isActive(job), false);
      expect((await client.execute({'command': 'catalog'}))['status'], 'ok');
      expect(calls, [
        '/catalog',
        '/credential-use/program/report',
        '/credential-use/program/cleanup',
        '/catalog',
      ]);
      expect(reports.single['executionId'], execution);
      expect(reports.single['executionState'], 'unknown');
      expect(reports.single['exitCode'], isNull);
      expect(jsonEncode(reports), isNot(contains('SYNTHETIC-LOCAL-MATERIAL')));
      expect(await file.exists(), false);
      expect(await journal.exists(), false);
      expect((await client.execute({'command': 'catalog'}))['status'], 'ok');
      expect(reports, hasLength(1));
    },
  );
}
