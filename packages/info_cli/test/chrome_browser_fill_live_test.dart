import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:info_cli/browser_form_script.dart';
import 'package:info_cli/chrome_browser_fill.dart';
import 'package:test/test.dart';

// Opt-in: launches only a new test profile, never the user's Chrome profile.
void main() {
  final executable = Platform.environment['CHIYO_CHROME_TEST_EXECUTABLE'];
  group(
    'Chrome form filling in a real isolated browser',
    () {
      late Directory profile;
      late Process browser;
      late HttpServer fixture;
      late ChromeBrowserFill driver;
      late _PageProbe probe;
      late String tab;
      late String url;
      var sequence = 0;
      var profileReady = false,
          browserReady = false,
          fixtureReady = false,
          probeReady = false;

      setUpAll(() async {
        final root = Directory('../../build/cli-redesign/chrome-live').absolute;
        await root.create(recursive: true);
        profile = await root.createTemp('profile-');
        profileReady = true;
        fixture = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        fixtureReady = true;
        fixture.listen((request) async {
          request.response.headers.contentType = ContentType.html;
          request.response.write(_fixture);
          await request.response.close();
        });
        browser = await Process.start(executable!, [
          '--headless=new',
          '--no-first-run',
          '--no-default-browser-check',
          '--remote-debugging-port=0',
          '--user-data-dir=${profile.path}',
          'about:blank',
        ]);
        browserReady = true;
        browser.stdout.drain<void>();
        browser.stderr.drain<void>();
        final portFile = File('${profile.path}/DevToolsActivePort');
        await _until(() => portFile.exists());
        final port = int.parse((await portFile.readAsLines()).first);
        driver = ChromeBrowserFill('http://127.0.0.1:$port');
        Map<String, Object?> pages = await driver.pages();
        await _until(() async {
          pages = await driver.pages();
          return (pages['pages'] as List).isNotEmpty;
        });
        tab = ((pages['pages'] as List).first as Map)['id'] as String;
        probe = await _PageProbe.open(
          'ws://127.0.0.1:$port/devtools/page/$tab',
        );
        probeReady = true;
      });

      setUp(() async {
        url = 'http://127.0.0.1:${fixture.port}/login?case=${++sequence}';
        await probe.call('Page.navigate', {'url': url});
        await _until(() async {
          try {
            return await probe.evaluate(
                  'location.href === ${jsonEncode(url)} && document.readyState === "complete" && !!document.querySelector("#login")',
                ) ==
                true;
          } on Object {
            return false;
          }
        });
      });

      tearDownAll(() async {
        if (browserReady) {
          if (probeReady) {
            probe.requestBrowserClose();
          } else {
            browser.kill();
          }
          try {
            await browser.exitCode.timeout(const Duration(seconds: 10));
          } on TimeoutException {
            browser.kill(ProcessSignal.sigkill);
            await browser.exitCode;
          }
        }
        if (probeReady) await probe.close();
        if (fixtureReady) await fixture.close(force: true);
        if (profileReady) {
          await _until(() async {
            if (!await profile.exists()) return true;
            try {
              await profile.delete(recursive: true);
              return true;
            } on FileSystemException {
              // Chrome helpers may finish their last profile write after the
              // parent exits. Retry only this test's exact temporary directory.
              return false;
            }
          });
        }
      });

      Future<ChromeFormInspection> inspect({
        String field = '[name="password"]',
      }) => driver.inspect(tab: tab, url: url, form: '#login', field: field);

      const synthetic = '  Synthetic-示例😊-"quoted"  ';

      test(
        'replaces exact approved field, scopes duplicate selectors, and keeps focus',
        () async {
          await probe.evaluate(
            'document.querySelector("#password").value="OLD"; document.querySelector("#account").focus(); true',
          );
          final checked = await inspect();
          expect(await driver.fill(checked.target, synthetic), {
            'status': 'filled',
          });
          expect(
            await probe.evaluate('''({
        matched:document.querySelector('#password').value===${jsonEncode(synthetic)},
        otherUnchanged:document.querySelector('#other-password').value==='KEEP',
        focusUnchanged:document.activeElement.id==='account',
        events:window.inputEvents
      })'''),
            {
              'matched': true,
              'otherUnchanged': true,
              'focusUnchanged': true,
              'events': 1,
            },
          );
        },
      );

      test('changed form is refused before any password is sent', () async {
        final checked = await inspect();
        await probe.evaluate(
          'document.querySelector("#login").setAttribute("action","/register"); true',
        );
        expect(
          (await driver.fill(checked.target, synthetic))['status'],
          'refused',
        );
        expect(
          await probe.evaluate(
            'window.inputEvents===0 && document.querySelector("#password").value===""',
          ),
          true,
        );
      });

      test(
        'normal text input is not accepted as a password destination',
        () async {
          await expectLater(
            inspect(field: '#account'),
            throwsA(isA<BrowserFillFailure>()),
          );
          expect(await probe.evaluate('window.inputEvents'), 0);
        },
      );

      test(
        'page script changing focus cannot redirect the password to another field',
        () async {
          await probe.evaluate('window.inputMode="focus"; true');
          final checked = await inspect();
          expect(await driver.fill(checked.target, synthetic), {
            'status': 'filled',
          });
          expect(
            await probe.evaluate(
              'document.querySelector("#other-password").value==="KEEP" && document.querySelector("#password").value===${jsonEncode(synthetic)}',
            ),
            true,
          );
        },
      );

      test(
        'navigation during input returns unknown without a second input',
        () async {
          await probe.evaluate('window.inputMode="navigate"; true');
          final checked = await inspect();
          expect(
            (await driver.fill(checked.target, synthetic))['status'],
            'unknown',
          );
          expect(await probe.evaluate('window.inputEvents'), 1);
        },
      );

      test(
        'replacement during input returns unknown and leaves replacement empty',
        () async {
          await probe.evaluate('window.inputMode="replace"; true');
          final checked = await inspect();
          expect(
            (await driver.fill(checked.target, synthetic))['status'],
            'unknown',
          );
          expect(
            await probe.evaluate(
              'window.inputEvents===1 && document.querySelector("#password").value===""',
            ),
            true,
          );
        },
      );

      test(
        'same-call guard refuses a structure change after a previous check',
        () async {
          final checked = await inspect();
          await probe.evaluate(
            'document.querySelector("#login").setAttribute("method","get"); true',
          );
          final receipt = await probe.evaluate(
            browserFormExpression(
              url: url,
              form: '#login',
              field: '[name="password"]',
              expectedStructure: checked.structure,
              password: synthetic,
            ),
          );
          expect(receipt, {'status': 'refused', 'code': 'form_changed'});
          expect(await probe.evaluate('window.inputEvents'), 0);
        },
      );
    },
    skip: executable == null
        ? 'Set CHIYO_CHROME_TEST_EXECUTABLE for an isolated Chrome check.'
        : false,
  );
}

Future<void> _until(Future<bool> Function() check) async {
  final end = DateTime.now().add(const Duration(seconds: 15));
  while (DateTime.now().isBefore(end)) {
    if (await check()) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  throw StateError('Synthetic browser did not become ready');
}

class _PageProbe {
  _PageProbe(this.socket) {
    subscription = socket.listen((event) {
      final data = jsonDecode(event as String) as Map<String, dynamic>;
      if (data['id'] is int) pending.remove(data['id'])?.complete(data);
    });
  }
  final WebSocket socket;
  late StreamSubscription<dynamic> subscription;
  final pending = <int, Completer<Map<String, dynamic>>>{};
  var next = 0;
  static Future<_PageProbe> open(String url) async =>
      _PageProbe(await WebSocket.connect(url));
  Future<Map<String, dynamic>> call(
    String method,
    Map<String, Object?> params,
  ) async {
    final id = ++next, completer = Completer<Map<String, dynamic>>();
    pending[id] = completer;
    socket.add(jsonEncode({'id': id, 'method': method, 'params': params}));
    final result = await completer.future.timeout(const Duration(seconds: 5));
    if (result['error'] != null) {
      throw StateError('Synthetic probe call failed');
    }
    return result['result'] as Map<String, dynamic>;
  }

  Future<Object?> evaluate(String expression) async {
    final result = await call('Runtime.evaluate', {
      'expression': expression,
      'returnByValue': true,
    });
    if (result['exceptionDetails'] != null) {
      throw StateError('Synthetic page not ready');
    }
    return (result['result'] as Map)['value'];
  }

  void requestBrowserClose() => socket.add(
    jsonEncode({
      'id': ++next,
      'method': 'Browser.close',
      'params': <String, Object?>{},
    }),
  );

  Future<void> close() async {
    await subscription.cancel();
    await socket.close();
  }
}

const _fixture =
    '''<!doctype html><meta charset="utf-8"><title>Chiyo synthetic form</title>
<form id="login" action="/session" method="post">
<input id="account" name="account" autocomplete="username">
<input id="password" name="password" type="password" autocomplete="current-password">
</form>
<form id="other"><input id="other-password" name="password" type="password" value="KEEP"></form>
<script>
window.inputEvents=0;window.inputMode='';
document.querySelector('#password').addEventListener('input',event=>{
  window.inputEvents++;
  if(window.inputMode==='focus')document.querySelector('#other-password').focus();
  if(window.inputMode==='navigate')location.hash='changed';
  if(window.inputMode==='replace'){
    const replacement=event.target.cloneNode();replacement.value='';event.target.replaceWith(replacement);
  }
});
</script>''';
