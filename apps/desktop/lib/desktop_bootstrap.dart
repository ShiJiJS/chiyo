import 'dart:async';
import 'package:flutter/foundation.dart';
import 'dart:io';
import 'package:info_cli/credential_execution_host.dart';
import 'package:info_core/agent_server.dart';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'desktop_runtime.dart';
import 'bundled_focused_fill.dart';

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
    this.credentialWorkerExecutable,
  });
  final Future<DesktopLibrary> Function() openLibrary;
  final DesktopPlatform platform;
  final int port;
  final String? credentialWorkerExecutable;
  DesktopStartupState state = DesktopStartupState.idle;
  DesktopLibrary? library;
  DesktopRuntime? runtime;
  AgentServer? _server;
  CredentialExecutionHost? _credentialExecutions;
  int? boundPort;
  bool cleanupPending = false;
  bool applicationFilesInvalid = false;
  Completer<void>? _startupSettled;

  Future<void> start() async {
    if (state == DesktopStartupState.starting ||
        state == DesktopStartupState.ready) {
      return;
    }
    state = DesktopStartupState.starting;
    final settled = _startupSettled = Completer<void>();
    applicationFilesInvalid = false;
    notifyListeners();
    try {
      // Install the lifetime entry before opening data. A failed key/open must
      // still be closable, and a quit during startup waits for owned work.
      await platform.initialize(_handleStartupEvent);
      await _release();
      library = await openLibrary();
      // Reconcile registered copies before publishing the Windows endpoint.
      // Occupied/uncertain copies stay registered and consume their quota.
      if (library!.service.owner.informationFileDeliveries.any(
        (record) => record.holdsCopy,
      )) {
        await library!.service.owner.reconcileInformationFileDeliveries();
      }
      _server = await AgentServer.start(
        library!.service.agent,
        port: port,
        enableReusableCredentialUse: Platform.isWindows,
        enableFocusedFill: Platform.isWindows,
        enableInformationFiles: Platform.isWindows,
        credentialExecutionHandler: (session, input) {
          final host = _credentialExecutions;
          return host == null
              ? Future.value(
                  Map<String, dynamic>.from(
                    const CredentialUseFailure('service_unavailable').toJson(),
                  ),
                )
              : host.execute(session, input);
        },
      );
      boundPort = _server!.port;
      final server = _server!;
      final host = CredentialExecutionHost(
        port: boundPort!,
        workerExecutable:
            credentialWorkerExecutable ??
            '${File(Platform.resolvedExecutable).parent.path}/info-runtime-worker.exe',
      );
      _credentialExecutions = host;
      runtime = DesktopRuntime(
        service: library!.service,
        platform: platform,
        closeServer: () async {
          host.close();
          await server.close();
        },
        closeRepository: library!.close,
      );
      await runtime!.start();
      await library!.service.owner.retryAuditStorage();
      state = DesktopStartupState.ready;
    } on Object catch (error) {
      applicationFilesInvalid = error is FocusedFillBundleFailure;
      try {
        await _release();
      } on Object {
        // Keep the core, failed fact queue and library owned and retryable.
        // Cleanup failure must never prevent the error screen from appearing.
        cleanupPending = true;
      }
      state = DesktopStartupState.failed;
      // Runtime.start may have replaced the handler before startup failed.
      // Route failed-startup quit through the retained bootstrap resources.
      try {
        await platform.initialize(_handleStartupEvent);
      } on Object {
        /* Preserve the startup failure and any retryable audit facts. */
      }
      try {
        await platform.showWindow();
      } on Object {
        // Native startup may also have failed; still render the error screen.
      }
    } finally {
      settled.complete();
    }
    notifyListeners();
  }

  Future<void> _handleStartupEvent(DesktopEvent event) async {
    await _startupSettled?.future;
    if (state == DesktopStartupState.ready) {
      await runtime!.handleEvent(event);
    } else if (event == DesktopEvent.quit ||
        event == DesktopEvent.closeWindow) {
      try {
        await _release();
        await platform.terminate();
      } on Object {
        cleanupPending = true;
        notifyListeners();
        try {
          await platform.showWindow();
        } on Object {
          /* Keep the original shutdown failure. */
        }
        if (event == DesktopEvent.quit) rethrow;
      }
    } else if (event == DesktopEvent.openApprovals) {
      await platform.showWindow();
    }
  }

  Future<void> _release() async {
    if (runtime case final active?) {
      await active.stop();
      active.dispose();
    } else if (library case final opened?) {
      _credentialExecutions?.close();
      await Future.wait([
        opened.service.close(),
        if (_server case final server?) server.close(),
      ]);
      await opened.close();
    }
    runtime = null;
    _server = null;
    _credentialExecutions = null;
    library = null;
    cleanupPending = false;
  }
}
