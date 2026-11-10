import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

// Synthetic read handle that briefly denies deletion; no application state.
Future<void> main(List<String> args) async {
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
      .lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');
  final path = args.single.toNativeUtf16();
  final handle = open(path, 0x80000000, 1, nullptr, 3, 0x80, 0);
  calloc.free(path);
  if (handle == -1) throw StateError('Synthetic reader did not acquire file');
  try {
    stdout.writeln('reader-ready');
    await stdout.flush();
    await Future<void>.delayed(const Duration(milliseconds: 200));
  } finally {
    close(handle);
  }
}
