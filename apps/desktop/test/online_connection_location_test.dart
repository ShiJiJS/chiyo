import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/online_connection_location.dart';

void main() {
  test('named connections keep all state in a separate private profile', () {
    const base = '/private/application/online';
    expect(onlineConnectionDirectory(base, []), base);
    expect(
      onlineConnectionDirectory(base, [
        '--connection-profile',
        'a12-candidate',
      ]),
      '$base/profiles/a12-candidate',
    );
    for (final args in [
      ['--connection-profile'],
      ['--connection-profile', '../daily'],
      ['--connection-profile', '/some/path'],
      ['--connection-profile', ''],
      ['--unknown', 'daily'],
      ['--connection-profile', 'daily', 'extra'],
    ]) {
      expect(
        () => onlineConnectionDirectory(base, args),
        throwsFormatException,
      );
    }
  });
}
