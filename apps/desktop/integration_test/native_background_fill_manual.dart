// Ordinary Flutter binding, production launcher/adapters and real approval UI.
// Only the library, key and credential are isolated synthetic fixtures. External
// acceptance invokes the compiled public CLI; this entry cannot approve or fill.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:info_cli/chiyo_context.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/desktop_bootstrap.dart';
import 'package:info_desktop/main.dart' show DesktopLauncher;
import 'package:info_desktop/storage_desktop_launcher.dart';
import 'package:info_remote/agent_connection.dart';
import 'package:info_remote/connection_profile.dart';
import 'package:info_remote/local_library_configuration.dart';
import 'package:info_storage/info_storage.dart';

class _SyntheticKey implements DatabaseKeyStore {
  List<int>? _value;
  @override
  Future<List<int>?> read() async => _value;
  @override
  Future<void> create(List<int> key) async {
    if (_value != null) throw const StorageFailure('key_creation_failed');
    _value = List<int>.of(key);
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const enabled = bool.fromEnvironment('NATIVE_FILL_QA');
  if (!enabled || !(Platform.isMacOS || Platform.isWindows)) {
    throw StateError('Explicit native background acceptance only');
  }
  final created = await Directory.systemTemp.createTemp('chiyo-native-app-');
  final root = Directory(await created.resolveSymbolicLinks());
  final configuration = await LocalLibraryConfiguration.open(root.path);
  final repository = await EncryptedInformationRepository.open(
    configuration.libraryDirectory,
    _SyntheticKey(),
  );
  final service = InformationService(repository: repository);
  final credential = await service.owner.createStringCredential(
    name: '原生后台填写 · 合成 ZIP 密码',
    publicPurpose: '仅本次隔离验收',
    secret: 'Synthetic-Zip-42!',
  );
  await service.owner.updateCredentialMetadata(
    credential.id,
    credential.revision,
    name: credential.name,
    publicPurpose: credential.publicPurpose,
    privateNote: '',
    suggestedBinding: 'password',
    discoverable: true,
  );
  DesktopBootstrap? bootstrap;
  var opened = false, closed = false;
  final closedSignal = Completer<void>();
  runApp(
    StorageDesktopLauncher(
      profiles: PrivateConnectionProfileStore(root.path),
      openLocal: (_, _) async {
        if (opened) throw StateError('Synthetic library already owned');
        opened = true;
        return DesktopLibrary(
          service: service,
          close: () async {
            await repository.close();
            closed = true;
            if (!closedSignal.isCompleted) closedSignal.complete();
          },
        );
      },
      localBuilder: (value) {
        bootstrap = value;
        return DesktopLauncher(bootstrap: value, useWorkspace: true);
      },
    ),
  );
  Future<void> until(bool Function() ready) async {
    final deadline = DateTime.now().add(const Duration(seconds: 45));
    while (!ready()) {
      if (closed || !DateTime.now().isBefore(deadline)) {
        throw StateError('Synthetic App bootstrap did not become ready');
      }
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
  }

  try {
    await until(() => bootstrap?.state == DesktopStartupState.ready);
    final profile = bootstrap!.localConnection!;
    final connection = AgentConnection(profile);
    try {
      final session = await connection.call('/session/lifecycle', {
        'chatLabel': '原生后台填写 · 完整 App/CLI 合成验收',
      });
      final contextFile = File('${root.path}/chat/context.json');
      await ChiyoContext(
        chatId: 'synthetic-native-app',
        agentName: 'Synthetic acceptance Agent',
        secret: session['sessionSecret'] as String,
        port: profile.address.port,
        connection: profile,
      ).saveNew(contextFile);
      await until(
        () => File(
          '${root.path}/credential-batch-host/endpoint.json',
        ).existsSync(),
      );
      stdout.writeln(
        'NATIVE_FILL_APP_READY=${jsonEncode({'root': root.path, 'contextFile': contextFile.path, 'credentialId': credential.id, 'encrypted': true, 'nativeDriverInjected': false})}',
      );
      await stdout.flush();
      while (!closed && !await File('${root.path}/stop').exists()) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    } finally {
      connection.close();
    }
  } finally {
    if (!closed) {
      runApp(const SizedBox.shrink());
      if (opened && bootstrap != null) {
        await bootstrap!.close();
        await closedSignal.future.timeout(const Duration(seconds: 15));
      } else {
        await service.close();
        await repository.close();
      }
    }
    final actual = await root.resolveSymbolicLinks();
    final parent = await Directory.systemTemp.resolveSymbolicLinks();
    if (actual != root.path ||
        !actual.startsWith('$parent${Platform.pathSeparator}') ||
        !root.uri.pathSegments
            .where((part) => part.isNotEmpty)
            .last
            .startsWith('chiyo-native-app-')) {
      throw StateError('Synthetic cleanup boundary changed');
    }
    await root.delete(recursive: true);
    stdout.writeln('NATIVE_FILL_APP_CLOSED');
    await stdout.flush();
  }
  exit(0);
}
