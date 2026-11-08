import 'package:info_core/info_core.dart';
import 'package:info_core/server_state.dart';
import 'package:test/test.dart';

/// Fault injection at the private commit boundary. Encrypted persistence is
/// separately covered by info_storage's reopen/restore tests.
class FaultingServerRepository extends MemoryInformationRepository
    implements ServerStateRepository {
  FaultingServerRepository() : super([]);
  var snapshot = ServerStateSnapshot(
    generation: 'g' * 43,
    revision: 0,
    payload: {},
  );
  bool failCommit = false, concurrentCommit = false;
  @override
  Future<ServerStateSnapshot> openServerState() async => snapshot;
  @override
  Future<ServerStateSnapshot> commitServerState(
    ServerStateSnapshot expected,
    Map<String, Object?> payload,
  ) async {
    if (failCommit) throw StateError('Synthetic unavailable state storage');
    if (concurrentCommit) {
      concurrentCommit = false;
      snapshot = ServerStateSnapshot(
        generation: snapshot.generation,
        revision: snapshot.revision + 1,
        payload: {
          ...snapshot.payload,
          'externalNamespace': {'written': true},
        },
      );
    }
    if (expected.generation != snapshot.generation ||
        expected.revision != snapshot.revision) {
      throw const AccessFailure('server_state_changed');
    }
    return snapshot = ServerStateSnapshot(
      generation: snapshot.generation,
      revision: snapshot.revision + 1,
      payload: payload,
    );
  }
}

void main() {
  test(
    'a failed private commit withholds a read and blocks later commands',
    () async {
      final repo = FaultingServerRepository();
      final runtime = await OnlineInformationRuntime.open(repository: repo);
      addTearDown(runtime.close);
      final service = runtime.service;
      final item = await runtime.run(
        () => service.owner.createInformation('Synthetic', '', [
          const FieldInput('Body', '', 'PRIVATE_SYNTHETIC'),
        ]),
      );
      final session = await runtime.run(
        () => service.agent.openSession('Synthetic chat'),
      );
      final request = await runtime.run(
        () => service.agent.request(session, 'Synthetic read', [
          FieldRef(item.id, item.fields.single.id),
        ]),
      );
      await runtime.run(
        () => service.owner.decideInformationRequest(
          InformationApprovalCommand(
            operationId: 'approval',
            requestId: request.id,
            action: InformationApprovalAction.approve,
            reviewToken: 'a' * 64,
            commandDigest: 'b' * 64,
            fields: [FieldRef(item.id, item.fields.single.id)],
            itemVersions: {item.id: item.version},
          ),
        ),
      );
      final grant = await runtime.run(
        () => service.agent.claim(session, request.id),
      );
      final reading = runtime.run(() async {
        final value = await service.agent.read(
          grant.token,
          FieldRef(item.id, item.fields.single.id),
        );
        repo.failCommit = true;
        return value;
      });
      await expectLater(reading, throwsStateError);
      var executed = false;
      await expectLater(
        runtime.run(() {
          executed = true;
          return service.agent.catalog();
        }),
        throwsA(
          isA<AccessFailure>().having(
            (e) => e.status,
            'status',
            'service_unavailable',
          ),
        ),
      );
      expect(executed, isFalse);
    },
  );

  test('CAS retry preserves concurrent device namespace changes', () async {
    final repo = FaultingServerRepository();
    final runtime = await OnlineInformationRuntime.open(repository: repo);
    addTearDown(runtime.close);
    repo.concurrentCommit = true;
    final session = await runtime.run(
      () => runtime.service.agent.openSession('Synthetic CAS'),
    );
    expect(repo.snapshot.payload['externalNamespace'], {'written': true});
    final textRuntime = repo.snapshot.payload['textRuntime'] as Map;
    expect((textRuntime['sessions'] as List).single['secret'], session);
  });
}
