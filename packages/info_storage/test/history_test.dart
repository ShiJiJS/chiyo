import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:test/test.dart';
import 'storage_test.dart' show TestKeyStore;

void main() {
  test('encrypted history survives restart without reviving grants or copying field values', () async {
    final folder = await Directory.systemTemp.createTemp('info-history-');
    addTearDown(()=>folder.delete(recursive:true));
    final keys = TestKeyStore();
    var repository = await EncryptedInformationRepository.open(folder.path,keys);
    var service = InformationService(repository:repository);
    final item = await service.owner.createInformation('Server','Description',[const FieldInput('Address','Host','PRIVATE-HISTORY-CONTENT-72836')]);
    final field = FieldRef(item.id,item.fields.single.id);
    final session = service.agent.openSession('Fictional chat');
    final request = service.agent.request(session,'Need address',[field]);
    service.owner.approve(request.id,[field]);
    final grant = service.agent.claim(session,request.id);
    expect(await service.agent.read(grant.token,field),'PRIVATE-HISTORY-CONTENT-72836');
    await service.close();
    await repository.close();
    repository = await EncryptedInformationRepository.open(folder.path,keys);
    service = InformationService(repository:repository);
    final history = await service.owner.history();
    expect(history.grants.single.events.last.kind,GrantEventKind.applicationClosed);
    expect(history.accesses.single.outcome,AccessOutcome.allowed);
    expect(history.toJson().toString(),isNot(contains('PRIVATE-HISTORY-CONTENT-72836')));
    await expectLater(service.agent.read(grant.token,field),throwsA(isA<AccessFailure>()));
    await service.close();
    await repository.close();
    for (final file in folder.listSync().whereType<File>()) {
      expect(String.fromCharCodes(await file.readAsBytes()),isNot(contains('PRIVATE-HISTORY-CONTENT-72836')));
    }
  });
}
