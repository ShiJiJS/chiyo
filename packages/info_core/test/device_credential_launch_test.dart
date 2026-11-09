import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() {
  test(
    'device preflight resolves its own cwd; a substituted command cannot use the original snapshot',
    () async {
      final root = await Directory.systemTemp.createTemp('device-plan-');
      addTearDown(() => root.delete(recursive: true));
      final input = {
        'receiver': 'gh_token',
        'executable': '${root.path}/gh',
        'argv': ['api', 'user'],
        'cwd': root.path,
        'env': {
          'GH_TOKEN': {'secret': 'token'},
        },
      };
      final plan = CredentialLaunchPlan.parse(input);
      var probes = 0;
      final prepared = await DeviceCredentialLaunch.prepare(
        plan,
        inspector: (path, receiver) async {
          probes++;
          expect(path, input['executable']);
          expect(receiver, 'gh_token');
          return ExecutableIdentity(path, 10, 1, 'sha256:${'a' * 64}');
        },
      );
      expect(probes, 1);
      final received = DeviceCredentialLaunch.fromPrivateJson(
        prepared.toPrivateJson(),
      );
      expect(received.resolve(plan).cwd, await root.resolveSymbolicLinks());
      final changed = CredentialLaunchPlan.parse({
        ...input,
        'argv': ['api', 'repos/private/delete'],
      });
      expect(
        () => received.resolve(changed),
        throwsA(isA<CredentialUseFailure>()),
      );
      final wrongProgram = DeviceCredentialLaunch.fromPrivateJson({
        ...prepared.toPrivateJson(),
        'executable': {
          'path': '${root.path}/sh',
          'byteLength': 10,
          'modifiedMicros': 1,
          'sha256': 'sha256:${'b' * 64}',
        },
      });
      expect(
        () => wrongProgram.resolve(plan),
        throwsA(isA<CredentialUseFailure>()),
      );
    },
  );
}
