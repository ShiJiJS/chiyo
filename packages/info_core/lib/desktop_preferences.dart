part of 'info_core.dart';

/// Owner-only preferences. These contain no capability or personal content.
class DesktopPreferences {
  const DesktopPreferences({
    required this.version,
    required this.dark,
    required this.notifications,
    required this.requestMinutes,
    required this.retentionDays,
    required this.background,
  });
  final int version, requestMinutes, retentionDays;
  final bool dark, notifications, background;
  Map<String, int> get settings => {
    'desktopPreferencesVersion': version,
    'desktopDarkAppearance': dark ? 1 : 0,
    'desktopNotificationsEnabled': notifications ? 1 : 0,
    'requestLifetimeMs': requestMinutes * 60000,
    'auditRetentionDays': retentionDays,
    'desktopBackground': background ? 1 : 0,
  };
  factory DesktopPreferences.fromSettings(Map<String, int> values) =>
      DesktopPreferences(
        version: values['desktopPreferencesVersion']!,
        dark: values['desktopDarkAppearance'] == 1,
        notifications: values['desktopNotificationsEnabled'] == 1,
        requestMinutes: values['requestLifetimeMs']! ~/ 60000,
        retentionDays: values['auditRetentionDays']!,
        background: values['desktopBackground'] == 1,
      );
}

class DesktopPreferencesReceipt {
  const DesktopPreferencesReceipt(
    this.operationId,
    this.commandDigest,
    this.expectedVersion,
    this.preferences,
  );
  final String operationId, commandDigest;
  final int expectedVersion;
  final DesktopPreferences preferences;
  Map<String, Object?> toJson() => {
    'operationId': operationId,
    'commandDigest': commandDigest,
    'expectedVersion': expectedVersion,
    'settings': preferences.settings,
  };
  factory DesktopPreferencesReceipt.fromJson(Map<String, dynamic> json) =>
      DesktopPreferencesReceipt(
        json['operationId'] as String,
        json['commandDigest'] as String,
        json['expectedVersion'] as int,
        DesktopPreferences.fromSettings(
          Map<String, int>.from(json['settings'] as Map),
        ),
      );
}

/// Exact metadata IDs approved for pruning, including ended credential work.
class DesktopHistoryCleanup {
  DesktopHistoryCleanup({
    Set<String> requests = const {},
    Set<String> grants = const {},
    Set<String> accesses = const {},
    Set<String> organizations = const {},
    Set<String> credentials = const {},
    Set<String> executions = const {},
    Set<String> fills = const {},
  }) : tables = Map.unmodifiable({
         'request_history': Set<String>.unmodifiable(requests),
         'grant_history': Set<String>.unmodifiable(grants),
         'access_records': Set<String>.unmodifiable(accesses),
         'organization_tasks': Set<String>.unmodifiable(organizations),
         'credential_operations': Set<String>.unmodifiable(executions),
         'credential_focused_fills': Set<String>.unmodifiable(fills),
         'credential_runtime_requests': Set<String>.unmodifiable(credentials),
       });
  final Map<String, Set<String>> tables;
  String get signature => jsonEncode({
    for (final e in tables.entries) e.key: e.value.toList()..sort(),
  });
  int get requests =>
      tables['request_history']!.length +
      tables['credential_runtime_requests']!.length;
  int get grants => tables['grant_history']!.length;
  int get operations =>
      tables['access_records']!.length +
      tables['organization_tasks']!.length +
      tables['credential_operations']!.length +
      tables['credential_focused_fills']!.length;
}

class DesktopRetentionPlan {
  DesktopRetentionPlan._(
    this.token,
    this.days,
    this.cutoff,
    this.version,
    this.cleanup,
    this.preserved,
    this._owner,
  ) : _generation = _owner._service._libraryGeneration;
  final OwnerAccess _owner;
  final int _generation;
  final String token;
  final int days, version, preserved;
  final DateTime cutoff;
  final DesktopHistoryCleanup cleanup;
}

abstract interface class DesktopPreferencesRepository {
  Future<DesktopPreferencesReceipt?> desktopPreferencesReceipt(
    String operationId,
  );
  Future<void> commitDesktopPreferences(
    DesktopPreferencesReceipt receipt,
    DesktopHistoryCleanup cleanup, {
    required void Function() validate,
  });
}

extension OwnerPersistentDesktopPreferences on OwnerAccess {
  DesktopPreferences get desktopPreferences {
    if (!serviceAvailable) throw const AccessFailure('service_unavailable');
    final repo = _service._repository;
    return DesktopPreferences(
      version: repo.readSetting('desktopPreferencesVersion') ?? 1,
      dark: repo.readSetting('desktopDarkAppearance') == 1,
      notifications: notificationsEnabled,
      requestMinutes: requestLifetime.inMinutes,
      retentionDays: auditRetentionDays,
      background: repo.readSetting('desktopBackground') != 0,
    );
  }

  DesktopPreferencesRepository get _desktopRepository =>
      _service._repository is DesktopPreferencesRepository
      ? _service._repository as DesktopPreferencesRepository
      : throw const AccessFailure('unsupported_capability');
  DesktopHistoryCleanup _desktopCleanup(DateTime cutoff) {
    final repo = _service._repository;
    final credentialIds = _service._credentialHistoryPruneIds(cutoff);
    final runtime = repo is CredentialRuntimeRepository
        ? repo as CredentialRuntimeRepository
        : null;
    return DesktopHistoryCleanup(
      requests: {
        for (final r in repo.requestHistory)
          if (r.createdAt.isBefore(cutoff) &&
              r.state != AccessRequestState.pending &&
              (r.state != AccessRequestState.approved ||
                  !repo.grantHistory.any(
                    (g) => g.requestId == r.id && g.active,
                  )))
            r.id,
      },
      grants: {
        for (final g in repo.grantHistory)
          if (g.approvedAt.isBefore(cutoff) && !g.active) g.id,
      },
      accesses: {
        for (final a in repo.accessRecords)
          if (a.at.isBefore(cutoff)) a.id,
      },
      organizations: {
        for (final t in repo.organizationTasks)
          if (_service._endedOrganization(t) &&
              (t.approvedAt ?? t.createdAt).isBefore(cutoff))
            t.id,
      },
      credentials: credentialIds,
      executions: {
        for (final e
            in runtime?.credentialExecutions ?? <CredentialExecution>[])
          if (credentialIds.contains(e.requestId)) e.id,
      },
      fills: {
        if (repo is FocusedFillRuntimeRepository)
          for (final f
              in (repo as FocusedFillRuntimeRepository).focusedFillOperations)
            if (credentialIds.contains(f.requestId)) f.id,
      },
    );
  }

  Future<DesktopRetentionPlan> previewDesktopRetention(int days) =>
      _serialize(() async {
        final preferences = desktopPreferences;
        if (![30, 90, 180, 365].contains(days) ||
            days >= preferences.retentionDays) {
          throw const AccessFailure('invalid_retention');
        }
        await history();
        final cutoff = _service._clock().subtract(Duration(days: days));
        final cleanup = _desktopCleanup(cutoff);
        final repo = _service._repository;
        final total =
            repo.requestHistory.length +
            repo.grantHistory.length +
            repo.accessRecords.length +
            repo.organizationTasks.length +
            (repo is CredentialRuntimeRepository
                ? (repo as CredentialRuntimeRepository)
                          .credentialUseRequests
                          .length +
                      (repo as CredentialRuntimeRepository)
                          .credentialExecutions
                          .length
                : 0) +
            (repo is FocusedFillRuntimeRepository
                ? (repo as FocusedFillRuntimeRepository)
                      .focusedFillOperations
                      .length
                : 0);
        return DesktopRetentionPlan._(
          _service._secret(),
          days,
          cutoff,
          preferences.version,
          cleanup,
          total - cleanup.requests - cleanup.grants - cleanup.operations,
          this,
        );
      });
  Future<DesktopPreferencesReceipt?> desktopPreferencesReceipt(
    String operationId,
  ) => _serialize(() async {
    if (!serviceAvailable) throw const AccessFailure('service_unavailable');
    return _desktopRepository.desktopPreferencesReceipt(operationId);
  });
  Future<DesktopPreferencesReceipt> saveDesktopPreferences({
    required String operationId,
    required String commandDigest,
    required int expectedVersion,
    required DesktopPreferences desired,
    DesktopRetentionPlan? retention,
  }) => _serialize(() async {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,199}$').hasMatch(operationId) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(commandDigest) ||
        desired.requestMinutes < 1 ||
        desired.requestMinutes > 10080 ||
        ![30, 90, 180, 365].contains(desired.retentionDays) ||
        desired.version != expectedVersion + 1) {
      throw const AccessFailure('invalid_preferences');
    }
    final previous = await _desktopRepository.desktopPreferencesReceipt(
      operationId,
    );
    if (previous != null) {
      if (previous.commandDigest != commandDigest ||
          previous.expectedVersion != expectedVersion ||
          jsonEncode(previous.preferences.settings) !=
              jsonEncode(desired.settings)) {
        throw const AccessFailure('operation_conflict');
      }
      return previous;
    }
    // Drain audit recovery before holding its runtime queue (no lock cycle).
    await history();
    return _service._serializeRuntimeWrite(() async {
      final current = desktopPreferences;
      final shrinking = desired.retentionDays < current.retentionDays;
      void validate() {
        if (!serviceAvailable) throw const AccessFailure('service_unavailable');
        if (desktopPreferences.version != expectedVersion) {
          throw const AccessFailure('conflict');
        }
        // Imported/older libraries can contain another valid duration. Keep
        // it when changing unrelated settings; only new duration choices use
        // the existing presets. Exact old receipts still replay unchanged.
        if (!AccessTiming.waitingMinutes.contains(desired.requestMinutes) &&
            desired.requestMinutes != desktopPreferences.requestMinutes) {
          throw const AccessFailure('invalid_preferences');
        }
        if (shrinking &&
            (retention == null ||
                !identical(retention._owner, this) ||
                retention._generation != _service._libraryGeneration ||
                retention.version != expectedVersion ||
                retention.days != desired.retentionDays ||
                retention.cleanup.signature !=
                    _desktopCleanup(retention.cutoff).signature)) {
          throw const AccessFailure('retention_changed');
        }
        if (!shrinking && retention != null) {
          throw const AccessFailure('invalid_retention');
        }
      }

      validate();
      final receipt = DesktopPreferencesReceipt(
        operationId,
        commandDigest,
        expectedVersion,
        desired,
      );
      await _desktopRepository.commitDesktopPreferences(
        receipt,
        retention?.cleanup ?? DesktopHistoryCleanup(),
        validate: validate,
      );
      return receipt;
    });
  });
}
