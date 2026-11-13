import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() {
  Map<String, dynamic> target({String provider = 'chrome'}) => {
    'provider': provider,
    'instanceId': 'browser-instance-1',
    'pageId': provider == 'ego' ? 'p1' : 'page-1',
    'url': 'https://workspace.example/login?flow=one',
    'form': '#login',
    'field': 'input[name="password"]',
    'structureDigest': List.filled(64, 'a').join(),
    if (provider == 'ego') 'space': 7,
    if (provider == 'chrome') 'browserAddress': 'http://127.0.0.1:9222',
  };

  test(
    'an unchanged form survives serialization without widening approval',
    () {
      for (final provider in ['ego', 'chrome']) {
        final approved = BrowserFormTarget.fromJson(target(provider: provider));
        approved.requireSameTarget(
          BrowserFormTarget.fromJson(approved.toJson()),
        );
      }
    },
  );

  test('same site or selector does not authorize a different target', () {
    final approved = BrowserFormTarget.fromJson(target());
    for (final change in <String, Object>{
      'instanceId': 'another-browser',
      'pageId': 'another-page-with-the-same-url',
      'url': 'https://workspace.example/change-password',
      'form': '#register',
      'field': 'input[name="new-password"]',
      'structureDigest': List.filled(64, 'b').join(),
      'browserAddress': 'http://127.0.0.1:9223',
    }.entries) {
      expect(
        () => approved.requireSameTarget(
          BrowserFormTarget.fromJson({...target(), change.key: change.value}),
        ),
        throwsA(isA<CredentialUseFailure>()),
        reason: change.key,
      );
    }
  });

  test('an ego page cannot be silently moved into another task space', () {
    final source = target(provider: 'ego');
    expect(
      () => BrowserFormTarget.fromJson(
        source,
      ).requireSameTarget(BrowserFormTarget.fromJson({...source, 'space': 8})),
      throwsA(isA<CredentialUseFailure>()),
    );
  });

  test(
    'CDP addresses cannot redirect selection to remote or credentialed URLs',
    () {
      for (final address in [
        'http://192.168.8.132:9222',
        'http://127.0.0.1.attacker.example:9222',
        'http://name:password@127.0.0.1:9222',
        'http://127.0.0.1:9222/another-api',
        'http://127.0.0.1:9222?target=other',
        'file:///browser/profile',
      ]) {
        expect(
          () => BrowserFormTarget.fromJson({
            ...target(),
            'browserAddress': address,
          }),
          throwsA(isA<CredentialUseFailure>()),
          reason: address,
        );
      }
    },
  );

  test('native application approval is not accepted as a web form proof', () {
    expect(
      () => BrowserFormTarget.fromJson({...target(), 'provider': 'focus'}),
      throwsA(isA<CredentialUseFailure>()),
    );
    expect(
      () => BrowserFormTarget.fromJson({...target(), 'application': 'Chrome'}),
      throwsA(isA<CredentialUseFailure>()),
    );
  });
}
