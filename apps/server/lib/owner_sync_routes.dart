import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:info_core/info_core.dart';
import 'package:info_core/server_state.dart';

/// Owner-only, bounded current-content deltas. Durable manifests contain only
/// hashes, not copies of bodies. Page continuations pin an immutable projection;
/// their loss explicitly requires a fresh pull, never a partial cache update.
class OwnerSyncRoutes {
  OwnerSyncRoutes(this.state, this.project);
  final ServerStateRepository state;
  final Future<Map<String, Object?>> Function() project;
  final _pages =
      <String, ({DateTime until, List<Map<String, Object?>> pages})>{};
  static const _historyLimit = 8;
  static const _pageBytes = 2 * 1024 * 1024;
  String _digest(Object? value) =>
      sha256.convert(utf8.encode(jsonEncode(value))).toString();

  Future<Map<String, Object?>> read(Map<String, dynamic> input) async {
    if (input.keys.any((k) => k != 'after' && k != 'next')) {
      throw const FormatException();
    }
    _pages.removeWhere((_, p) => p.until.isBefore(DateTime.now()));
    if (input['next'] != null) {
      if (input.length != 1 || input['next'] is! String)
        throw const FormatException();
      final saved = _pages.remove(input['next']);
      if (saved == null) throw const AccessFailure('sync_expired');
      final generation = (await state.openServerState()).generation;
      if (!(saved.pages.first['cursor'] as String).startsWith(
        '${_digest(generation).substring(0, 24)}:',
      )) {
        throw const AccessFailure('sync_expired');
      }
      return _page(saved.pages);
    }
    final after = input['after'];
    if (after != null && (after is! String || after.length > 128))
      throw const FormatException();
    final resources = await project();
    final hashes = {for (final e in resources.entries) e.key: _digest(e.value)};
    var snapshot = await state.openServerState();
    final raw = snapshot.payload['ownerSync'];
    var sequence = raw == null ? 0 : (raw as Map)['sequence'] as int;
    final history = raw == null
        ? <Map<String, dynamic>>[]
        : [
            for (final v in (raw as Map)['history'] as List)
              Map<String, dynamic>.from(v as Map),
          ];
    if (history.isEmpty || _digest(history.last['hashes']) != _digest(hashes)) {
      sequence++;
      final cursor =
          '${_digest(snapshot.generation).substring(0, 24)}:$sequence';
      history.add({'cursor': cursor, 'hashes': hashes});
      if (history.length > _historyLimit) history.removeAt(0);
      for (var attempt = 0; ; attempt++) {
        try {
          await state.commitServerState(snapshot, {
            ...snapshot.payload,
            'ownerSync': {'sequence': sequence, 'history': history},
          });
          break;
        } on AccessFailure catch (e) {
          if (e.status != 'server_state_changed' || attempt >= 7) rethrow;
          final fresh = await state.openServerState();
          if (fresh.generation != snapshot.generation)
            throw const AccessFailure('library_changed');
          snapshot = fresh;
        }
      }
    }
    final previous = history.where((h) => h['cursor'] == after).firstOrNull;
    final old = previous?['hashes'] as Map?;
    final removed = old == null
        ? <String>[]
        : [
            for (final key in old.keys)
              if (!hashes.containsKey(key)) key as String,
          ];
    final pages = <Map<String, Object?>>[];
    var upserts = <String, Object?>{};
    var size = 0;
    void finish() {
      pages.add({
        'cursor': history.last['cursor'],
        'reset': old == null,
        'upserts': upserts,
        'deleted': pages.isEmpty ? removed : <String>[],
      });
      upserts = {};
      size = 0;
    }

    for (final e in resources.entries) {
      if (old?[e.key] == hashes[e.key]) continue;
      final bytes = utf8.encode(jsonEncode(e.value)).length;
      if (size > 0 && size + bytes > _pageBytes) finish();
      upserts[e.key] = e.value;
      size += bytes;
    }
    finish();
    return _page(pages);
  }

  Map<String, Object?> _page(List<Map<String, Object?>> pages) {
    final result = pages.first;
    if (pages.length == 1) return result;
    if (_pages.length >= 4) throw const AccessFailure('sync_busy');
    final token = base64Url.encode(
      List.generate(32, (_) => Random.secure().nextInt(256)),
    );
    _pages[token] = (
      until: DateTime.now().add(const Duration(minutes: 3)),
      pages: pages.skip(1).toList(),
    );
    return {...result, 'next': token};
  }
}
