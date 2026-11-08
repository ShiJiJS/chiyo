import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'runtime_process_identity.dart';
export 'runtime_process_identity.dart';
import 'runtime_material_files.dart';
import 'new_file_publish.dart' as file_publication;
import 'macos_tool_probe.dart' as macos_probe;
import 'information_delivery_driver.dart';
export 'information_delivery_driver.dart';
export 'runtime_material_files.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;
import 'credentials.dart';
export 'credentials.dart';
import 'organization_tasks.dart';
export 'organization_tasks.dart';
import 'information.dart';
import 'information_files.dart';
export 'information_files.dart';
import 'information_import_files.dart';
export 'information_import_files.dart';
import 'templates.dart';
import 'template_packages.dart';
export 'template_packages.dart';
import 'history.dart';
export 'history.dart';
import 'server_state.dart';
import 'import_proposals.dart';
import 'update_proposals.dart';
import 'recycle.dart';
export 'information.dart';
export 'templates.dart';
export 'import_proposals.dart';
export 'update_proposals.dart';
export 'recycle.dart';
export 'revisions.dart';
import 'revisions.dart';
part 'organization_access.dart';
part 'organization_task_access.dart';
part 'history_access.dart';
part 'import_access.dart';
part 'proposal_password_operations.dart';
part 'information_import_file_access.dart';
part 'update_access.dart';
part 'recycle_access.dart';
part 'library_recycle.dart';
part 'library_recycle_operations.dart';
part 'library_recycle_access.dart';
part 'library_move.dart';
part 'library_order.dart';
part 'revision_access.dart';
part 'backup_access.dart';
part 'workspace_access.dart';
part 'desktop_preferences.dart';
part 'library_access.dart';
part 'information_file_access.dart';
part 'information_draft_models.dart';
part 'information_draft_access.dart';
part 'information_record_operations.dart';
part 'information_file_operations.dart';
part 'information_approval_operations.dart';
part 'information_approval_access.dart';
part 'information_classification_operations.dart';
part 'information_lifecycle_operations.dart';
part 'information_purge.dart';
part 'information_attachment_access.dart';
part 'information_delivery_models.dart';
part 'information_delivery_access.dart';
part 'information_device_delivery_access.dart';
part 'credential_access.dart';
part 'credential_record_operations.dart';
part 'credential_field_migration.dart';
part 'credential_runtime_models.dart';
part 'focused_fill_models.dart';
part 'focused_fill_access.dart';
part 'credential_runtime_access.dart';
part 'device_credential_launch.dart';
part 'device_credential_access.dart';
part 'device_credential_execution.dart';
part 'credential_execution_audit.dart';
part 'credential_file_receivers.dart';
part 'credential_material_access.dart';
part 'credential_history_access.dart';
part 'ssh_host_trust.dart';
part 'proposal_access.dart';
part 'proposal_operations.dart';
part 'additional_approval_operations.dart';
part 'template_package_access.dart';
part 'information_template_catalog.dart';
part 'template_import_access.dart';
part 'import_admission_access.dart';
part 'update_admission_access.dart';
part 'online_information_runtime.dart';

class AccessFailure implements Exception {
  const AccessFailure(this.status);
  final String status;
  @override
  String toString() => 'AccessFailure($status)';
}

class FieldRef {
  const FieldRef(this.itemId, this.fieldId);
  final String itemId;
  final String fieldId;
  Map<String, String> toJson() => {'itemId': itemId, 'fieldId': fieldId};
  @override
  bool operator ==(Object other) =>
      other is FieldRef && other.itemId == itemId && other.fieldId == fieldId;
  @override
  int get hashCode => Object.hash(itemId, fieldId);
}

class RequestReceipt {
  const RequestReceipt(this.id);
  final String id;
}

/// An owner-facing view of a request, without session secrets or grant tokens.
class OwnerRequestSnapshot {
  OwnerRequestSnapshot({
    required this.id,
    required this.state,
    required this.chatLabel,
    required this.purpose,
    required this.createdAt,
    required this.requestExpiresAt,
    required this.remainingSeconds,
    required Iterable<FieldRef> fields,
    required Iterable<FieldRef>? approvedFields,
    required this.grantExpiresAt,
    this.grantLifetime,
    this.sessionId = '',
    this.approvedAt,
    this.historical = false,
    this.applicationClosed = false,
    this.restoredAt,
    this.sessionEnded = false,
    this.decisionPending = false,
    Iterable<RecordedField> recordedFields = const [],
  }) : fields = List.unmodifiable(fields),
       recordedFields = List.unmodifiable(recordedFields),
       approvedFields = approvedFields == null
           ? null
           : List.unmodifiable(approvedFields);

  final String id;
  final AccessRequestState state;
  final String chatLabel;
  final String purpose;
  final DateTime createdAt;
  final DateTime requestExpiresAt;
  final int remainingSeconds;
  final List<FieldRef> fields;
  final List<FieldRef>? approvedFields;
  final DateTime? grantExpiresAt;
  final Duration? grantLifetime;
  final bool sessionEnded, decisionPending;

  /// Public audit identity, never the private session capability.
  final String sessionId;
  final DateTime? approvedAt, restoredAt;
  final bool historical, applicationClosed;

  /// Owner display names captured at request/approval, never old field values.
  final List<RecordedField> recordedFields;
}

class _Request {
  _Request(
    this.id,
    this.session,
    this.purpose,
    this.fields,
    this.createdAt,
    this.expiresAt, {
    this.operationId,
  });
  final String? operationId;
  final String id;
  final String session;
  final String purpose;
  final Set<FieldRef> fields;
  final DateTime createdAt;
  final DateTime expiresAt;
  AccessRequestState state = AccessRequestState.pending;
  ClaimedGrant? grant;
  DateTime? approvedAt;
  GrantHistory? history;
  List<RecordedField> recordedFields = const [];
  bool informationDecisionPending = false;
  bool decisionSessionEnded = false, decisionApplicationClosed = false;
  RequestHistory? deferredDecisionRequest;
  final invalidatedFields = <FieldRef>{};
}

/// In-memory authorization state over an injected information repository.
/// Only the fictional constructor supplies development data.
class InformationService {
  InformationService({
    required InformationRepository repository,
    DateTime Function()? clock,
    CredentialExecutableInspector? credentialExecutableInspector,
    this.focusedFillDriver,
    this.informationDeliveryFiles,
    FocusedFillApplicationInspector? focusedFillApplicationInspector,
  }) : _deviceFileDelivery = false,
       _repository = repository,
       focusedFillApplicationInspector =
           focusedFillApplicationInspector ?? inspectFocusedFillApplication,
       credentialExecutableInspector =
           credentialExecutableInspector ?? inspectCredentialExecutable,
       _clock = clock ?? DateTime.now {
    _recoverAudit();
  }
  InformationService.fictional({DateTime Function()? clock})
    : _deviceFileDelivery = false,
      focusedFillDriver = null,
      informationDeliveryFiles = null,
      focusedFillApplicationInspector = inspectFocusedFillApplication,
      credentialExecutableInspector = inspectCredentialExecutable,
      _clock = clock ?? DateTime.now,
      _repository = MemoryInformationRepository([
        InformationItem(
          'demo-server',
          'Fictional demo server',
          'Fictional connection information for development only',
          1,
          const [
            InformationField(
              'host',
              'Address',
              'Server host name',
              'demo.example.invalid',
              1,
            ),
            InformationField(
              'username',
              'Username',
              'Login name',
              'demo-user',
              1,
            ),
          ],
        ),
      ]);
  // The online runtime reconciles live capabilities before finishing orphaned
  // audit facts. Ordinary local construction retains its historical behavior.
  InformationService._online({
    required InformationRepository repository,
    DateTime Function()? clock,
  }) : _deviceFileDelivery = true,
       _repository = repository,
       _clock = clock ?? DateTime.now,
       focusedFillDriver = null,
       informationDeliveryFiles = null,
       focusedFillApplicationInspector = inspectFocusedFillApplication,
       credentialExecutableInspector = inspectCredentialExecutable;
  final InformationRepository _repository;
  final bool _deviceFileDelivery;
  final CredentialExecutableInspector credentialExecutableInspector;
  final FocusedFillDriver? focusedFillDriver;
  final FocusedFillApplicationInspector focusedFillApplicationInspector;
  final _focusedFillTasks = <String, Future<void>>{};
  final _failedFillAudits = <String>{};
  PreparedFocusedFill? _preparedFocusedFill;
  String? _activeFocusedFill;
  Future<void> drainFocusedFills() async {
    while (_focusedFillTasks.isNotEmpty) {
      await Future.wait(_focusedFillTasks.values.toList());
    }
  }

  final _credentialUseSessions = <String, String>{};
  // Online host only: the original authenticated device for each use request.
  // This private binding is not reconstructed from portable history.
  final _deviceCredentialRequests = <String, String>{};
  final _deviceCredentialExecutions = <String, _DeviceCredentialExecution>{};
  final _executionCapabilities = <String, String>{};
  final _pendingExecutionReceipts = <String, Map<String, Object?>>{};
  late Future<void> _runtimeWrites = Future.value();
  InformationField? _field(FieldRef ref) {
    for (final item in _repository.items) {
      if (item.id == ref.itemId) {
        for (final field in item.fields) {
          if (field.id == ref.fieldId) return field;
        }
      }
    }
    return null;
  }

  final DateTime Function() _clock;
  Duration get _requestLifetime => Duration(
    milliseconds: _repository.readSetting('requestLifetimeMs') ?? 1800000,
  );
  late final agent = AgentAccess._(this);
  late final owner = OwnerAccess._(this);
  final _grants = <String, _Request>{};
  final _sessions = <String, String>{};
  final _endedSessions = <String>{};
  final _endCapabilities = <String, String>{};
  final _sessionBindings = <String, String>{};
  final _requests = <String, _Request>{};
  final _expiredOrganizations = <String>{};
  final _submitted = StreamController<String>.broadcast();
  bool _closed = false;
  InformationTemplateCatalog Function()? _informationTemplates;
  bool _backupBusy = false;
  Completer<void>? _backupBarrier;
  int _libraryGeneration = 0;
  final _reads = <Future<void>>{};
  final _informationDecisionWrites = <Future<void>>{};
  final _uncertainInformationDecisions = <String, _InformationDecision>{};
  final _inactiveCredentialApprovals = <String>{};
  final _uncertainCredentialDecisions = <String, void Function(bool)>{};
  final _onlineCredentialDecisions = <String, InformationApprovalReceipt>{};
  Future<void> _auditWrites = Future.value();
  final _auditPending = <Future<void> Function()>[];
  bool _auditFailed = false;
  AuditRetentionPreview? _retentionPreview;
  Future<void> close() => _close();

  Future<void> _close({bool preserveOnlineAuthorizations = false}) {
    if (_backupBarrier case final barrier?) {
      return barrier.future.then(
        (_) =>
            _close(preserveOnlineAuthorizations: preserveOnlineAuthorizations),
      );
    }
    if (_closed) {
      return Future.wait<void>([
        _drainInformationDecisions(),
        owner._releaseAllInformationFileDrafts(),
        owner._closeInformationFileDeliveries(),
        drainFocusedFills(),
      ]).then((_) {});
    }
    _closed = true;
    for (final request
        in preserveOnlineAuthorizations ? <_Request>[] : _requests.values) {
      _expire(request);
      if (request.state != AccessRequestState.pending &&
          request.state != AccessRequestState.approved) {
        continue;
      }
      _finishHistory(request, GrantEventKind.applicationClosed);
      if (request.state == AccessRequestState.pending) {
        request.state = AccessRequestState.cancelled;
      }
      _recordRequest(request, applicationClosed: true);
    }
    _sessions.clear();
    _endCapabilities.clear();
    _endedSessions.clear();
    _sessionBindings.clear();
    _requests.clear();
    _grants.clear();
    _submitted.close();
    return Future.wait<void>([
      _drainInformationDecisions(),
      owner._releaseAllInformationFileDrafts(),
      owner._closeInformationFileDeliveries(),
      Future<void>.sync(
        () => _preparedFocusedFill?.close(),
      ).catchError((Object _) {}),
      drainFocusedFills(),
    ]).then((_) {});
  }

  final _random = Random.secure();
  final InformationDeliveryFiles? informationDeliveryFiles;
  final _pendingInformationDeliveries = <String, InformationFileDelivery>{};
  bool _informationDeliveryCleanupScheduled = false;
  bool _informationDeliveryCleanupRequested = false;
  bool _informationDeliveryShutdownComplete = false;
  Future<void> _informationDeliveryCleanup = Future.value();
  final _inFlightInformationDeliveries = <String>{};
  String _secret() =>
      base64Url.encode(List.generate(32, (_) => _random.nextInt(256)));

  bool _sessionActive(String session) =>
      !_closed &&
      !_backupBusy &&
      _sessions.containsKey(session) &&
      !_endedSessions.contains(session);

  void _requireSession(String session) {
    if (_backupBusy) throw const AccessFailure('service_unavailable');
    if (!_sessionActive(session)) throw const AccessFailure('unauthorized');
  }

  bool _canRead(
    _Request? request,
    FieldRef field, {
    bool ignoreDecisionBarrier = false,
  }) {
    if (request == null) return false;
    _expire(request);
    return _sessionActive(request.session) &&
        (!request.informationDecisionPending || ignoreDecisionBarrier) &&
        request.state == AccessRequestState.approved &&
        request.grant!.fields.contains(field) &&
        !request.invalidatedFields.contains(field) &&
        _field(field) != null;
  }

  void _endSession(String session) {
    if (_backupBusy) throw const AccessFailure('service_unavailable');
    if (!_sessions.containsKey(session)) {
      throw const AccessFailure('unauthorized');
    }
    if (!_endedSessions.add(session)) return;
    // Latch before audit persistence: every later request/read observes end.
    for (final request in _requests.values.where((r) => r.session == session)) {
      _expire(request);
      if (request.state == AccessRequestState.pending) {
        request.state = AccessRequestState.cancelled;
        _recordRequest(request, sessionEnded: true);
      } else if (request.state == AccessRequestState.approved) {
        request.state = AccessRequestState.revoked;
        _finishHistory(request, GrantEventKind.ended);
        _recordRequest(request, sessionEnded: true);
      }
    }
    _scheduleInformationDeliveryCleanup();
  }

  void _expire(_Request request) {
    if (_backupBusy) return;
    if (request.state == AccessRequestState.pending &&
        !_clock().isBefore(request.expiresAt)) {
      request.state = AccessRequestState.expired;
      _recordRequest(request);
    } else if (request.state == AccessRequestState.approved &&
        !_clock().isBefore(request.grant!.expiresAt)) {
      request.state = AccessRequestState.expired;
      _finishHistory(request, GrantEventKind.expired);
      _recordRequest(request);
      _scheduleInformationDeliveryCleanup();
    }
  }

  // Decisions are synchronous in the core's owning isolate: validation and
  // transition cannot interleave, so the first terminal decision wins.
  void _finishPending(_Request request, AccessRequestState state) {
    _expire(request);
    if (request.state != AccessRequestState.pending) {
      throw const AccessFailure('invalid_request');
    }
    request.state = state;
    _recordRequest(request);
  }
}

class AgentAccess {
  AgentAccess._(this._service);
  final InformationService _service;
  String openSession(String chatLabel) {
    return openSessionWithEndCapability(chatLabel).sessionSecret;
  }

  /// Both independent capabilities are issued only for a new unapproved session.
  /// Adapters must keep the end capability out of ordinary command output.
  OpenedSession openSessionWithEndCapability(String chatLabel) {
    if (_service._closed || _service._backupBusy) {
      throw const AccessFailure('service_unavailable');
    }
    if (chatLabel.trim().isEmpty || chatLabel.length > 200) {
      throw const AccessFailure('invalid_request');
    }
    final secret = _service._secret();
    _service._sessions[secret] = chatLabel;
    _service._sessionBindings[secret] = _service._secret();
    final endCapability = _service._secret();
    _service._endCapabilities[endCapability] = secret;
    return OpenedSession(secret, endCapability);
  }

  void validateSession(String session) => _service._requireSession(session);

  void endSession(String session) => _service._endSession(session);

  /// This credential can only end its session, never recover read capability.
  void endSessionWithCapability(String capability) {
    final session = _service._endCapabilities[capability];
    if (session == null) throw const AccessFailure('unauthorized');
    _service._endSession(session);
  }

  RequestReceipt request(
    String session,
    String purpose,
    List<FieldRef> fields, {
    String? operationId,
  }) {
    _service._requireSession(session);
    if (purpose.trim().isEmpty ||
        purpose.length > 2000 ||
        fields.isEmpty ||
        fields.length > 200) {
      throw const AccessFailure('invalid_request');
    }
    if (operationId != null) {
      final original = _findRequestOperation(session, operationId);
      if (original != null) {
        if (original.purpose != purpose ||
            original.fields.length != fields.toSet().length ||
            !original.fields.containsAll(fields)) {
          throw const AccessFailure('operation_conflict');
        }
        // The original request survives edits/deletion and terminal decisions.
        // Never revalidate it as a new intent or extend its fixed deadline.
        _service._expire(original);
        return RequestReceipt(original.id);
      }
    }
    if (fields.any((f) => _service._field(f) == null)) {
      throw const AccessFailure('invalid_request');
    }
    final id = _service._secret();
    final now = _service._clock();
    _service._requests[id] =
        _Request(
            id,
            session,
            purpose,
            Set.unmodifiable(fields),
            now,
            now.add(_service._requestLifetime),
            operationId: operationId,
          )
          ..recordedFields = fields.toSet().map((ref) {
            final item = _service._repository.items.firstWhere(
              (i) => i.id == ref.itemId,
            );
            final field = item.fields.firstWhere((f) => f.id == ref.fieldId);
            return RecordedField(item.id, field.id, item.name, field.name);
          }).toList();
    _service._submitted.add(id);
    return RequestReceipt(id);
  }

  _Request? _findRequestOperation(String session, String operationId) {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(operationId)) {
      throw const AccessFailure('invalid_request');
    }
    for (final request in _service._requests.values) {
      if (request.session == session && request.operationId == operationId) {
        return request;
      }
    }
    return null;
  }

  /// Query only; not_found is a snapshot, not proof an in-flight submit cannot
  /// arrive later. Private session authentication is required even for absence.
  Map<String, Object?> requestOperationStatus(
    String session,
    String operationId,
  ) {
    _service._requireSession(session);
    final request = _findRequestOperation(session, operationId);
    return {
      if (request == null)
        'status': 'not_found'
      else
        ...status(session, request.id),
      'operationId': operationId,
    };
  }

  _Request _request(String session, String id) {
    if (_service._backupBusy) throw const AccessFailure('service_unavailable');
    final request = _service._requests[id];
    if (!_service._sessionActive(session) ||
        request == null ||
        request.session != session) {
      throw const AccessFailure('unauthorized');
    }
    _service._expire(request);
    return request;
  }

  Map<String, Object?> status(String session, String id) {
    if (_service._credentialUseSessions.containsKey(id)) {
      return credentialUseStatus(session, id);
    }
    final request = _request(session, id);
    return {
      'status': request.state.name,
      'requestId': id,
      'createdAt': request.createdAt.toUtc().toIso8601String(),
      'requestExpiresAt': request.expiresAt.toUtc().toIso8601String(),
    };
  }

  void cancel(String session, String id) {
    _service._finishPending(
      _request(session, id),
      AccessRequestState.cancelled,
    );
  }

  ClaimedGrant claim(String session, String id) {
    if (_service._credentialUseSessions.containsKey(id) &&
        _service._sessionUseRequest(session, id).approvedFields.isEmpty) {
      throw const CredentialUseFailure('scope_not_approved');
    }
    final request = _request(session, id);
    if (request.informationDecisionPending) {
      throw const AccessFailure('decision_unknown');
    }
    if (request.grant == null) throw AccessFailure(request.state.name);
    if (request.state != AccessRequestState.approved) {
      throw const AccessFailure('unauthorized');
    }
    return request.grant!;
  }

  Future<String> read(String token, FieldRef field) {
    final reading = _service._readWithAudit(_service._grants[token], field);
    final settled = reading.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _service._reads.add(settled);
    settled.then((_) => _service._reads.remove(settled));
    return reading;
  }

  /// Complete metadata for internal capability checks. Transport discovery is
  /// paginated by searchCatalog; protocol checks must not stop at its first page.
  List<Map<String, Object?>> catalog() {
    if (_service._closed || _service._backupBusy) {
      throw const AccessFailure('service_unavailable');
    }
    return _catalogMetadata();
  }

  List<Map<String, Object?>> _catalogMetadata() {
    final tags = {
      for (final tag in _service._repository.tags) tag.id: tag.name,
    };
    return _service._repository.items
        .map(
          (item) => <String, Object?>{
            'id': item.id,
            'version': item.version,
            'name': item.name,
            'description': item.description,
            'typeId': item.layout?.typeId ?? 'generic',
            'directoryId': item.directoryId,
            'tagIds': item.tagIds,
            'tags': [
              for (final id in item.tagIds)
                if (tags.containsKey(id)) {'id': id, 'name': tags[id]!},
            ],
            'fields': item.fields
                .map(
                  (field) => {
                    'id': field.id,
                    'name': field.name,
                    'description': field.description,
                    'kind': field.kind.name,
                  },
                )
                .toList(),
          },
        )
        .toList();
  }
}

class OpenedSession {
  const OpenedSession(this.sessionSecret, this.endCapability);
  final String sessionSecret;
  final String endCapability;
}

class ClaimedGrant {
  ClaimedGrant(this.token, List<FieldRef> fields, this.expiresAt)
    : fields = List.unmodifiable(fields);
  final String token;
  final DateTime expiresAt;
  final List<FieldRef> fields;
}

/// Kept inside the desktop process. Never exposed by the agent transport.
/// An owner UI binding to one service and one successfully restored library.
/// This is not an Agent capability and is never serialized or exported.
class OwnerLibraryScope {
  OwnerLibraryScope._(this._service, this._generation);
  final InformationService _service;
  final int _generation;
  bool get isCurrent =>
      !_service._closed && _generation == _service._libraryGeneration;
}

final _ownerLibraryScopeZoneKey = Object();

class OwnerAccess {
  OwnerAccess._(this._service);
  final InformationService _service;
  OwnerLibraryScope captureLibraryScope() =>
      OwnerLibraryScope._(_service, _service._libraryGeneration);

  /// Keep the shared owner write queue while binding an asynchronous form
  /// operation to its original library. A replacement during an await also
  /// invalidates the result; callers must not render it in the new library.
  Future<T> inLibraryScope<T>(
    OwnerLibraryScope scope,
    Future<T> Function() action,
  ) async {
    void check() {
      if (!identical(scope._service, _service) || !scope.isCurrent) {
        throw const AccessFailure('library_changed');
      }
    }

    check();
    final result = await runZoned(
      action,
      zoneValues: {_ownerLibraryScopeZoneKey: scope},
    );
    check();
    return result;
  }

  final _informationFileDrafts = <String, InformationFileDraft>{};
  Stream<String> get requestSubmitted => _service._submitted.stream;
  Duration get requestLifetime => _service._requestLifetime;
  Future<void> setRequestLifetime(Duration duration) {
    if (duration < const Duration(minutes: 1) ||
        duration > const Duration(days: 7)) {
      throw const AccessFailure('invalid_request');
    }
    return _serialize(
      () => _service._repository.writeSetting(
        'requestLifetimeMs',
        duration.inMilliseconds,
      ),
    );
  }

  List<InformationItem> get information => _service._repository.items;
  List<InformationTemplate> get templates => _service._repository.templates;
  Future<void> deleteTemplate(String id, int expectedVersion) =>
      _serialize(() async {
        if (!serviceAvailable) throw const AccessFailure('service_unavailable');
        final current = templates.where((t) => t.id == id).firstOrNull;
        if (current == null || current.version != expectedVersion) {
          throw const AccessFailure('template_changed');
        }
        await _service._repository.deleteTemplate(id);
      });

  Future<InformationTemplate> createTemplate(
    String name,
    String description,
    List<TemplateFieldInput> fields,
  ) => _serialize(() async {
    if (_service._closed) throw const AccessFailure('service_unavailable');
    _validateTemplate(name, description, fields);
    final template = InformationTemplate(
      _service._secret(),
      name.trim(),
      description,
      1,
      fields.map(
        (f) => TemplateFieldDefinition(
          _service._secret(),
          f.name.trim(),
          f.description,
          f.kind,
        ),
      ),
    );
    await _service._repository.saveTemplate(template);
    return template;
  });

  void _validateTemplate(
    String name,
    String description,
    List<TemplateFieldInput> fields,
  ) {
    if (name.trim().isEmpty ||
        name.length > 200 ||
        description.length > 2000 ||
        fields.isEmpty ||
        fields.length > 200 ||
        fields.any(
          (f) =>
              f.name.trim().isEmpty ||
              f.name.length > 200 ||
              f.description.length > 2000,
        )) {
      throw const AccessFailure('invalid_template');
    }
  }

  /// Template edits affect future forms only. A changed definition receives a
  /// new ID, even when the caller supplies the previous definition's identity.
  Future<InformationTemplate> updateTemplate(
    String id,
    int expectedVersion,
    String name,
    String description,
    List<TemplateFieldInput> fields,
  ) => _serialize(() async {
    if (_service._closed) throw const AccessFailure('service_unavailable');
    _validateTemplate(name, description, fields);
    final matches = templates.where((t) => t.id == id);
    if (matches.isEmpty || matches.single.version != expectedVersion) {
      throw const AccessFailure('template_changed');
    }
    final previous = matches.single;
    final suppliedIds = fields
        .map((f) => f.definitionId)
        .whereType<String>()
        .toList();
    if (suppliedIds.toSet().length != suppliedIds.length ||
        suppliedIds.any((id) => !previous.fields.any((f) => f.id == id))) {
      throw const AccessFailure('invalid_template');
    }
    final template = InformationTemplate(
      id,
      name.trim(),
      description,
      previous.version + 1,
      fields.map((input) {
        final old = previous.fields.where((f) => f.id == input.definitionId);
        final unchanged =
            old.isNotEmpty &&
            old.single.name == input.name.trim() &&
            old.single.description == input.description &&
            old.single.kind == input.kind;
        return TemplateFieldDefinition(
          unchanged ? old.single.id : _service._secret(),
          input.name.trim(),
          input.description,
          input.kind,
        );
      }),
    );
    await _service._repository.saveTemplate(template);
    return template;
  });

  Future<InformationItem> createInformationFromTemplate(
    String templateId,
    int templateVersion,
    String name,
    String description,
    Map<String, String> values, {
    String? directoryId,
    Iterable<String> tagIds = const [],
  }) => _serialize(() async {
    final matches = templates.where((t) => t.id == templateId);
    if (matches.isEmpty || matches.single.version != templateVersion) {
      throw const AccessFailure('template_changed');
    }
    final template = matches.single;
    if (template.fields.any((f) => f.kind == FieldKind.file)) {
      throw const AccessFailure('attachment_missing');
    }
    if (values.length != template.fields.length ||
        template.fields.any((f) => !values.containsKey(f.id))) {
      throw const AccessFailure('invalid_information');
    }
    return _createInformation(
      name,
      description,
      template.fields
          .map(
            (f) =>
                FieldInput(f.name, f.description, values[f.id]!, kind: f.kind),
          )
          .toList(),
      directoryId: directoryId,
      tagIds: tagIds,
    );
  });
  Future<void> _writes = Future.value();
  Future<T> _serialize<T>(Future<T> Function() action) {
    final scope = Zone.current[_ownerLibraryScopeZoneKey] as OwnerLibraryScope?;
    final proposal = pendingOwnerProposalOperation;
    final approval = pendingAdditionalApproval;
    final generation = scope?._generation ?? _service._libraryGeneration;
    final result = _writes.then((_) async {
      if (generation != _service._libraryGeneration ||
          scope != null && !identical(scope._service, _service)) {
        throw const AccessFailure('library_changed');
      }
      if (proposal != null) await proposal._before(this);
      if (approval != null) await approval.before(this);
      return action();
    });
    _writes = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<InformationItem> createInformation(
    String name,
    String description,
    List<FieldInput> fields, {
    String? directoryId,
    Iterable<String> tagIds = const [],
  }) => _serialize(
    () => _createInformation(
      name,
      description,
      fields,
      directoryId: directoryId,
      tagIds: tagIds,
    ),
  );

  Future<InformationItem> _createInformation(
    String name,
    String description,
    List<FieldInput> fields, {
    String? directoryId,
    Iterable<String> tagIds = const [],
  }) async {
    if (_service._closed) throw const AccessFailure('service_unavailable');
    if (fields.any((f) => f.kind == FieldKind.file)) {
      throw const AccessFailure('unsupported_file_write');
    }
    _checkParent(directoryId);
    final selectedTags = tagIds.toSet();
    if (selectedTags.length > 100 ||
        selectedTags.any((id) => !tags.any((t) => t.id == id))) {
      throw const AccessFailure('invalid_information');
    }
    if (name.trim().isEmpty ||
        name.length > 200 ||
        description.length > 2000 ||
        fields.isEmpty ||
        fields.length > 200 ||
        fields.any(
          (f) =>
              f.name.trim().isEmpty ||
              f.name.length > 200 ||
              f.description.length > 2000 ||
              f.value.length > 1000000,
        )) {
      throw const AccessFailure('invalid_information');
    }
    final now = _service._clock();
    final item = InformationItem(
      _service._secret(),
      name.trim(),
      description,
      1,
      fields
          .map(
            (f) => InformationField(
              _service._secret(),
              f.name.trim(),
              f.description,
              f.value,
              1,
              kind: f.kind,
            ),
          )
          .toList(),
      createdAt: now,
      modifiedAt: now,
      directoryId: directoryId,
      tagIds: selectedTags,
    );
    await _service._repository.save(item);
    return item;
  }

  /// Ordinary value correction preserves meaning and identity. Semantic replacement
  /// will be a separate operation; it must never reuse an already authorized ID.
  Future<InformationItem> correctValue(FieldRef ref, String value) =>
      _serialize(() async {
        if (_service._closed) throw const AccessFailure('service_unavailable');
        if (value.length > 1000000 || _service._field(ref) == null) {
          throw const AccessFailure('invalid_information');
        }
        final previous = information.firstWhere((i) => i.id == ref.itemId);
        final item = InformationItem(
          previous.id,
          previous.name,
          previous.description,
          previous.version + 1,
          previous.fields
              .map((f) => f.id == ref.fieldId ? f.correctValue(value) : f)
              .toList(),
          directoryId: previous.directoryId,
          tagIds: previous.tagIds,
          layout: previous.layout,
          createdAt: previous.createdAt,
          modifiedAt: _service._clock(),
        );
        await _service._repository.saveInformationRevision(
          item,
          InformationRevision(previous, _service._clock()),
        );
        return item;
      });
  List<OwnerRequestSnapshot> get requests => _service._requests.values.map((r) {
    _service._expire(r);
    return OwnerRequestSnapshot(
      id: r.id,
      state: r.state,
      chatLabel: _service._sessions[r.session]!,
      sessionId: _service._sessionBindings[r.session]!,
      approvedAt: r.approvedAt,
      purpose: r.purpose,
      createdAt: r.createdAt,
      requestExpiresAt: r.expiresAt,
      remainingSeconds: max(
        0,
        r.expiresAt.difference(_service._clock()).inSeconds,
      ),
      fields: r.fields,
      approvedFields: r.grant?.fields,
      grantExpiresAt: r.grant?.expiresAt,
      grantLifetime: r.approvedAt == null
          ? null
          : r.grant?.expiresAt.difference(r.approvedAt!),
      sessionEnded: _service._endedSessions.contains(r.session),
      decisionPending: r.informationDecisionPending,
      recordedFields: {
        for (final field in r.recordedFields)
          FieldRef(field.itemId, field.fieldId): field,
        for (final field in r.history?.fields ?? const <RecordedField>[])
          FieldRef(field.itemId, field.fieldId): field,
      }.values,
    );
  }).toList();
  void revoke(String requestId) {
    if (_service._backupBusy) throw const AccessFailure('service_unavailable');
    final request = _service._requests[requestId];
    if (request?.informationDecisionPending ?? false) {
      throw const AccessFailure('decision_unknown');
    }
    if (request?.grant == null) throw const AccessFailure('invalid_request');
    request!.state = AccessRequestState.revoked;
    _service._finishHistory(request, GrantEventKind.revoked);
    _service._recordRequest(request);
    _service._scheduleInformationDeliveryCleanup();
  }

  void deny(String requestId) {
    if (_service._backupBusy) throw const AccessFailure('service_unavailable');
    final request = _service._requests[requestId];
    if (request?.informationDecisionPending ?? false) {
      throw const AccessFailure('decision_unknown');
    }
    if (request == null) throw const AccessFailure('invalid_request');
    _service._finishPending(request, AccessRequestState.denied);
  }

  void approve(
    String requestId,
    List<FieldRef> fields, {
    Duration lifetime = const Duration(hours: 8),
    Map<FieldRef, int>? reviewedVersions,
  }) {
    if (_service._backupBusy) throw const AccessFailure('service_unavailable');
    final request = _service._requests[requestId];
    if (request?.informationDecisionPending ?? false) {
      throw const AccessFailure('decision_unknown');
    }
    if (request != null) _service._expire(request);
    if (request == null ||
        !_service._sessionActive(request.session) ||
        request.state != AccessRequestState.pending ||
        request.grant != null) {
      throw const AccessFailure('invalid_request');
    }
    if (fields.isEmpty ||
        fields.length > 200 ||
        fields.any((f) => _service._field(f) == null)) {
      throw const AccessFailure('invalid_scope');
    }
    if (reviewedVersions != null &&
        (reviewedVersions.length != fields.toSet().length ||
            fields.any(
              (ref) => reviewedVersions[ref] != _service._field(ref)!.version,
            ))) {
      // Check the displayed field revision immediately before creating a grant.
      // Later reads still follow the approved stable field's current content.
      throw const AccessFailure('scope_changed');
    }
    if (lifetime < const Duration(minutes: 1) ||
        lifetime > const Duration(days: 7)) {
      throw const AccessFailure('invalid_duration');
    }
    final approvedAt = _service._clock();
    request.approvedAt = approvedAt;
    request.grant = ClaimedGrant(
      _service._secret(),
      fields.toSet().toList(),
      approvedAt.add(lifetime),
    );
    _service._grants[request.grant!.token] = request;
    request.state = AccessRequestState.approved;
    _service._approveHistory(request);
    _service._recordRequest(request);
  }
}
