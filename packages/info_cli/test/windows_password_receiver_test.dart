import 'dart:io';

import 'package:test/test.dart';

import 'support/windows_password_receiver.dart';

void main() {
  final executable = Platform.environment['WINDOWS_PASSWORD_RECEIVER'];
  test(
    'Win32 receiver frames remain private and EOF closes the owned window',
    () async {
      final receiver = await WindowsPasswordReceiver.start(
        executable!,
        '  Synthetic receiver 中文🧭  ',
      );
      addTearDown(receiver.close);
      final empty = await receiver.verify();
      expect(empty['matches'], isFalse);
      expect(empty['empty'], isTrue);
      expect(empty['otherEmpty'], isTrue);
      expect(empty['plainEmpty'], isTrue);
      expect(empty['noPaste'], isTrue);
      await receiver.armFocusChange();
      await receiver.clear();
      expect((await receiver.verify())['focusChanged'], isFalse);
      await receiver.close();
      await receiver.close();
      expect(receiver.verify, throwsStateError);
    },
    skip: !Platform.isWindows || executable == null,
  );
}
