@TestOn('windows')
library;

import 'dart:convert';
import 'dart:io';
import 'package:info_cli/private_device_state.dart';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() {
  test(
    'settings, execution and copy control facts persist privately without reset',
    () async {
      final root = await Directory.systemTemp.createTemp('本机 state space ');
      addTearDown(() => root.delete(recursive: true));
      final folder = await privateDeviceDirectory(
        Directory('${root.path}/facts'),
      );
      final lock = File('${folder.path}/launch.lock');
      await Future.wait(List.generate(32, (_) => privateDeviceFile(lock)));
      final state = File('${folder.path}/state.json');
      const original = {
        'serverId': 'original-server',
        'operationId': 'original-operation',
        'executionCapability': 'synthetic-control-secret',
        'pending': true,
      };
      await writePrivateDeviceState(state, original);
      expect(await readPrivateDeviceState(File(state.path)), original);
      expect(
        latin1.decode(await state.readAsBytes()),
        isNot(contains('synthetic-control-secret')),
      );
      await writePrivateDeviceState(state, {...original, 'pending': false});
      expect(
        (await readPrivateDeviceState(state))!['operationId'],
        original['operationId'],
      );
      expect((await readPrivateDeviceState(state))!['pending'], isFalse);
      await state.writeAsBytes([1, 2, 3]);
      await expectLater(
        readPrivateDeviceState(state),
        throwsA(isA<InformationFileFailure>()),
      );
      expect(await state.readAsBytes(), [1, 2, 3]);
    },
  );
}
