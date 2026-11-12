// Interactive Windows-only QA. This is not a public command or a secret-read
// capability. The browser fixture and credential contain random synthetic data.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:info_cli/windows_focused_fill.dart';
import 'package:info_core/agent_server.dart';
import 'package:info_core/info_core.dart';

import '../../../../apps/desktop/integration_test/support/browser_fill_receiver.dart';

Future<void> main(List<String> args) async {
  if (!Platform.isWindows || args.length != 3) {
    exitCode = 64;
    return;
  }
  final folder = Directory(args[2]).absolute;
  await folder.create(recursive: true);
  final secret =
      '  Browser-A1b2C3d4-${base64Url.encode(List.generate(32, (_) => Random.secure().nextInt(256)))}-中文🧭  ';
  final sequenceNumber = DynamicLibrary.open('user32.dll')
      .lookupFunction<Uint32 Function(), int Function()>(
        'GetClipboardSequenceNumber',
      );
  void scan(String text) {
    if (text.contains(secret) ||
        text.contains(
          jsonEncode(secret).substring(1, jsonEncode(secret).length - 1),
        )) {
      throw StateError('Synthetic secret escaped public output');
    }
  }

  Future<void> record(Map<String, Object?> value) async {
    final text = jsonEncode(value);
    scan(text);
    await File('${folder.path}/state.json').writeAsString(text, flush: true);
    await File(
      '${folder.path}/events.jsonl',
    ).writeAsString('$text\n', mode: FileMode.append, flush: true);
    stdout.writeln(text);
  }

  final helperPath = await File(args[0]).resolveSymbolicLinks();
  final helper = FocusedFillApplication.fromJson({
    'executable': helperPath,
    'sha256': (await sha256.bind(File(helperPath).openRead()).first).toString(),
  });
  final driver = WindowsFocusedFillDriver(helper: helper);
  final service = InformationService(
    repository: MemoryInformationRepository(),
    focusedFillDriver: driver,
  );
  final browser = await BrowserFillReceiver.start(secret);
  final server = await AgentServer.start(
    service.agent,
    port: 0,
    enableReusableCredentialUse: true,
    enableFocusedFill: true,
  );
  final cli = await Process.start(File(args[1]).absolute.path, [
    '--port',
    '${server.port}',
  ]);
  final lines = StreamIterator(
    cli.stdout.transform(utf8.decoder).transform(const LineSplitter()),
  );
  final errors = cli.stderr.transform(utf8.decoder).join();
  PreparedFocusedFill? prepared;
  var requestedClose = false;
  try {
    var credential = await service.owner.createStringCredential(
      name: 'Synthetic Windows browser password',
      publicPurpose: 'Local disposable browser QA',
      secret: secret,
    );
    credential = await service.owner.updateCredentialMetadata(
      credential.id,
      credential.revision,
      name: credential.name,
      publicPurpose: credential.publicPurpose,
      privateNote: '',
      suggestedBinding: '',
      discoverable: true,
    );
    Future<Map<String, dynamic>> call(Map<String, Object?> value) async {
      cli.stdin.writeln(jsonEncode({'protocolVersion': 2, ...value}));
      await cli.stdin.flush();
      if (!await lines.moveNext().timeout(const Duration(seconds: 15))) {
        throw StateError('Synthetic CLI ended');
      }
      scan(lines.current);
      return jsonDecode(lines.current) as Map<String, dynamic>;
    }

    await call({
      'command': 'session',
      'chatLabel': 'Synthetic Windows browser QA',
      'externalChatId': 'synthetic-windows-browser-qa',
    });
    await record({'phase': 'ready', 'url': browser.url});
    FocusedFillApplication? application;
    String? request, operation;
    var seen = -1, operationSequence = 0;
    final until = DateTime.now().add(const Duration(minutes: 20));
    while (!requestedClose && DateTime.now().isBefore(until)) {
      final command = File('${folder.path}/command.json');
      Map<String, dynamic>? input;
      try {
        if (await command.exists()) {
          input =
              jsonDecode(await command.readAsString()) as Map<String, dynamic>;
        }
      } on FormatException {
        // An operator may still be finishing an atomic control-file write.
      }
      if (input == null || input['id'] is! int || input['id'] == seen) {
        await Future<void>.delayed(const Duration(milliseconds: 60));
        continue;
      }
      seen = input['id'] as int;
      final action = input['action'];
      try {
        Map<String, Object?> result;
        switch (action) {
          case 'probe':
            result = await call({'command': 'focus-target'});
          case 'authorize':
            final target = FocusedFillTarget.fromJson(
              await call({'command': 'focus-target'}),
            );
            application = target.application;
            if (application == null ||
                !{'msedge.exe', 'chrome.exe'}.contains(
                  application.executable
                      .replaceAll('\\', '/')
                      .split('/')
                      .last
                      .toLowerCase(),
                )) {
              throw StateError('A supported browser password must be focused');
            }
            final pending = await call({
              'command': 'request-use',
              'purpose': 'Fill the local synthetic browser test',
              'credentials': [
                {
                  'alias': 'password',
                  'credentialId': credential.id,
                  'version': credential.version,
                },
              ],
              'fill': {
                'application': application.toJson(),
                'targetHint': browser.url,
              },
            });
            request = pending['requestId'] as String;
            final blocked = await call({
              'command': 'fill-use',
              'requestId': request,
              'operationId': 'unapproved',
            });
            if (blocked['errorCode'] != 'request_pending') {
              throw StateError('Unapproved use was not refused');
            }
            await service.owner.decideCredentialUse(
              request,
              approveCredential: true,
              lifetime: const Duration(minutes: 15),
            );
            result = {
              'approved': true,
              'unapprovedBlocked': true,
              'application': application.toJson(),
            };
          case 'fill':
          case 'duplicate':
            if (request == null) throw StateError('No synthetic approval');
            if (action == 'fill') operation = 'browser-${++operationSequence}';
            final clipboard = sequenceNumber();
            final receipt = await call({
              'command': 'fill-use',
              'requestId': request,
              'operationId': operation,
            });
            await service.drainFocusedFills().timeout(
              const Duration(seconds: 15),
            );
            result = {
              'receipt': receipt,
              'status': await call({
                'command': 'fill-status',
                'requestId': request,
                'operationId': operation,
              }),
              'receiver': await browser.command(2),
              'clipboardUnchanged': clipboard == sequenceNumber(),
            };
          case 'reserve':
            prepared = await driver.prepare(application!);
            result = {'prepared': true};
          case 'send-reserved':
            final clipboard = sequenceNumber();
            final sent = await prepared!.sendBatch(
              secret.codeUnits.take(16).toList(),
            );
            result = {
              'batchState': sent.state.name,
              'errorCode': sent.errorCode,
              'receiver': await browser.command(2),
              'clipboardUnchanged': clipboard == sequenceNumber(),
            };
            await prepared.close();
            prepared = null;
          case 'clear':
            result = await browser.command(3);
          case 'arm-change':
            result = await browser.command(4);
          case 'query':
            result = await browser.command(2);
          case 'close':
            requestedClose = true;
            result = {'closing': true};
          default:
            throw StateError('Unknown synthetic action');
        }
        await record({'id': seen, 'action': action, 'result': result});
      } on Object catch (error) {
        await record({
          'id': seen,
          'action': action,
          'failed': true,
          'type': error.runtimeType.toString(),
        });
      }
    }
  } finally {
    await prepared?.close();
    await cli.stdin.close();
    await cli.exitCode.timeout(const Duration(seconds: 10));
    scan(await errors);
    await lines.cancel();
    await server.close();
    await service.close();
    await browser.close();
    await record({'phase': 'closed', 'requested': requestedClose});
  }
}
