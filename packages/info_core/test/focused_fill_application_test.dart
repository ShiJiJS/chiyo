import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() {
  FocusedFillApplication application(String path, [String? hash]) =>
      FocusedFillApplication.fromJson({
        'executable': path,
        'sha256': hash ?? '31' * 32,
      });
  final invalid = throwsA(
    isA<CredentialUseFailure>().having((e) => e.code, 'code', 'invalid_plan'),
  );

  test(
    'Windows application identities keep their original wire shape and case rules',
    () {
      final original = application(r'C:\Apps\Browser.EXE');
      expect(original.toJson(), {
        'executable': r'C:\Apps\Browser.EXE',
        'sha256': '31' * 32,
      });
      expect(original.matches(application(r'c:\apps\browser.exe')), isTrue);
      expect(
        original.matches(application(r'C:\Apps\Browser.EXE', '32' * 32)),
        isFalse,
      );
    },
  );

  test(
    'Mac application identity preserves literal case, Unicode and spaces through serialization',
    () {
      const path = '/Applications/中文 空格.app/Contents/MacOS/Browser';
      final original = application(path);
      final restored = FocusedFillApplication.fromJson(
        jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>,
      );
      expect(original.matches(restored), isTrue);
      expect(restored.executable, path);
      expect(
        original.matches(
          application('/applications/中文 空格.app/Contents/MacOS/Browser'),
        ),
        isFalse,
      );
      expect(original.matches(application('$path.exe')), isFalse);
      expect(original.matches(application(r'C:\Apps\Browser.exe')), isFalse);
    },
  );

  test(
    'platform support does not turn relative paths, URLs or control text into applications',
    () {
      for (final path in [
        'Browser',
        './Browser',
        '~/Browser',
        'file:///Applications/Browser',
        'https://example.invalid/Browser.exe',
        '/',
        '//network/Browser',
        '/Applications/',
        'C:Browser.exe',
        r'\\server\Browser.exe',
        r'C:\Apps\Browser',
        '/Applications/Bad\nBrowser',
      ]) {
        expect(() => application(path), invalid, reason: path);
      }
      expect(() => application('/Applications/Browser', 'ff'), invalid);
    },
  );

  test(
    'the local inspector refuses foreign platform paths before accessing a local file',
    () async {
      final foreign = application(
        Platform.isWindows ? '/Applications/Browser' : r'C:\Apps\Browser.exe',
      );
      await expectLater(
        inspectFocusedFillApplication(foreign),
        throwsA(
          isA<CredentialUseFailure>().having(
            (e) => e.code,
            'code',
            'unsupported_desktop',
          ),
        ),
      );
    },
  );

  test(
    'the Mac contract example parses with the real focused-fill request interface',
    () async {
      final doc = await File(
        '../../docs/design/macos-focused-fill-contract.md',
      ).readAsString();
      final json = RegExp(
        r'```json\r?\n([\s\S]*?)\r?\n```',
      ).firstMatch(doc)!.group(1)!;
      final input = FocusedFillInput.fromJson(
        jsonDecode(json) as Map<String, dynamic>,
      );
      expect(
        input.fill.application.executable,
        '/Applications/合成浏览器.app/Contents/MacOS/SyntheticBrowser',
      );
      expect(input.fill.application.sha256, 'a' * 64);
    },
  );

  test(
    'Mac operation metadata round-trips without adding secret or input fields',
    () {
      final app = application(
        '/Applications/Browser.app/Contents/MacOS/Browser',
      );
      final operation = FocusedFillOperation(
        id: 'synthetic-fill',
        requestId: 'synthetic-request',
        operationId: 'synthetic-operation',
        fingerprint: 'sha256:${'32' * 32}',
        createdAt: DateTime.utc(2026, 10, 23),
        application: app,
      );
      final decoded = FocusedFillOperation.fromStorageJson(
        jsonDecode(jsonEncode(operation.toStorageJson()))
            as Map<String, dynamic>,
      );
      expect(decoded.application.matches(app), isTrue);
      expect(decoded.toStorageJson(), operation.toStorageJson());
      expect(decoded.toJson(), isNot(contains('secret')));
      expect(decoded.toJson(), isNot(contains('input')));
    },
  );
}
