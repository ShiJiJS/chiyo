import 'dart:async';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

class _DelayedStorage extends MemoryInformationRepository {
  Completer<void>? hold;
  bool fail = false;
  @override
  Future<void> saveAccessRecord(AccessRecord record) async {
    await hold?.future;
    if (fail) throw StateError('fictional unavailable storage');
    await super.saveAccessRecord(record);
  }
}

void main() {
  for (final transition in ['none', 'end', 'revoke', 'expire']) {
    test(
      'export retains normal in-flight delivery and respects $transition while its snapshot is pending',
      () async {
        var now = DateTime.utc(2026, 10, 16);
        final repository = _DelayedStorage();
        final service = InformationService(
          repository: repository,
          clock: () => now,
        );
        final item = await service.owner.createInformation('Source', '', [
          const FieldInput('Value', '', 'private'),
        ]);
        final field = FieldRef(item.id, item.fields.single.id);
        final session = service.agent.openSession('chat');
        final request = service.agent.request(session, 'read', [field]);
        service.owner.approve(request.id, [
          field,
        ], lifetime: const Duration(minutes: 1));
        final token = service.agent.claim(session, request.id).token;
        repository.hold = Completer<void>();
        final read = service.agent.read(token, field);
        final entered = Completer<void>();
        final finish = Completer<void>();
        final export = service.owner.exportLibrary(() async {
          entered.complete();
          await finish.future;
        });
        await Future<void>.delayed(Duration.zero);
        repository.hold!.complete();
        expect(await read, 'private');
        await entered.future;
        switch (transition) {
          case 'end':
            service.agent.endSession(session);
          case 'revoke':
            service.owner.revoke(request.id);
          case 'expire':
            now = now.add(const Duration(minutes: 2));
        }
        if (transition == 'none') {
          expect(await service.agent.read(token, field), 'private');
        } else {
          await expectLater(
            service.agent.read(token, field),
            throwsA(isA<AccessFailure>()),
          );
        }
        finish.complete();
        await export;
        if (transition == 'none') {
          expect(await service.agent.read(token, field), 'private');
        }
        await service.close();
      },
    );
  }

  test(
    'owner restore waits for in-flight denials and discards every prior session capability only after success',
    () async {
      final repository = _DelayedStorage();
      final service = InformationService(repository: repository);
      final item = await service.owner.createInformation('Source', '', [
        const FieldInput('Value', '', 'private'),
      ]);
      final field = FieldRef(item.id, item.fields.single.id);
      final session = service.agent.openSessionWithEndCapability(
        'pre-restore chat',
      );
      final request = service.agent.request(session.sessionSecret, 'read', [
        field,
      ]);
      service.owner.approve(request.id, [field]);
      final token = service.agent
          .claim(session.sessionSecret, request.id)
          .token;
      repository.hold = Completer<void>();
      final read = service.agent.read(token, field);
      final denied = expectLater(read, throwsA(isA<AccessFailure>()));
      final entered = Completer<void>();
      final finish = Completer<void>();
      final restoring = service.owner.restoreLibrary(() async {
        expect(
          repository.accessRecords.single.outcome,
          AccessOutcome.unauthorized,
        );
        entered.complete();
        await finish.future;
      });
      await Future<void>.delayed(Duration.zero);
      expect(entered.isCompleted, isFalse);
      repository.hold!.complete();
      await entered.future;
      await denied;
      final temporarilyUnavailable = throwsA(
        isA<AccessFailure>().having(
          (e) => e.status,
          'status',
          'service_unavailable',
        ),
      );
      expect(
        () => service.agent.request(session.sessionSecret, 'during restore', [
          field,
        ]),
        temporarilyUnavailable,
      );
      expect(
        () => service.agent.status(session.sessionSecret, request.id),
        temporarilyUnavailable,
      );
      expect(
        () => service.agent.openSession('during restore'),
        throwsA(isA<AccessFailure>()),
      );
      expect(
        () => service.owner.approve(request.id, [field]),
        throwsA(isA<AccessFailure>()),
      );
      finish.complete();
      await restoring;
      expect(service.owner.requests, isEmpty);
      expect(
        () => service.agent.validateSession(session.sessionSecret),
        throwsA(isA<AccessFailure>()),
      );
      expect(
        () => service.agent.endSessionWithCapability(session.endCapability),
        throwsA(isA<AccessFailure>()),
      );
      await expectLater(
        service.agent.read(token, field),
        throwsA(isA<AccessFailure>()),
      );
      final fresh = service.agent.openSession('new chat');
      final freshRequest = service.agent.request(fresh, 'read again', [field]);
      service.owner.approve(freshRequest.id, [field]);
      expect(
        await service.agent.read(
          service.agent.claim(fresh, freshRequest.id).token,
          field,
        ),
        'private',
      );
      await service.close();
    },
  );

  test(
    'failed restore and audit failure preserve old permissions and queued evidence',
    () async {
      final repository = _DelayedStorage();
      final service = InformationService(repository: repository);
      final item = await service.owner.createInformation('Source', '', [
        const FieldInput('Value', '', 'private'),
      ]);
      final field = FieldRef(item.id, item.fields.single.id);
      final session = service.agent.openSession('chat');
      final request = service.agent.request(session, 'read', [field]);
      service.owner.approve(request.id, [field]);
      final token = service.agent.claim(session, request.id).token;
      await expectLater(
        service.owner.restoreLibrary(() async {
          throw StateError('recipient not empty');
        }),
        throwsStateError,
      );
      expect(await service.agent.read(token, field), 'private');
      repository.fail = true;
      await expectLater(
        service.agent.read(token, field),
        throwsA(isA<AccessFailure>()),
      );
      var called = false;
      await expectLater(
        service.owner.restoreLibrary(() async {
          called = true;
        }),
        throwsA(isA<AccessFailure>()),
      );
      expect(called, isFalse);
      repository.fail = false;
      await service.owner.retryAuditStorage();
      expect(
        (await service.owner.history()).accesses.last.outcome,
        AccessOutcome.auditUnavailable,
      );
      expect(await service.agent.read(token, field), 'private');
      await service.close();
    },
  );

  test(
    'export is ordered after owner edits and queued approval history',
    () async {
      final repository = MemoryInformationRepository();
      final service = InformationService(repository: repository);
      final item = await service.owner.createInformation('Source', '', [
        const FieldInput('Value', '', 'old'),
      ]);
      final field = FieldRef(item.id, item.fields.single.id);
      final session = service.agent.openSession('chat');
      final request = service.agent.request(session, 'read', [field]);
      service.owner.approve(request.id, [field]);
      final edited = service.owner.correctValue(field, 'corrected.invalid');
      await service.owner.exportLibrary(() async {
        expect(
          service.owner.information.first.fields.first.value,
          'corrected.invalid',
        );
        expect(service.owner.auditStorageUnavailable, isFalse);
        expect(repository.grantHistory.single.active, isTrue);
      });
      await edited;
      expect((await service.owner.history()).grants.single.active, isTrue);
      await service.close();
    },
  );

  test(
    'owner edits queued behind successful restore cannot modify the new library',
    () async {
      final service = InformationService.fictional();
      final entered = Completer<void>();
      final finish = Completer<void>();
      final restore = service.owner.restoreLibrary(() async {
        entered.complete();
        await finish.future;
      });
      final edit = service.owner.correctValue(
        const FieldRef('demo-server', 'host'),
        'stale edit',
      );
      final denied = expectLater(
        edit,
        throwsA(
          isA<AccessFailure>().having(
            (e) => e.status,
            'status',
            'library_changed',
          ),
        ),
      );
      await entered.future;
      final quitting = service.close();
      finish.complete();
      await restore;
      await denied;
      await quitting;
      expect(
        service.owner.information.first.fields.first.value,
        'demo.example.invalid',
      );
      expect(
        () => service.agent.openSession('after close'),
        throwsA(isA<AccessFailure>()),
      );
    },
  );
}
