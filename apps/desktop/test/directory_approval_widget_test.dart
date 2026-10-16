import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/approvals.dart';

void main() {
  testWidgets('owner batch selects a directory as fixed field identities', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final service = InformationService(
      repository: MemoryInformationRepository(),
    );
    addTearDown(service.close);
    final directory = await service.owner.createDirectory('Project');
    final child = await service.owner.createDirectory(
      'Servers',
      parentId: directory.id,
    );
    final first = await service.owner.createInformation('First', '', [
      const FieldInput('Host', '', 'first.invalid'),
    ]);
    final second = await service.owner.createInformation('Second', '', [
      const FieldInput('Host', '', 'second.invalid'),
    ]);
    await service.owner.organizeInformation(first.id, directoryId: child.id);
    final session = service.agent.openSession('test');
    final requested = FieldRef(second.id, second.fields.single.id);
    final request = service.agent.request(session, 'connect', [requested]);
    await tester.pumpWidget(
      MaterialApp(home: Approvals(service: service, port: 47125)),
    );
    await tester.tap(find.byKey(ValueKey('field-${requested.fieldId}')));
    await tester.tap(
      find.byKey(ValueKey('directory-${request.id}-${directory.id}')),
    );
    await tester.pump();
    final approve = find.text('批准所选字段');
    await tester.ensureVisible(approve);
    await tester.tap(approve);
    await tester.pump();
    final grant = service.agent.claim(session, request.id);
    expect(grant.fields, [FieldRef(first.id, first.fields.single.id)]);
    await service.owner.organizeInformation(second.id, directoryId: child.id);
    expect(
      () => service.agent.read(grant.token, requested),
      throwsA(isA<AccessFailure>()),
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
