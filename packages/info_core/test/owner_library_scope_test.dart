import 'dart:async';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() {
  late InformationService service;
  setUp(
    () => service = InformationService(
      repository: MemoryInformationRepository([]),
    ),
  );
  tearDown(() => service.close());
  final changed = isA<AccessFailure>().having(
    (e) => e.status,
    'status',
    'library_changed',
  );
  Future<InformationItem> create(OwnerAccess owner) => owner.createInformation(
    '合成资料',
    '',
    [const FieldInput('字段', '', 'synthetic')],
  );

  test('delayed form cannot write after successful restore', () async {
    final scope = service.owner.captureLibraryScope();
    final ready = Completer<void>(), proceed = Completer<void>();
    final result = service.owner.inLibraryScope(scope, () async {
      ready.complete();
      await proceed.future;
      return create(service.owner);
    });
    final rejected = expectLater(result, throwsA(changed));
    await ready.future;
    await service.owner.restoreLibrary(() async {});
    proceed.complete();
    await rejected;
    expect(service.owner.information, isEmpty);
    expect(scope.isCurrent, isFalse);
    await service.owner.inLibraryScope(
      service.owner.captureLibraryScope(),
      () => create(service.owner),
    );
    expect(service.owner.information, hasLength(1));
  });

  test(
    'already queued write rechecks scope behind restore on same queue',
    () async {
      final scope = service.owner.captureLibraryScope();
      final entered = Completer<void>(), release = Completer<void>();
      final restore = service.owner.restoreLibrary(() async {
        entered.complete();
        await release.future;
      });
      await entered.future;
      final result = service.owner.inLibraryScope(
        scope,
        () => create(service.owner),
      );
      final rejected = expectLater(result, throwsA(changed));
      release.complete();
      await restore;
      await rejected;
      expect(service.owner.information, isEmpty);
    },
  );

  test(
    'failed restore and export preserve binding; another service cannot use it',
    () async {
      final scope = service.owner.captureLibraryScope();
      await expectLater(
        service.owner.restoreLibrary(() async => throw StateError('synthetic')),
        throwsStateError,
      );
      await service.owner.exportLibrary(() async {});
      expect(scope.isCurrent, isTrue);
      await service.owner.inLibraryScope(scope, () => create(service.owner));
      final other = InformationService(
        repository: MemoryInformationRepository([]),
      );
      addTearDown(other.close);
      await expectLater(
        other.owner.inLibraryScope(scope, () => create(other.owner)),
        throwsA(changed),
      );
      // A nested call cannot silently redirect a bound operation to another owner.
      await expectLater(
        service.owner.inLibraryScope(scope, () => create(other.owner)),
        throwsA(changed),
      );
      expect(other.owner.information, isEmpty);
    },
  );

  test('late read results and closed owner scopes cannot be reused', () async {
    final scope = service.owner.captureLibraryScope();
    final delayed = Completer<String>();
    final result = service.owner.inLibraryScope(scope, () => delayed.future);
    final rejected = expectLater(result, throwsA(changed));
    await service.owner.restoreLibrary(() async {});
    delayed.complete('old body');
    await rejected;
    final current = service.owner.captureLibraryScope();
    await service.close();
    expect(current.isCurrent, isFalse);
    await expectLater(
      service.owner.inLibraryScope(current, () async => 'body'),
      throwsA(changed),
    );
  });
}
