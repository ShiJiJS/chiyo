import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() {
  test(
    'only explicit device transport accepts another platform absolute plan',
    () {
      final windows = !Platform.isWindows;
      final launch = <String, dynamic>{
        'receiver': 'gh_token',
        'executable': windows
            ? r'C:\device-not-server\gh.exe'
            : '/device-not-server/gh',
        'cwd': windows
            ? r'C:\device-not-server\work'
            : '/device-not-server/work',
        'argv': ['api', 'user'],
        'env': {
          'GH_TOKEN': {'secret': 'token'},
        },
      };
      final request = <String, dynamic>{
        'protocolVersion': 2,
        'command': 'request-use',
        'purpose': 'Synthetic foreign device',
        'credentials': [
          {'alias': 'token', 'credentialId': 'synthetic', 'version': 1},
        ],
        'launch': launch,
      };
      final operation = <String, dynamic>{
        'protocolVersion': 2,
        'command': 'run-use',
        'requestId': 'synthetic',
        'operationId': 'original',
        'launch': launch,
      };
      expect(
        () => CredentialUseInput.fromJson(request),
        throwsA(isA<CredentialUseFailure>()),
      );
      expect(
        () => CredentialOperationInput.fromJson(operation),
        throwsA(isA<CredentialUseFailure>()),
      );
      final received = CredentialUseInput.fromJson(
        request,
        allowPortableLaunchPaths: true,
      );
      final op = CredentialOperationInput.fromJson(
        operation,
        allowPortableLaunchPaths: true,
      );
      expect(received.launch.path, launch['executable']);
      expect(op.launch.cwd, launch['cwd']);
      expect(op.toJson()['launch'], received.launch.toJson());
      for (final invalid in [
        'relative/gh',
        r'\\server\share\gh.exe',
        'C:relative',
      ]) {
        expect(
          () => CredentialUseInput.fromJson({
            ...request,
            'launch': {...launch, 'executable': invalid},
          }, allowPortableLaunchPaths: true),
          throwsA(isA<CredentialUseFailure>()),
        );
      }
    },
  );
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
