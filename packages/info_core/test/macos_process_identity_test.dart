import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() {
  test(
    'Darwin identities distinguish current, ended, mismatched and foreign facts',
    () async {
      final current = CredentialProcessIdentity.capture(pid)!;
      addTearDown(current.close);
      expect(current.value, startsWith('macos:'));
      expect(CredentialProcessIdentity.isActive(pid, current.value), isTrue);
      expect(CredentialProcessIdentity.isActive(pid, 'macos:1:0'), isFalse);
      expect(CredentialProcessIdentity.isActive(pid, 'windows:1'), isNull);
      expect(CredentialProcessIdentity.capture(-1), isNull);
      final child = await Process.start('/bin/cat', []);
      final identity = CredentialProcessIdentity.capture(child.pid)!;
      addTearDown(identity.close);
      expect(
        CredentialProcessIdentity.isActive(child.pid, identity.value),
        isTrue,
      );
      await child.stdin.close();
      await child.exitCode;
      expect(
        CredentialProcessIdentity.isActive(child.pid, identity.value),
        isFalse,
      );
    },
    skip: !Platform.isMacOS,
  );
}
