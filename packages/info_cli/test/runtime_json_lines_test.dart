import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_core/agent_server.dart';
import 'package:test/test.dart';

void main() {
  test(
    'real JSON-lines CLI bounds and rejects each invalid byte line and continues the same session',
    () async {
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      final server = await AgentServer.start(service.agent, port: 0);
      final cli = await Process.start(Platform.resolvedExecutable, [
        'run',
        'bin/info.dart',
        '--port',
        '${server.port}',
      ]);
      final lines = StreamIterator(
        cli.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );
      final errors = cli.stderr.drain<void>();
      addTearDown(() async {
        await cli.stdin.close();
        await cli.exitCode.timeout(const Duration(seconds: 10));
        await lines.cancel();
        await errors;
        await server.close();
        await service.close();
      });
      Future<Map<String, dynamic>> response() async {
        expect(
          await lines.moveNext().timeout(const Duration(seconds: 10)),
          isTrue,
        );
        return jsonDecode(lines.current) as Map<String, dynamic>;
      }

      cli.stdin.writeln('{"command":"session","chatLabel":"Transport limits"}');
      expect((await response())['status'], 'ok');
      cli.stdin.add([
        ...utf8.encode('{"command":"request-use","purpose":"'),
        ...List<int>.filled(262144, 120),
        ...utf8.encode('"}\n'),
      ]);
      expect((await response())['errorCode'], 'limit_exceeded');
      cli.stdin.add([0xff, 0x0a]);
      expect((await response())['errorCode'], 'invalid_json');
      cli.stdin.writeln(
        '{"command":"run-use","command":"session","requestId":"fake"}',
      );
      expect((await response())['errorCode'], 'invalid_json');
      cli.stdin.writeln('{"command":"credential-catalog"}');
      expect((await response())['status'], 'ok');
      cli.stdin.writeln('{"command":"run-use","requestId":"unknown"}');
      expect((await response())['errorCode'], 'session_mismatch');
    },
  );
}
