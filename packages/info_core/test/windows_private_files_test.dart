@TestOn('windows')
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  setUp(() {
    root = Directory.systemTemp.createTempSync('private 中文 space ');
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('DPAPI state reopens privately, rejects tampering and plaintext', () {
    final folder = WindowsPrivateFiles.directory(Directory('${root.path}/在线'));
    final file = File('${folder.path}/state.json');
    expect(WindowsPrivateFiles.readSecret(file), isNull);
    WindowsPrivateFiles.writeSecret(
      file,
      '{"token":"synthetic-private-token"}',
    );
    final encrypted = file.readAsBytesSync();
    expect(
      latin1.decode(encrypted),
      isNot(contains('synthetic-private-token')),
    );
    expect(
      WindowsPrivateFiles.readSecret(file),
      '{"token":"synthetic-private-token"}',
    );
    WindowsPrivateFiles.verify(folder.path, directory: true);
    WindowsPrivateFiles.verify(file.path);
    final tampered = List<int>.from(encrypted)..[encrypted.length - 1] ^= 1;
    WindowsPrivateFiles.write(file, tampered);
    expect(
      () => WindowsPrivateFiles.readSecret(file),
      throwsA(isA<RuntimeMaterialFailure>()),
    );
    WindowsPrivateFiles.write(file, utf8.encode('{"token":"plain"}'));
    expect(
      () => WindowsPrivateFiles.readSecret(file),
      throwsA(isA<RuntimeMaterialFailure>()),
    );
    expect(
      () => WindowsPrivateFiles.read(file, maxBytes: 2),
      throwsA(isA<RuntimeMaterialFailure>()),
    );
  });

  test(
    'exclusive creation and a sharing violation preserve original state',
    () {
      final folder = WindowsPrivateFiles.directory(
        Directory('${root.path}/private'),
      );
      final file = File('${folder.path}/state.json');
      WindowsPrivateFiles.writeSecret(file, 'original', replace: false);
      final original = file.readAsBytesSync();
      expect(
        () => WindowsPrivateFiles.writeSecret(
          file,
          'conflicting',
          replace: false,
        ),
        throwsA(isA<RuntimeMaterialFailure>()),
      );
      expect(file.readAsBytesSync(), original);
      final kernel = DynamicLibrary.open('kernel32.dll');
      final open = kernel
          .lookupFunction<
            IntPtr Function(
              Pointer<Utf16>,
              Uint32,
              Uint32,
              Pointer<Void>,
              Uint32,
              Uint32,
              IntPtr,
            ),
            int Function(Pointer<Utf16>, int, int, Pointer<Void>, int, int, int)
          >('CreateFileW');
      final close = kernel
          .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
            'CloseHandle',
          );
      final path = file.path.toNativeUtf16();
      final handle = open(path, 0x80000000, 1, nullptr, 3, 0x80, 0);
      calloc.free(path);
      expect(handle, isNot(-1));
      try {
        final publication = Stopwatch()..start();
        expect(
          () => WindowsPrivateFiles.writeSecret(file, 'replacement'),
          throwsA(isA<RuntimeMaterialFailure>()),
        );
        expect(publication.elapsed, lessThan(const Duration(seconds: 2)));
        expect(file.readAsBytesSync(), original);
      } finally {
        close(handle);
      }
      expect(folder.listSync().map((f) => f.uri.pathSegments.last), [
        'state.json',
      ]);
      WindowsPrivateFiles.writeSecret(file, 'replacement');
      expect(WindowsPrivateFiles.readSecret(file), 'replacement');
    },
  );

  test(
    'a temporary native reader releases its original handle before atomic publication completes',
    () async {
      final folder = WindowsPrivateFiles.directory(
        Directory('${root.path}/reader'),
      );
      final file = File('${folder.path}/state.json');
      WindowsPrivateFiles.writeSecret(file, 'original');
      final reader = await Process.start(Platform.resolvedExecutable, [
        '--packages=${Directory.current.path}/.dart_tool/package_config.json',
        '${Directory.current.path}/test/support/windows_private_reader.dart',
        file.path,
      ]);
      final errors = utf8.decoder.bind(reader.stderr).join();
      try {
        expect(
          await reader.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .first,
          'reader-ready',
        );
        WindowsPrivateFiles.writeSecret(file, 'replacement');
        expect(WindowsPrivateFiles.readSecret(file), 'replacement');
        expect(folder.listSync().map((f) => f.uri.pathSegments.last), [
          'state.json',
        ]);
      } finally {
        await reader.stdin.close();
        expect(
          await reader.exitCode.timeout(const Duration(seconds: 5)),
          0,
          reason: await errors,
        );
      }
    },
  );

  test(
    'a permissive file is refused without silently repairing its ACL',
    () async {
      final folder = WindowsPrivateFiles.directory(
        Directory('${root.path}/private'),
      );
      final file = File('${folder.path}/state.json');
      WindowsPrivateFiles.writeSecret(file, 'protected');
      final original = file.readAsBytesSync();
      final change = await Process.run('icacls.exe', [
        file.path,
        '/grant',
        '*S-1-1-0:(R)',
      ]);
      expect(change.exitCode, 0, reason: '${change.stderr}');
      expect(
        () => WindowsPrivateFiles.readSecret(file),
        throwsA(isA<RuntimeMaterialFailure>()),
      );
      expect(
        () => WindowsPrivateFiles.writeSecret(file, 'replacement'),
        throwsA(isA<RuntimeMaterialFailure>()),
      );
      expect(file.readAsBytesSync(), original);
    },
  );

  test(
    'private files refuse hard links and junction directory aliases',
    () async {
      final folder = WindowsPrivateFiles.directory(
        Directory('${root.path}/private'),
      );
      final file = File('${folder.path}/state.json');
      WindowsPrivateFiles.writeSecret(file, 'preserve');
      final createLink = DynamicLibrary.open('kernel32.dll')
          .lookupFunction<
            Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Pointer<Void>),
            int Function(Pointer<Utf16>, Pointer<Utf16>, Pointer<Void>)
          >('CreateHardLinkW');
      final alias = '${root.path}/other-link'.toNativeUtf16();
      final original = file.path.toNativeUtf16();
      try {
        expect(createLink(alias, original, nullptr), 1);
      } finally {
        calloc.free(alias);
        calloc.free(original);
      }
      expect(
        () => WindowsPrivateFiles.readSecret(file),
        throwsA(isA<RuntimeMaterialFailure>()),
      );
      expect(
        () => WindowsPrivateFiles.writeSecret(file, 'changed'),
        throwsA(isA<RuntimeMaterialFailure>()),
      );
      await File('${root.path}/other-link').delete();
      final junction = '${root.path}/alias';
      final result = await Process.run('cmd', [
        '/c',
        'mklink',
        '/J',
        junction,
        folder.path,
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      try {
        expect(
          () => WindowsPrivateFiles.directory(Directory(junction)),
          throwsA(isA<RuntimeMaterialFailure>()),
        );
        expect(
          () => WindowsPrivateFiles.readSecret(File('$junction/state.json')),
          throwsA(isA<RuntimeMaterialFailure>()),
        );
        expect(WindowsPrivateFiles.readSecret(file), 'preserve');
      } finally {
        await Link(junction).delete();
      }
    },
  );

  test(
    'concurrent first launches reserve one file and publish whole states',
    () async {
      final path = '${root.path}/first launch';
      final results = await Future.wait(
        List.generate(
          6,
          (i) => Process.run(Platform.resolvedExecutable, [
            '--packages=${Directory.current.path}/.dart_tool/package_config.json',
            '${Directory.current.path}/test/support/windows_private_writer.dart',
            path,
            '$i',
          ]),
        ),
      );
      for (final result in results) {
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
      }
      final file = File('$path/state.json');
      final state = jsonDecode(WindowsPrivateFiles.readSecret(file)!) as Map;
      expect(state['writer'], inInclusiveRange(0, 5));
      expect(state['payload'], List.filled(1000, state['writer']));
      expect(Directory(path).listSync().length, 2);
    },
  );
}
