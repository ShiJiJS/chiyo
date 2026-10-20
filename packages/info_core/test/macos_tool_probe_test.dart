import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() {
  test(
    'Mac version probe admits a slow first startup and freezes the actual file identity',
    () async {
      final root = await Directory.systemTemp.createTemp('mac-version-probe-');
      final tool = File('${root.path}/gh');
      try {
        await tool.writeAsString(
          '#!/bin/sh\n/bin/sleep 6\n/usr/bin/printf "gh version 2.102.0\\n"\n',
        );
        expect(
          (await Process.run('/bin/chmod', ['700', tool.path])).exitCode,
          0,
        );
        final identity = await inspectCredentialExecutable(
          tool.path,
          'gh_token',
        );
        expect(identity.path, await tool.resolveSymbolicLinks());
        expect(identity.byteLength, await tool.length());
      } finally {
        await tool.delete();
        await root.delete();
      }
    },
    skip: !Platform.isMacOS,
  );
  test(
    'Mac rejects an unbounded version response and reaps the probe',
    () async {
      final root = await Directory.systemTemp.createTemp('mac-version-output-');
      final tool = File('${root.path}/gh');
      try {
        await tool.writeAsString('#!/bin/sh\nexec /usr/bin/yes x\n');
        expect(
          (await Process.run('/bin/chmod', ['700', tool.path])).exitCode,
          0,
        );
        await expectLater(
          inspectCredentialExecutable(
            tool.path,
            'gh_token',
          ).timeout(const Duration(seconds: 5)),
          throwsA(isA<CredentialUseFailure>()),
        );
      } finally {
        await tool.delete();
        await root.delete();
      }
    },
    skip: !Platform.isMacOS,
  );
}
