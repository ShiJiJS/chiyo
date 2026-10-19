// Explicit QA worker: no service/owner API and no credential store. The random
// synthetic value is received over private stdin, never arguments or files.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:info_cli/windows_focused_fill.dart';
import 'package:info_core/info_core.dart';

Future<FocusedFillApplication> identity(String path) async =>
    FocusedFillApplication.fromJson({
      'executable': await File(path).resolveSymbolicLinks(),
      'sha256': (await sha256.bind(File(path).openRead()).first).toString(),
    });

Future<void> main(List<String> args) async {
  if (args.length != 2) exit(64);
  PreparedFocusedFill? prepared;
  try {
    final init =
        jsonDecode(
              await stdin
                  .transform(utf8.decoder)
                  .transform(const LineSplitter())
                  .first,
            )
            as Map<String, dynamic>;
    final value = init['synthetic'] as String;
    if (value.length < 32) exit(64);
    final driver = WindowsFocusedFillDriver(helper: await identity(args[0]));
    prepared = await driver.prepare(await identity(args[1]));
    final batch = value.codeUnits.take(16).toList();
    final result = await prepared.sendBatch(batch);
    batch.fillRange(0, batch.length, 0);
    stdout.writeln(
      jsonEncode({'phase': 'one_batch', 'state': result.state.name}),
    );
    await stdout.flush();
    // The controller terminates this process unexpectedly while the real
    // prepared broker is waiting. Reaching this deadline is test failure.
    await Future<void>.delayed(const Duration(seconds: 45));
    exitCode = 1;
  } on Object {
    stdout.writeln('{"phase":"failed"}');
    exitCode = 1;
  } finally {
    await prepared?.close();
  }
}
