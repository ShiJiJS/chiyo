import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:info_cli/chrome_browser_fill.dart';

/// A new headless profile owned exclusively by this integration test.
class SyntheticChrome {
  SyntheticChrome._(this.process, this.profile, this.address, this.tab);
  final Process process;
  final Directory profile;
  final String address, tab;
  static Future<SyntheticChrome> start(
    String executable,
    Directory root,
  ) async {
    final profile = await Directory('${root.path}/chrome-profile').create();
    final process = await Process.start(executable, [
      '--headless=new',
      '--no-first-run',
      '--no-default-browser-check',
      '--remote-debugging-port=0',
      '--user-data-dir=${profile.path}',
      'about:blank',
    ]);
    unawaited(process.stdout.drain<void>());
    unawaited(process.stderr.drain<void>());
    final portFile = File('${profile.path}/DevToolsActivePort');
    for (var i = 0; i < 200 && !await portFile.exists(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    final port = int.parse((await portFile.readAsLines()).first);
    final address = 'http://127.0.0.1:$port';
    final pages = await ChromeBrowserFill(address).pages();
    final tab = ((pages['pages'] as List).single as Map)['id'] as String;
    return SyntheticChrome._(process, profile, address, tab);
  }

  Future<Map<String, dynamic>> call(
    String method,
    Map<String, Object?> params,
  ) async {
    final socket = await WebSocket.connect(
      '${address.replaceFirst('http', 'ws')}/devtools/page/$tab',
    );
    try {
      final result = socket
          .map((e) => jsonDecode(e as String) as Map<String, dynamic>)
          .firstWhere((e) => e['id'] == 1);
      socket.add(jsonEncode({'id': 1, 'method': method, 'params': params}));
      final response = await result.timeout(const Duration(seconds: 5));
      if (response['error'] != null) {
        throw StateError('Synthetic Chrome protocol failure');
      }
      return response['result'] as Map<String, dynamic>;
    } finally {
      await socket.close();
    }
  }

  Future<Object?> evaluate(String expression) async {
    final result = await call('Runtime.evaluate', {
      'expression': expression,
      'returnByValue': true,
    });
    if (result['exceptionDetails'] != null) {
      throw StateError('Synthetic Chrome page not ready');
    }
    return (result['result'] as Map)['value'];
  }

  Future<void> go(String url) async {
    await call('Page.navigate', {'url': url});
    for (var i = 0; i < 200; i++) {
      try {
        if (await evaluate(
              'location.href===${jsonEncode(url)} && document.readyState==="complete" && !!document.querySelector("#password")',
            ) ==
            true) {
          return;
        }
      } on Object {
        /* A navigation replaces the old context. */
      }
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    throw StateError('Synthetic Chrome navigation did not settle');
  }

  Future<void> close() async {
    try {
      await call('Browser.close', {});
    } on Object {
      /* Chrome can close before acknowledging. */
    }
    await process.exitCode.timeout(const Duration(seconds: 10));
  }
}
