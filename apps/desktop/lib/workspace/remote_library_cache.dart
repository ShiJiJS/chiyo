import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:info_remote/owner_client.dart';
import 'package:info_workspace/workspace_transport.dart';
import 'package:info_workspace/plugin_transport.dart';
import 'workspace_sync.dart';

/// One connection's memory-only owner projection. A failed page never changes
/// the published contents or cursor. Writes are never queued here.
class RemoteLibraryCache extends ChangeNotifier implements WorkspaceSync {
  RemoteLibraryCache(this.client, this.changed);
  final OwnerClient client;
  final void Function() changed;
  Map<String, dynamic>? resources;
  String? _cursor;
  @override
  DateTime? updatedAt;
  @override
  Object? failure;
  Future<void>? _running;
  bool _closed = false;
  @override
  bool get enabled => true;
  @override
  bool get needsReview => false;
  @override
  bool get busy => _running != null;
  @override
  Future<void> synchronize({bool requireFresh = false}) {
    if (_closed) return Future.value();
    if (_running != null) {
      if (requireFresh) return _running!.then((_) => synchronize());
      return _running!;
    }
    final completer = Completer<void>();
    _running = completer.future;
    notifyListeners();
    unawaited(() async {
      try {
        await _pull();
        if (!_closed) {
          failure = null;
          updatedAt = DateTime.now();
        }
        completer.complete();
      } catch (e, stack) {
        if (!_closed) {
          failure = e;
          if (e is RemoteFailure &&
              {'unauthorized', 'server_changed'}.contains(e.code)) {
            resources = null;
            _cursor = null;
          }
        }
        completer.completeError(e, stack);
      } finally {
        _running = null;
        if (!_closed) notifyListeners();
      }
    }());
    return completer.future;
  }

  Future<void> _pull() async {
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        var response = await client.request('POST', '/v1/owner/sync', {
          if (attempt == 0 && _cursor != null) 'after': _cursor,
        });
        final reset = response['reset'] as bool;
        final cursor = response['cursor'] as String;
        final nextResources = reset ? <String, dynamic>{} : {...?resources};
        var didChange = reset;
        var pages = 0;
        while (true) {
          if (++pages > 10000 ||
              response['cursor'] != cursor ||
              response['reset'] != reset) {
            throw const FormatException('Invalid sync page');
          }
          for (final id in response['deleted'] as List) {
            nextResources.remove(id as String);
            didChange = true;
          }
          final upserts = Map<String, dynamic>.from(response['upserts'] as Map);
          nextResources.addAll(upserts);
          didChange |= upserts.isNotEmpty;
          if (response['next'] == null) break;
          response = await client.request('POST', '/v1/owner/sync', {
            'next': response['next'],
          });
        }
        // Validate the entire new projection before publishing any of it.
        workspaceCatalogFromJson(
          (nextResources['catalog'] as Map)['workspace'],
        );
        pluginCatalogFromJson(nextResources['plugins']);
        for (final e in nextResources.entries.where(
          (e) => e.key.startsWith('record:'),
        )) {
          final detail = workspaceDetailFromJson(e.value);
          if (e.key !=
              'record:${detail.record.ref.kind.name}:${detail.record.ref.id}') {
            throw const FormatException('Mismatched sync identity');
          }
        }
        if (_closed) return;
        resources = nextResources;
        _cursor = cursor;
        if (didChange) changed();
        return;
      } on RemoteFailure catch (e) {
        if (e.code != 'sync_expired' || attempt != 0) rethrow;
      }
    }
  }

  @override
  void dispose() {
    _closed = true;
    resources = null;
    _cursor = null;
    super.dispose();
  }
}
