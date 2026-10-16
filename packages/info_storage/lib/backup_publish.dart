import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

/// Same-volume, no-replace publication of an already closed, verified backup.
/// Unsupported native/filesystem behavior fails instead of replacing a target.
void publishNewBackup(String source, String destination) {
  if (source.contains('\x00') || destination.contains('\x00')) {
    throw const FileSystemException('Invalid backup destination');
  }
  if (Platform.isWindows) {
    final move = DynamicLibrary.open('Kernel32.dll')
        .lookupFunction<
          Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Uint32),
          int Function(Pointer<Utf16>, Pointer<Utf16>, int)
        >('MoveFileExW');
    final from = source.toNativeUtf16();
    final to = destination.toNativeUtf16();
    try {
      // WRITE_THROUGH, with neither REPLACE_EXISTING nor COPY_ALLOWED. A
      // cross-volume move or an existing destination must fail safely.
      if (move(from, to, 8) == 0)
        throw const FileSystemException('Backup publication failed');
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
    final from = source.toNativeUtf8();
    final to = destination.toNativeUtf8();
    try {
      // RENAME_EXCL from Darwin sys/stdio.h. Never fall back to replacing rename.
      if (rename(from, to, 4) != 0)
        throw const FileSystemException('Backup publication failed');
    } finally {
      calloc.free(from);
      calloc.free(to);
    }
  } else {
    throw const FileSystemException('Backup platform unsupported');
  }
}
