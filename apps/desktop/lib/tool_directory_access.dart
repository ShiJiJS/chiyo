import 'package:flutter/services.dart';

enum ToolDirectoryPermission { readOnly, readWrite }

class ToolDirectory {
  const ToolDirectory(
    this.id,
    this.name,
    this.path,
    this.available, {
    this.permission = ToolDirectoryPermission.readOnly,
  });
  final String id, name, path;
  final bool available;
  final ToolDirectoryPermission permission;
}

class ToolDirectorySnapshot {
  const ToolDirectorySnapshot(
    this.directories, {
    this.storageUnavailable = false,
  });
  final List<ToolDirectory> directories;
  final bool storageUnavailable;

  factory ToolDirectorySnapshot.fromNative(Map<Object?, Object?> data) {
    final rows = data['directories'];
    if (rows is! List ||
        rows.length > 16 ||
        data['storageUnavailable'] is! bool) {
      throw const FormatException('Invalid tool directory status');
    }
    return ToolDirectorySnapshot(
      List.unmodifiable(
        rows.map((row) {
          if (row is! Map ||
              row['id'] is! String ||
              row['name'] is! String ||
              row['path'] is! String ||
              row['available'] is! bool ||
              !ToolDirectoryPermission.values.any(
                (permission) => permission.name == row['permission'],
              )) {
            throw const FormatException('Invalid tool directory status');
          }
          return ToolDirectory(
            row['id'] as String,
            row['name'] as String,
            row['path'] as String,
            row['available'] as bool,
            permission: ToolDirectoryPermission.values.byName(
              row['permission'] as String,
            ),
          );
        }),
      ),
      storageUnavailable: data['storageUnavailable'] as bool,
    );
  }
}

/// Owner settings only. No bookmark, path-based grant, or Agent endpoint.
abstract interface class ToolDirectoryAccess {
  Future<ToolDirectorySnapshot> read();
  Future<ToolDirectorySnapshot?> choose({
    String? replacing,
    ToolDirectoryPermission permission = ToolDirectoryPermission.readOnly,
  });
  Future<ToolDirectorySnapshot> forget(String id);
}

class NativeToolDirectoryAccess implements ToolDirectoryAccess {
  const NativeToolDirectoryAccess();
  static const _channel = MethodChannel('agent_info_manage/tool_directories');

  Future<ToolDirectorySnapshot?> _call(
    String method, [
    Object? arguments,
  ]) async {
    final value = await _channel.invokeMapMethod<Object?, Object?>(
      method,
      arguments,
    );
    return value == null ? null : ToolDirectorySnapshot.fromNative(value);
  }

  @override
  Future<ToolDirectorySnapshot> read() async =>
      await _call('read') ?? (throw const FormatException('Missing status'));
  @override
  Future<ToolDirectorySnapshot?> choose({
    String? replacing,
    ToolDirectoryPermission permission = ToolDirectoryPermission.readOnly,
  }) =>
      _call('choose', {'permission': permission.name, 'replacing': ?replacing});
  @override
  Future<ToolDirectorySnapshot> forget(String id) async =>
      await _call('forget', id) ??
      (throw const FormatException('Missing status'));
}
