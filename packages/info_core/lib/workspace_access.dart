part of 'info_core.dart';

enum InboxFilter { all, pending, handled }

enum DesktopColorTheme { purple, green, blue, mono }

extension OwnerDesktopPreferences on OwnerAccess {
  bool get notificationsEnabled =>
      _service._repository.readSetting('desktopNotificationsEnabled') != 0;
  Future<void> setNotificationsEnabled(bool enabled) => _serialize(() async {
    if (!serviceAvailable) throw const AccessFailure('service_unavailable');
    await _service._repository.writeSetting(
      'desktopNotificationsEnabled',
      enabled ? 1 : 0,
    );
  });
  DesktopColorTheme get colorTheme {
    final value = _service._repository.readSetting('desktopColorTheme') ?? 0;
    return value >= 0 && value < DesktopColorTheme.values.length
        ? DesktopColorTheme.values[value]
        : DesktopColorTheme.purple;
  }

  Future<void> setColorTheme(DesktopColorTheme theme) => _serialize(() async {
    if (!serviceAvailable) throw const AccessFailure('service_unavailable');
    await _service._repository.writeSetting('desktopColorTheme', theme.index);
  });
}

/// Owner-only request identity and display state. Never sent to AgentAccess.
class InboxEntry {
  InboxEntry.access(this.access)
    : credentialUse = null,
      credentialUseState = null,
      organization = null,
      organizationState = null,
      organizationRemainingSeconds = 0;
  InboxEntry.organization(
    this.organization,
    this.organizationState, {
    this.organizationRemainingSeconds = 0,
  }) : access = null,credentialUse=null,credentialUseState=null;
  InboxEntry.credential(this.credentialUse,this.credentialUseState):access=null,organization=null,organizationState=null,organizationRemainingSeconds=0;
  final CredentialUseRequest? credentialUse;
  final String? credentialUseState;
  final OwnerRequestSnapshot? access;
  final OrganizationTask? organization;
  final OrganizationTaskState? organizationState;
  final int organizationRemainingSeconds;
  String get id => access?.id ?? credentialUse?.id ?? organization!.id;
  String get chatLabel => access?.chatLabel ?? credentialUse?.chatLabel ?? organization!.chatLabel;
  String get purpose => access?.purpose ?? credentialUse?.purpose ?? organization!.purpose;
  DateTime get createdAt => access?.createdAt ?? credentialUse?.createdAt ?? organization!.createdAt;
  bool get pending =>
      access?.state == AccessRequestState.pending ||
      credentialUseState == 'pending' ||
      organizationState == OrganizationTaskState.pending;
}

class InboxPage {
  InboxPage(
    Iterable<InboxEntry> entries, {
    required this.total,
    required this.pendingCount,
    required this.offset,
    required this.limit,
  }) : entries = List.unmodifiable(entries);
  final List<InboxEntry> entries;
  final int total, pendingCount, offset, limit;
}

extension OwnerInbox on OwnerAccess {
  bool get serviceAvailable => !_service._closed && !_service._backupBusy;

  /// Bounded results over the repository's current snapshot. Ordering is newest
  /// first, then opaque ID, independent of Map/repository insertion order.
  InboxPage queryInbox({
    String search = '',
    InboxFilter filter = InboxFilter.all,
    int offset = 0,
    int limit = 20,
    String? focusRequestId,
  }) {
    if (!serviceAvailable) throw const AccessFailure('service_unavailable');
    if (offset < 0 || limit < 1 || limit > 100 || search.length > 2000) {
      throw const AccessFailure('invalid_query');
    }
    final needle = search.trim().toLowerCase();
    final names = {for (final item in information) item.id: item.name};
    final matching =
        <InboxEntry>[
          for (final request in requests) if(!_service._credentialUseSessions.containsKey(request.id)) InboxEntry.access(request),
          if(_service._repository is CredentialRuntimeRepository)
            for(final request in credentialUseRequests) InboxEntry.credential(request,credentialUseState(request)),
          for (final task in organizationTasks)
            InboxEntry.organization(
              task,
              organizationState(task),
              organizationRemainingSeconds: max(
                0,
                task.expiresAt.difference(_service._clock()).inSeconds,
              ),
            ),
        ].where((entry) {
          if (needle.isEmpty) return true;
          final itemIds =
              entry.access?.fields.map((f) => f.itemId) ??
              entry.credentialUse?.fields.map((f)=>f.itemId) ??
              entry.organization!.itemVersions.keys;
          return [
            entry.id,
            entry.chatLabel,
            entry.purpose,
            ...itemIds.map((id) => names[id] ?? ''),
          ].any((text) => text.toLowerCase().contains(needle));
        }).toList();
    final pending = matching.where((e) => e.pending).length;
    final filtered =
        matching
            .where(
              (e) => switch (filter) {
                InboxFilter.all => true,
                InboxFilter.pending => e.pending,
                InboxFilter.handled => !e.pending,
              },
            )
            .toList()
          ..sort((a, b) {
            final time = b.createdAt.compareTo(a.createdAt);
            return time == 0 ? a.id.compareTo(b.id) : time;
          });
    if (focusRequestId != null) {
      final index = filtered.indexWhere((e) => e.id == focusRequestId);
      if (index >= 0) offset = (index ~/ limit) * limit;
    }
    final effective = filtered.isEmpty
        ? 0
        : min(offset, ((filtered.length - 1) ~/ limit) * limit);
    return InboxPage(
      filtered.skip(effective).take(limit),
      total: filtered.length,
      pendingCount: pending,
      offset: effective,
      limit: limit,
    );
  }
}
