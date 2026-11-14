part of 'info_core.dart';

/// Public description of a helper-held native password control. Opaque IDs
/// describe one surviving object; they cannot recreate a native reference.
class NativeFillTarget {
  const NativeFillTarget._({
    required this.targetId,
    required this.helperInstanceId,
    required this.platform,
    required this.application,
    required this.appId,
    required this.appName,
    required this.windowId,
    required this.windowTitle,
    required this.fieldLabel,
    required this.controlKind,
  });
  final String targetId, helperInstanceId, platform, appId, appName;
  final String windowId, windowTitle, fieldLabel, controlKind;
  final FocusedFillApplication application;

  factory NativeFillTarget.fromJson(Map<String, dynamic> json) {
    _useShape(json, {
      'targetId',
      'helperInstanceId',
      'platform',
      'application',
      'appId',
      'appName',
      'windowId',
      'windowTitle',
      'fieldLabel',
      'controlKind',
    });
    String id(String key) {
      final value = _useText(json[key], key, max: 128, empty: false);
      if (!RegExp(r'^[A-Za-z0-9_-]{22,128}$').hasMatch(value)) {
        throw CredentialUseFailure('invalid_reference', fieldPath: key);
      }
      return value;
    }

    final platform = json['platform'], kind = json['controlKind'];
    if (!(platform == 'macos' && kind == 'appkit_secure_text' ||
            platform == 'windows' &&
                {
                  'win32_password',
                  'winforms_password',
                  'wpf_password',
                }.contains(kind)) ||
        json['application'] is! Map<String, dynamic>) {
      throw const CredentialUseFailure('unsupported_target');
    }
    final application = FocusedFillApplication.fromJson(
      json['application'] as Map<String, dynamic>,
    );
    if ((platform == 'macos') != application.executable.startsWith('/')) {
      throw const CredentialUseFailure('application_changed');
    }
    return NativeFillTarget._(
      targetId: id('targetId'),
      helperInstanceId: id('helperInstanceId'),
      platform: platform as String,
      application: application,
      appId: _useText(json['appId'], 'appId', max: 4096, empty: false),
      appName: _useText(json['appName'], 'appName', max: 256),
      windowId: id('windowId'),
      windowTitle: _useText(json['windowTitle'], 'windowTitle', max: 256),
      fieldLabel: _useText(json['fieldLabel'], 'fieldLabel', max: 256),
      controlKind: kind as String,
    );
  }
  Map<String, Object?> toJson() => {
    'targetId': targetId,
    'helperInstanceId': helperInstanceId,
    'platform': platform,
    'application': application.toJson(),
    'appId': appId,
    'appName': appName,
    'windowId': windowId,
    'windowTitle': windowTitle,
    'fieldLabel': fieldLabel,
    'controlKind': controlKind,
  };
  bool matches(NativeFillTarget other) =>
      _useFingerprint(toJson()) == _useFingerprint(other.toJson());
}

/// The implementation owns helper incarnation, process generation, references
/// and bounded discovery lifetimes. scope is an original private-chat digest.
abstract interface class NativeFillDriver {
  Future<List<NativeFillTarget>> discover({
    required String scope,
    required String appId,
    String? windowId,
  });
  Future<PreparedNativeFill> prepare({
    required String scope,
    required String targetId,
    NativeFillTarget? expected,
  });

  /// Explicitly forget a retained target once no original request needs it.
  /// close() on an individual preparation must never do this implicitly.
  Future<void> release({required String scope, required String targetId});
}

abstract interface class PreparedNativeFill {
  NativeFillTarget get target;

  /// One complete setter, after the callback succeeds and the helper rechecks
  /// the original reference. No focus, keyboard input or clipboard fallback.
  Future<NativeFillResult> setValue(
    List<int> utf8Bytes, {
    required Future<void> Function() beforeDispatch,
  });
  Future<void> close();
}

enum NativeFillState { sent, refused, unknown }

class NativeFillResult {
  const NativeFillResult(this.state, [this.errorCode]);
  final NativeFillState state;
  final String? errorCode;

  factory NativeFillResult.fromJson(Map<String, dynamic> json) {
    _useShape(json, {'state'}, {'errorCode'});
    final state = NativeFillState.values
        .where((s) => s.name == json['state'])
        .firstOrNull;
    final code = json['errorCode'];
    if (state == null ||
        state == NativeFillState.sent && code != null ||
        state != NativeFillState.sent && !nativeFillErrorCodes.contains(code)) {
      throw const CredentialUseFailure('invalid_type');
    }
    return NativeFillResult(state, code as String?);
  }
  Map<String, Object?> toJson() => {
    'state': state.name,
    if (errorCode != null) 'errorCode': errorCode,
  };
}

const nativeFillErrorCodes = {
  'access_denied',
  'session_unavailable',
  'unsupported_capability',
  'unsupported_target',
  'target_unavailable',
  'destination_changed',
  'application_changed',
  'busy',
  'fill_unknown',
  'input_rejected',
  'unsupported_secret',
  'grant_revoked',
  'grant_expired',
  'scope_not_approved',
  'service_unavailable',
};
