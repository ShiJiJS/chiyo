import 'package:flutter/foundation.dart';
import 'package:info_core/agent_server.dart';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'desktop_runtime.dart';

/// The opened library remains owned here until authorization facts are saved.
class DesktopLibrary {
  const DesktopLibrary({
    required this.service,
    required this.close,
    this.backups,
  });
  final InformationService service;
  final Future<void> Function() close;
  final InformationBackups? backups;
}

enum DesktopStartupState { idle, starting, ready, failed }

class DesktopBootstrap extends ChangeNotifier {
  DesktopBootstrap({
    required this.openLibrary,
    required this.platform,
    this.port = 47125,
  });
  final Future<DesktopLibrary> Function() openLibrary;
  final DesktopPlatform platform;
  final int port;
  DesktopStartupState state = DesktopStartupState.idle;
  DesktopLibrary? library;
  DesktopRuntime? runtime;
  AgentServer? _server;
  int? boundPort;
  bool cleanupPending = false;

  Future<void> start() async {
    if (state == DesktopStartupState.starting ||
        state == DesktopStartupState.ready) {
      return;
    }
    state = DesktopStartupState.starting;
    notifyListeners();
    try {
      await _release();
      library = await openLibrary();
      _server = await AgentServer.start(library!.service.agent, port: port);
      boundPort = _server!.port;
      runtime = DesktopRuntime(
        service: library!.service,
        platform: platform,
        closeServer: _server!.close,
        closeRepository: library!.close,
      );
      await runtime!.start();
      await library!.service.owner.retryAuditStorage();
      state = DesktopStartupState.ready;
    } on Object {
      try {
        await _release();
      } on Object {
        // Keep the core, failed fact queue and library owned and retryable.
        // Cleanup failure must never prevent the error screen from appearing.
        cleanupPending = true;
      }
      state = DesktopStartupState.failed;
      try {
        await platform.showWindow();
      } on Object {
        // Native startup may also have failed; still render the error screen.
      }
    }
    notifyListeners();
  }

  Future<void> _release() async {
    if (runtime case final active?) {
      await active.stop();
      active.dispose();
    } else if (library case final opened?) {
      await Future.wait([
        opened.service.close(),
        if (_server case final server?) server.close(),
      ]);
      await opened.close();
    }
    runtime = null;
    _server = null;
    library = null;
    cleanupPending = false;
  }
}
