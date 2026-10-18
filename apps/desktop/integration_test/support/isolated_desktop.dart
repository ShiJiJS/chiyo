import 'dart:io';

import 'package:info_desktop/desktop_bootstrap.dart';
import 'package:info_desktop/desktop_runtime.dart';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';

/// A native test library whose database, DPAPI envelope and port are isolated.
/// This never calls the application's default-profile bootstrap.
class IsolatedDesktopFixture {
  IsolatedDesktopFixture._(this.root, this.bootstrap);

  final Directory root;
  final DesktopBootstrap bootstrap;
  InformationService get service => bootstrap.library!.service;
  int get port => bootstrap.boundPort!;

  /// Normal native tests retain the inert OS adapter. Only an explicit manual
  /// probe supplies a native platform; preparation runs before runtime request
  /// subscriptions so preloading a queue never emits a burst of OS balloons.
  static Future<IsolatedDesktopFixture> start({
    DesktopPlatform? platform,
    Future<void> Function(InformationService)? prepareLibrary,
    String? credentialWorkerExecutable,
  }) async {
    final root = await Directory.systemTemp.createTemp('aim-native-approval-');
    final bootstrap = DesktopBootstrap(
      port: 0,
      credentialWorkerExecutable: credentialWorkerExecutable,
      platform: platform ?? _AcceptancePlatform(),
      openLibrary: () async {
        final repository = await EncryptedInformationRepository.open(
          root.path,
          WindowsDatabaseKeyStore('${root.path}/database-key.dpapi'),
        );
        final service = InformationService(repository: repository);
        try {
          await service.owner.createInformation(
            'Native fictional server',
            'Synthetic information used only by the isolated native test.',
            const [
              FieldInput('Address', 'Fictional host', 'native.example.invalid'),
              FieldInput('Username', 'Fictional login', 'native-demo-user'),
            ],
          );
          await prepareLibrary?.call(service);
        } catch (_) {
          await service.close();
          await repository.close();
          rethrow;
        }
        return DesktopLibrary(
          service: service,
          backups: repository.backups,
          close: repository.close,
        );
      },
    );
    final fixture = IsolatedDesktopFixture._(root, bootstrap);
    try {
      await bootstrap.start();
      if (bootstrap.state != DesktopStartupState.ready) {
        throw StateError('Isolated native library did not start.');
      }
      return fixture;
    } catch (_) {
      await fixture.close();
      rethrow;
    }
  }

  Future<void> close() async {
    if (bootstrap.runtime case final runtime?) {
      await runtime.stop();
      runtime.dispose();
    } else if (bootstrap.library case final library?) {
      await library.service.close();
      await library.close();
    }
    bootstrap.dispose();
    // Resolve both boundaries before recursive removal. Never remove a source,
    // user profile, substituted link, or a directory not created by this test.
    final parent = await Directory.systemTemp.resolveSymbolicLinks();
    final target = root.absolute.path;
    final actual = await root.resolveSymbolicLinks();
    final prefix = '$parent${Platform.pathSeparator}'.toLowerCase();
    if (!target.toLowerCase().startsWith(prefix) ||
        target.toLowerCase() != actual.toLowerCase() ||
        !root.uri.pathSegments
            .where((part) => part.isNotEmpty)
            .last
            .startsWith('aim-native-approval-')) {
      throw StateError('Refusing cleanup outside the isolated fixture.');
    }
    await root.delete(recursive: true);
  }
}

/// The Flutter Windows runner and window frame are real. This OS boundary is
/// deliberately inert so tests cannot hide a user window, create tray entries,
/// send notifications, or terminate the integration runner during teardown.
class _AcceptancePlatform implements DesktopPlatform {
  @override
  String? get openedRequestId => null;
  @override
  Future<DesktopAvailability> initialize(
    Future<void> Function(DesktopEvent) onEvent,
  ) async => DesktopAvailability.unavailable;
  @override
  Future<bool> hideWindow() async => false;
  @override
  Future<void> showWindow() async {}
  @override
  Future<bool> notifyNewRequest(String requestId) async => false;
  @override
  Future<bool> notifyTest() async => false;
  @override
  Future<DesktopAvailability> readAvailability() async =>
      DesktopAvailability.unavailable;
  @override
  Future<DesktopAvailability> requestNotificationPermission() async =>
      DesktopAvailability.unavailable;
  @override
  Future<void> terminate() async {}
}
