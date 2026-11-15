import 'dart:io';
import 'package:flutter/services.dart';
import 'bundled_focused_fill.dart';
import 'bundled_windows_native_fill.dart';

enum CredentialFillPermissionState { ready, permissionRequired, unavailable }

/// Permission belongs to the actual helper; neither state selects a target.
class CredentialFillPermissionReport {
  const CredentialFillPermissionReport({
    required this.native,
    required this.focus,
    this.errorCode,
    this.applicationName = 'chiyo',
    this.applicationPath,
  });
  const CredentialFillPermissionReport.unavailable([this.errorCode])
    : native = CredentialFillPermissionState.unavailable,
      focus = CredentialFillPermissionState.unavailable,
      applicationName = 'chiyo',
      applicationPath = null;

  final CredentialFillPermissionState native, focus;
  final String? errorCode, applicationPath;
  final String applicationName;

  factory CredentialFillPermissionReport.fromMac(Map<String, Object?> value) {
    if (value['format'] != 2 || value['platform'] != 'macos') {
      throw const FormatException('Invalid permission status');
    }
    final name = value['applicationName'], path = value['applicationPath'];
    if (name != null &&
            (name is! String || name.isEmpty || name.length > 256) ||
        path != null &&
            (path is! String || !path.startsWith('/') || path.length > 4096)) {
      throw const FormatException('Invalid application identity');
    }
    final keys = value.keys.toSet().difference({
      'applicationName',
      'applicationPath',
    });
    if (value['state'] == 'unavailable' &&
        keys.length == 4 &&
        keys.containsAll({'format', 'platform', 'state', 'errorCode'}) &&
        {'busy', 'session_unavailable'}.contains(value['errorCode'])) {
      return CredentialFillPermissionReport(
        native: CredentialFillPermissionState.unavailable,
        focus: CredentialFillPermissionState.unavailable,
        errorCode: value['errorCode'] as String,
        applicationName: name as String? ?? 'chiyo',
        applicationPath: path as String?,
      );
    }
    if (value['state'] != 'checked' ||
        keys.length != 5 ||
        !keys.containsAll({
          'format',
          'platform',
          'state',
          'accessibilityTrusted',
          'postEventsTrusted',
        }) ||
        value['accessibilityTrusted'] is! bool ||
        value['postEventsTrusted'] is! bool) {
      throw const FormatException('Invalid permission status');
    }
    final ax = value['accessibilityTrusted'] as bool;
    return CredentialFillPermissionReport(
      native: ax
          ? CredentialFillPermissionState.ready
          : CredentialFillPermissionState.permissionRequired,
      focus: ax && value['postEventsTrusted'] == true
          ? CredentialFillPermissionState.ready
          : CredentialFillPermissionState.permissionRequired,
      applicationName: name as String? ?? 'chiyo',
      applicationPath: path as String?,
    );
  }
}

/// Passive checks do not inspect another app or request OS permission.
class CredentialFillPermissions {
  const CredentialFillPermissions();
  static const _channel = MethodChannel('agent_info_manage/focused_fill');
  bool get canRequest => Platform.isMacOS;

  Future<CredentialFillPermissionState> read() async =>
      (await readReport()).native;
  Future<CredentialFillPermissionState> request() async =>
      (await requestNative()).native;
  Future<CredentialFillPermissionReport> readReport() =>
      _invoke('permissionDetails');
  Future<CredentialFillPermissionReport> requestNative() =>
      _invoke('requestNativePermissionDetails');

  Future<CredentialFillPermissionReport> requestFocus() async {
    if (!Platform.isMacOS) return readReport();
    try {
      await _channel
          .invokeMethod<Object?>('requestPermission')
          .timeout(const Duration(seconds: 7));
    } on Object {
      return const CredentialFillPermissionReport.unavailable();
    }
    return readReport();
  }

  Future<bool> openSettings() => _ownerAction('openAccessibilitySettings');
  Future<bool> revealApplication() => _ownerAction('revealApplication');
  Future<bool> _ownerAction(String method) async {
    if (!Platform.isMacOS) return false;
    try {
      return await _channel
              .invokeMethod<bool>(method)
              .timeout(const Duration(seconds: 7)) ==
          true;
    } on Object {
      return false;
    }
  }

  Future<CredentialFillPermissionReport> _invoke(String method) async {
    if (Platform.isWindows) {
      var native = CredentialFillPermissionState.unavailable;
      var focus = CredentialFillPermissionState.unavailable;
      try {
        final driver = await loadBundledWindowsNativeFill();
        await driver.dispose();
        native = CredentialFillPermissionState.ready;
      } on Object {
        /* Keep module failure independent from OS permission. */
      }
      try {
        await loadBundledFocusedFill();
        focus = CredentialFillPermissionState.ready;
      } on Object {
        /* Preserve the native result. */
      }
      return CredentialFillPermissionReport(native: native, focus: focus);
    }
    if (!Platform.isMacOS) {
      return const CredentialFillPermissionReport.unavailable();
    }
    try {
      final value = await _channel
          .invokeMapMethod<String, Object?>(method)
          .timeout(const Duration(seconds: 7));
      if (value == null) throw const FormatException();
      return CredentialFillPermissionReport.fromMac(value);
    } on Object {
      return const CredentialFillPermissionReport.unavailable(
        'session_unavailable',
      );
    }
  }
}
