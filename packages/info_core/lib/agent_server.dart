import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'info_core.dart';
import 'protocol_json.dart';

class _CredentialRequestFailure implements Exception {
  const _CredentialRequestFailure(this.code, [this.fieldPath]);
  final String code;
  final String? fieldPath;
}

Map<String, Object?> _credentialFailure(String code, {String? fieldPath}) => {
  'protocolVersion': 1,
  'status': 'invalid_request',
  'errorCode': code,
  'retryable': false,
  'fieldPath': ?fieldPath,
};

/// Agent-only transport. OwnerAccess is intentionally not a dependency.
typedef CredentialExecutionHandler =
    Future<Map<String, dynamic>> Function(
      String session,
      Map<String, dynamic> input,
    );

/// Public location hints only. These do not grant access or start a program.
class CredentialToolLocation {
  const CredentialToolLocation({
    required this.receiver,
    required this.source,
    required this.available,
    this.version,
    this.executable,
    this.unavailableReason,
  });
  final String receiver, source;
  final bool available;
  final String? version, executable, unavailableReason;
  Map<String, Object?> toJson() => {
    'receiver': receiver,
    'source': source,
    'available': available,
    'version': ?version,
    'executable': ?executable,
    'unavailableReason': ?unavailableReason,
  };
}

class AgentServer extends AgentProtocol {
  AgentServer._(
    this._server,
    AgentAccess agent,
    CredentialExecutionHandler? credentialExecutionHandler,
    bool reusable,
    bool focused,
    bool files,
    Future<List<CredentialToolLocation>> Function()? credentialTools,
    this._connectionToken,
    this._libraryId,
  ) : super(
        agent,
        credentialExecutionHandler: credentialExecutionHandler,
        enableReusableCredentialUse: reusable,
        enableFocusedFill: focused,
        enableInformationFiles: files,
        credentialTools: credentialTools,
      ) {
    _server.listen(_handle);
  }
  final HttpServer _server;
  final String? _connectionToken, _libraryId;
  int get port => _server.port;
  static Future<AgentServer> start(
    AgentAccess agent, {
    int port = 47125,
    CredentialExecutionHandler? credentialExecutionHandler,
    bool enableReusableCredentialUse = false,
    bool enableFocusedFill = false,
    bool enableInformationFiles = false,
    Future<List<CredentialToolLocation>> Function()? credentialTools,
    String? connectionToken,
    String? libraryId,
  }) async {
    if ((connectionToken == null) != (libraryId == null) ||
        connectionToken != null &&
            !RegExp(
              r'^[A-Za-z0-9_-]{22}\.[A-Za-z0-9_-]{43}$',
            ).hasMatch(connectionToken) ||
        libraryId != null &&
            !RegExp(r'^[A-Za-z0-9_-]{16,128}$').hasMatch(libraryId)) {
      throw const AccessFailure('invalid_request');
    }
    return AgentServer._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, port, shared: false),
      agent,
      credentialExecutionHandler,
      enableReusableCredentialUse,
      enableFocusedFill,
      enableInformationFiles,
      credentialTools,
      connectionToken,
      libraryId,
    );
  }

  bool _acceptsConnection(HttpRequest request) {
    final token = _connectionToken;
    if (token == null) return true;
    final supplied = request.headers.value('authorization') ?? '';
    final expected = 'Bearer $token';
    if (supplied.length != expected.length ||
        request.headers.value('x-chiyo-server-id') != _libraryId) {
      return false;
    }
    var difference = 0;
    for (var i = 0; i < expected.length; i++) {
      difference |= expected.codeUnitAt(i) ^ supplied.codeUnitAt(i);
    }
    return difference == 0;
  }

  Future<void> close() async {
    await _server.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    Map<String, Object?> result;
    final runtime = request.uri.path.startsWith('/credential-use/');
    final informationFile = request.uri.path.startsWith('/information-file/');
    var protocolVersion = 1;
    if (_libraryId != null) {
      request.response.headers.set('x-chiyo-server-id', _libraryId);
    }
    try {
      if (!_acceptsConnection(request) ||
          request.method != 'POST' ||
          request.headers.value('origin') != null ||
          request.headers.host != '127.0.0.1' ||
          request.headers.port != port ||
          request.headers.contentType?.mimeType != 'application/json') {
        throw const AccessFailure('unauthorized');
      }
      final limit = request.uri.path == '/import-file/submit'
          ? 15 * 1024 * 1024
          : request.uri.path == '/import/submit' ||
                request.uri.path == '/import/revise'
          ? 6000000
          : request.uri.path == '/organization/submit' ||
                request.uri.path == '/update/submit' ||
                request.uri.path == '/update/revise' ||
                request.uri.path == '/credentials/catalog' ||
                runtime
          ? 262144
          : 16384;
      if (request.contentLength > limit) {
        if (request.uri.path == '/credentials/catalog' || runtime) {
          throw const _CredentialRequestFailure('limit_exceeded');
        }
        throw const AccessFailure('invalid_request');
      }
      final bytes = <int>[];
      await for (final chunk in request.timeout(const Duration(seconds: 5))) {
        if (bytes.length + chunk.length > limit) {
          if (request.uri.path == '/credentials/catalog' || runtime) {
            throw const _CredentialRequestFailure('limit_exceeded');
          }
          throw const AccessFailure('invalid_request');
        }
        bytes.addAll(chunk);
      }
      final body =
          request.uri.path == '/credentials/catalog' ||
              runtime ||
              informationFile ||
              request.uri.path == '/catalog' ||
              request.uri.path == '/directories/catalog' ||
              request.uri.path == '/request' ||
              request.uri.path == '/request/status' ||
              request.uri.path == '/import/submit' ||
              request.uri.path == '/import/revise' ||
              request.uri.path == '/update/submit' ||
              request.uri.path == '/update/revise' ||
              request.uri.path.startsWith('/templates/') ||
              request.uri.path.startsWith('/import-file/') ||
              request.uri.path == '/plugins/catalog'
          ? decodeProtocolObject(utf8.decode(bytes), maxBytes: limit)
          : jsonDecode(utf8.decode(bytes));
      if (body is! Map<String, dynamic>) {
        throw const AccessFailure('invalid_request');
      }
      if (body['protocolVersion'] == 2) protocolVersion = 2;
      result = await _dispatch(request.uri.path, body);
    } on InformationFileFailure catch (error) {
      result = error.toJson();
    } on CredentialUseFailure catch (error) {
      result = error.toJson();
    } on _CredentialRequestFailure catch (error) {
      result = _credentialFailure(error.code, fieldPath: error.fieldPath);
    } on FormatException {
      result = informationFile
          ? const InformationFileFailure('invalid_json').toJson()
          : request.uri.path == '/credentials/catalog' || runtime
          ? _credentialFailure('invalid_json')
          : {'status': 'invalid_request'};
    } on InformationTemplateInputFailure catch (error) {
      result = {'status': error.status, 'fieldErrors': error.fieldErrors};
    } on AccessFailure catch (error) {
      result = {'status': error.status};
    } on Object {
      // Never echo submitted text, authorization material, or internal errors.
      result = {'status': 'invalid_request'};
    }
    if (informationFile && result['protocolVersion'] == null) {
      result = InformationFileFailure(
        result['status'] == 'unauthorized'
            ? 'not_authorized'
            : result['status'] == 'service_unavailable'
            ? 'service_unavailable'
            : 'invalid_request',
      ).toJson();
    }
    if ((request.uri.path == '/credentials/catalog' || runtime) &&
        result['protocolVersion'] == null) {
      result = {
        'protocolVersion': 1,
        'status':
            {'service_unavailable', 'unauthorized'}.contains(result['status'])
            ? result['status']
            : 'invalid_request',
        'errorCode': result['status'] == 'service_unavailable'
            ? 'service_unavailable'
            : 'invalid_reference',
        'retryable': false,
      };
    }
    if (runtime && protocolVersion == 2) {
      result = {...result, 'protocolVersion': 2};
      if (result.containsKey('attemptConsumed')) {
        result['operationClaimed'] = result.remove('attemptConsumed');
      }
    }
    request.response.headers.contentType = ContentType.json;
    request.response.headers.set('Cache-Control', 'no-store');
    request.response.headers.set('X-Content-Type-Options', 'nosniff');
    request.response.statusCode = result['status'] == 'unauthorized'
        ? 403
        : result['status'] == 'invalid_request'
        ? 400
        : 200;
    try {
      request.response.write(jsonEncode(result));
      await request.response.close();
    } on Object {
      /* A disconnected caller must not terminate the desktop. */
    }
  }
}

/// Agent-only command processing shared by local and authenticated remote
/// transports. Callers must enforce their own origin, identity and body limits.
/// It receives no OwnerAccess, so cannot approve or manage information.
class AgentProtocol {
  AgentProtocol(
    this._agent, {
    CredentialExecutionHandler? credentialExecutionHandler,
    this.enableReusableCredentialUse = false,
    this.enableFocusedFill = false,
    this.enableInformationFiles = false,
    Future<List<CredentialToolLocation>> Function()? credentialTools,
  }) : _credentialExecutionHandler = credentialExecutionHandler,
       _credentialTools = credentialTools;
  final AgentAccess _agent;
  final CredentialExecutionHandler? _credentialExecutionHandler;
  final Future<List<CredentialToolLocation>> Function()? _credentialTools;

  /// Enable only after the caller's storage and executor support v2 semantics.
  final bool enableReusableCredentialUse;

  /// Kept off until the repository, native host, and owner UI support fills.
  final bool enableFocusedFill;

  /// Off until storage, file driver and owner UI are connected by the host.
  final bool enableInformationFiles;
  bool get _informationFilesEnabled =>
      enableReusableCredentialUse &&
      enableInformationFiles &&
      _agent.informationFileDeliveryAvailable;
  bool get _focusedFillEnabled =>
      enableReusableCredentialUse &&
      enableFocusedFill &&
      _agent.focusedFillAvailable;

  Future<Map<String, Object?>> dispatch(
    String path,
    Map<String, dynamic> body,
  ) => _dispatch(path, body);

  Future<Map<String, Object?>> _dispatch(
    String path,
    Map<String, dynamic> body,
  ) async {
    if (const {
      '/request',
      '/credential-use/request',
      '/organization/request',
      '/import/submit',
      '/update/submit',
      '/delete/submit',
    }.contains(path)) {
      final errors = submissionMetadataErrors(
        body,
        proposal: const {
          '/organization/request',
          '/import/submit',
          '/update/submit',
          '/delete/submit',
        }.contains(path),
      );
      if (errors.isNotEmpty) {
        return {
          'status': 'invalid_request',
          'errorCode': 'invalid_submission_metadata',
          'fieldErrors': errors,
        };
      }
    }
    switch (path) {
      case '/health':
        if (body.isNotEmpty) throw const AccessFailure('invalid_request');
        // Transport readiness is authenticated by AgentServer. It must not
        // depend on optional tool inventory or inspect any library contents.
        return {'protocolVersion': 1, 'status': 'ok'};
      case '/capabilities':
        if (body.isNotEmpty) throw const CredentialUseFailure('unknown_field');
        final tools = await _credentialTools?.call();
        return {
          'protocolVersion': 1,
          'status': 'ok',
          'protocolVersions': [1, if (enableReusableCredentialUse) 2],
          'capabilities': [
            'information-request-operations.v1',
            'submission-metadata.v1',
            if (enableReusableCredentialUse) 'credential-use-reuse.v1',
            if (enableReusableCredentialUse)
              'credential-ssh-session-validity.v1',
            if (_focusedFillEnabled) 'credential-focused-fill.v1',
            if (_focusedFillEnabled && _agent.focusedFillDiscoveryAvailable)
              'credential-focused-target.v1',
            if (_informationFilesEnabled) 'information-attachments.v1',
            if (tools != null) 'credential-tools.v1',
            if (_agent.informationTemplatesAvailable)
              'information-template-discovery.v1',
            if (_agent.informationTemplatesAvailable)
              'information-import-admission.v1',
            if (_agent.credentialImportAvailable) 'credential-import.v1',
            'information-import-operations.v1',
            'import-proposal-title.v1',
            'information-update-operations.v1',
            'information-directory-discovery.v1',
            if (_agent.informationImportFilesAvailable)
              'information-file-upload.v1',
            if (_agent.informationImportFilesAvailable)
              'information-file-update.v1',
          ],
          if (enableReusableCredentialUse)
            'sshGrantValidity': {
              'receiver': 'ssh_identity',
              'options': ['timed', 'session'],
              'description':
                  'The user chooses the lifetime during approval. Session validity has no fixed deadline and remains bound to the original live chat, credential version and receiver. Revocation stops future use; completed remote operations are not rolled back.',
            },
          if (tools != null)
            'credentialTools': tools.map((tool) => tool.toJson()).toList(),
          'directoryDiscovery': {
            'command': 'directory-list',
            'example': {'command': 'directory-list'},
            'description':
                'Returns all current directories, including empty ones, with complete paths and sibling order. Query before proposing a location; reuse existing IDs. Discovery does not permit writes or reveal record contents.',
          },
        };
      case '/import-file/submit':
        if (body.keys.any(
          (k) => !{
            'sessionSecret',
            'operationId',
            'originalName',
            'mediaType',
            'bytes',
          }.contains(k),
        )) {
          throw const AccessFailure('invalid_request');
        }
        final encoded = body['bytes'];
        if (encoded is! String) throw const AccessFailure('invalid_request');
        if (encoded.length > ((informationFileByteLimit + 2) ~/ 3) * 4) {
          throw const AccessFailure('file_too_large');
        }
        final upload = await _agent.uploadImportFile(
          _text(body, 'sessionSecret'),
          operationId: _text(body, 'operationId'),
          originalName: _text(body, 'originalName'),
          mediaType: _text(body, 'mediaType'),
          bytes: Uint8List.fromList(base64Decode(encoded)),
        );
        return {'status': 'ok', ...upload.metadata};
      case '/import-file/status':
        if (body.keys.any(
          (k) => !{'sessionSecret', 'operationId'}.contains(k),
        )) {
          throw const AccessFailure('invalid_request');
        }
        return _agent.importFileStatus(
          _text(body, 'sessionSecret'),
          _text(body, 'operationId'),
        );
      case '/plugins/catalog':
        if (body.isNotEmpty) throw const AccessFailure('invalid_request');
        return _agent.pluginCatalog();
      case '/templates/catalog':
        if (body.keys.any(
              (k) => !{'packageId', 'offset', 'limit'}.contains(k),
            ) ||
            body['packageId'] != null && body['packageId'] is! String ||
            body.containsKey('offset') && body['offset'] is! int ||
            body.containsKey('limit') && body['limit'] is! int) {
          throw const AccessFailure('invalid_request');
        }
        return _agent.informationTemplateCatalog(
          packageId: body['packageId'] as String?,
          offset: body['offset'] as int? ?? 0,
          limit: body['limit'] as int? ?? 50,
        );
      case '/templates/read':
        if (body.length != 1 || body['templateId'] is! String) {
          throw const AccessFailure('invalid_request');
        }
        return _agent.readInformationTemplate(body['templateId'] as String);
      case '/information-file/fetch':
      case '/information-file/status':
      case '/information-file/release':
        if (!_informationFilesEnabled) {
          throw const InformationFileFailure('unsupported_capability');
        }
        final command = Map<String, dynamic>.of(body)..remove('sessionSecret');
        final expected = 'file-${path.split('/').last}';
        if (command['command'] != expected) {
          throw const InformationFileFailure('invalid_request');
        }
        final session = _text(body, 'sessionSecret');
        if (path.endsWith('/fetch')) {
          return _agent.fetchInformationFile(
            session,
            InformationFileFetchInput.fromJson(command),
          );
        }
        final input = InformationFileDeliveryInput.fromJson(command);
        if (input.operationId != null) {
          return _agent.informationFileOperationStatus(
            session,
            input.operationId!,
          );
        }
        return path.endsWith('/status')
            ? _agent.informationFileStatus(session, input.deliveryId!)
            : _agent.releaseInformationFile(session, input.deliveryId!);
      case '/information-file/watch':
      case '/information-file/discard':
        if (!_informationFilesEnabled) {
          throw const InformationFileFailure('unsupported_capability');
        }
        final input = InformationFileCleanupInput.fromJson(body);
        if (input.command != 'file-${path.split('/').last}') {
          throw const InformationFileFailure('invalid_request');
        }
        return path.endsWith('/watch')
            ? _agent.watchDeviceInformationFile(input)
            : _agent.discardDeviceInformationFile(input);
      case '/information-file/download':
      case '/information-file/complete':
      case '/information-file/cleanup':
        if (!_informationFilesEnabled) {
          throw const InformationFileFailure('unsupported_capability');
        }
        final command = Map<String, dynamic>.of(body)..remove('sessionSecret');
        final input = InformationFileDeviceInput.fromJson(command);
        if (input.command != 'file-${path.split('/').last}') {
          throw const InformationFileFailure('invalid_request');
        }
        final session = _text(body, 'sessionSecret');
        if (path.endsWith('/download')) {
          return _agent.downloadDeviceInformationFile(
            session,
            input.deliveryId,
          );
        }
        if (path.endsWith('/complete')) {
          return _agent.completeDeviceInformationFile(
            session,
            input.deliveryId,
            input.byteLength!,
            input.sha256!,
          );
        }
        return _agent.cleanupDeviceInformationFile(session, input.deliveryId);
      case '/credential-use/focus-target':
        if (!_focusedFillEnabled || !_agent.focusedFillDiscoveryAvailable) {
          throw const CredentialUseFailure('unsupported_capability');
        }
        final command = Map<String, dynamic>.of(body)..remove('sessionSecret');
        FocusedFillTargetQuery.fromJson(command);
        return (await _agent.discoverFocusedFillTarget(
          _text(body, 'sessionSecret'),
        )).toJson();
      case '/credential-use/fill':
      case '/credential-use/fill/status':
        if (!_focusedFillEnabled) {
          throw const CredentialUseFailure('unsupported_capability');
        }
        final session = _text(body, 'sessionSecret');
        final command = Map<String, dynamic>.of(body)..remove('sessionSecret');
        if (command['command'] !=
            (path.endsWith('/status') ? 'fill-status' : 'fill-use')) {
          throw const CredentialUseFailure('invalid_plan');
        }
        final input = FocusedFillOperationInput.fromJson(command);
        return path.endsWith('/status')
            ? _agent.focusedFillStatus(session, input)
            : await _agent.startFocusedFill(session, input);
      case '/credential-use/operation':
      case '/credential-use/operation/status':
        if (!enableReusableCredentialUse) {
          throw const CredentialUseFailure('unsupported_capability');
        }
        final input = Map<String, dynamic>.from(body)
          ..remove('sessionSecret')
          ..remove('supervisorPid')
          ..remove('supervisorCreatedAt');
        final operation = CredentialOperationInput.fromJson(input);
        final session = _text(body, 'sessionSecret');
        if (path.endsWith('/status')) {
          if (body.containsKey('supervisorPid') ||
              body.containsKey('supervisorCreatedAt')) {
            throw const CredentialUseFailure('unknown_field');
          }
          return _agent
                  .credentialUseOperationStatus(session, operation)
                  ?.toPublicJson() ??
              {'protocolVersion': 2, 'status': 'not_found'};
        }
        if (body.containsKey('supervisorPid') !=
                body.containsKey('supervisorCreatedAt') ||
            body.containsKey('supervisorPid') &&
                (body['supervisorPid'] is! int ||
                    body['supervisorCreatedAt'] is! String)) {
          throw const CredentialUseFailure('invalid_plan');
        }
        return (await _agent.beginCredentialUseOperation(
          session,
          operation,
          supervisorPid: body['supervisorPid'] as int?,
          supervisorCreatedAt: body['supervisorCreatedAt'] as String?,
        )).toPrivateJson();
      case '/credential-use/hosted':
        final handler = _credentialExecutionHandler;
        if (handler == null) {
          throw const CredentialUseFailure('service_unavailable');
        }
        final session = _text(body, 'sessionSecret');
        final input = Map<String, dynamic>.of(body)..remove('sessionSecret');
        if (input['protocolVersion'] == 2 && !enableReusableCredentialUse) {
          throw const CredentialUseFailure('unsupported_capability');
        }
        if (!{
          'run-use',
          'execution-status',
          'execution-output',
          'cleanup-use',
        }.contains(input['command'])) {
          throw const CredentialUseFailure('invalid_plan');
        }
        try {
          return await handler(session, input);
        } on Object {
          // The handler can fail after the operation was committed or started.
          // Never turn that uncertainty into an unclaimed/retryable launch.
          final launching = input['command'] == 'run-use';
          throw CredentialUseFailure(
            launching ? 'execution_unknown' : 'service_unavailable',
            attemptConsumed: launching,
          );
        }
      case '/credential-use/materials/register':
        if (body.keys.any(
          (k) => !{'executionId', 'executionCapability', 'lease'}.contains(k),
        )) {
          throw const CredentialUseFailure('unknown_field');
        }
        await _agent.registerCredentialMaterials(
          _text(body, 'executionId'),
          _text(body, 'executionCapability'),
          CredentialMaterialLease.fromPrivateJson(
            body['lease'] as Map<String, dynamic>,
          ),
        );
        return {'protocolVersion': 1, 'status': 'ok'};
      case '/credential-use/cleanup':
        if (body.keys.any(
          (k) => !{'sessionSecret', 'executionId'}.contains(k),
        )) {
          throw const CredentialUseFailure('unknown_field');
        }
        final execution = await _agent.cleanupCredentialExecution(
          _text(body, 'sessionSecret'),
          _text(body, 'executionId'),
        );
        return {
          'protocolVersion': execution.protocolVersion,
          'status': 'ok',
          'executionId': execution.id,
          'cleanupState': execution.cleanupState,
        };
      case '/credential-use/request':
        final session = _text(body, 'sessionSecret');
        final command = Map<String, dynamic>.from(body)
          ..remove('sessionSecret');
        if (command['protocolVersion'] == 2 && !enableReusableCredentialUse) {
          throw const CredentialUseFailure('unsupported_capability');
        }
        if (command.containsKey('fill')) {
          if (!_focusedFillEnabled) {
            throw const CredentialUseFailure('unsupported_capability');
          }
          final request = await _agent.requestFocusedFill(
            session,
            FocusedFillInput.fromJson(command),
          );
          return _agent.credentialUseStatus(session, request.id);
        }
        final request = await _agent.requestCredentialUse(
          session,
          CredentialUseInput.fromJson(command),
        );
        return _agent.credentialUseStatus(session, request.id);
      case '/credential-use/consume':
        if (body.keys.any(
          (k) => !{
            'sessionSecret',
            'requestId',
            'supervisorPid',
            'supervisorCreatedAt',
          }.contains(k),
        )) {
          throw const CredentialUseFailure('unknown_field');
        }
        if (body.containsKey('supervisorPid') !=
                body.containsKey('supervisorCreatedAt') ||
            body.containsKey('supervisorPid') &&
                (body['supervisorPid'] is! int ||
                    body['supervisorCreatedAt'] is! String)) {
          throw const CredentialUseFailure('invalid_plan');
        }
        return (await _agent.consumeCredentialUse(
          _text(body, 'sessionSecret'),
          _text(body, 'requestId'),
          supervisorPid: body['supervisorPid'] as int?,
          supervisorCreatedAt: body['supervisorCreatedAt'] as String?,
        )).toPrivateJson();
      case '/credential-use/execution/report':
        return (await _agent.reportCredentialExecution(
          CredentialExecutionReport.fromPrivateJson(body),
        )).toJson();
      case '/credential-use/worker/register':
        if (body.keys.any(
              (k) => !{
                'executionId',
                'executionCapability',
                'workerPid',
                'workerCreatedAt',
              }.contains(k),
            ) ||
            body['workerPid'] is! int) {
          throw const CredentialUseFailure('invalid_plan');
        }
        await _agent.registerCredentialWorker(
          _text(body, 'executionId'),
          _text(body, 'executionCapability'),
          body['workerPid'] as int,
          _text(body, 'workerCreatedAt'),
        );
        return {'protocolVersion': 1, 'status': 'ok'};
      case '/credential-use/execution/status':
        if (body.keys.any(
          (k) => !{'sessionSecret', 'executionId'}.contains(k),
        )) {
          throw const CredentialUseFailure('unknown_field');
        }
        return _agent
            .credentialExecutionStatus(
              _text(body, 'sessionSecret'),
              _text(body, 'executionId'),
            )
            .toJson();
      case '/credentials/catalog':
        if (body.keys.any((k) => !{'cursor', 'limit'}.contains(k))) {
          throw const _CredentialRequestFailure('unknown_field');
        }
        if (body['cursor'] != null && body['cursor'] is! String) {
          throw const _CredentialRequestFailure('invalid_type', 'cursor');
        }
        if (body['limit'] != null && body['limit'] is! int) {
          throw const _CredentialRequestFailure('invalid_type', 'limit');
        }
        if (body['limit'] is int &&
            ((body['limit'] as int) < 1 || (body['limit'] as int) > 100)) {
          throw const _CredentialRequestFailure('limit_exceeded', 'limit');
        }
        return _agent
            .credentialCatalog(
              cursor: body['cursor'] as String?,
              limit: body['limit'] as int? ?? 50,
            )
            .toJson();
      case '/delete/submit':
        return _submitDelete(body);
      case '/delete/status':
        return _agent.deleteStatus(
          _text(body, 'sessionSecret'),
          _text(body, 'proposalId'),
        );
      case '/update/submit':
        return _submitUpdate(body);
      case '/update/revise':
        if (body['update'] is! Map<String, dynamic> ||
            body['version'] is! int) {
          throw const AccessFailure('invalid_request');
        }
        final session = _text(body, 'sessionSecret'),
            id = _text(body, 'proposalId');
        await _agent.reviseUpdate(
          session,
          id,
          body['version'] as int,
          UpdateInput.fromJson(body['update'] as Map<String, dynamic>),
        );
        return _agent.updateStatus(session, id);
      case '/update/status':
        if (body.containsKey('operationId')) {
          if (body.containsKey('proposalId')) {
            throw const AccessFailure('invalid_request');
          }
          return _agent.updateStatusByOperation(
            _text(body, 'sessionSecret'),
            _text(body, 'operationId'),
          );
        }
        return _agent.updateStatus(
          _text(body, 'sessionSecret'),
          _text(body, 'proposalId'),
        );
      case '/import/submit':
        return _submitImport(body);
      case '/import/revise':
        final raw = body['items'];
        if (raw is! List ||
            raw.isEmpty ||
            raw.length > 20 ||
            body['version'] is! int) {
          throw const AccessFailure('invalid_request');
        }
        final session = _text(body, 'sessionSecret'),
            id = _text(body, 'proposalId');
        await _agent.reviseImport(session, id, body['version'] as int, [
          for (final row in raw)
            ImportItemInput.fromJson(Map<String, dynamic>.from(row as Map)),
        ]);
        return _agent.importStatus(session, id);
      case '/import/status':
        if (body.containsKey('operationId')) {
          if (body.containsKey('proposalId')) {
            throw const AccessFailure('invalid_request');
          }
          return _agent.importStatusByOperation(
            _text(body, 'sessionSecret'),
            _text(body, 'operationId'),
          );
        }
        return _agent.importStatus(
          _text(body, 'sessionSecret'),
          _text(body, 'proposalId'),
        );
      case '/organization/request':
        final ids = body['itemIds'];
        final agentName = body['agentName'] ?? '';
        if (ids is! List ||
            ids.any((id) => id is! String) ||
            agentName is! String) {
          throw const AccessFailure('invalid_request');
        }
        final task = await _agent.requestOrganization(
          _text(body, 'sessionSecret'),
          _text(body, 'purpose'),
          ids.cast<String>(),
          agentName: agentName,
          title: _optionalMetadata(body, 'title'),
          externalChatId: _optionalMetadata(body, 'externalChatId'),
        );
        return _agent.organizationStatus(_text(body, 'sessionSecret'), task.id);
      case '/organization/status':
        return _agent.organizationStatus(
          _text(body, 'sessionSecret'),
          _text(body, 'taskId'),
        );
      case '/organization/tasks':
        return {
          'status': 'ok',
          'tasks': _agent.organizationTasks(_text(body, 'sessionSecret')),
        };
      case '/organization/metadata':
        return _agent.organizationMetadata(
          _text(body, 'sessionSecret'),
          _text(body, 'taskId'),
        );
      case '/organization/submit':
        final raw = body['changes'];
        if (raw is! List ||
            raw.length > 200 ||
            raw.any((c) => c is! Map<String, dynamic>)) {
          throw const AccessFailure('invalid_request');
        }
        final allowed = {
          'itemId',
          'baseVersion',
          'directoryId',
          'directoryName',
          'tagIds',
          'tagNames',
        };
        if (raw.any(
          (dynamic c) => (c as Map<String, dynamic>).keys.any(
            (key) => !allowed.contains(key),
          ),
        )) {
          throw const AccessFailure('invalid_request');
        }
        await _agent.submitOrganization(
          _text(body, 'sessionSecret'),
          _text(body, 'taskId'),
          raw
              .map(
                (dynamic c) =>
                    OrganizationChange.fromJson(c as Map<String, dynamic>),
              )
              .toList(),
        );
        return _agent.organizationStatus(
          _text(body, 'sessionSecret'),
          _text(body, 'taskId'),
        );
      case '/directories/catalog':
        if (body.isNotEmpty) throw const AccessFailure('invalid_request');
        final directories = _agent.catalogDirectories();
        return {
          'status': 'ok',
          'directories': directories,
          'total': directories.length,
          'complete': true,
        };
      case '/catalog':
        final query = body['query'] ?? '';
        final typeId = body['typeId'];
        final directoryId = body['directoryId'];
        final tagId = body['tagId'];
        final offset = body['offset'] ?? 0;
        final limit = body['limit'] ?? 20;
        if (query is! String ||
            (typeId != null && typeId is! String) ||
            (directoryId != null && directoryId is! String) ||
            (tagId != null && tagId is! String) ||
            offset is! int ||
            limit is! int) {
          throw const AccessFailure('invalid_request');
        }
        final page = _agent.searchCatalog(
          query: query,
          typeId: typeId as String?,
          directoryId: directoryId as String?,
          tagId: tagId as String?,
          offset: offset,
          limit: limit,
        );
        // Legacy clients fail explicitly rather than dropping file fields.
        if ((!_informationFilesEnabled ||
                body['protocolVersion'] is! int ||
                body['protocolVersion'] != 2) &&
            page.items.any(
              (item) => (item['fields'] as List).any(
                (field) => (field as Map)['kind'] == FieldKind.file.name,
              ),
            )) {
          throw const AccessFailure('unsupported_capability');
        }
        return {
          'status': 'ok',
          'items': page.items,
          'tags': _agent.catalogTags(),
          'total': page.total,
          'offset': offset,
          'nextOffset': page.nextOffset,
        };
      case '/session':
      case '/session/lifecycle':
        final session = _agent.openSessionWithEndCapability(
          _text(body, 'chatLabel'),
        );
        return {
          'status': 'ok',
          'sessionSecret': session.sessionSecret,
          if (path == '/session/lifecycle')
            'endCapability': session.endCapability,
        };
      case '/session/check':
        _agent.validateSession(_text(body, 'sessionSecret'));
        return {'status': 'ok'};
      case '/session/end':
        _agent.endSessionWithCapability(_text(body, 'endCapability'));
        return {'status': 'ended'};
      case '/request':
        _agent.validateSession(_text(body, 'sessionSecret'));
        if (body.containsKey('operationId') && body['operationId'] is! String) {
          throw const AccessFailure('invalid_request');
        }
        final raw = body['fields'];
        if (raw is! List || raw.length > 200) {
          throw const AccessFailure('invalid_request');
        }
        final fields = raw.map((f) {
          if (f is! Map<String, dynamic>) {
            throw const AccessFailure('invalid_request');
          }
          return FieldRef(_text(f, 'itemId'), _text(f, 'fieldId'));
        }).toList();
        final fileFields = {
          for (final item in _agent.catalog())
            for (final field in item['fields'] as List)
              if ((field as Map)['kind'] == FieldKind.file.name)
                FieldRef(item['id'] as String, field['id'] as String),
        };
        if ((!_informationFilesEnabled ||
                body['protocolVersion'] is! int ||
                body['protocolVersion'] != 2) &&
            fields.any(fileFields.contains)) {
          throw const AccessFailure('unsupported_capability');
        }
        final receipt = _agent.request(
          _text(body, 'sessionSecret'),
          _text(body, 'purpose'),
          fields,
          operationId: body['operationId'] as String?,
          agentName: _optionalMetadata(body, 'agentName'),
          externalChatId: _optionalMetadata(body, 'externalChatId'),
        );
        return {
          ..._agent.status(_text(body, 'sessionSecret'), receipt.id),
          if (body.containsKey('operationId'))
            'operationId': body['operationId'],
        };
      case '/request/status':
        return _agent.requestOperationStatus(
          _text(body, 'sessionSecret'),
          _text(body, 'operationId'),
        );
      case '/cancel':
        final session = _text(body, 'sessionSecret');
        final id = _text(body, 'requestId');
        _agent.cancel(session, id);
        return _agent.status(session, id);
      case '/status':
        return _agent.status(
          _text(body, 'sessionSecret'),
          _text(body, 'requestId'),
        );
      case '/claim':
        final grant = _agent.claim(
          _text(body, 'sessionSecret'),
          _text(body, 'requestId'),
        );
        return {
          'status': 'ok',
          'token': grant.token,
          'fields': grant.fields.map((f) => f.toJson()).toList(),
          'expiresAt': grant.expiresAt.toUtc().toIso8601String(),
          'scopeNotice':
              'Only these item and field identities are approved. New items and fields require a new request.',
        };
      case '/read':
        return {
          'status': 'ok',
          'value': await _agent.read(
            _text(body, 'token'),
            FieldRef(_text(body, 'itemId'), _text(body, 'fieldId')),
          ),
        };
      default:
        throw const AccessFailure('unauthorized');
    }
  }

  Future<Map<String, Object?>> _submitImport(Map<String, dynamic> body) async {
    final raw = body['items'];
    if (raw is! List ||
        raw.isEmpty ||
        raw.length > 20 ||
        raw.any((i) => i is! Map<String, dynamic>)) {
      throw const AccessFailure('invalid_request');
    }
    for (final key in ['agentName', 'purpose', 'title', 'externalChatId']) {
      if (body.containsKey(key) && body[key] is! String) {
        throw const AccessFailure('invalid_request');
      }
    }
    if (body.containsKey('title') && (body['title'] as String).trim().isEmpty) {
      throw const AccessFailure('proposal_title_required');
    }
    final session = _text(body, 'sessionSecret');
    final items = raw
        .map((i) => ImportItemInput.fromJson(i as Map<String, dynamic>))
        .toList();
    final id = await _agent.submitImport(
      session,
      items,
      agentName: body['agentName'] is String ? body['agentName'] as String : '',
      title: body['title'] as String? ?? '',
      externalChatId: body['externalChatId'] as String? ?? '',
      purpose: body['purpose'] is String ? body['purpose'] as String : '',
      operationId: body['operationId'] as String?,
    );
    return _agent.importStatus(session, id);
  }

  Future<Map<String, Object?>> _submitUpdate(Map<String, dynamic> body) async {
    final raw = body['update'];
    if (raw is! Map<String, dynamic>) {
      throw const AccessFailure('invalid_request');
    }
    final session = _text(body, 'sessionSecret');
    final id = await _agent.submitUpdate(
      session,
      UpdateInput.fromJson(raw),
      title: _optionalMetadata(body, 'title'),
      agentName: _optionalMetadata(body, 'agentName'),
      purpose: _optionalMetadata(body, 'purpose'),
      externalChatId: _optionalMetadata(body, 'externalChatId'),
      operationId: body['operationId'] == null
          ? null
          : _text(body, 'operationId'),
    );
    return _agent.updateStatus(session, id);
  }

  Future<Map<String, Object?>> _submitDelete(Map<String, dynamic> body) async {
    final version = body['baseVersion'];
    if (version is! int ||
        (body['fieldId'] != null && body['fieldId'] is! String)) {
      throw const AccessFailure('invalid_request');
    }
    final session = _text(body, 'sessionSecret');
    final id = await _agent.submitDelete(
      session,
      _text(body, 'itemId'),
      version,
      fieldId: body['fieldId'] == null ? null : _text(body, 'fieldId'),
      title: _optionalMetadata(body, 'title'),
      agentName: _optionalMetadata(body, 'agentName'),
      purpose: _optionalMetadata(body, 'purpose'),
      externalChatId: _optionalMetadata(body, 'externalChatId'),
    );
    return _agent.deleteStatus(session, id);
  }

  String _optionalMetadata(Map<String, dynamic> body, String key) {
    final value = body[key];
    if (!body.containsKey(key)) return '';
    if (value is! String) {
      throw const AccessFailure('invalid_submission_metadata');
    }
    return value;
  }

  String _text(Map<String, dynamic> body, String key) {
    final value = body[key];
    if (value is! String || value.isEmpty || value.length > 2000) {
      throw const AccessFailure('invalid_request');
    }
    return value;
  }
}
