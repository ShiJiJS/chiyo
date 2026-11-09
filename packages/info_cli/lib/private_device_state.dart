import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_core/protocol_json.dart';

// Shared private journal storage for device files and credential executions.
Future<Directory> privateDeviceDirectory(Directory folder) async {
  if (!Platform.isMacOS) {
    throw const InformationFileFailure('unsupported_capability');
  }
  final type = await FileSystemEntity.type(folder.path, followLinks: false);
  if (type != FileSystemEntityType.notFound &&
      type != FileSystemEntityType.directory) {
    throw const InformationFileFailure('delivery_io_failed');
  }
  await folder.create(recursive: true);
  if ((await Process.run('/bin/chmod', ['700', folder.path])).exitCode != 0) {
    throw const InformationFileFailure('delivery_io_failed');
  }
  // macOS system temporary roots use /var -> /private/var. Resolve that
  // ancestor alias once; the supplied journal directory itself cannot be a link.
  return Directory(await folder.resolveSymbolicLinks());
}

Future<void> privateDeviceFile(File file) async {
  final type = await FileSystemEntity.type(file.path, followLinks: false);
  if (type != FileSystemEntityType.notFound &&
      type != FileSystemEntityType.file) {
    throw const InformationFileFailure('delivery_io_failed');
  }
  if (type == FileSystemEntityType.notFound) {
    try {
      await file.create(exclusive: true);
    } on FileSystemException catch (e) {
      // Separate CLI processes can both observe the first launch lock absent.
      // Only accept the other creator's regular file; links and all other I/O
      // errors retain the original failure. Never truncate an existing lock.
      if (e.osError?.errorCode != 17 ||
          await FileSystemEntity.type(file.path, followLinks: false) !=
              FileSystemEntityType.file) {
        rethrow;
      }
    }
  }
  if ((await Process.run('/bin/chmod', ['600', file.path])).exitCode != 0) {
    throw const InformationFileFailure('delivery_io_failed');
  }
}

Future<Map<String, dynamic>?> readPrivateDeviceState(File file) async {
  final type = await FileSystemEntity.type(file.path, followLinks: false);
  if (type == FileSystemEntityType.notFound) return null;
  if (type != FileSystemEntityType.file ||
      (await file.stat()).mode & 0xE3F != 0 ||
      await file.length() > 131072) {
    throw const InformationFileFailure('delivery_io_failed');
  }
  return decodeProtocolObject(await file.readAsString(), maxBytes: 131072);
}

Future<void> writePrivateDeviceState(
  File file,
  Map<String, dynamic> value,
) async {
  final staging = await file.parent.createTemp('.copy-state-');
  try {
    await privateDeviceDirectory(staging);
    final next = File('${staging.path}/state');
    await privateDeviceFile(next);
    await next.writeAsString(jsonEncode(value), flush: true);
    await next.rename(file.path);
  } finally {
    await staging.delete(recursive: true);
  }
}
