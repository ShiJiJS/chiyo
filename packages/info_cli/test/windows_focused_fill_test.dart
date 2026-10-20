import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:info_cli/windows_focused_fill.dart';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

class _Repository extends MemoryInformationRepository {
  int materialReads = 0;
  @override
  List<CredentialMaterial> get credentialMaterials {
    materialReads++;
    return super.credentialMaterials;
  }
}

Future<FocusedFillApplication> _identity(String path) async =>
    FocusedFillApplication.fromJson({
      'executable': await File(path).resolveSymbolicLinks(),
      'sha256': (await sha256.bind(File(path).openRead()).first).toString(),
    });
void main() {
  final folder = Platform.environment['ISSUE35_NATIVE_FAULTS'];
  final skipped = folder == null || !Platform.isWindows;
  Future<(_Repository, InformationService, String, CredentialUseRequest)>
  fixture(String name) async {
    final helper = await _identity('$folder/focus_${name}_stub.exe');
    final repo = _Repository();
    final service = InformationService(
      repository: repo,
      focusedFillDriver: WindowsFocusedFillDriver(
        helper: helper,
        timeout: const Duration(milliseconds: 250),
      ),
    );
    addTearDown(service.close);
    var c = await service.owner.createStringCredential(
      name: 'Synthetic fault test',
      publicPurpose: '',
      secret: 'SYNTHETIC_NATIVE_FAULT_ONLY',
    );
    c = await service.owner.updateCredentialMetadata(
      c.id,
      c.revision,
      name: c.name,
      publicPurpose: '',
      privateNote: '',
      suggestedBinding: '',
      discoverable: true,
    );
    final session = service.agent.openSession('Synthetic native fault');
    final request = await service.agent.requestFocusedFill(
      session,
      FocusedFillInput.fromJson({
        'protocolVersion': 2,
        'command': 'request-use',
        'purpose': 'Synthetic process fault',
        'credentials': [
          {'alias': 'password', 'credentialId': c.id, 'version': 1},
        ],
        'fill': {
          'application': helper.toJson(),
          'targetHint': 'Test receiver, no real input',
        },
      }),
    );
    await service.owner.decideCredentialUse(
      request.id,
      approveCredential: true,
    );
    repo.materialReads = 0;
    return (repo, service, session, request);
  }

  FocusedFillOperationInput input(String request, String op) =>
      FocusedFillOperationInput.fromJson({
        'protocolVersion': 2,
        'command': 'fill-use',
        'requestId': request,
        'operationId': op,
      });
  test(
    'actual hung helper times out before reading material and close drains',
    () async {
      final (repo, service, session, request) = await fixture('stall');
      final watch = Stopwatch()..start();
      await service.agent.startFocusedFill(session, input(request.id, 'hung'));
      await service.drainFocusedFills().timeout(const Duration(seconds: 4));
      expect(watch.elapsed, lessThan(const Duration(seconds: 4)));
      expect(repo.materialReads, 0);
      expect(
        service.owner.focusedFillOperations.single.state,
        FocusedFillState.refused,
      );
      await service.close();
      await service.close();
    },
    skip: skipped,
  );
  test(
    'actual helper lost acknowledgement remains unknown and is not replayed',
    () async {
      final (repo, service, session, request) = await fixture('drop');
      final command = input(request.id, 'lost');
      await service.agent.startFocusedFill(session, command);
      await service.drainFocusedFills();
      final op = service.owner.focusedFillOperations.single;
      expect(repo.materialReads, greaterThan(0));
      expect(op.inputReleased, true);
      expect(op.state, FocusedFillState.unknown);
      final repeated = await service.agent.startFocusedFill(session, command);
      expect(repeated['duplicate'], true);
      expect(repeated['fillState'], 'unknown');
      await expectLater(
        service.agent.startFocusedFill(
          session,
          input(request.id, 'not-reviewed'),
        ),
        throwsA(
          isA<CredentialUseFailure>().having(
            (e) => e.code,
            'code',
            'fill_needs_attention',
          ),
        ),
      );
      expect(service.owner.focusedFillOperations, hasLength(1));
    },
    skip: skipped,
  );
  test(
    'actual malformed native response is refused before material is read',
    () async {
      final (repo, service, session, request) = await fixture('malformed');
      await service.agent.startFocusedFill(
        session,
        input(request.id, 'malformed'),
      );
      await service.drainFocusedFills();
      expect(repo.materialReads, 0);
      expect(
        service.owner.focusedFillOperations.single.state,
        FocusedFillState.refused,
      );
    },
    skip: skipped,
  );
  test(
    'actual final refusal is read from stdout before process exit is treated as lost reply',
    () async {
      final helper = await _identity('$folder/focus_refusal_stub.exe');
      final driver = WindowsFocusedFillDriver(helper: helper);
      for (var i = 0; i < 3; i++) {
        final result = await driver.inspectTarget();
        expect(result.errorCode, 'desktop_locked');
        expect(result.application, isNull);
      }
    },
    skip: skipped,
  );
}
