import 'dart:convert';
import 'dart:typed_data';
import 'package:info_core/info_core.dart';
import 'file_import_fixture.dart';

Future<InformationItem> createLegacyAttachment(
  InformationService service,
  InformationRepository repo,
) async {
  configureFileImports(service);
  final session = service.agent.openSession('合成旧附件');
  final uploads = <InformationImportUpload>[];
  for (var n = 0; n < 2; n++) {
    uploads.add(
      await service.agent.uploadImportFile(
        session,
        operationId: 'old-original-$n',
        originalName: '材料$n.md',
        mediaType: 'text/plain',
        bytes: Uint8List.fromList(utf8.encode('原文$n')),
      ),
    );
  }
  final id = await service.agent.submitImport(session, [
    fileInput('legacy', uploads),
  ]);
  final proposal = repo.importProposals.singleWhere((p) => p.id == id);
  await service.owner.confirmImport(id, proposal.version, proposal.items);
  final file = repo.items.single;
  final old = InformationItem(
    file.id,
    '旧混合资料',
    '合成资料',
    file.version,
    [...file.fields, const InformationField('fact', '事实', '', '重要事实', 1)],
    layout: InformationLayout(
      typeId: 'document',
      snapshot: {
        'codec': 'workspace-information-v1',
        'definition': {
          'id': 'document',
          'name': '文档',
          'fields': [
            {'key': 'body', 'label': '事实', 'type': 'multiline'},
          ],
        },
        'retainedFields': [
          {'key': 'original', 'label': '材料原文', 'type': 'file'},
        ],
      },
      fieldIds: {
        jsonEncode(['field', 'body']): 'fact',
        jsonEncode(['field', 'original']): file.fields.single.id,
      },
      relations: const {},
    ),
  );
  await repo.save(old);
  return old;
}
