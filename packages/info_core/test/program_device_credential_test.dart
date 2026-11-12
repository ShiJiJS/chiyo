import 'dart:convert';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';
import 'online_runtime_failure_test.dart' show FaultingServerRepository;

void main() {
  for (final receiver in CredentialLaunchPlan.programReceivers) {
    test(
      'server grants $receiver for foreign device, fixes binding and tracks correct cleanup',
      () async {
        final runtime = await OnlineInformationRuntime.open(
          repository: FaultingServerRepository(),
        );
        addTearDown(runtime.close);
        final s = runtime.service;
        final credential = await runtime.run(() async {
          final c = await s.owner.createStringCredential(
            name: 'Synthetic',
            publicPurpose: '',
            secret: 'synthetic-device-secret',
          );
          return s.owner.updateCredentialMetadata(
            c.id,
            c.revision,
            name: c.name,
            publicPurpose: '',
            privateNote: '',
            suggestedBinding: '',
            discoverable: true,
          );
        });
        final session = await runtime.run(
          () => s.agent.openSession('Synthetic program device'),
        );
        final raw = <String, dynamic>{
          'receiver': receiver,
          'executable': r'C:\device-only\tool.exe',
          'argv': [
            'task',
            if (receiver == 'program_file') {'file': 'secret'},
          ],
          'cwd': r'C:\device-only\work',
          'env': {
            if (receiver == 'program_env') 'TOKEN': {'secret': 'secret'},
          },
          if (receiver == 'program_stdin') 'stdin': {'secret': 'secret'},
        };
        DeviceCredentialLaunch prepared(
          CredentialLaunchPlan plan, {
          String? path,
        }) => DeviceCredentialLaunch.fromPrivateJson({
          'version': 1,
          'planHash': plan.planHash,
          'executable': {
            'path': path ?? plan.path,
            'byteLength': 123,
            'modifiedMicros': 456,
            'sha256': 'sha256:${'a' * 64}',
          },
          'cwd': plan.cwd,
        });
        const device = 'synthetic_device_12345';
        final input = CredentialUseInput.fromJson({
          'protocolVersion': 2,
          'command': 'request-use',
          'purpose': 'Synthetic server approved program',
          'credentials': [
            {
              'alias': 'secret',
              'credentialId': credential.id,
              'version': credential.version,
            },
          ],
          'launch': raw,
        }, allowPortableLaunchPaths: true);
        final request = await runtime.run(
          () => s.agent.requestDeviceCredentialUse(
            device,
            session,
            input,
            prepared(input.launch),
          ),
        );
        await runtime.run(
          () =>
              s.owner.decideCredentialUse(request.id, approveCredential: true),
        );
        CredentialOperationInput operation(
          String id,
          Map<String, dynamic> launch,
        ) => CredentialOperationInput.fromJson({
          'protocolVersion': 2,
          'command': 'run-use',
          'requestId': request.id,
          'operationId': id,
          'launch': launch,
        }, allowPortableLaunchPaths: true);
        final first = operation('first', raw);
        final claim = await runtime.run(
          () => s.agent.beginDeviceCredentialOperation(
            device,
            session,
            first,
            prepared(first.launch),
            'Local\\AgentInfoRuntime-${'a' * 32}',
          ),
        );
        final material = claim.material!;
        expect(
          material.credentialMaterial.stringValue,
          'synthetic-device-secret',
        );
        expect(
          material.materialLease,
          isNull,
        ); // Never create server plaintext files.
        expect(
          claim.execution.cleanupState,
          receiver == 'program_file' ? 'pending' : 'not_needed',
        );
        if (receiver == 'program_file') {
          await expectLater(
            runtime.run(
              () => s.agent.registerDeviceCredentialWorker(
                device,
                material.executionId,
                material.executionCapability,
                101,
                'device-process',
              ),
            ),
            throwsA(isA<CredentialUseFailure>()),
          );
          await runtime.run(
            () => s.agent.registerDeviceCredentialMaterials(
              device,
              material.executionId,
              material.executionCapability,
              CredentialMaterialLease.fromPrivateJson({
                'path': r'C:\private-device-material',
                'identity': 'private-identity',
                'files': {'credential.bin': 'file-identity'},
              }),
            ),
          );
        }
        await runtime.run(
          () => s.agent.registerDeviceCredentialWorker(
            device,
            material.executionId,
            material.executionCapability,
            101,
            'device-process',
          ),
        );
        final duplicate = await runtime.run(
          () => s.agent.beginDeviceCredentialOperation(
            device,
            session,
            first,
            prepared(first.launch),
            'Local\\AgentInfoRuntime-${'a' * 32}',
          ),
        );
        expect(duplicate.material, isNull);
        final changed = operation('changed-program', {
          ...raw,
          'executable': r'C:\other\tool.exe',
        });
        await expectLater(
          runtime.run(
            () => s.agent.beginDeviceCredentialOperation(
              device,
              session,
              changed,
              prepared(changed.launch),
              'Local\\AgentInfoRuntime-${'b' * 32}',
            ),
          ),
          throwsA(
            isA<CredentialUseFailure>().having(
              (e) => e.code,
              'code',
              'scope_not_approved',
            ),
          ),
        );
        expect(
          jsonEncode(
            s.owner.credentialExecutions.map((e) => e.toStorageJson()).toList(),
          ),
          isNot(contains('synthetic-device-secret')),
        );
      },
    );
  }
}
