import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

Map<String, dynamic> launch({String root = '/synthetic'}) => {
  'executable': '$root/tool',
  'cwd': '$root/work',
  'argv': [
    'sync',
    '--key',
    {
      'file': {'credentialId': 'key-a'},
    },
  ],
  'env': {
    'DB_PASSWORD': {'credentialId': 'db-a', 'version': 2},
    'SERVICE_TOKEN': {'credentialId': 'token-a'},
    'CREDENTIAL_FILE': {
      'file': {'credentialId': 'key-a'},
    },
    'MODE': 'synthetic',
  },
  'stdin': {'credentialId': 'input-a'},
};
final identity = ExecutableIdentity(
  '/canonical/tool',
  100,
  1,
  'sha256:${'a' * 64}',
);
CredentialProgramPlan parse(Map<String, dynamic> json) =>
    CredentialProgramPlan.fromJson(json, allowPortablePaths: true);
CredentialProgramPlan fixed(Map<String, dynamic> json) => parse(json)
    .withVersions({'key-a': 1, 'db-a': 9, 'token-a': 3, 'input-a': 2})
    .resolved(identity, '/canonical/work');
Matcher failure(String code) =>
    isA<CredentialUseFailure>().having((e) => e.code, 'code', code);

void main() {
  test(
    'one process names each actual receiver directly and freezes omitted versions',
    () {
      final original = launch(), plan = fixed(original);
      expect(plan.bindings.map((b) => b.location), [
        'argv[2]',
        'env.DB_PASSWORD',
        'env.SERVICE_TOKEN',
        'env.CREDENTIAL_FILE',
        'stdin',
      ]);
      expect(plan.bindings.map((b) => b.via), [
        'file',
        'env',
        'env',
        'file',
        'stdin',
      ]);
      expect(plan.bindings.map((b) => b.reference.version), [1, 2, 3, 1, 2]);
      expect(plan.bindings.first.acceptsForm(CredentialForm.file), true);
      expect(plan.bindings[1].acceptsForm(CredentialForm.file), false);
      expect(plan.bindings.last.acceptsForm(CredentialForm.file), false);
      expect(
        plan.bindings.every((b) => b.acceptsForm(CredentialForm.string)),
        true,
      );
      expect(jsonEncode(original), isNot(contains('executableIdentity')));
      expect(jsonEncode(plan.toJson()), isNot(contains('alias')));
      expect((plan.toJson()['env'] as Map)['DB_PASSWORD'], {
        'credentialId': 'db-a',
        'version': 2,
      });
      expect(
        plan.withVersions({'token-a': 99}).planHash,
        plan.planHash,
        reason: 'An already fixed plan never changes to the newest password.',
      );
      expect(
        () => parse(launch()).withVersions({'token-a': 3}),
        throwsA(failure('credential_version_changed')),
      );
      expect(() => plan.env.clear(), throwsUnsupportedError);
      expect(() => plan.argv.clear(), throwsUnsupportedError);
    },
  );

  test(
    'typed receivers reject aliases, plaintext argv injection, malformed mappings and ambiguous environment names',
    () {
      final invalid = <Map<String, dynamic>>[
        {
          ...launch(),
          'argv': [
            {'credentialId': 'db-a', 'version': 2},
          ],
        },
        {
          ...launch(),
          'stdin': [
            {'credentialId': 'a'},
            {'credentialId': 'b'},
          ],
        },
        {...launch(), 'stdin': 'a raw password'},
        {
          ...launch(),
          'stdin': {
            'file': {'credentialId': 'a'},
          },
        },
        {
          ...launch(),
          'env': {
            'TOKEN': {'secret': 'temporary_alias'},
          },
        },
        {
          ...launch(),
          'env': {
            'TOKEN': {'credentialId': 'a', 'filePath': '/caller/secret'},
          },
        },
        {
          ...launch(),
          'env': {
            'TOKEN': {'credentialId': 'a', 'version': 0},
          },
        },
        {
          ...launch(),
          'env': {
            'TOKEN': {'credentialId': 'a', 'version': null},
          },
        },
        {
          ...launch(),
          'env': {
            'TOKEN': {'credentialId': 'a'},
            'token': {'credentialId': 'b'},
          },
        },
        {...launch(), 'executable': 'relative-tool'},
        {...launch(), 'cwd': 'relative-work'},
        {...launch(), 'executableIdentity': identity.toJson()},
        {
          ...launch(),
          'argv': ['text\u0000injection'],
        },
        {
          ...launch(),
          'env': {'BAD=NAME': 'x'},
        },
      ];
      for (final json in invalid) {
        expect(
          () => parse(json),
          throwsA(isA<CredentialUseFailure>()),
          reason: '${json.keys}',
        );
      }
      expect(
        () => parse({
          'executable': '/tool',
          'cwd': '/work',
          'argv': [],
          'env': <String, dynamic>{},
        }),
        throwsA(failure('limit_exceeded')),
      );
      expect(
        () => parse({
          ...launch(),
          'argv': [
            for (var i = 0; i < 21; i++)
              {
                'file': {'credentialId': 'key-$i'},
              },
          ],
        }),
        throwsA(failure('limit_exceeded')),
      );
      final windows = parse(launch(root: r'C:\synthetic'));
      expect(windows.path, startsWith(r'C:\'));
    },
  );

  test(
    'approved program scope allows independent subsets and literal command changes but not different material positions',
    () {
      final approved = fixed(launch());
      final onlyToken = fixed({
        'executable': '/synthetic/tool',
        'cwd': '/another/work',
        'argv': ['query', '--limit', '20'],
        'env': {
          'SERVICE_TOKEN': {'credentialId': 'token-a', 'version': 3},
        },
      });
      expect(() => onlyToken.requireApprovedScope(approved), returnsNormally);
      expect(onlyToken.bindings, hasLength(1));
      final changed = <Map<String, dynamic>>[
        {
          ...launch(),
          'env': {
            'OTHER_TOKEN': {'credentialId': 'token-a', 'version': 3},
          },
        },
        {
          ...launch(),
          'env': {
            'SERVICE_TOKEN': {'credentialId': 'db-a', 'version': 2},
          },
        },
        {
          ...launch(),
          'env': {
            'SERVICE_TOKEN': {'credentialId': 'token-a', 'version': 4},
          },
        },
        {
          ...launch(),
          'env': {
            'SERVICE_TOKEN': {
              'file': {'credentialId': 'token-a', 'version': 3},
            },
          },
        },
        {
          ...launch(),
          'argv': [
            'sync',
            {
              'file': {'credentialId': 'key-a'},
            },
          ],
        },
        {
          ...launch(),
          'stdin': {'credentialId': 'token-a', 'version': 3},
        },
      ];
      for (final json in changed) {
        expect(
          () => fixed(json).requireApprovedScope(approved),
          throwsA(failure('scope_not_approved')),
        );
      }
      expect(
        () => parse(
          launch(),
        ).resolved(identity, '/canonical/work').requireApprovedScope(approved),
        throwsA(failure('scope_not_approved')),
      );
      expect(
        () => approved
            .resolved(
              ExecutableIdentity(identity.path, 100, 1, 'sha256:${'b' * 64}'),
              approved.cwd,
            )
            .requireApprovedScope(approved),
        throwsA(failure('scope_not_approved')),
      );
    },
  );

  test(
    'device preparation reuses the existing identity transport without launching or accepting a different plan',
    () async {
      final root = await Directory.systemTemp.createTemp('program-plan-test-');
      addTearDown(() => root.delete(recursive: true));
      final plan = CredentialProgramPlan.fromJson({
        'executable': '${root.path}/tool',
        'cwd': root.path,
        'argv': [],
        'env': {
          'PASSWORD': {'credentialId': 'a', 'version': 1},
        },
      });
      final canonical = await root.resolveSymbolicLinks();
      var inspections = 0;
      final prepared = await DeviceCredentialLaunch.prepareProgram(
        plan,
        inspector: (path, receiver) async {
          inspections++;
          expect(path, plan.path);
          expect(receiver, 'program_env');
          return ExecutableIdentity('$canonical/tool', 100, 1, identity.sha256);
        },
      );
      expect(inspections, 1);
      final roundtrip = DeviceCredentialLaunch.fromPrivateJson(
        Map<String, dynamic>.from(prepared.toPrivateJson()),
      );
      final resolved = roundtrip.resolveProgram(plan);
      expect(resolved.path, '$canonical/tool');
      expect(resolved.cwd, canonical);
      final changed = CredentialProgramPlan.fromJson({
        'executable': plan.path,
        'cwd': root.path,
        'argv': ['different'],
        'env': {
          'PASSWORD': {'credentialId': 'a', 'version': 1},
        },
      });
      expect(
        () => roundtrip.resolveProgram(changed),
        throwsA(failure('invalid_plan')),
      );
      expect(
        () => roundtrip.resolveProgram(resolved),
        throwsA(failure('invalid_plan')),
      );
      expect(plan.toJson().containsKey('executableIdentity'), false);
    },
  );
}
