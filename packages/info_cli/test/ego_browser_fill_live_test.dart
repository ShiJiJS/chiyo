import 'dart:convert';
import 'dart:io';
import 'package:info_cli/ego_browser_fill.dart';
import 'package:test/test.dart';

// Opt-in only. SPACE/PAGE must name an exclusively owned synthetic test Page.
// These tests navigate/close that Page, never create a replacement or claim a
// user-owned space. The caller finishes its TaskSpace after collecting results.
void main() {
  final executable = Platform.environment['CHIYO_EGO_TEST_EXECUTABLE'];
  final space = int.tryParse(
    Platform.environment['CHIYO_EGO_TEST_SPACE'] ?? '',
  );
  final label = Platform.environment['CHIYO_EGO_TEST_PAGE'];
  group(
    'Ego exact form filling through the installed helper',
    () {
      late HttpServer fixture;
      late EgoBrowserFill driver;
      late String url;
      var sequence = 0;
      const synthetic = '  Synthetic-示例😊-"quoted"  ';

      Future<Object?> control(String operation) async {
        final process = await Process.start(executable!, ['nodejs']);
        final out = utf8.decoder.bind(process.stdout).join();
        final err = utf8.decoder.bind(process.stderr).join();
        process.stdin.add(
          utf8.encode('''
const task=await taskSpace($space);
const page=task.page(${jsonEncode(label)});
const result=await (async()=>{$operation})();
console.log('chiyo-probe:'+JSON.stringify(result));
'''),
        );
        await process.stdin.close();
        final code = await process.exitCode.timeout(
          const Duration(seconds: 15),
        );
        final lines = const LineSplitter().convert(
          '${await out}\n${await err}',
        );
        expect(code, 0, reason: 'Synthetic fixture control must succeed');
        final receipt = lines
            .where((line) => line.startsWith('chiyo-probe:'))
            .single;
        return jsonDecode(receipt.substring('chiyo-probe:'.length));
      }

      Future<Object?> evaluate(String expression) =>
          control('return await page.evaluate(${jsonEncode(expression)});');
      Future<BrowserFormInspection> inspect({
        String field = '[name="password"]',
      }) => driver.inspect(
        space: space!,
        page: label!,
        url: url,
        form: '#login',
        field: field,
      );

      setUpAll(() async {
        driver = EgoBrowserFill(executable!);
        fixture = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        fixture.listen((request) async {
          request.response.headers.contentType = ContentType.html;
          request.response.write(_fixture);
          await request.response.close();
        });
      });
      setUp(() async {
        url = 'http://127.0.0.1:${fixture.port}/login?case=${++sequence}';
        await control('await page.goto(${jsonEncode(url)}); return true;');
      });
      tearDownAll(() async => fixture.close(force: true));

      test(
        'replaces only the unique form field, preserves Unicode/spaces and focus',
        () async {
          await evaluate(
            'document.querySelector("#password").value="OLD";document.querySelector("#account").focus();true',
          );
          final checked = await inspect();
          expect(await driver.fill(checked.target, synthetic), {
            'status': 'filled',
          });
          expect(
            await evaluate(
              '''({matched:document.querySelector('#password').value===${jsonEncode(synthetic)},other:document.querySelector('#other-password').value,focused:document.activeElement.id,events:window.inputEvents})''',
            ),
            {
              'matched': true,
              'other': 'KEEP',
              'focused': 'account',
              'events': 1,
            },
          );
        },
      );
      test(
        'ordinary text controls are refused before receiving material',
        () async {
          await expectLater(
            inspect(field: '#account'),
            throwsA(isA<BrowserFillFailure>()),
          );
          expect(
            await evaluate('document.querySelector("#account").value'),
            isEmpty,
          );
        },
      );
      test(
        'changed structure and full URL after approval are refused without input',
        () async {
          final checked = await inspect();
          await evaluate(
            'document.querySelector("#login").setAttribute("action","/changed");true',
          );
          expect(await driver.fill(checked.target, synthetic), {
            'status': 'refused',
            'code': 'form_changed',
          });
          expect(await evaluate('window.inputEvents'), 0);
          await evaluate('location.hash="changed";true');
          expect(await driver.fill(checked.target, synthetic), {
            'status': 'refused',
            'code': 'destination_changed',
          });
          expect(await evaluate('window.inputEvents'), 0);
        },
      );
      test(
        'reload only reuses the same Page, URL and unchanged form structure',
        () async {
          final checked = await inspect();
          await control('await page.reload();return true;');
          expect(await driver.fill(checked.target, synthetic), {
            'status': 'filled',
          });
          expect(await evaluate('window.inputEvents'), 1);
        },
      );
      test('input-event focus changes do not redirect material', () async {
        await evaluate('window.inputMode="focus";true');
        final checked = await inspect();
        expect(await driver.fill(checked.target, synthetic), {
          'status': 'filled',
        });
        expect(
          await evaluate(
            '({other:document.querySelector("#other-password").value,events:window.inputEvents})',
          ),
          {'other': 'KEEP', 'events': 1},
        );
      });
      for (final mode in ['replace', 'navigate']) {
        test('$mode during input is unknown without a second write', () async {
          await evaluate('window.inputMode=${jsonEncode(mode)};true');
          final checked = await inspect();
          expect(
            (await driver.fill(checked.target, synthetic))['status'],
            'unknown',
          );
          expect(await evaluate('window.inputEvents'), 1);
          if (mode == 'replace') {
            expect(
              await evaluate('document.querySelector("#password").value'),
              isEmpty,
            );
          }
        });
      }
      test(
        'a system-unique context cannot evaluate in the replacement document',
        () async {
          expect(
            await control('''
await page.cdp('Runtime.enable');
const frame=(await page.cdp('Page.getFrameTree')).frameTree.frame;
const name='chiyo-test-'+Date.now();
const world=await page.cdp('Page.createIsolatedWorld',{frameId:frame.id,worldName:name});
const context=(await page.events()).filter(e=>e.method==='Runtime.executionContextCreated').map(e=>e.params.context).find(c=>c.id===world.executionContextId && c.name===name);
await page.reload();
try {
  await page.cdp('Runtime.evaluate',{expression:'document.querySelector("#password").value="WRONG"',uniqueContextId:context.uniqueId,returnByValue:true});
  return false;
} catch {return true;}
'''),
            true,
          );
          expect(
            await evaluate('document.querySelector("#password").value'),
            isEmpty,
          );
        },
      );
      test(
        'closing the selected Page refuses and does not create a replacement',
        () async {
          final checked = await inspect();
          await control('await page.close();return true;');
          final result = await driver.fill(checked.target, synthetic);
          expect(result['status'], 'refused');
          expect(
            await control(
              'return (await task.pages()).some(p=>p.label===${jsonEncode(label)});',
            ),
            false,
          );
        },
      );
    },
    skip: executable == null || space == null || label == null
        ? 'Set an Ego executable and an exclusively owned synthetic TaskSpace/Page.'
        : false,
  );
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
