import 'dart:io';

import 'package:flutter/services.dart';
import 'bundled_focused_fill.dart';

enum CredentialFillPermissionState { ready, permissionRequired, unavailable }

/// Permission belongs to the device doing the typing, never to its server.
/// Reading this status does not inspect another app or request OS permission.
class CredentialFillPermissions {
  const CredentialFillPermissions();

  bool get canRequest => Platform.isMacOS;

  Future<CredentialFillPermissionState> read() => _invoke('permissions');

  Future<CredentialFillPermissionState> request() =>
      _invoke('requestPermission');

  Future<CredentialFillPermissionState> _invoke(String method) async {
    if (Platform.isWindows) {
      try {
        await loadBundledFocusedFill();
        return CredentialFillPermissionState.ready;
      } on FocusedFillBundleFailure {
        return CredentialFillPermissionState.unavailable;
      }
    }
    if (!Platform.isMacOS) return CredentialFillPermissionState.unavailable;
    try {
      final result = await const MethodChannel('agent_info_manage/focused_fill')
          .invokeMapMethod<String, Object?>(method)
          .timeout(const Duration(seconds: 7));
      if (result?['format'] != 1 || result?['platform'] != 'macos') {
        return CredentialFillPermissionState.unavailable;
      }
      return switch (result?['state']) {
        'ready' => CredentialFillPermissionState.ready,
        'permission_required' =>
          CredentialFillPermissionState.permissionRequired,
        _ => CredentialFillPermissionState.unavailable,
      };
    } on Object {
      return CredentialFillPermissionState.unavailable;
    }
  }
}
