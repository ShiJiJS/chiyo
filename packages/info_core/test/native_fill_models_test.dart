import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

import '../test_support/native_fill.dart';

void main() {
  test('capability kinds remain distinct from legacy approved snapshots', () {
    for (final kind in ['macos_ax_password', 'windows_uia_password']) {
      final json = nativeTargetFixture(controlKind: kind);
      final target = NativeFillTarget.fromJson(json);
      expect(target.toJson(), json);
      expect(target.requiresV2, isTrue);
      for (final legacy
          in kind == 'macos_ax_password'
              ? ['appkit_secure_text']
              : ['win32_password', 'winforms_password', 'wpf_password']) {
        final old = NativeFillTarget.fromJson({...json, 'controlKind': legacy});
        expect(old.requiresV2, isFalse);
        expect(old.matches(target), isFalse);
        expect(
          CredentialBatchDestination.fromJson({
            'via': 'native',
            'target': old.toJson(),
          }).matches(
            CredentialBatchDestination.fromJson({
              'via': 'native',
              'target': json,
            }),
          ),
          isFalse,
        );
      }
      expect(
        () => NativeFillTarget.fromJson({
          ...json,
          'controlKind': kind == 'macos_ax_password'
              ? 'windows_uia_password'
              : 'macos_ax_password',
        }),
        throwsA(isA<CredentialUseFailure>()),
      );
    }
  });
  test(
    'legal AppKit and all three Windows snapshot kinds parse their field values',
    () {
      final mac = nativeTargetFixture();
      expect(NativeFillTarget.fromJson(mac).toJson(), mac);
      for (final kind in [
        'win32_password',
        'winforms_password',
        'wpf_password',
      ]) {
        final windows = {
          ...mac,
          'platform': 'windows',
          'controlKind': kind,
          'application': {
            'executable': r'C:\Synthetic\NativeFixture.exe',
            'sha256': 'b' * 64,
          },
          'appId': r'C:\Synthetic\NativeFixture.exe',
          'appName': 'Native Windows fixture',
          'windowTitle': 'Synthetic login',
          'fieldLabel': 'Password [AutomationId=loginPassword]',
        };
        final target = NativeFillTarget.fromJson(windows);
        expect(target.toJson(), windows);
        expect(target.application.executable, windows['appId']);
      }
    },
  );
  test(
    'native snapshots preserve identity without accepting raw handles or embedded web controls',
    () {
      final json = nativeTargetFixture();
      final target = NativeFillTarget.fromJson(json);
      expect(target.toJson(), json);
      expect(
        target.matches(
          NativeFillTarget.fromJson({...json, 'helperInstanceId': 'J' * 32}),
        ),
        false,
      );
      for (final invalid in [
        {...json, 'pid': 1234},
        {...json, 'targetId': '1234'},
        {...json, 'controlKind': 'WKWebView'},
        {...json, 'value': 'MUST-NOT-READ'},
      ]) {
        expect(
          () => NativeFillTarget.fromJson(invalid),
          throwsA(isA<CredentialUseFailure>()),
        );
      }
    },
  );
  test(
    'setter receipts cannot claim sent with an error or leak native exception details',
    () {
      expect(
        NativeFillResult.fromJson({'state': 'sent'}).state,
        NativeFillState.sent,
      );
      expect(
        NativeFillResult.fromJson({
          'state': 'unknown',
          'errorCode': 'fill_unknown',
        }).state,
        NativeFillState.unknown,
      );
      for (final invalid in [
        {'state': 'sent', 'errorCode': 'access_denied'},
        {'state': 'refused', 'errorCode': 'RAW_PRIVATE_NATIVE_EXCEPTION'},
        {'state': 'unknown'},
      ]) {
        expect(
          () => NativeFillResult.fromJson(invalid),
          throwsA(isA<CredentialUseFailure>()),
        );
      }
    },
  );
}
