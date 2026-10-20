import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:info_core/agent_server.dart';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:test/test.dart';

const lifecyclePassword = 'Synthetic-password-中文';
const lifecycleCredential =
    '[default]\naws_access_key_id=TEST_ACCESS_ONLY\n'
    'aws_secret_access_key=SYNTHETIC_LIFECYCLE_NOT_A_REAL_KEY\n';
const lifecycleDocument = '这是可授权读取的虚构简历。';

Future<void> removeLifecycleDirectory(Directory root, String prefix) async {
  final base = await Directory.systemTemp.resolveSymbolicLinks();
  final actual = await root.resolveSymbolicLinks();
  if (root.absolute.path.toLowerCase() != actual.toLowerCase() ||
      !actual.toLowerCase().startsWith(
        '$base${Platform.pathSeparator}'.toLowerCase(),
      ) ||
      !root.uri.pathSegments
          .where((s) => s.isNotEmpty)
          .last
          .startsWith(prefix)) {
    throw StateError('Refusing cleanup outside this lifecycle fixture');
  }
  await root.delete(recursive: true);
}

class LifecycleAdapters {
  LifecycleAdapters._(this.root, this.bundle, this.host);
  final Directory root;
  final String bundle, host;
  static Future<LifecycleAdapters> build() async {
    final root = await Directory.systemTemp.createTemp(
      'aim-lifecycle-adapters-',
    );
    final cli = Directory('../info_cli').absolute.path;
    final supplied = Platform.environment['INFO_TEST_BUNDLE'];
    final output = supplied ?? root.path;
    final entries = {
      if (supplied == null) ...{
        'info-codex': 'bin/codex_info.dart',
        'info-codex-hook': 'bin/codex_hook.dart',
        'info-runtime-worker': 'bin/runtime_worker.dart',
      },
      'lifecycle-host': 'test/support/mixed_lifecycle_host.dart',
    };
    try {
      for (final entry in entries.entries) {
        final built = await Process.run(Platform.resolvedExecutable, [
          'compile',
          'exe',
          entry.value,
          '-o',
          '${root.path}/${entry.key}.exe',
        ], workingDirectory: cli);
        if (built.exitCode != 0) {
          throw StateError(
            'Cannot compile lifecycle ${entry.key}: ${built.stderr}',
          );
        }
      }
      for (final name in [
        'info-codex',
        'info-codex-hook',
        'info-runtime-worker',
      ]) {
        if (!await File('$output/$name.exe').exists()) {
          throw StateError('Incomplete lifecycle input bundle');
        }
      }
      return LifecycleAdapters._(
        root,
        output,
        '${root.path}/lifecycle-host.exe',
      );
    } on Object {
      await removeLifecycleDirectory(root, 'aim-lifecycle-adapters-');
      rethrow;
    }
  }

  Future<void> close() =>
      removeLifecycleDirectory(root, 'aim-lifecycle-adapters-');
}

class _Host {
  _Host(this.process)
    : lines = StreamIterator(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      ),
      errors = process.stderr.transform(utf8.decoder).join();
  final Process process;
  final StreamIterator<String> lines;
  final Future<String> errors;
  Future<void> _ordered = Future.value();
  bool closed = false;
  Future<Map<String, dynamic>> call(Map<String, Object?> message) {
    final result = Completer<Map<String, dynamic>>();
    _ordered = _ordered.then((_) async {
      try {
        if (closed) throw StateError('Lifecycle host already closed');
        process.stdin.writeln(jsonEncode(message));
        await process.stdin.flush();
        if (!await lines.moveNext().timeout(const Duration(seconds: 40))) {
          throw StateError('Lifecycle host ended before response');
        }
        result.complete(jsonDecode(lines.current) as Map<String, dynamic>);
      } on Object catch (e, s) {
        result.completeError(e, s);
      }
    });
    return result.future;
  }

  Future<void> drain() async {
    if (!closed) expect(await call({'action': 'drain'}), {'status': 'ok'});
  }

  Future<void> close({bool kill = false}) async {
    if (closed) return;
    if (kill) {
      process.kill();
    } else {
      expect(await call({'action': 'close'}), {'status': 'closed'});
    }
    closed = true;
    await process.stdin.close();
    final code = await process.exitCode.timeout(const Duration(seconds: 10));
    if (!kill) expect(code, 0);
    await lines.cancel();
    expect(await errors, isEmpty);
  }
}

class LifecycleFiles implements InformationDeliveryFiles {
  final native = WindowsInformationDeliveryFiles();
  final leases = <InformationDeliveryLease>[];
  @override
  Future<InformationDeliveryLease> reserve(String name) async {
    final lease = await native.reserve(name);
    leases.add(lease);
    return lease;
  }

  @override
  Future<void> write(InformationDeliveryLease lease, Uint8List body) =>
      native.write(lease, body);
  @override
  Future<void> verify(InformationDeliveryLease lease, int size, String hash) =>
      native.verify(lease, size, hash);
  @override
  Future<void> cleanup(InformationDeliveryLease lease) => native.cleanup(lease);
}

class LifecycleInput implements FocusedFillDiscoveryDriver {
  final application = FocusedFillApplication.fromJson({
    'executable': r'C:\Synthetic\LifecycleReceiver.exe',
    'sha256': '41' * 32,
  });
  int batches = 0;
  final completed = <String>[];
  @override
  Future<FocusedFillTarget> inspectTarget() async =>
      FocusedFillTarget.ready(application);
  @override
  Future<PreparedFocusedFill> prepare(FocusedFillApplication actual) async {
    if (!actual.matches(application))
      throw const CredentialUseFailure('application_changed');
    return _Prepared(this);
  }
}

class _Prepared implements PreparedFocusedFill {
  _Prepared(this.driver);
  final LifecycleInput driver;
  final received = <int>[];
  @override
  FocusedFillApplication get application => driver.application;
  @override
  Future<FocusedFillBatchResult> sendBatch(List<int> units) async {
    driver.batches++;
    received.addAll(units);
    return const FocusedFillBatchResult(FocusedFillState.sent);
  }

  @override
  Future<void> close() async {
    if (received.isNotEmpty) {
      driver.completed.add(
        sha256.convert(utf8.encode(String.fromCharCodes(received))).toString(),
      );
    }
    received.fillRange(0, received.length, 0);
  }
}

/// Actual encrypted repository/DPAPI, AOT hook/adapter/host/worker and Windows
/// files/Jobs; focused input and tool classification are controlled fixtures.
class MixedLifecycle {
  MixedLifecycle(this.adapters);
  final LifecycleAdapters adapters;
  late Directory root;
  late WindowsDatabaseKeyStore keys;
  late EncryptedInformationRepository repository;
  late InformationService service;
  late AgentServer server;
  late _Host host;
  final files = LifecycleFiles();
  final input = LifecycleInput();
  late ExecutableIdentity executable;
  late InformationItem item;
  late ManagedCredential password, credentialFile;
  String? association;
  final privateReferences = <String>[];
  String? ordinaryRequest, fillRequest, commandRequest, executionId;
  Map<String, dynamic>? documentCopy;
  File? material;
  sqlite.Database? blocker;
  DateTime now = DateTime.now().toUtc();
  final chat = 'synthetic-lifecycle';
  Future<void> start() async {
    root = await Directory.systemTemp.createTemp('aim-mixed-lifecycle-');
    keys = WindowsDatabaseKeyStore('${root.path}/database-key.dpapi');
    final target = File(Platform.resolvedExecutable);
    final stat = await target.stat();
    executable = ExecutableIdentity(
      target.path,
      stat.size,
      stat.modified.microsecondsSinceEpoch,
      'sha256:${sha256.convert(await target.readAsBytes())}',
    );
    await _open();
    addTearDown(close);
    item = await saveDocument(lifecycleDocument);
    password = await service.owner.createStringCredential(
      name: 'Synthetic password',
      publicPurpose: 'Local input test',
      secret: lifecyclePassword,
    );
    credentialFile = await service.owner.createFileCredential(
      name: 'Synthetic file credential',
      publicPurpose: 'Local receiver test',
      fileName: 'credentials.ini',
      bytes: utf8.encode(lifecycleCredential),
    );
    Future<ManagedCredential> publish(ManagedCredential c) =>
        service.owner.updateCredentialMetadata(
          c.id,
          c.revision,
          name: c.name,
          publicPurpose: c.publicPurpose,
          privateNote: '',
          suggestedBinding: '',
          discoverable: true,
        );
    password = await publish(password);
    credentialFile = await publish(credentialFile);
    final started = await hook({
      'hook_event_name': 'SessionStart',
      'source': 'startup',
      'session_id': chat,
    });
    association =
        jsonDecode(
              started['hookSpecificOutput']['additionalContext'] as String,
            )['association']
            as String;
    privateReferences.add(association!);
  }

  Future<void> _open({int port = 0}) async {
    repository = await EncryptedInformationRepository.open(
      '${root.path}/vault',
      keys,
      clock: () => now,
    );
    service = InformationService(
      repository: repository,
      clock: () => now,
      informationDeliveryFiles: files,
      focusedFillDriver: input,
      focusedFillApplicationInspector: (a) async => a,
      credentialExecutableInspector: (path, receiver) async => executable,
    );
    server = await AgentServer.start(
      service.agent,
      port: port,
      enableReusableCredentialUse: true,
      enableFocusedFill: true,
      enableInformationFiles: true,
      credentialExecutionHandler: (session, command) =>
          host.call({'session': session, 'input': command}),
    );
    host = _Host(await Process.start(adapters.host, []));
    expect(
      await host.call({
        'action': 'initialize',
        'port': server.port,
        'worker': '${adapters.bundle}/info-runtime-worker.exe',
      }),
      {'status': 'ready'},
    );
  }

  void checkOutput(String raw) {
    for (final value in [
      lifecyclePassword,
      lifecycleCredential,
      'TEST_ACCESS_ONLY',
      'SYNTHETIC_LIFECYCLE_NOT_A_REAL_KEY',
      ...privateReferences,
    ]) {
      final encoded = jsonEncode(value);
      expect(raw, isNot(contains(value)));
      expect(raw, isNot(contains(encoded.substring(1, encoded.length - 1))));
    }
    expect(raw, isNot(contains('"sessionSecret"')));
    expect(raw, isNot(contains('"endCapability"')));
  }

  Future<Map<String, dynamic>> invoke(
    String executable,
    Map<String, dynamic> data, {
    List<String> args = const [],
  }) async {
    final process = await Process.start(
      '${adapters.bundle}/$executable.exe',
      args,
      environment: {'CODEX_THREAD_ID': chat},
    );
    final stdout = process.stdout.transform(utf8.decoder).join(),
        stderr = process.stderr.transform(utf8.decoder).join();
    var exited = false;
    try {
      process.stdin.writeln(jsonEncode(data));
      await process.stdin.close();
      expect(await process.exitCode.timeout(const Duration(seconds: 20)), 0);
      exited = true;
      final raw = await stdout, errors = await stderr;
      checkOutput('$raw$errors');
      expect(errors, isEmpty);
      return jsonDecode(raw) as Map<String, dynamic>;
    } finally {
      if (!exited) {
        process.kill();
        await process.exitCode.timeout(const Duration(seconds: 5));
      }
    }
  }

  Future<Map<String, dynamic>> hook(Map<String, dynamic> data) => invoke(
    'info-codex-hook',
    data,
    args: [
      '--port',
      '${server.port}',
      '--state-root',
      '${root.path}/associations',
    ],
  );
  Future<Map<String, dynamic>> call(Map<String, dynamic> input) =>
      invoke('info-codex', {'association': association, ...input});
  Map<String, dynamic> fetch(String operation) => {
    'command': 'file-fetch',
    'requestId': ordinaryRequest,
    'itemId': item.id,
    'fieldId': item.fields.last.id,
    'operationId': operation,
  };
  Map<String, dynamic> fill(String operation) => {
    'command': 'fill-use',
    'requestId': fillRequest,
    'operationId': operation,
  };
  Map<String, dynamic> get launch => {
    'receiver': 'aws_shared_credentials',
    'executable': executable.path,
    'argv': ['sts', 'get-caller-identity', '--region', 'us-east-1'],
    'cwd': root.path,
    'env': {
      'AWS_SHARED_CREDENTIALS_FILE': {'file': 'token'},
    },
  };
  Map<String, dynamic> run(String operation) => {
    'command': 'run-use',
    'requestId': commandRequest,
    'operationId': operation,
    'launch': launch,
  };
  Map<String, dynamic> delivery(Map<String, dynamic> reply) {
    expect(reply['status'], 'ok', reason: '$reply');
    return Map<String, dynamic>.from(reply['delivery'] as Map);
  }

  Future<InformationItem> saveDocument(
    String text, [
    InformationItem? before,
  ]) async {
    final file = File('${root.path}/private-resume.txt');
    await file.writeAsString(text);
    final draft = await service.owner.beginInformationFileDraft();
    try {
      final stage = await service.owner.stageInformationFile(
        draft,
        file.path,
        mediaType: 'text/plain',
      );
      return await service.owner.commitInformationDraft(
        draft,
        'save-${before?.version ?? 0}',
        InformationDraftInput(
          name: 'Synthetic profile',
          description: '',
          itemId: before?.id,
          baseVersion: before?.version,
          fields: [
            InformationDraftField.text(
              'Name',
              '',
              'Synthetic name',
              fieldId: before?.fields.first.id,
            ),
            InformationDraftField.stagedFile(
              'Resume',
              '',
              stage.id,
              fieldId: before?.fields.last.id,
            ),
          ],
        ),
      );
    } finally {
      await service.owner.releaseInformationFileDraft(draft);
    }
  }

  Future<void> approveThree() async {
    final ordinary = await call({
      'command': 'request',
      'purpose': 'Read synthetic resume',
      'fields': [
        for (final f in item.fields) {'itemId': item.id, 'fieldId': f.id},
      ],
    });
    expect(ordinary['status'], 'pending');
    ordinaryRequest = ordinary['requestId'] as String;
    service.owner.approve(ordinaryRequest!, [
      for (final f in item.fields) FieldRef(item.id, f.id),
    ], lifetime: const Duration(minutes: 15));
    await service.owner.retryAuditStorage();
    final focused = await call({
      'command': 'request-use',
      'purpose': 'Synthetic focused input',
      'credentials': [
        {'alias': 'password', 'credentialId': password.id, 'version': 1},
      ],
      'fill': {
        'application': input.application.toJson(),
        'targetHint': 'Synthetic local receiver',
      },
    });
    expect(focused['status'], 'pending', reason: '$focused');
    fillRequest = focused['requestId'] as String;
    await service.owner.decideCredentialUse(
      fillRequest!,
      approveCredential: true,
    );
    final command = await call({
      'command': 'request-use',
      'purpose': 'Synthetic file receiver',
      'credentials': [
        {'alias': 'token', 'credentialId': credentialFile.id, 'version': 1},
      ],
      'launch': launch,
    });
    expect(command['status'], 'pending', reason: '$command');
    commandRequest = command['requestId'] as String;
    await service.owner.decideCredentialUse(
      commandRequest!,
      approveCredential: true,
    );
    await writeReceiver();
  }

  Future<void> writeReceiver() async {
    await File('${root.path}/sts').writeAsString('''
import 'dart:async'; import 'dart:convert'; import 'dart:io';
Future<void> main() async {
  final path = Platform.environment['AWS_SHARED_CREDENTIALS_FILE']!;
  final body = File(path).readAsStringSync();
  final countFile = File('receiver-count');
  final count = countFile.existsSync() ? int.parse(countFile.readAsStringSync()) : 0;
  countFile.writeAsStringSync((count + 1).toString());
  stdout.write(body); await stdout.flush();
  File('receiver-ready.json').writeAsStringSync(jsonEncode({'path': path, 'matches': body == ${jsonEncode(lifecycleCredential)}}), flush: true);
  final end = DateTime.now().add(const Duration(seconds: 60));
  while (!File('release-receiver').existsSync() && DateTime.now().isBefore(end)) { await Future<void>.delayed(const Duration(milliseconds: 30)); }
}
''');
  }

  Future<void> useThree() async {
    documentCopy = delivery(await call(fetch('document-01')));
    expect(
      await File(documentCopy!['path'] as String).readAsString(),
      lifecycleDocument,
    );
    expect((await call(fill('fill-01')))['status'], 'accepted');
    await service.drainFocusedFills();
    expect(input.completed, [
      sha256.convert(utf8.encode(lifecyclePassword)).toString(),
    ]);
    final accepted = await call(run('command-01'));
    expect(accepted['status'], 'accepted', reason: '$accepted');
    executionId = accepted['executionId'] as String;
    await until(
      () => File('${root.path}/receiver-ready.json').exists(),
      'Controlled credential receiver did not start',
    );
    final ready =
        jsonDecode(
              await File('${root.path}/receiver-ready.json').readAsString(),
            )
            as Map;
    expect(ready['matches'], true);
    material = File(ready['path'] as String);
    expect(await material!.exists(), true);
    expect(
      service.owner.credentialExecutions.single.supervisorPid,
      host.process.pid,
    );
  }

  Future<void> until(Future<bool> Function() check, String failure) async {
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (!await check()) {
      if (DateTime.now().isAfter(deadline)) fail(failure);
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
  }

  Future<void> releaseReceiver() async {
    await File(
      '${root.path}/release-receiver',
    ).writeAsString('released', flush: true);
    await host.drain();
    await until(() async {
      await service.owner.reconcileCredentialMaterialCleanup();
      return material == null || !await material!.exists();
    }, 'Registered credential material was not reclaimed after its Job ended');
  }

  Future<void> restart() async {
    final port = server.port;
    await host.close(kill: true);
    await server.close();
    await service.close();
    await repository.close();
    await _open(port: port);
    await service.owner.reconcileInformationFileDeliveries();
    await service.owner.reconcileCredentialMaterialCleanup();
  }

  Future<void> lockWrites() async {
    final key = await keys.read();
    if (key == null) throw StateError('Missing isolated key');
    final db = sqlite.sqlite3.open('${root.path}/vault/library.db');
    try {
      final hex = key.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      db.execute('PRAGMA key = "x\'$hex\'"');
      db.execute('BEGIN IMMEDIATE');
      blocker = db;
    } on Object {
      db.close();
      throw StateError('Cannot lock the isolated encrypted test database');
    } finally {
      key.fillRange(0, key.length, 0);
    }
  }

  void unlockWrites() {
    final db = blocker;
    blocker = null;
    if (db != null) {
      db.execute('ROLLBACK');
      db.close();
    }
  }

  Future<void> close() async {
    unlockWrites();
    await releaseReceiver();
    await host.close();
    await service.owner.retryAuditStorage();
    await service.owner.reconcileInformationFileDeliveries();
    await server.close();
    await service.close();
    await repository.close();
    for (final lease in files.leases) {
      expect(await File(lease.filePath).exists(), false);
    }
    await removeLifecycleDirectory(root, 'aim-mixed-lifecycle-');
  }
}
