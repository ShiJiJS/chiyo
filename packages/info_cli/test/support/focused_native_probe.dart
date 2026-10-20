// Interactive synthetic receiver harness, not a public CLI command. It keeps
// its random fake value in this process and the private receiver/broker pipes.
// Commands/results on disk contain actions and public facts only.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:info_cli/windows_focused_fill.dart';
import 'package:info_core/info_core.dart';
import 'package:info_core/agent_server.dart';

Future<FocusedFillApplication> identity(String path) async =>
    FocusedFillApplication.fromJson({
      'executable': await File(path).resolveSymbolicLinks(),
      'sha256': (await sha256.bind(File(path).openRead()).first).toString(),
    });
Future<void> main(List<String> args) async {
  if (args.length != 4) {
    exitCode = 64;
    return;
  }
  final folder = Directory(args[3]);
  await folder.create(recursive: true);
  final command = File('${folder.path}/command.json'),
      state = File('${folder.path}/state.json');
  final events = File('${folder.path}/events.jsonl');
  final random = Random.secure();
  final secret =
      '  A1b2C3d4E5f6G7h8${base64Url.encode(List.generate(24, (_) => random.nextInt(256)))}中文🧭  ';
  void scan(String text) {
    if (text.contains(secret) ||
        text.contains(
          jsonEncode(secret).substring(1, jsonEncode(secret).length - 1),
        )) {
      throw StateError('Synthetic value escaped private channel');
    }
  }

  Future<void> record(Map<String, Object?> value) async {
    final text = jsonEncode(value);
    scan(text);
    await state.writeAsString(text, flush: true);
    await events.writeAsString('$text\n', mode: FileMode.append, flush: true);
  }

  Process? receiver, cli;
  InformationService? service;
  AgentServer? server;
  PreparedFocusedFill? reservation;
  StreamIterator<String>? receiverLines, cliLines;
  final helper = await identity(args[0]), application = await identity(args[1]);
  var closed = false;
  try {
    receiver = await Process.start(application.executable, []);
    receiverLines = StreamIterator(
      receiver.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    Future<Map<String, dynamic>> receiverResponse() async {
      final lines = receiverLines!;
      if (!await lines.moveNext().timeout(const Duration(seconds: 5))) {
        throw StateError('Receiver ended');
      }
      scan(lines.current);
      return jsonDecode(lines.current) as Map<String, dynamic>;
    }

    if ((await receiverResponse())['event'] != 'window_ready') {
      throw StateError('Receiver not ready');
    }
    Future<Map<String, dynamic>> receiverCall(int code, [String? value]) async {
      final units = value?.codeUnits ?? const <int>[];
      final bytes = Uint8List(1 + units.length * 2);
      bytes[0] = code;
      final view = ByteData.sublistView(bytes);
      for (var i = 0; i < units.length; i++) {
        view.setUint16(1 + i * 2, units[i], Endian.little);
      }
      final header = ByteData(4)..setUint32(0, bytes.length, Endian.little);
      receiver!.stdin.add(header.buffer.asUint8List());
      receiver.stdin.add(bytes);
      await receiver.stdin.flush();
      bytes.fillRange(0, bytes.length, 0);
      return receiverResponse();
    }

    await receiverCall(1, secret);
    final driver = WindowsFocusedFillDriver(helper: helper);
    service = InformationService(
      repository: MemoryInformationRepository(),
      focusedFillDriver: driver,
    );
    var credential = await service.owner.createStringCredential(
      name: 'Synthetic native password',
      publicPurpose: 'Local test only',
      secret: secret,
      suggestedBinding: '',
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
    server = await AgentServer.start(
      service.agent,
      port: 0,
      enableReusableCredentialUse: true,
      enableFocusedFill: true,
    );
    cli = await Process.start(args[2], ['--port', '${server.port}']);
    cliLines = StreamIterator(
      cli.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    final errorDrain = cli.stderr.listen((data) {
      scan(utf8.decode(data, allowMalformed: true));
    });
    final receiverErrors = receiver.stderr.listen((data) {
      scan(utf8.decode(data, allowMalformed: true));
    });
    Future<Map<String, dynamic>> call(Map<String, Object?> input) async {
      cli!.stdin.writeln(jsonEncode(input));
      await cli.stdin.flush();
      final lines = cliLines!;
      if (!await lines.moveNext().timeout(const Duration(seconds: 12))) {
        throw StateError('CLI ended');
      }
      scan(lines.current);
      return jsonDecode(lines.current) as Map<String, dynamic>;
    }

    await call({
      'command': 'session',
      'chatLabel': 'Independent native focused-fill CLI',
    });
    await record({
      'phase': 'awaiting_focus',
      'application': application.toJson(),
      'secretNotPrintedByHarness': true,
    });
    stdout.writeln(
      jsonEncode({'phase': 'native_probe_ready', 'directory': folder.path}),
    );
    String? requestId, lastOperation;
    DateTime? deadline;
    var seen = -1, sequence = 0, approvals = 0;
    final until = DateTime.now().add(const Duration(minutes: 4));
    while (!closed && DateTime.now().isBefore(until)) {
      Map<String, dynamic>? next;
      try {
        if (await command.exists()) {
          next =
              jsonDecode(await command.readAsString()) as Map<String, dynamic>;
        }
      } on Object {
        /* incomplete control file */
      }
      if (next == null || next['id'] is! int || next['id'] == seen) {
        await Future<void>.delayed(const Duration(milliseconds: 60));
        continue;
      }
      seen = next['id'] as int;
      final action = next['action'];
      try {
        Map<String, Object?> result;
        switch (action) {
          case 'reserve':
            reservation = await driver.prepare(application);
            result = {'reservedForContentionTest': true};
          case 'release':
            await reservation?.close();
            reservation = null;
            result = {'reservationClosed': true};
          case 'scan-snapshot':
            final snapshot = await File(
              '${folder.path}/tool-snapshot.json',
            ).readAsString();
            scan(snapshot);
            result = {'normalToolSnapshotExactAndEscapedScan': true};
          case 'probe':
            result = await call({'command': 'focus-target'});
            if (result['targetState'] == 'ready') {
              final observed = FocusedFillTarget.fromJson(
                Map<String, dynamic>.from(result),
              );
              if (!application.matches(observed.application!)) {
                throw StateError('Another application was focused');
              }
            }
          case 'authorize':
            final requested = await call({
              'command': 'request-use',
              'purpose': 'Synthetic local native input test',
              'credentials': [
                {
                  'alias': 'password',
                  'credentialId': credential.id,
                  'version': 1,
                },
              ],
              'fill': {
                'application': application.toJson(),
                'targetHint': 'Synthetic local masked control',
              },
            });
            requestId = requested['requestId'] as String;
            await service.owner.decideCredentialUse(
              requestId,
              approveCredential: true,
            );
            approvals++;
            deadline =
                service.owner.credentialUseRequests.single.credentialExpiresAt;
            result = {
              'approved': true,
              'approvals': approvals,
              'requestId': requestId,
            };
          case 'fill':
          case 'duplicate':
            if (requestId == null) {
              throw StateError('No synthetic owner approval');
            }
            if (action == 'fill') lastOperation = 'native-${++sequence}';
            final accepted = await call({
              'command': 'fill-use',
              'requestId': requestId,
              'operationId': lastOperation,
            });
            await service.drainFocusedFills().timeout(
              const Duration(seconds: 15),
            );
            result = {
              'receipt': accepted,
              'status': await call({
                'command': 'fill-status',
                'requestId': requestId,
                'operationId': lastOperation,
              }),
              'receiver': await receiverCall(2),
              'approvals': approvals,
              'deadlineUnchanged':
                  service
                      .owner
                      .credentialUseRequests
                      .single
                      .credentialExpiresAt ==
                  deadline,
            };
          case 'clear':
            result = await receiverCall(3);
          case 'arm-change':
            result = await receiverCall(4);
          case 'query':
            result = await receiverCall(2);
          case 'acknowledge':
            await service.owner.acknowledgeFocusedFillAttention(
              service.owner.focusedFillOperations.last.id,
            );
            result = {'ownerReviewed': true};
          case 'revoke':
            await service.owner.revokeCredentialUse(requestId!);
            result = {'revoked': true};
          case 'close':
            closed = true;
            result = {'closing': true};
          default:
            result = {'unsupportedAction': true};
        }
        await record({'id': seen, 'action': action, 'result': result});
      } on Object {
        await record({'id': seen, 'action': action, 'testStepFailed': true});
      }
    }
    await errorDrain.cancel();
    await receiverErrors.cancel();
  } on Object {
    await record({'phase': 'probe_failed', 'rawErrorNotRecorded': true});
    exitCode = 1;
  } finally {
    await reservation?.close();
    try {
      await cli?.stdin.close();
      await receiver?.stdin.close();
    } on Object {
      /* no secret diagnostics */
    }
    await cliLines?.cancel();
    await receiverLines?.cancel();
    for (final process in [cli, receiver]) {
      if (process == null) continue;
      try {
        await process.exitCode.timeout(const Duration(seconds: 2));
      } on Object {
        process.kill();
        await process.exitCode;
      }
    }
    await server?.close();
    await service?.close();
    await File(
      '${folder.path}/closed.json',
    ).writeAsString(jsonEncode({'closed': true, 'requested': closed}));
  }
}
