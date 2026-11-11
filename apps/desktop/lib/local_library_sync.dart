import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:info_core/info_core.dart';
import 'package:info_core/library_replication.dart';
import 'package:info_remote/connection_profile.dart';
import 'package:info_remote/library_replication_client.dart';
import 'package:info_remote/local_library_configuration.dart';
import 'package:info_remote/owner_client.dart';
import 'package:info_remote/private_connection_files.dart';
import 'package:info_storage/info_storage.dart';

/// Owner-private pending transfer, protected like connection configuration.
/// Keeping its exact manifest/key allows process-restart reconciliation without
/// exporting a new snapshot or replacing the original operation.
final class LocalLibrarySync {
  LocalLibrarySync({
    required this.configuration,
    required this.owner,
    required this.replication,
  });
  final LocalLibraryConfiguration configuration;
  final OwnerAccess owner;
  final LibraryReplication replication;
  bool _busy = false;
  File get _configuration =>
      File('${configuration.directory}/library-sync.json');
  Directory get _staging =>
      Directory('${configuration.directory}/replication-staging');

  Future<Map<String, dynamic>> readConfiguration() async {
    final stored = await PrivateConnectionFiles.read(_configuration);
    if (stored == null) {
      return {
        'version': 1,
        'localLibraryId': configuration.libraryId,
        'enabled': false,
        'server': null,
        'pending': null,
      };
    }
    if (stored['version'] != 1 ||
        stored['localLibraryId'] != configuration.libraryId ||
        stored['enabled'] is! bool ||
        !stored.containsKey('pending')) {
      throw const RemoteFailure('invalid_sync_configuration');
    }
    return stored;
  }

  Future<void> disable() async {
    if (_busy) throw const RemoteFailure('sync_busy');
    final stored = await readConfiguration();
    await PrivateConnectionFiles.write(_configuration, {
      ...stored,
      'enabled': false,
    });
  }

  String _id() => base64Url
      .encode(List.generate(24, (_) => Random.secure().nextInt(256)))
      .replaceAll('=', '');
  File _file(String id) =>
      File('${_staging.path}/${libraryReplicaId(id)}/content.encrypted');

  bool _sameServer(ConnectionProfile a, ConnectionProfile b) =>
      a.address == b.address &&
      a.serverId == b.serverId &&
      a.certificate == b.certificate;

  Future<void> _removePendingFile(Map<String, dynamic> pending) async {
    final file = _file(libraryReplicaId(pending['fileId']));
    if (await FileSystemEntity.type(file.parent.path, followLinks: false) ==
        FileSystemEntityType.directory) {
      await file.parent.delete(recursive: true);
    }
  }

  Future<void> _cleanupUnusedStaging(Map<String, dynamic> stored) async {
    final type = await FileSystemEntity.type(_staging.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return;
    if (type != FileSystemEntityType.directory) {
      throw const RemoteFailure('invalid_sync_file');
    }
    final pending = stored['pending'] as Map?;
    final retained = pending == null
        ? null
        : libraryReplicaId(pending['fileId']);
    await for (final entity in _staging.list(followLinks: false)) {
      final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (name == retained || !RegExp(r'^[A-Za-z0-9_-]{32}$').hasMatch(name)) {
        continue;
      }
      if (await FileSystemEntity.type(entity.path, followLinks: false) ==
          FileSystemEntityType.directory) {
        await entity.delete(recursive: true);
      }
    }
  }

  Future<void> _settleStaging(Map<String, dynamic> pending) async {
    try {
      await _removePendingFile(pending);
    } on FileSystemException {
      /* Encrypted leftovers are swept before a new transfer. */
    }
  }

  /// Finish only a locally committed pull; requires no NAS connection. This
  /// repairs the crash window between SQL admission and publishing local mode.
  Future<bool> recoverCompletedLocalCopy(ConnectionProfile server) async {
    final stored = await readConfiguration();
    final local = await replication.identity();
    final raw = stored['pending'];
    if (raw == null) {
      if (stored['server'] == null || stored['initialSnapshotId'] is! String) {
        return false;
      }
      return _sameServer(
            ConnectionProfile.fromJson(
              Map<String, dynamic>.from(stored['server'] as Map),
            ),
            server,
          ) &&
          stored['libraryId'] == local.libraryId &&
          stored['localReplicaId'] == local.replicaId;
    }
    final pending = Map<String, dynamic>.from(raw as Map);
    if (pending['direction'] != 'pull' ||
        pending['transfer'] == null ||
        pending['localReplicaId'] != local.replicaId ||
        !_sameServer(
          ConnectionProfile.fromJson(
            Map<String, dynamic>.from(pending['server'] as Map),
          ),
          server,
        )) {
      return false;
    }
    final transfer = LibraryInitialTransfer.fromJson(
      Map<String, dynamic>.from(pending['transfer'] as Map),
    );
    final receipt = await replication.receipt(
      replicaOperationId(pending['operationId']),
      transfer,
    );
    if (receipt == null ||
        receipt.identity.replicaId != local.replicaId ||
        receipt.identity.libraryId != local.libraryId) {
      return false;
    }
    await PrivateConnectionFiles.write(_configuration, {
      ...stored,
      'pending': null,
      'enabled': pending['enabledAfterCompletion'] == true,
      'server': server.toJson(),
      'libraryId': local.libraryId,
      'localReplicaId': local.replicaId,
      'remoteReplicaId': pending['remoteReplicaId'],
      'initialSnapshotId': transfer.snapshotId,
    });
    await _settleStaging(pending);
    return true;
  }

  Future<LibraryReplicaIdentity> connect(
    ConnectionProfile profile, {
    bool enabled = true,
    OwnerClient? connection,
    void Function(int completed, int total)? progress,
  }) async {
    if (_busy) throw const RemoteFailure('sync_busy');
    _busy = true;
    OwnerClient? opened;
    try {
      var stored = await readConfiguration();
      await _cleanupUnusedStaging(stored);
      final client =
          connection ??
          (opened = await OwnerClient.connect(
            address: Uri.parse(profile.address),
            token: profile.token,
            expectedServerId: profile.serverId.isEmpty
                ? null
                : profile.serverId,
            trust: profile.certificate.isEmpty
                ? null
                : (SecurityContext(withTrustedRoots: false)
                    ..setTrustedCertificatesBytes(
                      utf8.encode(profile.certificate),
                    )),
          ));
      if (client.serverId != profile.serverId && profile.serverId.isNotEmpty ||
          client.address.toString() != Uri.parse(profile.address).toString()) {
        throw const RemoteFailure('server_changed');
      }
      final confirmedProfile = ConnectionProfile(
        address: client.address.toString(),
        token: profile.token,
        serverId: client.serverId,
        certificate: profile.certificate,
      );
      final remote = LibraryReplicationClient(client);
      final peer = await remote.status();
      var local = await replication.identity();
      var pending = stored['pending'] == null
          ? null
          : Map<String, dynamic>.from(stored['pending'] as Map);
      if (pending != null) {
        final priorProfile = ConnectionProfile.fromJson(
          Map<String, dynamic>.from(pending['server'] as Map),
        );
        if (!_sameServer(priorProfile, confirmedProfile) ||
            pending['localReplicaId'] != local.replicaId) {
          throw const RemoteFailure('sync_pending_other_library');
        }
      } else {
        final localEmpty = await replication.empty();
        if (!localEmpty && !peer.empty) {
          if (local.libraryId != peer.identity.libraryId) {
            throw const RemoteFailure('different_libraries');
          }
          // Only the initial link is already present. Incremental work uses the
          // saved common base in #131; no whole-library replacement is allowed.
          await PrivateConnectionFiles.write(_configuration, {
            ...stored,
            'enabled': enabled,
            'server': confirmedProfile.toJson(),
            'libraryId': local.libraryId,
            'localReplicaId': local.replicaId,
            'remoteReplicaId': peer.identity.replicaId,
          });
          return local;
        }
        pending = {
          'direction': peer.empty ? 'push' : 'pull',
          'operationId': _id(),
          'fileId': _id(),
          'localReplicaId': local.replicaId,
          'remoteReplicaId': peer.identity.replicaId,
          'enabledAfterCompletion': enabled,
          'server': confirmedProfile.toJson(),
          'transfer': null,
          'transferKey': null,
        };
        stored = {...stored, 'pending': pending};
        await PrivateConnectionFiles.write(_configuration, stored);
      }
      if (pending['transfer'] == null) {
        final file = _file(libraryReplicaId(pending['fileId']));
        await file.parent.create(recursive: true);
        LibraryInitialTransfer manifest;
        String key;
        if (pending['direction'] == 'push') {
          // No upload starts until the prepared key and manifest commit. A
          // crashed preparation may leave only an unusable encrypted file.
          if (await file.exists()) await file.delete();
          final prepared = await owner.exportLibrary(
            () => replication.exportInitial(file.path),
          );
          manifest = prepared.transfer;
          key = prepared.transferKey;
        } else {
          final prepared = await remote.prepareExport(
            replicaOperationId(pending['operationId']),
          );
          manifest = prepared.transfer;
          key = prepared.transferKey;
        }
        pending = {
          ...pending,
          'transfer': manifest.toJson(),
          'transferKey': key,
        };
        stored = {...stored, 'pending': pending};
        await PrivateConnectionFiles.write(_configuration, stored);
      }
      var transfer = LibraryInitialTransfer.fromJson(
        Map<String, dynamic>.from(pending['transfer'] as Map),
      );
      final operation = replicaOperationId(pending['operationId']);
      final file = _file(libraryReplicaId(pending['fileId']));
      var key = pending['transferKey'] as String;
      if (pending['direction'] == 'push') {
        final receipt = await remote.upload(
          file: file,
          transfer: transfer,
          transferKey: key,
          operationId: operation,
          progress: progress,
        );
        if (receipt.identity.replicaId != peer.identity.replicaId) {
          throw const RemoteFailure('server_changed');
        }
      } else if (pending['direction'] == 'pull') {
        final known = await replication.receipt(operation, transfer);
        if (known == null) {
          // Reuse the immutable export while retained. If the service itself
          // restarted, only an empty, still-uncommitted target may start a fresh
          // snapshot of that same logical library.
          final prepared = await remote.prepareExport(operation);
          if (jsonEncode(prepared.transfer.toJson()) !=
                  jsonEncode(transfer.toJson()) ||
              prepared.transferKey != key) {
            if (!await replication.empty() ||
                prepared.transfer.libraryId != transfer.libraryId) {
              throw const RemoteFailure('sync_pending_other_library');
            }
            if (await file.exists()) await file.delete();
            transfer = prepared.transfer;
            key = prepared.transferKey;
            pending = {
              ...pending,
              'transfer': transfer.toJson(),
              'transferKey': key,
            };
            stored = {...stored, 'pending': pending};
            await PrivateConnectionFiles.write(_configuration, stored);
          }
          await remote.download(prepared, file, progress: progress);
          await owner.restoreLibraryOnce(
            previous: () => replication.receipt(operation, transfer),
            restore: () => replication.installInitial(
              path: file.path,
              transferKey: key,
              operationId: operation,
              transfer: transfer,
            ),
          );
          await remote.release(prepared);
        }
        local = await replication.identity();
      } else {
        throw const RemoteFailure('invalid_sync_configuration');
      }
      await PrivateConnectionFiles.write(_configuration, {
        ...stored,
        'pending': null,
        'enabled': enabled,
        'server': confirmedProfile.toJson(),
        'libraryId': local.libraryId,
        'localReplicaId': local.replicaId,
        'remoteReplicaId': peer.identity.replicaId,
        'initialSnapshotId': transfer.snapshotId,
      });
      await _settleStaging(pending);
      return local;
    } finally {
      opened?.close();
      _busy = false;
    }
  }
}
