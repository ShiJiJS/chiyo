import 'dart:convert';
import 'package:crypto/crypto.dart';

enum WorkspaceTheme { light, dark }

class WorkspacePreferences {
  const WorkspacePreferences({
    this.version = 1,
    this.theme = WorkspaceTheme.light,
    this.notifications = true,
    this.requestMinutes = 30,
    this.retentionDays = 180,
    this.background = true,
  });
  final int version, requestMinutes, retentionDays;
  final WorkspaceTheme theme;
  final bool notifications, background;
  WorkspacePreferences copyWith({
    int? version,
    WorkspaceTheme? theme,
    bool? notifications,
    int? requestMinutes,
    int? retentionDays,
    bool? background,
  }) => WorkspacePreferences(
    version: version ?? this.version,
    theme: theme ?? this.theme,
    notifications: notifications ?? this.notifications,
    requestMinutes: requestMinutes ?? this.requestMinutes,
    retentionDays: retentionDays ?? this.retentionDays,
    background: background ?? this.background,
  );
  Map<String, Object?> get values => {
    'theme': theme.name,
    'notifications': notifications,
    'requestMinutes': requestMinutes,
    'retentionDays': retentionDays,
    'background': background,
  };
  bool sameValues(WorkspacePreferences other) =>
      jsonEncode(values) == jsonEncode(other.values);
}

class WorkspaceSettingsChange {
  const WorkspaceSettingsChange({
    required this.operationId,
    required this.expectedVersion,
    required this.desired,
    this.retentionToken,
  });
  final String operationId;
  final int expectedVersion;
  final WorkspacePreferences desired;
  final String? retentionToken;
  String get digest => sha256
      .convert(
        utf8.encode(
          jsonEncode({
            'operation': operationId,
            'version': expectedVersion,
            'values': desired.values,
            'retentionToken': retentionToken,
          }),
        ),
      )
      .toString();
}

class WorkspaceSettingsReceipt {
  const WorkspaceSettingsReceipt({
    required this.operationId,
    required this.expectedVersion,
    required this.commandDigest,
    required this.preferences,
  });
  final String operationId, commandDigest;
  final int expectedVersion;
  final WorkspacePreferences preferences;
}

/// Exact, content-free cleanup scope. The token binds the observed history,
/// settings version and cutoff; a changed scope requires a new confirmation.
class WorkspaceRetentionPreview {
  const WorkspaceRetentionPreview({
    required this.token,
    required this.days,
    required this.cutoff,
    required this.requests,
    required this.grants,
    required this.operations,
    required this.preserved,
  });
  final String token;
  final int days, requests, grants, operations, preserved;
  final DateTime cutoff;
}

/// Notification metadata, never field values or a system authorization token.
class WorkspaceNotificationPreview {
  const WorkspaceNotificationPreview({
    this.requestId,
    this.title = '暂无待处理申请',
    this.description = '收到新申请后，可在访问审批中查看。',
  });
  final String? requestId;
  final String title, description;
}

abstract interface class WorkspaceSettingsSource {
  Future<WorkspacePreferences> read();
  Future<WorkspaceSettingsReceipt> change(WorkspaceSettingsChange change);
  Future<WorkspaceSettingsReceipt?> receipt(String operationId);
  Future<WorkspaceNotificationPreview> notificationPreview();
  Future<WorkspaceRetentionPreview> previewRetention(int days);
}

/// Restores an already submitted device operation after the App reopens. This
/// grants no new save and never supplies a replacement operation identifier.
abstract interface class WorkspaceSettingsRecovery {
  Future<WorkspaceSettingsChange?> pendingChange();
}
