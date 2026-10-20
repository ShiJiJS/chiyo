import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';

class _Keys implements DatabaseKeyStore {
  @override
  Future<List<int>?> read() async => List<int>.filled(32, 61);
  @override
  Future<void> create(List<int> key) async =>
      throw StateError('Fixed synthetic key');
}

class _Files implements InformationDeliveryFiles {
  final native = WindowsInformationDeliveryFiles();
  @override
  Future<InformationDeliveryLease> reserve(String name) => native.reserve(name);
  @override
  Future<void> write(InformationDeliveryLease lease, Uint8List bytes) =>
      native.write(lease, bytes);
  @override
  Future<void> cleanup(InformationDeliveryLease lease) => native.cleanup(lease);
  @override
  Future<void> verify(
    InformationDeliveryLease lease,
    int size,
    String digest,
  ) async {
    await native.verify(lease, size, digest);
    // At this exact point original bytes exist but ready has not been saved.
    // The parent interrupts our reported VM, never the Dart launcher alone.
    stdout.writeln('delivery_prepared:$pid');
    await stdout.flush();
    await Completer<void>().future;
  }
}

Future<void> main(List<String> args) async {
  stdout.writeln('delivery_worker:$pid');
  await stdout.flush();
  final root = args.single;
  final repo = await EncryptedInformationRepository.open(
    '$root/vault',
    _Keys(),
  );
  final service = InformationService(
    repository: repo,
    informationDeliveryFiles: _Files(),
  );
  final source = File('$root/synthetic.pdf');
  await source.writeAsBytes([0, 255, 8, 10, 27, 42]);
  final draft = await service.owner.beginInformationFileDraft();
  final stage = await service.owner.stageInformationFile(
    draft,
    source.path,
    mediaType: 'application/pdf',
  );
  final item = await service.owner.commitInformationDraft(
    draft,
    'create',
    InformationDraftInput(
      name: 'Crash fixture',
      description: '',
      fields: [InformationDraftField.stagedFile('Document', '', stage.id)],
    ),
  );
  await service.owner.releaseInformationFileDraft(draft);
  final session = service.agent.openSession('Synthetic crash fixture');
  final field = FieldRef(item.id, item.fields.single.id);
  final request = service.agent.request(
    session,
    'Crash after bytes before ready',
    [field],
  );
  service.owner.approve(request.id, [field]);
  await service.owner.retryAuditStorage();
  await service.agent.fetchInformationFile(
    session,
    InformationFileFetchInput.fromJson({
      'protocolVersion': 2,
      'command': 'file-fetch',
      'requestId': request.id,
      'itemId': item.id,
      'fieldId': field.fieldId,
      'operationId': 'interrupted-original',
    }),
  );
  throw StateError('Crash fixture must be interrupted before ready');
}
