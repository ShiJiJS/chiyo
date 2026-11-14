import 'dart:io';

import 'package:flutter/services.dart';
import 'package:info_core/info_core.dart';

import 'windows_native_background_fill.dart';

/// Loads and initializes the runner's build-bound sibling helper. Optional
/// injections are Owner test seams; Agent endpoints cannot provide identities.
/// The caller owns the returned driver until AppHost.start succeeds with
/// ownsNativeDriver:true, and must dispose it if host initialization fails.
Future<WindowsNativeFillDriver> loadBundledWindowsNativeFill({
  String? applicationExecutable,
  Future<Object?> Function()? readIdentity,
}) async {
  if (!Platform.isWindows) {
    throw const CredentialUseFailure('unsupported_capability');
  }
  WindowsNativeFillDriver? driver;
  try {
    final raw =
        await (readIdentity?.call() ??
            const MethodChannel(
              'agent_info_manage/desktop',
            ).invokeMethod<Object?>('nativeBackgroundFillHelper'));
    if (raw is! Map) throw const FormatException();
    final identity = FocusedFillApplication.fromJson(
      Map<String, dynamic>.from(raw),
    );
    final directory = await File(
      applicationExecutable ?? Platform.resolvedExecutable,
    ).parent.resolveSymbolicLinks();
    final expected = File(
      '$directory/info-native-background-broker.exe',
    ).absolute.path;
    String normalized(String path) => path.replaceAll('/', r'\').toLowerCase();
    final resolved = await File(identity.executable).resolveSymbolicLinks();
    if (normalized(resolved) != normalized(expected)) {
      throw const FormatException();
    }
    final checked = await inspectFocusedFillApplication(identity);
    if (normalized(checked.executable) != normalized(expected)) {
      throw const FormatException();
    }
    driver = WindowsNativeFillDriver(helper: checked);
    await driver.initialize();
    return driver;
  } on Object {
    try {
      await driver?.dispose();
    } on Object {
      // The failure remains sanitized even when owned transport cleanup fails.
    }
    throw const CredentialUseFailure('session_unavailable');
  }
}
