import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

/// Publish a fully prepared directory on the same volume. The native primitive
/// refuses an existing destination, including an empty directory created after
/// the caller's preflight check. No partial merge or replacement is allowed.
void publishNewDirectory(String source, String destination) =>
    publishNewFile(source, destination);

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
  } else if (Platform.isLinux) {
    // Linux renameat2(AT_FDCWD, ..., RENAME_NOREPLACE) provides the same
    // no-clobber contract for both files and directories. Unsupported kernels
    // or filesystems fail closed; an overwriting rename is never a fallback.
    final rename = DynamicLibrary.process()
        .lookupFunction<
          Int32 Function(Int32, Pointer<Utf8>, Int32, Pointer<Utf8>, Uint32),
          int Function(int, Pointer<Utf8>, int, Pointer<Utf8>, int)
        >('renameat2');
    final from = source.toNativeUtf8(), to = destination.toNativeUtf8();
    try {
      if (rename(-100, from, -100, to, 1) != 0) {
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
