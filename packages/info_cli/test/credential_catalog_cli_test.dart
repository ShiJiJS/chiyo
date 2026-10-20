import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_core/agent_server.dart';
import 'package:test/test.dart';
import 'package:info_cli/codex_association.dart';

void main() {
  test(
    'Codex private association is adapter context, never a catalog field or output',
    () async {
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      final c = await service.owner.createStringCredential(
        name: 'Synthetic public token',
        publicPurpose: 'API',
        secret: 'FICTIONAL-CODEX-SECRET',
      );
      await service.owner.updateCredentialMetadata(
        c.id,
        c.revision,
        name: c.name,
        publicPurpose: c.publicPurpose,
        privateNote: 'private',
        suggestedBinding: c.suggestedBinding,
        discoverable: true,
      );
      final server = await AgentServer.start(service.agent, port: 0);
      final root = await Directory.systemTemp.createTemp('credential-codex-');
      addTearDown(() async {
        await server.close();
        await service.close();
        await root.delete(recursive: true);
      });
      final session = service.agent.openSession('Synthetic Codex');
      final reference = await CodexAssociation(
        'synthetic-credential-chat',
        server.port,
        session,
      ).save(root);
      final process = await Process.start(
        Platform.resolvedExecutable,
        ['run', 'bin/codex_info.dart'],
        environment: {'CODEX_THREAD_ID': 'synthetic-credential-chat'},
      );
      final output = process.stdout.transform(utf8.decoder).join();
      final errors = process.stderr.transform(utf8.decoder).join();
      process.stdin.write(
        jsonEncode({'association': reference, 'command': 'credential-catalog'}),
      );
      await process.stdin.close();
      expect(await process.exitCode, 0);
      expect(await errors, isEmpty);
      final text = await output;
      final result = jsonDecode(text) as Map<String, dynamic>;
      expect(result['status'], 'ok');
      expect((result['credentials'] as List).single['credentialId'], c.id);
      expect(text, isNot(contains(reference)));
      expect(text, isNot(contains(session)));
      expect(text, isNot(contains('FICTIONAL-')));
    },
  );
  test(
    'real CLI discovers only opted-in metadata and rejects duplicate/unknown properties',
    () async {
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      final owner = service.owner;
      final c = await owner.createStringCredential(
        name: 'Public token',
        publicPurpose: 'Repository API',
        privateNote: 'PRIVATE-NOTE-731',
        secret: 'FICTIONAL-SECRET-731',
      );
      await owner.updateCredentialMetadata(
        c.id,
        1,
        name: c.name,
        publicPurpose: c.publicPurpose,
        privateNote: c.privateNote,
        suggestedBinding: c.suggestedBinding,
        discoverable: true,
      );
      await owner.createFileCredential(
        name: 'Hidden key',
        publicPurpose: 'SSH',
        fileName: 'private.key',
        bytes: [1, 2, 3],
      );
      final server = await AgentServer.start(service.agent, port: 0);
      final process = await Process.start(Platform.resolvedExecutable, [
        'run',
        'bin/info.dart',
        '--port',
        '${server.port}',
      ]);
      final lines = StreamIterator(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );
      final errors = process.stderr.transform(utf8.decoder).join();
      addTearDown(() async {
        await process.stdin.close();
        process.kill();
        await lines.cancel();
        await server.close();
        await service.close();
      });
      Future<Map<String, dynamic>> command(String input) async {
        process.stdin.writeln(input);
        expect(
          await lines.moveNext().timeout(const Duration(seconds: 20)),
          isTrue,
        );
        return jsonDecode(lines.current) as Map<String, dynamic>;
      }

      final page = await command('{"command":"credential-catalog","limit":1}');
      expect(page['status'], 'ok');
      expect((page['credentials'] as List).single['credentialId'], c.id);
      expect(page['protocolVersion'], 1);
      expect(jsonEncode(page), isNot(contains('FICTIONAL-')));
      expect(jsonEncode(page), isNot(contains('PRIVATE-NOTE')));
      expect(jsonEncode(page), isNot(contains('private.key')));
      for (final input in [
        '{"command":"credential-catalog","limit":1,"limit":2}',
        '{"command":"credential-catalog","command":"catalog"}',
        '{"command":"credential-catalog","extra":true}',
        '{"command":"credential-catalog","limit":1.0}',
      ]) {
        final result = await command(input);
        expect(result['status'], 'invalid_request');
        expect(result['protocolVersion'], 1);
      }
      await process.stdin.close();
      expect(await process.exitCode, 0);
      expect(await errors, isEmpty);
    },
  );
}
