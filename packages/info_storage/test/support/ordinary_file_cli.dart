import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Real independent JSON-lines client; private session handling stays inside it.
class OrdinaryFileCli {
  OrdinaryFileCli._(this.process, this.lines, this.errors);
  final Process process;
  final StreamIterator<String> lines;
  final Future<String> errors;
  static Future<OrdinaryFileCli> start(int port) async {
    final cli = Directory('../info_cli').absolute.path;
    final process = await Process.start(Platform.resolvedExecutable, [
      '--packages=$cli/.dart_tool/package_config.json',
      '$cli/bin/info.dart',
      '--port',
      '$port',
    ], workingDirectory: cli);
    return OrdinaryFileCli._(
      process,
      StreamIterator(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      ),
      process.stderr.transform(utf8.decoder).join(),
    );
  }

  Future<Map<String, dynamic>> command(Map<String, dynamic> input) async {
    process.stdin.writeln(jsonEncode(input));
    if (!await lines.moveNext().timeout(const Duration(seconds: 45))) {
      throw StateError('Independent CLI ended before response');
    }
    return jsonDecode(lines.current) as Map<String, dynamic>;
  }

  Future<void> close() async {
    await process.stdin.close();
    final code = await process.exitCode.timeout(const Duration(seconds: 15));
    await lines.cancel();
    final stderr = await errors;
    if (code != 0 || stderr.isNotEmpty) {
      throw StateError('Independent CLI failed with exit $code');
    }
  }
}
