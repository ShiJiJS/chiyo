import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

Map<String, dynamic> nativeTargetFixture() => {
  'targetId': 'N' * 32,
  'helperInstanceId': 'H' * 32,
  'platform': 'macos',
  'application': {
    'executable': '/Applications/Synthetic.app/Contents/MacOS/Synthetic',
    'sha256': 'a' * 64,
  },
  'appId': 'synthetic.native',
  'appName': 'Synthetic Native',
  'windowId': 'W' * 32,
  'windowTitle': 'Synthetic login',
  'fieldLabel': 'Password',
  'controlKind': 'appkit_secure_text',
};

void main() {
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
