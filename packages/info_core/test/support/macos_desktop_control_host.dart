import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:info_core/macos_desktop_control.dart';

// Headless, synthetic receiver. No Flutter, Keychain, database or user profile.
Future<void> main(List<String> args) async {
  final directory = Directory(args[0]);
  final mode = args[1];
  late MacDesktopControlHost host;
  var calls = 0;
  host = await MacDesktopControlHost.start(
    directory: directory,
    state: () => mode == 'startup-failed' ? 'startup_failed' : 'running',
    quit: () async {
      calls++;
      await File('${directory.path}/quit-count.txt').writeAsString('$calls');
      if (mode == 'hang') return Completer<void>().future;
      if (mode == 'fail-once' && calls == 1) {
        throw StateError('synthetic save failure');
      }
      if (mode != 'unexpected') await host.commitExit();
      Timer(
        const Duration(milliseconds: 60),
        () => exit(mode == 'unexpected' ? 7 : 0),
      );
    },
  );
  stdout.writeln(jsonEncode({'ready': true, 'processId': pid}));
}
