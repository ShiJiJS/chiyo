@TestOn('windows')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:info_cli/ssh_session_transport.dart';
import 'package:info_cli/ssh_session_windows.dart';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() {
  final root = Directory.current.parent.parent.absolute.path;
  final helper =
      Platform.environment['D7_WINDOWS_SSH_HELPER'] ??
      '$root/build/ssh-session/native/Release/info-ssh-session.exe';
  final child = '${File(helper).parent.path}/ssh_session_test_child.exe';
  if (!File(helper).existsSync() || !File(child).existsSync()) {
    test(
      'Windows broker registration gate',
      () {},
      skip: 'Build scripts/build-windows-ssh-session.ps1 -BuildTests first',
    );
    return;
  }

  File receipt(String name) => File(
    '$root/build/ssh-session/registration-$name-${DateTime.now().microsecondsSinceEpoch}.txt',
  );
  SshTransportLaunch launch(
    File file,
    Future<void> Function(int, String) register,
  ) => SshTransportLaunch(
    executable: File(child).absolute.path,
    arguments: const ['mark'],
    environment: {'CHIYO_QA_STARTED_RECEIPT': file.path},
    onLoginChallenge: (_) async =>
        fail('Registration fixture must not authenticate'),
    onProcessCreated: register,
  );

  test(
    'awaits durable registration of the actual broker before creating SSH',
    () async {
      final file = receipt('success');
      final observed = Completer<void>();
      final approve = Completer<void>();
      late int pid;
      late String identity;
      final started = WindowsSshTransportLauncher(helperPath: helper).start(
        launch(file, (p, value) async {
          pid = p;
          identity = value;
          final actual = CredentialProcessIdentity.capture(p);
          try {
            expect(actual?.value, value);
          } finally {
            actual?.close();
          }
          expect(CredentialProcessIdentity.isActive(p, value), isTrue);
          expect(CredentialProcessIdentity.isActive(p, 'windows:1'), isFalse);
          observed.complete();
          await approve.future;
        }),
      );
      await observed.future.timeout(const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(
        await file.exists(),
        isFalse,
        reason: 'No child before registration succeeds',
      );
      approve.complete();
      final transport = await started;
      try {
        final output = transport.output.transform(utf8.decoder).join();
        unawaited(transport.diagnostics.drain<void>());
        expect(await transport.exitCode.timeout(const Duration(seconds: 5)), 0);
        expect(await output, 'started\n');
        expect(await file.readAsString(), 'started\n');
      } finally {
        await transport.terminate();
      }
      expect(CredentialProcessIdentity.isActive(pid, identity), isFalse);
    },
  );

  test(
    'registration failure ends the verified broker without starting SSH',
    () async {
      final file = receipt('refused');
      late int pid;
      late String identity;
      await expectLater(
        WindowsSshTransportLauncher(helperPath: helper).start(
          launch(file, (p, value) async {
            pid = p;
            identity = value;
            throw StateError('synthetic-registration-failure');
          }),
        ),
        throwsA(isA<StateError>()),
      );
      expect(await file.exists(), isFalse);
      expect(CredentialProcessIdentity.isActive(pid, identity), isFalse);
    },
  );

  test('an ended broker cannot pass the registration gate', () async {
    final file = receipt('ended');
    late int pid;
    late String identity;
    await expectLater(
      WindowsSshTransportLauncher(helperPath: helper).start(
        launch(file, (p, value) async {
          pid = p;
          identity = value;
          expect(Process.killPid(p), isTrue);
          final deadline = DateTime.now().add(const Duration(seconds: 3));
          while (CredentialProcessIdentity.isActive(p, value) == true) {
            if (DateTime.now().isAfter(deadline)) {
              fail('Owned broker did not end');
            }
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
        }),
      ),
      throwsA(
        isA<SshTransportFailure>().having(
          (e) => e.code,
          'code',
          'ssh_broker_identity_ended',
        ),
      ),
    );
    expect(await file.exists(), isFalse);
    expect(CredentialProcessIdentity.isActive(pid, identity), isFalse);
  });
}
