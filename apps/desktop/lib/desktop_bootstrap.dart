import 'dart:async';
import 'package:flutter/foundation.dart';
import 'dart:io';
import 'local_library_sync.dart';
import 'package:info_remote/agent_connection.dart';
import 'package:info_remote/local_library_configuration.dart';
import 'package:info_remote/owner_client.dart';
import 'package:info_cli/credential_execution_host.dart';
import 'package:info_cli/macos_bundled_tools.dart';
import 'package:info_cli/windows_bundled_tools.dart';
import 'package:info_core/agent_server.dart';
import 'package:info_core/info_core.dart';
import 'package:info_core/macos_desktop_control.dart';
import 'package:info_storage/info_storage.dart';
import 'desktop_runtime.dart';
import 'bundled_focused_fill.dart';
import 'workspace/owner_agent_templates.dart';

/// The opened library remains owned here until authorization facts are saved.
class DesktopLibrary {
  const DesktopLibrary({
    required this.service,
    required this.close,
    this.backups,
    this.fileOutputs,
    this.fileOpens,
    this.replication,
  });
  final InformationService service;
  final Future<void> Function() close;
  final InformationBackups? backups;
  final InformationFileOutputs? fileOutputs;
  final InformationFileOpens? fileOpens;
  final LibraryReplication? replication;
}

enum DesktopStartupState { idle, starting, ready, failed }

class DesktopBootstrap extends ChangeNotifier {
  DesktopBootstrap({
    required this.openLibrary,
    required this.platform,
    this.port = 47125,
    this.credentialWorkerExecutable,
    this.openLibraryWithKeyAccess,
    this.openAppControl,
    this.localConfiguration,
  });
  final Future<DesktopLibrary> Function() openLibrary;

  /// Owner-only recovery. Ordinary startup never invokes an interactive read.
  final Future<DesktopLibrary> Function()? openLibraryWithKeyAccess;
  final DesktopPlatform platform;
  final int port;
  final LocalLibraryConfiguration? localConfiguration;
  AgentConnectionProfile? localConnection;
  final String? credentialWorkerExecutable;
  final Future<MacDesktopControlHost> Function(
    String Function() state,
    Future<void> Function() quit,
  )?
  openAppControl;
  MacDesktopControlHost? _appControl;
  DesktopStartupState state = DesktopStartupState.idle;
  DesktopLibrary? library;
  DesktopRuntime? runtime;
  AgentServer? _server;
  CredentialExecutionHost? _credentialExecutions;
  int? boundPort;
  bool cleanupPending = false;
  bool applicationFilesInvalid = false;
  bool systemKeyUnavailable = false;
  bool keyAccessPending = false;
  bool keyAccessExitFailed = false;
  bool _keyAccessQuitRequested = false;
  Completer<void>? _startupSettled;

  bool get canRequestKeyAccess =>
      Platform.isMacOS &&
      state == DesktopStartupState.failed &&
      systemKeyUnavailable &&
      !cleanupPending &&
      library == null &&
      runtime == null &&
      openLibraryWithKeyAccess != null;

  Future<void> requestKeyAccess() async {
    if (canRequestKeyAccess) await _start(interactive: true);
  }

  Future<void> quitKeyAccess() async {
    if (!keyAccessPending) return;
    try {
      await _handleStartupEvent(DesktopEvent.quit);
    } on Object {
      // The native failure is already visible and can be retried.
    }
  }

  Future<void> start() => _start();

  Future<void> _start({bool interactive = false}) async {
    if (state == DesktopStartupState.starting ||
        state == DesktopStartupState.ready) {
      return;
    }
    state = DesktopStartupState.starting;
    keyAccessPending = interactive;
    keyAccessExitFailed = false;
    _keyAccessQuitRequested = false;
    final settled = _startupSettled = Completer<void>();
    applicationFilesInvalid = false;
    systemKeyUnavailable = false;
    notifyListeners();
    try {
      // Install the lifetime entry before opening data. A failed key/open must
      // still be closable, and a quit during startup waits for owned work.
      await platform.initialize(_handleStartupEvent);
      if (_appControl == null && openAppControl != null) {
        try {
          _appControl = await openAppControl!(
            _controlState,
            () => _handleStartupEvent(DesktopEvent.quit),
          );
          if (platform case final NativeDesktopPlatform native) {
            native.commitAppControlExit = _appControl!.commitExit;
          }
        } on Object {
          // Lifetime control is optional. A stale/private registry failure
          // must not stop the information library or erase its old record.
        }
      }
      await _release();
      if (_keyAccessQuitRequested) {
        state = DesktopStartupState.failed;
        return;
      }
      library = await (interactive ? openLibraryWithKeyAccess! : openLibrary)();
      if (_keyAccessQuitRequested) {
        // A late authorization result must not publish an endpoint after quit.
        await _release();
        state = DesktopStartupState.failed;
        return;
      }
      keyAccessPending = false;
      // Reconcile registered copies before publishing the Windows endpoint.
      // Occupied/uncertain copies stay registered and consume their quota.
      if (library!.service.owner.informationFileDeliveries.any(
        (record) => record.holdsCopy,
      )) {
        await library!.service.owner.reconcileInformationFileDeliveries();
      }
      final templateOwner = library!.service.owner;
      templateOwner.configureInformationTemplates(
        () => currentAgentTemplates(templateOwner),
      );
      final transport = localConfiguration?.connection(1);
      _server = await AgentServer.start(
        library!.service.agent,
        port: port,
        connectionToken: transport?.deviceToken,
        libraryId: transport?.serverId,
        enableReusableCredentialUse: Platform.isWindows || Platform.isMacOS,
        enableFocusedFill: Platform.isWindows,
        enableInformationFiles: Platform.isWindows || Platform.isMacOS,
        credentialTools: Platform.isWindows
            ? WindowsBundledTools().read
            : Platform.isMacOS
            ? MacBundledTools().read
            : null,
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
      final profile = transport == null
          ? null
          : AgentConnectionProfile.local(
              port: boundPort!,
              deviceToken: transport.deviceToken,
              libraryId: transport.serverId,
            );
      localConnection = profile;
      final host = CredentialExecutionHost(
        port: boundPort!,
        connection: profile,
        workerExecutable:
            credentialWorkerExecutable ??
            '${File(Platform.resolvedExecutable).parent.path}/info-runtime-worker${Platform.isWindows ? '.exe' : ''}',
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
        maintainOwnerFiles: library!.fileOpens == null
            ? null
            : () => library!.service.owner.exportLibrary(
                () => library!.fileOpens!.maintain(closePrevious: true),
              ),
        closeOwnerFiles: library!.fileOpens == null
            ? null
            : () async {
                await library!.fileOpens!.maintain(closeAll: true);
              },
      );
      await runtime!.start();
      await library!.service.owner.retryAuditStorage();
      if (localConfiguration != null) {
        final connection = AgentConnection(profile!);
        try {
          if ((await connection.call('/capabilities', {}))['status'] != 'ok') {
            throw const RemoteFailure('local_connection_unavailable');
          }
        } finally {
          connection.close();
        }
        final replica = library!.replication;
        final serverMode =
            replica != null &&
            (await LocalLibrarySync(
                  configuration: localConfiguration!,
                  owner: library!.service.owner,
                  replication: replica,
                ).readConfiguration())['enabled'] ==
                true;
        // Opening the replica does not select its approval service. Keep the
        // server target until the Host prepares that mode's request connection.
        if (!serverMode) await localConfiguration!.publish(profile);
      }
      state = DesktopStartupState.ready;
    } on Object catch (error) {
      applicationFilesInvalid = error is FocusedFillBundleFailure;
      systemKeyUnavailable =
          Platform.isMacOS &&
          error is StorageFailure &&
          {
            'key_unavailable',
            'key_creation_failed',
            'invalid_key',
          }.contains(error.code);
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
      if (!_keyAccessQuitRequested) {
        try {
          await platform.showWindow();
        } on Object {
          // Native startup may also have failed; still render the error screen.
        }
      }
    } finally {
      keyAccessPending = false;
      settled.complete();
      notifyListeners();
    }
  }

  Future<void> _handleStartupEvent(DesktopEvent event) async {
    if (keyAccessPending &&
        library == null &&
        runtime == null &&
        !cleanupPending &&
        (event == DesktopEvent.quit || event == DesktopEvent.closeWindow)) {
      // Interactive recovery is offered only after all previous resources have
      // closed. Do not wait for a system authorization dialog to return.
      _keyAccessQuitRequested = true;
      try {
        await platform.terminate();
        keyAccessExitFailed = false;
      } on Object {
        keyAccessExitFailed = true;
        notifyListeners();
        rethrow;
      }
      return;
    }
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

  String _controlState() {
    if (cleanupPending || runtime?.shutdownFailed == true) {
      return 'shutdown_failed';
    }
    if (_keyAccessQuitRequested || runtime?.quitting == true) return 'exiting';
    return switch (state) {
      DesktopStartupState.ready => 'running',
      DesktopStartupState.failed => 'startup_failed',
      _ => 'starting',
    };
  }

  Future<void>? _closing;
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    try {
      _keyAccessQuitRequested = true;
      await _startupSettled?.future;
      await _release();
    } on Object {
      _closing = null;
      rethrow;
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
    boundPort = null;
    localConnection = null;
    _credentialExecutions = null;
    library = null;
    cleanupPending = false;
  }
}
