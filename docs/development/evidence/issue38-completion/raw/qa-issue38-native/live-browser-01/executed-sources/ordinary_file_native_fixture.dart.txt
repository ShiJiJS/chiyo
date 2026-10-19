import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/desktop_bootstrap.dart';
import '../../test/support/desktop_platform_fixture.dart';

/// Real Windows DPAPI/SQLCipher, file driver and endpoint; inert tray/toasts.
/// Reopening uses the same owned test directory, never the default profile.
class NativeOrdinaryFileLibrary {
  NativeOrdinaryFileLibrary(this.root);
  final Directory root;
  DesktopBootstrap? _bootstrap;
  EncryptedInformationRepository? _repository;
  DesktopBootstrap get bootstrap => _bootstrap!;
  InformationService get service => bootstrap.library!.service;
  OwnerAccess get owner => service.owner;
  InformationBackups get backups => _repository!.backups;
  int get port => bootstrap.boundPort!;
  Future<void> open() async {
    expect(_bootstrap, isNull);
    _bootstrap = DesktopBootstrap(
      port: 0,
      platform: NativeDesktopFixture(),
      openLibrary: () async {
        final repository = await EncryptedInformationRepository.open(
          root.path,
          WindowsDatabaseKeyStore('${root.path}/database-key.dpapi'),
        );
        _repository = repository;
        return DesktopLibrary(
          service: InformationService(
            repository: repository,
            informationDeliveryFiles: WindowsInformationDeliveryFiles(),
          ),
          backups: repository.backups,
          close: repository.close,
        );
      },
    );
    await bootstrap.start();
    expect(bootstrap.state, DesktopStartupState.ready);
  }

  Future<void> close() async {
    final boot = _bootstrap;
    if (boot == null) return;
    if (boot.runtime case final runtime?) {
      await runtime.stop();
      runtime.dispose();
    } else if (boot.library case final library?) {
      await library.service.close();
      await library.close();
    }
    boot.dispose();
    _bootstrap = null;
    _repository = null;
  }

  Future<List<int>> read(InformationAttachmentRef reference, int size) =>
      _repository!.readInformationAttachmentChunk(reference, 0, size);
}

/// Independent AOT CLI; its private session/grant material stays in-process.
class NativeOrdinaryFileCli {
  NativeOrdinaryFileCli._(this._process, this._lines, this._errors);
  final Process _process;
  final StreamIterator<String> _lines;
  final Future<void> _errors;
  static Future<NativeOrdinaryFileCli> start(
    String executable,
    int port,
    String cwd,
  ) async {
    final process = await Process.start(executable, [
      '--port',
      '$port',
    ], workingDirectory: cwd);
    return NativeOrdinaryFileCli._(
      process,
      StreamIterator(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      ),
      process.stderr.drain<void>(),
    );
  }

  Future<Map<String, dynamic>> command(Map<String, Object?> input) async {
    _process.stdin.writeln(jsonEncode(input));
    expect(
      await _lines.moveNext().timeout(const Duration(seconds: 40)),
      isTrue,
    );
    return jsonDecode(_lines.current) as Map<String, dynamic>;
  }

  Future<void> close() async {
    await _process.stdin.close();
    expect(await _process.exitCode.timeout(const Duration(seconds: 20)), 0);
    await _lines.cancel();
    await _errors;
  }
}
