import 'dart:io';
import 'package:flutter/services.dart';
import 'package:info_cli/windows_focused_fill.dart';
import 'package:info_core/info_core.dart';

/// No raw path, digest or exception detail is projected onto the startup screen.
class FocusedFillBundleFailure implements Exception {
  const FocusedFillBundleFailure();
}

/// Reads the build-bound identity from the native runner, then checks the
/// sibling helper before the library/server opens. Caller injection is an owner
/// test seam; no agent endpoint or environment/config lookup reaches it.
Future<WindowsFocusedFillDriver> loadBundledFocusedFill({
  String? applicationExecutable,
  Future<Object?> Function()? readIdentity,
}) async {
  try {
    if (!Platform.isWindows) throw const FocusedFillBundleFailure();
    final raw =
        await (readIdentity?.call() ??
            const MethodChannel(
              'agent_info_manage/desktop',
            ).invokeMethod<Object?>('focusedFillHelper'));
    if (raw is! Map) throw const FocusedFillBundleFailure();
    final identity = FocusedFillApplication.fromJson(
      Map<String, dynamic>.from(raw),
    );
    final directory = await File(
      applicationExecutable ?? Platform.resolvedExecutable,
    ).parent.resolveSymbolicLinks();
    final expected = File('$directory/info-focus-broker.exe').absolute.path;
    final resolved = await File(identity.executable).resolveSymbolicLinks();
    String normalized(String path) => path.replaceAll('/', r'\').toLowerCase();
    // Reject an outside path, an alternate filename or a sibling symlink whose
    // target escapes the application directory, even if the hash matches.
    if (normalized(resolved) != normalized(expected)) {
      throw const FocusedFillBundleFailure();
    }
    final checked = await inspectFocusedFillApplication(identity);
    if (normalized(checked.executable) != normalized(expected)) {
      throw const FocusedFillBundleFailure();
    }
    return WindowsFocusedFillDriver(helper: checked);
  } on Object {
    throw const FocusedFillBundleFailure();
  }
}
