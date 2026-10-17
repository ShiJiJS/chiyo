import 'dart:io';
import 'package:flutter/services.dart';

class SelectedCredentialFile {
  SelectedCredentialFile(this.name, Iterable<int> bytes)
    : bytes = List.unmodifiable(bytes);
  final String name;
  final List<int> bytes;
}

abstract interface class CredentialFilePicker {
  Future<SelectedCredentialFile?> choose();
}

class NativeCredentialFilePicker implements CredentialFilePicker {
  const NativeCredentialFilePicker();
  @override
  Future<SelectedCredentialFile?> choose() async {
    final path = await const MethodChannel(
      'agent_info_manage/backup_files',
    ).invokeMethod<String>('credentialInput');
    if (path == null) return null;
    return readCredentialFile(path);
  }
}

/// The source path remains local to this function and is never persisted or
/// included in UI errors. Generic opaque files are supported, 1 byte–1 MiB.
Future<SelectedCredentialFile> readCredentialFile(String path) async {
  try {
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const FormatException();
    }
    final bytes = <int>[];
    await for (final chunk in File(path).openRead()) {
      if (bytes.length + chunk.length > 1048576) throw const FormatException();
      bytes.addAll(chunk);
    }
    if (bytes.isEmpty) throw const FormatException();
    return SelectedCredentialFile(path.split(RegExp(r'[/\\]')).last, bytes);
  } on Object {
    throw const FormatException('credential_file_unavailable');
  }
}
