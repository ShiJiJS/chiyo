import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

/// Same-volume no-replace publication of a closed, verified ordinary file or
/// encrypted backup. Never fall back to an overwriting rename or copy.
void publishNewFile(String source, String destination) {
  if (source.contains('\x00') || destination.contains('\x00')) {
    throw const FileSystemException('Invalid destination');
  }
  if (Platform.isWindows) {
    final move = DynamicLibrary.open('Kernel32.dll')
        .lookupFunction<
          Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Uint32),
          int Function(Pointer<Utf16>, Pointer<Utf16>, int)
        >('MoveFileExW');
    final from = source.toNativeUtf16(), to = destination.toNativeUtf16();
    try {
      if (move(from, to, 8) == 0) {
        throw const FileSystemException('File publication failed');
      }
    } finally {
      calloc.free(from);
      calloc.free(to);
    }
  } else if (Platform.isMacOS) {
    final rename = DynamicLibrary.process()
        .lookupFunction<
          Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Uint32),
          int Function(Pointer<Utf8>, Pointer<Utf8>, int)
        >('renamex_np');
    final from = source.toNativeUtf8(), to = destination.toNativeUtf8();
    try {
      if (rename(from, to, 4) != 0) {
        throw const FileSystemException('File publication failed');
      }
    } finally {
      calloc.free(from);
      calloc.free(to);
    }
  } else {
    throw const FileSystemException('File publication unsupported');
  }
}
