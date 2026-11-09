import 'package:info_core/info_core.dart';
import 'package:info_core/server_state.dart';
import 'package:info_server/owner_sync_routes.dart';
import 'package:test/test.dart';

class StateStore implements ServerStateRepository {
  var saved = ServerStateSnapshot(
    generation: 'g' * 43,
    revision: 0,
    payload: {},
  );
  int writes = 0;
  bool fail = false;
  @override
  Future<ServerStateSnapshot> openServerState() async => saved;
  @override
  Future<ServerStateSnapshot> commitServerState(
    ServerStateSnapshot expected,
    Map<String, Object?> payload,
  ) async {
    if (fail) throw StateError('Synthetic write failure');
    if (expected.revision != saved.revision)
      throw const AccessFailure('server_state_changed');
    writes++;
    return saved = ServerStateSnapshot(
      generation: saved.generation,
      revision: saved.revision + 1,
      payload: payload,
    );
  }
}

void main() {
  test(
    'no-change writes nothing; deltas include deletion and survive host restart',
    () async {
      final state = StateStore();
      var data = <String, Object?>{'a': 'first', 'b': 'second'};
      var route = OwnerSyncRoutes(state, () async => {...data});
      final first = await route.read({});
      expect(first['reset'], true);
      final cursor = first['cursor'];
      final writes = state.writes;
      final same = await route.read({'after': cursor});
      expect(same['upserts'], isEmpty);
      expect(state.writes, writes);
      data = {'a': 'revised', 'c': 'new'};
      route = OwnerSyncRoutes(state, () async => {...data});
      final next = await route.read({'after': cursor});
      expect(next['reset'], false);
      expect(next['deleted'], ['b']);
      expect(next['upserts'], data);
      expect(next['cursor'], isNot(cursor));
      expect(state.saved.payload.toString(), isNot(contains('revised')));
      final snapshot = state.saved;
      state.saved = ServerStateSnapshot(
        generation: 'n' * 43,
        revision: 0,
        payload: {},
      );
      expect((await route.read({'after': next['cursor']}))['reset'], true);
      expect(state.saved.generation, isNot(snapshot.generation));
    },
  );
  test(
    'pages are frozen across concurrent saves; lost pages cannot continue',
    () async {
      final state = StateStore();
      var data = <String, Object?>{'a': 'a' * 1500000, 'b': 'b' * 1500000};
      final route = OwnerSyncRoutes(state, () async => {...data});
      final first = await route.read({});
      expect((first['upserts'] as Map).keys, ['a']);
      data = {'c': 'new'};
      final last = await route.read({'next': first['next']});
      expect((last['upserts'] as Map).keys, ['b']);
      expect(last['cursor'], first['cursor']);
      final next = await route.read({'after': last['cursor']});
      expect(next['deleted'], ['a', 'b']);
      expect(next['upserts'], data);
      await expectLater(
        route.read({'next': first['next']}),
        throwsA(isA<AccessFailure>()),
      );
    },
  );
  test(
    'expired cursor rebuilds; failed manifest write cannot advance update',
    () async {
      final state = StateStore();
      var value = 0;
      final route = OwnerSyncRoutes(state, () async => {'a': value});
      final first = await route.read({});
      for (var i = 1; i < 10; i++) {
        value = i;
        await route.read({});
      }
      expect((await route.read({'after': first['cursor']}))['reset'], true);
      final revision = state.saved.revision;
      value++;
      state.fail = true;
      await expectLater(route.read({}), throwsStateError);
      expect(state.saved.revision, revision);
    },
  );
}
