import 'dart:convert';
import 'package:info_storage/info_storage.dart';

Future<void> main(List<String> args) async {
  DeviceBackupOperations? store;
  try {
    store = await DeviceBackupOperations.open(
      args.single,
      serverId: 'original-server',
    );
    await store.record({
      'operationId': 'first_launch',
      'action': 'export',
      'expectedVersion': 73,
      'selection': {
        'id': 'first_selection',
        'name': 'original.aimbackup',
        'kind': 'archiveOutput',
        'version': 1,
      },
      'previewToken': null,
    });
    await Future<void>.delayed(const Duration(milliseconds: 100));
    print(jsonEncode({'opened': true}));
  } on StorageFailure catch (e) {
    if (!{
      'device_journal_in_use',
      'device_journal_unavailable',
    }.contains(e.code))
      rethrow;
    print(jsonEncode({'opened': false, 'code': e.code}));
  } finally {
    await store?.close();
  }
}
