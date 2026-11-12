import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() {
  Map<String, dynamic> plan(String receiver) => {
    'receiver': receiver,
    'executable': Platform.resolvedExecutable,
    'argv': [
      'child.dart',
      if (receiver == 'program_file') {'file': 'token'},
    ],
    'cwd': Directory.current.path,
    'env': {
      if (receiver == 'program_env') 'TOKEN': {'secret': 'token'},
    },
    if (receiver == 'program_stdin') 'stdin': {'secret': 'token'},
  };
  test(
    'program receivers explicitly reject v1 and omitted legacy protocol',
    () {
      for (final receiver in CredentialLaunchPlan.programReceivers) {
        for (final version in [null, 1]) {
          expect(
            () => CredentialUseInput.fromJson({
              'protocolVersion': ?version,
              'command': 'request-use',
              'purpose': 'Synthetic legacy rejection',
              'credentials': [
                {'alias': 'token', 'credentialId': 'test', 'version': 1},
              ],
              'launch': plan(receiver),
            }),
            throwsA(
              isA<CredentialUseFailure>().having(
                (e) => e.code,
                'code',
                'unsupported_protocol',
              ),
            ),
          );
        }
      }
    },
  );
  test(
    'program snapshots inspect bytes without version-probing or name allowlists',
    () async {
      final p = CredentialLaunchPlan.parse(plan('program_stdin'));
      final prepared = await DeviceCredentialLaunch.prepare(p);
      final resolved = prepared.resolve(p);
      expect(
        resolved.executable.path,
        await File(Platform.resolvedExecutable).resolveSymbolicLinks(),
      );
      expect(
        CredentialLaunchPlan.fromStorageJson(resolved.toJson()).stdin!.toJson(),
        {'secret': 'token'},
      );
      expect(resolved.requiresMaterialFiles, isFalse);
    },
  );
  test(
    'stdin is a required typed reference, unavailable to every other receiver',
    () {
      for (final value in [
        'password',
        {'file': 'token'},
        {'secret': 'other'},
        null,
      ]) {
        expect(() {
          final p = CredentialLaunchPlan.parse({
            ...plan('program_stdin'),
            'stdin': value,
          });
          p.validateProgramBindings('token', CredentialForm.string);
        }, throwsA(isA<CredentialUseFailure>()));
      }
      for (final receiver in ['program_env', 'program_file', 'gh_token']) {
        expect(
          () => CredentialLaunchPlan.parse({
            ...plan(receiver),
            'stdin': {'secret': 'token'},
          }),
          throwsA(isA<CredentialUseFailure>()),
        );
      }
      expect(
        () => CredentialLaunchPlan.parse({
          ...plan('program_env'),
          'argv': [
            {'secret': 'token'},
          ],
        }),
        throwsA(isA<CredentialUseFailure>()),
      );
    },
  );
  test(
    'program grants fix executable identity and every typed destination',
    () async {
      for (final receiver in CredentialLaunchPlan.programReceivers) {
        final raw = plan(receiver);
        final parsed = CredentialLaunchPlan.parse(raw);
        final identity = await inspectCredentialExecutable(
          parsed.path,
          receiver,
        );
        final approved = parsed.resolved(identity, parsed.cwd);
        CredentialLaunchPlan candidate(Map<String, dynamic> json) =>
            CredentialLaunchPlan.parse(json).resolved(identity, parsed.cwd);
        candidate({
          ...raw,
          'argv': [...raw['argv'] as List, 'literal'],
        }).requireApprovedProgramScope(approved);
        final changes = [
          {
            ...raw,
            'env': {
              ...raw['env'] as Map,
              'EXTRA': {'secret': 'token'},
            },
          },
          if (receiver == 'program_file')
            {
              ...raw,
              'argv': [
                {'file': 'token'},
                'child.dart',
              ],
            },
          if (receiver == 'program_stdin')
            {
              ...raw,
              'stdin': {'secret': 'other'},
            },
        ];
        for (final changed in changes) {
          expect(
            () => candidate(changed).requireApprovedProgramScope(approved),
            throwsA(isA<CredentialUseFailure>()),
          );
        }
        expect(
          () => parsed
              .resolved(
                ExecutableIdentity(
                  identity.path,
                  identity.byteLength,
                  identity.modifiedMicros,
                  'sha256:${'a' * 64}',
                ),
                parsed.cwd,
              )
              .requireApprovedProgramScope(approved),
          throwsA(isA<CredentialUseFailure>()),
        );
      }
    },
  );
  test(
    'file delivery accepts string and file material but cannot substitute env delivery',
    () {
      final p = CredentialLaunchPlan.parse(plan('program_file'));
      for (final form in CredentialForm.values) {
        p.validateProgramBindings('token', form);
      }
      expect(p.requiresMaterialFiles, isTrue);
      for (final receiver in ['program_env', 'program_stdin']) {
        expect(
          () => CredentialLaunchPlan.parse(
            plan(receiver),
          ).validateProgramBindings('token', CredentialForm.file),
          throwsA(isA<CredentialUseFailure>()),
        );
      }
    },
  );
}
