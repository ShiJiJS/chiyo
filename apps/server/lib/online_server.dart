import 'owner_sync_routes.dart';
import 'owner_authentication.dart';
import 'owner_replication_routes.dart';
import 'agent_devices.dart';
import 'agent_gateway.dart';
import 'package:info_core/agent_server.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_core/server_state.dart';
import 'package:info_core/information_transport.dart';
import 'package:info_core/protocol_json.dart';
import 'package:crypto/crypto.dart';
import 'package:info_workspace/owner_workspace_approvals.dart';
import 'package:info_workspace/workspace_records.dart';
import 'package:info_workspace/approval_transport.dart';
import 'package:info_workspace/owner_agent_templates.dart';
import 'package:info_workspace/owner_workspace_template_packages.dart';
import 'package:info_workspace/plugin_transport.dart';
import 'package:info_workspace/owner_workspace_proposals.dart';
import 'package:info_workspace/workspace_transport.dart';
import 'owner_library.dart';
import 'owner_proposal_routes.dart';
import 'owner_library_routes.dart';
import 'owner_file_routes.dart';
import 'owner_credential_routes.dart';
import 'owner_credential_batch_routes.dart';
import 'owner_host_routes.dart';
import 'owner_history_routes.dart';
import 'owner_backup_routes.dart';
import 'owner_adoption_routes.dart';
import 'owner_policy_routes.dart';
import 'package:info_workspace/owner_runtime_observation.dart';
import 'package:info_workspace/runtime_transport.dart';
import 'package:info_storage/info_storage.dart';

/// User management is a separate authenticated surface from the Agent API.
/// This host never starts a local credential executor or owns a desktop.
final class OnlineServer {
  OnlineServer._(
    this._http,
    this._runtime,
    this._ownerToken,
    this.serverId,
    this._devices,
    this._backups,
    this._policyState,
    this._onRequestTiming,
    this._replication,
    this._ownerAuthentication,
  ) : _agents = AgentGateway(
        AgentProtocol(
          _runtime.service.agent,
          enableReusableCredentialUse: true,
          enableInformationFiles: true,
        ),
        _devices,
        deviceCredentials: _runtime.service.agent,
      ),
      _approvals = OwnerWorkspaceApprovals(owner: _runtime.service.owner),
      _plugins = OwnerWorkspaceTemplatePackages(
        owner: _runtime.service.owner,
        changed: () {},
      ) {
    _ownerScope = _service.owner.captureLibraryScope();
    _service.owner.configureInformationTemplates(
      () => currentAgentTemplates(_service.owner),
    );
    _fileCleanupTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (_fileCleanup != null ||
          (_files?.needsCleanup != true &&
              _credentials?.needsCleanup != true &&
              _hosts?.needsCleanup != true &&
              _backups?.needsCleanup != true &&
              _replication?.needsCleanup != true))
        return;
      _fileCleanup = _runtime
          .run(() async {
            await _files?.cleanup();
            await _credentials?.cleanup();
            await _hosts?.cleanup();
            await _backups?.cleanup();
            await _replication?.cleanup();
          })
          .catchError((Object _) {
            /* Retry next sweep; shutdown also releases staging. */
          })
          .whenComplete(() => _fileCleanup = null);
    });
    _http.listen(
      _handle,
      onError: (Object error, StackTrace stack) {
        // Rejected TLS peers and disconnected clients are transport failures,
        // not unhandled host errors. Certificate verification stays enabled.
        if (error is! HandshakeException &&
            error is! SocketException &&
            error is! HttpException) {
          Zone.current.handleUncaughtError(error, stack);
        }
      },
    );
  }
  final void Function(Map<String, Object?>)? _onRequestTiming;
  final HttpServer _http;
  final OnlineInformationRuntime _runtime;
  InformationService get _service => _runtime.service;
  final String _ownerToken;
  final OwnerAuthentication? _ownerAuthentication;
  final String serverId;
  final AgentDeviceRegistry _devices;
  final AgentGateway _agents;
  final OwnerBackupRoutes? _backups;
  final OwnerReplicationRoutes? _replication;
  final ServerStateRepository? _policyState;
  OwnerPolicyRoutes? _policyRoutesValue;
  OwnerPolicyRoutes get _policyRoutes {
    if (_policyState == null)
      throw const WorkspaceFailure('unavailable', '服务设置未配置。');
    return _policyRoutesValue ??= OwnerPolicyRoutes(
      _service.owner,
      _policyState,
    );
  }

  OwnerRuntimeObservation? _runtimeObservation;
  OwnerWorkspaceApprovals _approvals;
  OwnerWorkspaceTemplatePackages _plugins;
  late OwnerLibraryScope _ownerScope;
  OnlineOwnerLibrary? _libraryValue;
  OnlineOwnerLibrary get _library =>
      _libraryValue ??= OnlineOwnerLibrary(_service.owner, _plugins);
  OwnerWorkspaceProposals? _proposalsValue;
  OwnerWorkspaceProposals get _proposals =>
      _proposalsValue ??= OwnerWorkspaceProposals(
        owner: _service.owner,
        library: () => _library,
        changed: () {},
      );
  OwnerProposalRoutes? _proposalRoutesValue;
  OwnerProposalRoutes get _proposalRoutes =>
      _proposalRoutesValue ??= OwnerProposalRoutes(_proposals);
  OwnerLibraryRoutes? _libraryRoutesValue;
  OwnerLibraryRoutes get _libraryRoutes =>
      _libraryRoutesValue ??= OwnerLibraryRoutes(_library);
  OwnerHistoryRoutes? _historyRoutesValue;
  OwnerAdoptionRoutes? _adoptionRoutesValue;
  OwnerAdoptionRoutes get _adoptionRoutes =>
      _adoptionRoutesValue ??= OwnerAdoptionRoutes(_library);
  OwnerHistoryRoutes get _historyRoutes =>
      _historyRoutesValue ??= OwnerHistoryRoutes(_library);
  OwnerFileRoutes? _files;
  OwnerCredentialRoutes? _credentials;
  OwnerHostRoutes? _hosts;
  OwnerHostRoutes get _hostRoutes => _hosts ??= OwnerHostRoutes(_service.owner);
  OwnerCredentialRoutes get _credentialRoutes =>
      _credentials ??= OwnerCredentialRoutes(_service.owner);
  late final Timer _fileCleanupTimer;
  Future<void>? _fileCleanup;
  OwnerFileRoutes get _fileRoutes => _files ??= OwnerFileRoutes(_library);
  int get port => _http.port;

  /// A successful original restore invalidates every Owner projection and
  /// staged selection. Rebind in the serialized host queue before serving the
  /// next request; keeping a stale projection would make a live server unusable
  /// until restart. Device authentication reads the new generation directly.
  Future<void> _refreshOwnerScope() async {
    if (_ownerScope.isCurrent) return;
    await _files?.dispose();
    _credentials?.dispose();
    _hosts?.dispose();
    _plugins.dispose();
    _adoptionRoutesValue?.dispose();
    _adoptionRoutesValue = null;
    _policyRoutesValue?.dispose();
    _policyRoutesValue = null;
    _runtimeObservation = null;
    _files = null;
    _credentials = null;
    _hosts = null;
    _libraryValue = null;
    _proposalsValue = null;
    _proposalRoutesValue = null;
    _libraryRoutesValue = null;
    _historyRoutesValue = null;
    _approvals = OwnerWorkspaceApprovals(owner: _service.owner);
    _plugins = OwnerWorkspaceTemplatePackages(
      owner: _service.owner,
      changed: () {},
    );
    _ownerScope = _service.owner.captureLibraryScope();
    _service.owner.configureInformationTemplates(
      () => currentAgentTemplates(_service.owner),
    );
  }

  static Future<OnlineServer> start({
    required OnlineInformationRuntime runtime,
    required AgentDeviceRegistry devices,
    required SecurityContext tls,
    required String ownerToken,
    required String serverId,
    InternetAddress? address,
    int port = 0,
    InformationBackups? backups,
    Directory? backupDirectory,
    ServerStateRepository? policyState,
    void Function(Map<String, Object?>)? onRequestTiming,
    LibraryReplication? replication,
    Directory? replicationDirectory,
    OwnerAuthentication? ownerAuthentication,
  }) async {
    if (!RegExp(r'^[A-Za-z0-9_-]{43,128}$').hasMatch(ownerToken) ||
        !RegExp(r'^[A-Za-z0-9_-]{16,128}$').hasMatch(serverId)) {
      throw const FormatException('Invalid server configuration');
    }
    if ((backups == null) != (backupDirectory == null)) {
      throw const FormatException('Incomplete backup configuration');
    }
    if ((replication == null) != (replicationDirectory == null))
      throw const FormatException('Incomplete replication configuration');
    if (replicationDirectory != null) {
      final type = await FileSystemEntity.type(
        replicationDirectory.path,
        followLinks: false,
      );
      if (type != FileSystemEntityType.notFound &&
          type != FileSystemEntityType.directory)
        throw const StorageFailure('sync_staging_failed');
      if (Platform.isWindows) {
        WindowsPrivateFiles.directory(replicationDirectory);
      } else {
        await replicationDirectory.create(recursive: true);
        if ((await Process.run('/bin/chmod', [
              '700',
              replicationDirectory.path,
            ])).exitCode !=
            0)
          throw const StorageFailure('sync_staging_failed');
      }
    }
    if (backupDirectory != null) {
      final type = await FileSystemEntity.type(
        backupDirectory.path,
        followLinks: false,
      );
      if (type != FileSystemEntityType.notFound &&
          type != FileSystemEntityType.directory) {
        throw const StorageFailure('backup_staging_failed');
      }
      if (Platform.isWindows) {
        WindowsPrivateFiles.directory(backupDirectory);
      } else {
        await backupDirectory.create(recursive: true);
        if ((await Process.run('/bin/chmod', [
              '700',
              backupDirectory.path,
            ])).exitCode !=
            0) {
          throw const StorageFailure('backup_staging_failed');
        }
      }
    }
    final http = await HttpServer.bindSecure(
      address ?? InternetAddress.loopbackIPv4,
      port,
      tls,
    );
    return OnlineServer._(
      http,
      runtime,
      ownerToken,
      serverId,
      devices,
      backups == null
          ? null
          : OwnerBackupRoutes(
              owner: runtime.service.owner,
              backups: backups,
              directory: backupDirectory!,
            ),
      policyState,
      onRequestTiming ??
          (Platform.environment['CHIYO_REQUEST_TIMINGS'] == '1'
              ? (value) => stderr.writeln(jsonEncode(value))
              : null),
      replication == null
          ? null
          : OwnerReplicationRoutes(
              owner: runtime.service.owner,
              replication: replication,
              directory: replicationDirectory!,
            ),
      ownerAuthentication,
    );
  }

  Future<void> close() async {
    _fileCleanupTimer.cancel();
    await _http.close(force: true);
    await _fileCleanup;
    try {
      await _files?.dispose();
      await _backups?.dispose();
      await _replication?.dispose();
    } finally {
      _credentials?.dispose();
      _hosts?.dispose();
      _plugins.dispose();
      _adoptionRoutesValue?.dispose();
      _policyRoutesValue?.dispose();
    }
  }

  bool _authenticated(String? value) {
    if (_ownerAuthentication case final auth?) {
      return value?.startsWith('Bearer ') == true &&
          auth.accepts(value!.substring(7));
    }
    final expected = 'Bearer $_ownerToken'.codeUnits;
    final supplied = (value ?? '').codeUnits;
    var difference = expected.length ^ supplied.length;
    for (var i = 0; i < expected.length; i++) {
      difference |= expected[i] ^ (i < supplied.length ? supplied[i] : 0);
    }
    return difference == 0;
  }

  static const _authPaths = {
    '/v1/setup',
    '/v1/setup/initialize',
    '/v1/setup/login',
    '/v1/owner/connection-password',
  };

  Future<(int, Map<String, Object?>)> _connectionAuthentication(
    HttpRequest request,
  ) async {
    final auth = _ownerAuthentication!;
    if (request.uri.hasQuery) throw const FormatException();
    final expected = request.headers.value('x-chiyo-server-id');
    if (expected != null && expected != serverId)
      throw const AccessFailure('server_changed');
    if (request.method == 'GET' && request.uri.path == '/v1/setup') {
      return (200, auth.status(serverId));
    }
    if (request.method != 'POST') return (405, {'error': 'method_not_allowed'});
    final authorization = request.headers.value('authorization') ?? '';
    final token = authorization.startsWith('Bearer ')
        ? authorization.substring(7)
        : '';
    final peer = request.connectionInfo?.remoteAddress.address ?? 'unknown';
    if (request.uri.path == '/v1/owner/connection-password' &&
        !auth.accepts(token)) {
      throw const AccessFailure('unauthorized');
    }
    final body = await _body(request);
    if (request.uri.path == '/v1/owner/connection-password') {
      if (body.length != 2 ||
          body['currentPassword'] is! String ||
          body['newPassword'] is! String)
        throw const FormatException();
      return (
        200,
        {
          'serverId': serverId,
          'token': await auth.change(
            body['currentPassword'] as String,
            body['newPassword'] as String,
            token: token,
            peer: peer,
          ),
        },
      );
    }
    if (body.length != 1 || body['password'] is! String)
      throw const FormatException();
    final password = body['password'] as String;
    if (request.uri.path == '/v1/setup/initialize') {
      return (
        200,
        {
          'serverId': serverId,
          'token': await auth.initialize(
            password,
            peer: peer,
            ownerToken: token,
          ),
        },
      );
    }
    if (request.uri.path == '/v1/setup/login') {
      return (
        200,
        {'serverId': serverId, 'token': await auth.login(password, peer: peer)},
      );
    }
    return (405, {'error': 'method_not_allowed'});
  }

  Future<Map<String, dynamic>> _body(HttpRequest request) async {
    if (request.headers.contentType?.mimeType != 'application/json') {
      throw const FormatException('Expected JSON');
    }
    // Only dedicated file upload routes accept the existing 10 MiB original
    // plus Base64 and bounded metadata. Ordinary management stays at 2 MiB.
    final limit = _authPaths.contains(request.uri.path)
        ? 8192
        : const {
            '/v1/agent/import/submit',
            '/v1/agent/import/revise',
            '/v1/agent/proposals/check',
          }.contains(request.uri.path)
        ? 6000000
        : request.uri.path == '/v1/owner/ssh-hosts/imports'
        ? 16 * 1024 * 1024
        : const {
            '/v1/owner/files/uploads',
            '/v1/agent/import-file/submit',
          }.contains(request.uri.path)
        ? ((informationFileByteLimit + 2) ~/ 3) * 4 + 16384
        : 2 * 1024 * 1024;
    final bytes = <int>[];
    await for (final chunk in request.timeout(const Duration(seconds: 15))) {
      if (bytes.length + chunk.length > limit) {
        throw const FormatException('Request too large');
      }
      bytes.addAll(chunk);
    }
    return decodeProtocolObject(utf8.decode(bytes), maxBytes: limit);
  }

  Future<Map<String, Object?>> _catalogProjection() async {
    final classification = await _library.loadCatalog();
    return {
      'version': classification.version,
      'summary': {
        'records':
            _service.owner.information.length +
            _service.owner.credentials.length,
        'pending':
            _service.owner.queryInbox(limit: 1).pendingCount +
            _service.owner.pendingCredentialBatchCount,
        'proposals': _service.owner.queryProposals(limit: 1).pendingCount,
      },
      'directories': [
        for (final d in _service.owner.directories)
          {'id': d.id, 'name': d.name, 'parentId': d.parentId},
      ],
      'tags': [
        for (final t in _service.owner.tags) {'id': t.id, 'name': t.name},
      ],
      'templates': _plugins.templates.values.toList(),
      'workspace': workspaceCatalogToJson(classification),
      'recordOrder': _libraryRoutes.order()['records'],
    };
  }

  Future<Map<String, Object?>> _syncCatalogProjection() async {
    final catalog = await _catalogProjection();
    catalog.remove('summary'); // Pending approvals are not library content.
    return catalog;
  }

  late final _sync = OwnerSyncRoutes(
    _runtime.hostState,
    () async => {
      'catalog': await _syncCatalogProjection(),
      'plugins': pluginCatalogToJson(await _plugins.load()),
      for (final summary in _library.summaries())
        'record:${summary.ref.kind.name}:${summary.ref.id}':
            workspaceDetailToJson(await _library.readDetail(summary.ref)),
    },
  );

  Future<String> _requestObservation() async {
    final owner = _service.owner;
    return sha256
        .convert(
          utf8.encode(
            jsonEncode([
              [
                for (final i in owner.information) [i.id, i.version],
              ],
              [
                for (final r in owner.informationRequests)
                  [
                    r.id,
                    r.state.name,
                    r.sessionEnded,
                    r.applicationClosed,
                    [for (final f in r.fields) f.toJson()],
                    [
                      for (final f in r.approvedFields ?? <FieldRef>[])
                        f.toJson(),
                    ],
                    r.decisionPending,
                    r.grantExpiresAt?.toIso8601String(),
                  ],
              ],
              [
                for (final r in owner.credentialUseRequests)
                  [
                    r.id,
                    owner.credentialUseState(r),
                    owner.credentialGrantState(r),
                  ],
              ],
              [
                for (final r in owner.credentialBatches)
                  [
                    r.id,
                    r.revision,
                    owner.credentialBatchState(r),
                    for (final item in r.items)
                      [item.id, owner.credentialBatchItemState(r, item)],
                  ],
              ],
              [
                for (final op in owner.credentialBatchOperations)
                  owner.credentialBatchOperationView(op),
              ],
              [
                for (final e in owner.credentialExecutions)
                  [e.id, e.state, e.cleanupState, e.exitCode],
              ],
              [
                for (final p in owner.importProposals)
                  [p.id, p.version, p.state.name],
              ],
              [
                for (final p in owner.updateProposals)
                  [p.id, p.version, p.state.name],
              ],
            ]),
          ),
        )
        .toString();
  }

  Future<String> _observation() async {
    final owner = _service.owner;
    final requests = await owner.informationRequestInbox();
    final audit = await owner.informationHistory(includeCredentialFields: true);
    return sha256
        .convert(
          utf8.encode(
            jsonEncode([
              owner.templatePackageVersion,
              owner.desktopPreferences.version,
              [
                for (final s in owner.sessions) [s.id, s.chatLabel, s.ended],
              ],
              [
                for (final e in owner.recycleEntries) [e.id, e.version],
              ],
              [
                if (owner.libraryRecycleSupported)
                  for (final b in owner.libraryRecycleBatches)
                    [b.id, b.version],
              ],
              [
                for (final c in owner.recycledCredentials) [c.id, c.revision],
              ],
              [for (final a in audit.history.accesses) a.id],
              [
                for (final g in audit.history.grants)
                  [
                    g.id,
                    for (final e in g.events)
                      [e.kind.name, e.at.toIso8601String()],
                  ],
              ],
              owner.sshKnownHosts?.id,
              [
                for (final c in owner.credentials) [c.id, c.revision],
              ],
              [
                for (final r in owner.credentialUseRequests)
                  [
                    r.id,
                    r.toJson(),
                    owner.credentialUseState(r),
                    owner.credentialGrantState(r),
                    owner.credentialFieldGrantState(r, forReview: true),
                    owner.credentialUseDecisionUnconfirmed(r),
                  ],
              ],
              [
                for (final r in owner.credentialBatches)
                  [
                    r.id,
                    r.revision,
                    owner.credentialBatchState(r),
                    for (final item in r.items)
                      [item.id, owner.credentialBatchItemState(r, item)],
                  ],
              ],
              [
                for (final op in owner.credentialBatchOperations)
                  owner.credentialBatchOperationView(op),
              ],
              [
                for (final e in owner.credentialExecutions)
                  [
                    e.id,
                    e.state,
                    e.cleanupState,
                    e.exitCode,
                    e.finishedAt?.toIso8601String(),
                    e.restoredAt?.toIso8601String(),
                  ],
              ],
              owner.libraryOrderRevision,
              owner.libraryDisplayOrder.name,
              [
                for (final t in owner.organizationTasks)
                  [
                    t.id,
                    owner.organizationState(t).name,
                    t.expiresAt.toIso8601String(),
                    t.approvedAt?.toIso8601String(),
                    t.completedAt?.toIso8601String(),
                    t.itemVersions,
                    t.changes.map((c) => c.toJson()).toList(),
                  ],
              ],
              [
                for (final p in owner.importProposals)
                  [p.id, p.version, p.state.name],
              ],
              [
                for (final p in owner.updateProposals)
                  [p.id, p.version, p.state.name],
              ],
              owner.queryProposals(limit: 1).pendingCount,
              [
                for (final i in owner.information) [i.id, i.version],
              ],
              [
                for (final d in owner.directories) [d.id, d.name, d.parentId],
              ],
              [
                for (final t in owner.tags) [t.id, t.name],
              ],
              [
                for (final r in requests)
                  [
                    r.id,
                    r.state.name,
                    r.sessionEnded,
                    r.applicationClosed,
                    r.decisionPending,
                    r.grantExpiresAt?.toIso8601String(),
                    r.fields.map((f) => f.toJson()).toList(),
                    r.approvedFields?.map((f) => f.toJson()).toList(),
                  ],
              ],
            ]),
          ),
        )
        .toString();
  }

  static String _timingSurface(Uri uri) {
    final path = uri.pathSegments;
    if (path.length < 2 || path.first != 'v1') return 'other';
    if (path[1] == 'server') return 'v1/server';
    if (!{'owner', 'agent'}.contains(path[1])) return 'other';
    const categories = {
      'sync',
      'replication',
      'updates',
      'catalog',
      'summaries',
      'information',
      'settings',
      'runtime',
      'approvals',
      'proposals',
      'history',
      'backups',
      'plugins',
      'files',
      'ssh-hosts',
      'credentials',
      'devices',
      'saves',
      'operations',
      'classification',
      'library',
      'sessions',
      'request',
      'read',
      'claim',
      'status',
      'capabilities',
    };
    return 'v1/${path[1]}/${path.length > 2 && categories.contains(path[2]) ? path[2] : 'other'}';
  }

  Future<void> _handle(HttpRequest request) async {
    final timing = Stopwatch()..start();
    Duration? routeStarted, routeFinished;
    int status = 500;
    Object result = {'error': 'service_failure'};
    Future<void> reply(int code, Object value) async {
      status = code;
      result = value;
    }

    Map<String, dynamic>? parsedBody;
    Future<void> route() async {
      try {
        await _refreshOwnerScope();
        // No browser management surface is part of this version.
        if (request.headers.value('origin') != null) {
          await reply(401, {'error': 'unauthorized'});
          return;
        }
        final expectedServer = request.headers.value('x-chiyo-server-id');
        if (expectedServer != null && expectedServer != serverId) {
          await reply(409, {'error': 'server_changed'});
          return;
        }
        final path = request.uri.pathSegments;
        if (path.length >= 3 && path.take(2).join('/') == 'v1/agent') {
          final authorization = request.headers.value('authorization') ?? '';
          if (!authorization.startsWith('Bearer ')) {
            await reply(401, {'error': 'unauthorized'});
            return;
          }
          final bearer = authorization.substring(7);
          // Authenticate before parsing body or consulting the shared protocol.
          await _devices.authenticate(bearer);
          if (request.method != 'POST') {
            await reply(405, {'error': 'method_not_allowed'});
            return;
          }
          final result = await _agents.dispatch(
            bearer,
            '/${path.skip(2).join('/')}',
            parsedBody!,
          );
          await reply(200, result);
          return;
        }
        if (!_authenticated(request.headers.value('authorization'))) {
          await reply(401, {'error': 'unauthorized'});
          return;
        }
        if (request.method == 'GET' &&
            request.uri.path == '/v1/owner/updates') {
          await reply(200, {
            'workspaceObservation': await _requestObservation(),
            'summary': {
              'records':
                  _service.owner.information.length +
                  _service.owner.credentials.length,
              'pending':
                  _service.owner.queryInbox(limit: 1).pendingCount +
                  _service.owner.pendingCredentialBatchCount,
              'proposals': _service.owner.queryProposals(limit: 1).pendingCount,
            },
          });
        } else if (request.method == 'POST' &&
            request.uri.path == '/v1/owner/sync') {
          await reply(200, await _sync.read(parsedBody!));
        } else if (request.method == 'GET' &&
            request.uri.path == '/v1/server') {
          await reply(200, {
            'protocolVersion': 1,
            'serverId': serverId,
            'workspaceObservation': await _observation(),
            'librarySort': _service.owner.libraryDisplayOrder.name,
            if (_replication != null)
              'replication': OwnerReplicationRoutes.capabilities,
          });
        } else if (path.length >= 3 &&
            path.take(3).join('/') == 'v1/owner/replication') {
          final replication = _replication;
          if (replication == null)
            throw const WorkspaceFailure(
              'unsupported_sync',
              '服务器需要更新后才能同步本地资料库。',
            );
          final (code, value) = await replication.dispatch(
            request.method,
            path,
            parsedBody,
          );
          await reply(code, value);
        } else if (request.method == 'GET' &&
            request.uri.path == '/v1/owner/runtime') {
          if (request.uri.hasQuery) throw const FormatException();
          await reply(
            200,
            serverRuntimeToJson(
              await (_runtimeObservation ??= OwnerRuntimeObservation(
                _service.owner,
              )).read(),
            ),
          );
        } else if (path.length >= 3 &&
            path.take(3).join('/') == 'v1/owner/settings') {
          final (code, value) = await _policyRoutes.dispatch(
            request.method,
            path,
            parsedBody,
          );
          await reply(code, value);
        } else if (path.length >= 3 &&
            path.take(3).join('/') == 'v1/owner/adoption') {
          final (code, value) = await _adoptionRoutes.dispatch(
            request.method,
            path,
            parsedBody,
          );
          await reply(code, value);
        } else if (path.length >= 3 &&
            path.take(3).join('/') == 'v1/owner/backups') {
          final backups = _backups;
          if (backups == null) {
            throw const WorkspaceFailure('unavailable', '备份服务未配置。');
          }
          final (code, value) = await backups.dispatch(
            request.method,
            path,
            parsedBody,
          );
          await reply(code, value);
        } else if (path.length >= 3 &&
            path.take(2).join('/') == 'v1/owner' &&
            const {'history', 'grant-history'}.contains(path[2])) {
          final (code, value) = await _historyRoutes.dispatch(
            request.method,
            path,
            parsedBody,
          );
          await reply(code, value);
        } else if (path.length >= 3 &&
            path.take(3).join('/') == 'v1/owner/ssh-hosts') {
          final (code, value) = await _hostRoutes.dispatch(
            request.method,
            path,
            parsedBody,
          );
          await reply(code, value);
        } else if (path.length >= 3 &&
            path.take(3).join('/') == 'v1/owner/credential-batches') {
          final (code, value) = await OwnerCredentialBatchRoutes(
            _service.owner,
          ).dispatch(request.method, path, parsedBody);
          await reply(code, value);
        } else if (path.length >= 3 &&
            path.take(3).join('/') == 'v1/owner/credentials') {
          final (code, value) = await _credentialRoutes.dispatch(
            request.method,
            path,
            parsedBody,
          );
          await reply(code, value);
        } else if (path.length >= 3 &&
            path.take(3).join('/') == 'v1/owner/files') {
          final (code, value) = await _fileRoutes.dispatch(
            request.method,
            path,
            parsedBody,
          );
          await reply(code, value);
        } else if (path.length >= 3 &&
            path.take(2).join('/') == 'v1/owner' &&
            const {'classification', 'library'}.contains(path[2])) {
          final (code, value) = await _libraryRoutes.dispatch(
            request.method,
            path,
            parsedBody,
          );
          await reply(code, value);
        } else if (path.length >= 3 &&
            path.take(3).join('/') == 'v1/owner/proposals') {
          final (code, value) = await _proposalRoutes.dispatch(
            request.method,
            path,
            parsedBody,
          );
          await reply(code, value);
        } else if (path.length == 4 &&
            path.take(3).join('/') == 'v1/owner/relations' &&
            request.method == 'POST') {
          if (path.last == 'query') {
            await reply(
              200,
              workspaceResultsToJson(
                await _library.queryRelationCandidates(
                  relationQueryFromJson(parsedBody!['query']),
                ),
              ),
            );
          } else if (path.last == 'summaries') {
            await reply(200, {
              'items': (await _library.readSummaries(
                (parsedBody!['records'] as List).map(recordRefFromJson),
              )).map(recordSummaryToJson).toList(),
            });
          } else {
            await reply(404, {'error': 'not_found'});
          }
        } else if (path.length >= 3 &&
            path.take(3).join('/') == 'v1/owner/plugins') {
          if (path.length == 3 && request.method == 'GET') {
            await reply(200, pluginCatalogToJson(await _plugins.load()));
          } else if (path.length == 4 &&
              path.last == 'stage' &&
              request.method == 'POST') {
            final body = parsedBody!;
            if (body.length != 2 ||
                body['filename'] is! String ||
                body['bytes'] is! String ||
                (body['bytes'] as String).length > 1398104) {
              throw const FormatException('Invalid package input');
            }
            final staged = _plugins.stageBytes(
              body['filename'] as String,
              base64Decode(body['bytes'] as String),
            );
            await reply(200, {
              'selectionId': staged.selectionId,
              'filename': staged.filename,
              'byteLength': staged.byteLength,
            });
          } else if (path.length == 5 &&
              path[3] == 'previews' &&
              request.method == 'GET') {
            await reply(
              200,
              pluginPreviewToJson(await _plugins.previewInstall(path.last)),
            );
          } else if (path.length == 5 &&
              path[3] == 'selections' &&
              request.method == 'DELETE') {
            await _plugins.releaseCandidate(path.last);
            await reply(200, {'status': 'released'});
          } else if (path.length == 4 &&
              path.last == 'changes' &&
              request.method == 'POST') {
            await reply(
              200,
              pluginReceiptToJson(
                await _plugins.change(pluginChangeFromJson(parsedBody!)),
              ),
            );
          } else if (path.length == 5 &&
              path[3] == 'operations' &&
              request.method == 'GET') {
            final receipt = await _plugins.receipt(path.last);
            await reply(
              receipt == null ? 404 : 200,
              receipt == null
                  ? {'error': 'operation_not_found'}
                  : pluginReceiptToJson(receipt),
            );
          } else {
            await reply(404, {'error': 'not_found'});
          }
        } else if (path.length >= 4 &&
            path.take(3).join('/') == 'v1/owner/approvals') {
          if (path.length == 4 &&
              path.last == 'query' &&
              request.method == 'POST') {
            await reply(
              200,
              approvalResultsToJson(
                await _approvals.query(
                  approvalQueryFromJson(parsedBody!),
                  keepSelection: parsedBody['keepSelection'] as String?,
                ),
              ),
            );
          } else if (path.length == 4 &&
              path.last == 'decisions' &&
              request.method == 'POST') {
            await reply(
              200,
              approvalReceiptToJson(
                await _approvals.change(approvalChangeFromJson(parsedBody!)),
              ),
            );
          } else if (path.length == 5 &&
              path[3] == 'operations' &&
              request.method == 'GET') {
            final receipt = await _approvals.receipt(path.last);
            await reply(
              receipt == null ? 404 : 200,
              receipt == null
                  ? {'error': 'operation_not_found'}
                  : approvalReceiptToJson(receipt),
            );
          } else if (path.length == 5 &&
              path[3] == 'details' &&
              request.method == 'GET') {
            final detail = await _approvals.read(path.last);
            await reply(
              200,
              approvalDetailToJson(
                detail,
                version: detail.credentialBatch ? 5 : 2,
              ),
            );
          } else if (path.length == 4 && request.method == 'GET') {
            await reply(
              200,
              approvalDetailToJson(await _approvals.read(path.last)),
            );
          } else {
            await reply(404, {'error': 'not_found'});
          }
        } else if (request.uri.path == '/v1/owner/devices' &&
            request.method == 'GET') {
          await reply(200, {'devices': await _devices.metadata()});
        } else if (request.uri.path == '/v1/owner/devices' &&
            request.method == 'POST') {
          final input = parsedBody!;
          if (input.keys.any((k) => !const {'operationId', 'name'}.contains(k)))
            throw const FormatException('Invalid device request');
          final device = await _devices.enroll(
            input['operationId'] as String,
            input['name'] as String,
          );
          await reply(200, {
            'deviceId': device.identity.id,
            'name': device.identity.name,
            'generation': device.identity.generation,
            'deviceToken': device.bearer,
          });
        } else if (request.method == 'POST' &&
            path.length == 5 &&
            path.take(3).join('/') == 'v1/owner/devices' &&
            path.last == 'revoke') {
          final input = parsedBody!;
          if (input.length != 1 || input['operationId'] is! String)
            throw const FormatException('Invalid device request');
          await _devices.revoke(input['operationId'] as String, path[3]);
          await reply(200, {'status': 'revoked', 'deviceId': path[3]});
        } else if (request.method == 'GET' &&
            request.uri.path == '/v1/owner/catalog') {
          await reply(200, await _catalogProjection());
        } else if (request.method == 'GET' &&
            request.uri.path == '/v1/owner/summaries') {
          await reply(200, {
            'credentials': [
              for (final summary in _library.summaries())
                if (summary.ref.kind == WorkspaceRecordKind.credential)
                  recordSummaryToJson(summary),
            ],
            'items': [
              for (final item in _service.owner.information)
                {
                  ...informationToJson(item),
                  'fields': [],
                  if (item.layout != null)
                    'layout': InformationLayout(
                      typeId: item.layout!.typeId,
                      snapshot: {
                        if (item.layout!.snapshot['type'] != null)
                          'type': item.layout!.snapshot['type'],
                      },
                      fieldIds: {},
                    ).toJson(),
                },
            ],
          });
        } else if (request.method == 'GET' &&
            path.length == 4 &&
            path.take(3).join('/') == 'v1/owner/information') {
          final item = _service.owner.information
              .where((i) => i.id == path.last)
              .firstOrNull;
          await reply(
            item == null ? 404 : 200,
            item == null ? {'error': 'not_found'} : informationToJson(item),
          );
        } else if (request.method == 'GET' &&
            request.uri.path == '/v1/owner/information') {
          await reply(200, {
            'items': _service.owner.information.map(informationToJson).toList(),
          });
        } else if (path.length == 4 &&
            path.take(3).join('/') == 'v1/owner/operations' &&
            request.method == 'GET') {
          final receipt = await _service.owner.informationRecordReceipt(
            path.last,
          );
          await reply(
            receipt == null ? 404 : 200,
            receipt?.toJson() ?? {'error': 'operation_not_found'},
          );
        } else if (path.length == 4 &&
            path.take(3).join('/') == 'v1/owner/saves' &&
            request.method == 'POST') {
          final receipt = await _service.owner.saveInformationRecord(
            path.last,
            informationDraftFromJson(parsedBody!),
          );
          await reply(200, receipt.toJson());
        } else {
          await reply(404, {'error': 'not_found'});
        }
      } on InformationFileFailure catch (e) {
        await reply(200, e.toJson());
      } on WorkspaceFailure catch (e) {
        await reply(e.code == 'not_found' ? 404 : 409, {
          'error': e.code,
          if (e.fieldErrors.isNotEmpty) 'fieldErrors': e.fieldErrors,
        });
      } on StorageFailure catch (e) {
        await reply(409, {'error': e.code});
      } on InformationTemplateInputFailure catch (e) {
        await reply(409, {
          'error': e.status,
          'status': e.status,
          'fieldErrors': e.fieldErrors,
        });
      } on AccessFailure catch (e) {
        await reply(e.status == 'unauthorized' ? 401 : 409, {
          'error': e.status,
          'status': e.status,
        });
      } on CredentialUseFailure catch (e) {
        await reply(
          request.uri.path.startsWith('/v1/agent/') ? 200 : 400,
          e.toJson(
            protocolVersion:
                (request.uri.path.startsWith(
                      '/v1/agent/credential-use/batch/',
                    ) ||
                    request.uri.path.startsWith(
                      '/v1/agent/credential-use/program/',
                    ))
                ? 3
                : parsedBody?['protocolVersion'] == 2 ||
                      request.uri.path.startsWith(
                        '/v1/agent/credential-use/device/',
                      )
                ? 2
                : 1,
          ),
        );
      } on FormatException {
        await reply(400, {'error': 'invalid_request'});
      } on TypeError {
        await reply(400, {'error': 'invalid_request'});
      } on Object {
        // Never reflect field values, tokens, filesystem paths or exception text.
        try {
          await reply(500, {'error': 'service_failure'});
        } on Object {
          /* disconnected */
        }
      }
    }

    try {
      // Reject unauthenticated peers and parse bounded request bodies before
      // entering the serialized business queue. No network await holds its lock.
      if (request.headers.value('origin') != null) {
        throw const AccessFailure('unauthorized');
      }
      if (_ownerAuthentication != null &&
          _authPaths.contains(request.uri.path)) {
        final response = await _connectionAuthentication(request);
        status = response.$1;
        result = response.$2;
      } else {
        final path = request.uri.pathSegments;
        final authorization = request.headers.value('authorization') ?? '';
        if (path.length >= 3 && path.take(2).join('/') == 'v1/agent') {
          if (!authorization.startsWith('Bearer '))
            throw const AccessFailure('unauthorized');
          await _devices.authenticate(authorization.substring(7));
        } else if (!_authenticated(authorization)) {
          throw const AccessFailure('unauthorized');
        }
        if (request.method == 'POST') parsedBody = await _body(request);
        if (request.method == 'GET' && request.uri.path == '/v1/owner/health') {
          final expected = request.headers.value('x-chiyo-server-id');
          if (request.uri.hasQuery) throw const FormatException();
          if (expected != null && expected != serverId) {
            throw const AccessFailure('server_changed');
          }
          status = _runtime.isAvailable ? 200 : 503;
          result = {
            'serverId': serverId,
            'state': _runtime.isAvailable ? 'ready' : 'unavailable',
          };
        } else
          await _runtime.run(() async {
            routeStarted = timing.elapsed;
            try {
              await route();
            } finally {
              routeFinished = timing.elapsed;
            }
          }, skipUnchangedCheckpoint: true);
      }
    } on OwnerAuthFailure catch (e) {
      status = e.status;
      result = {'error': e.code};
    } on AccessFailure catch (e) {
      status = e.status == 'unauthorized' ? 401 : 409;
      result = {'error': e.status, 'status': e.status};
    } on FormatException {
      status = 400;
      result = {'error': 'invalid_request'};
    } on Object {
      status = 500;
      result = {'error': 'service_failure'};
    }
    try {
      _onRequestTiming?.call({
        'event': 'request_timing',
        'method': request.method,
        'surface': _timingSurface(request.uri),
        'status': status,
        'totalMicros': timing.elapsedMicroseconds,
        'beforeRouteMicros': routeStarted?.inMicroseconds,
        'routeMicros': routeStarted == null || routeFinished == null
            ? null
            : (routeFinished! - routeStarted!).inMicroseconds,
        'checkpointMicros': routeFinished == null
            ? null
            : (timing.elapsed - routeFinished!).inMicroseconds,
      });
    } on Object {
      /* Diagnostics cannot change request outcomes. */
    }
    // Never publish content, new session proofs or approval success before the
    // encrypted runtime checkpoint has committed. A failed checkpoint replaces
    // the staged response above with a fixed error.
    try {
      request.response.statusCode = status;
      request.response.headers.contentType = ContentType.json;
      request.response.headers.set('cache-control', 'no-store');
      request.response.headers.set('x-chiyo-server-id', serverId);
      request.response.write(jsonEncode(result));
      await request.response.close();
    } on Object {
      /* disconnected */
    }
  }
}
