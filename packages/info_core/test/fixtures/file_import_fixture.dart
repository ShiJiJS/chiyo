import 'package:info_core/info_core.dart';

void configureFileImports(
  InformationService service, {
  bool enabled = true,
  String digest =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
}) => service.owner.configureInformationTemplates(
  () => InformationTemplateCatalog(
    version: 1,
    plugins: [],
    templates: [
      InformationTemplateDescription(
        id: 'file',
        name: '文件资料',
        version: '1',
        digest: digest,
        enabled: enabled,
        definition: {
          'id': 'file',
          'name': '文件资料',
          'icon': 'file',
          'fields': [
            {'key': 'file', 'label': '原文件', 'type': 'file', 'required': true},
          ],
          'sections': [
            {
              'kind': 'fields',
              'title': '原文',
              'keys': ['file'],
            },
          ],
          'relations': [
            {'key': 'related', 'label': '关联资料', 'targetTemplates': []},
          ],
          'instructions': '按用途分别建资料；同一材料修订作为版本，有依据时选择当前文件。',
          'example': {
            'name': '后端岗位简历',
            'summary': '用于后端岗位投递。',
            'values': {'file': 'primary'},
          },
        },
      ),
    ],
  ),
);

ImportItemInput fileInput(
  String key,
  List<InformationImportUpload> originals, {
  int current = 1,
  List<ImportAttachmentInput> extra = const [],
  List<ImportPendingReference> pending = const [],
}) => ImportItemInput(
  key,
  '用户提供的普通材料。',
  [],
  key: key,
  templateId: 'file',
  templateVersion: '1',
  templateDigest: 'a' * 64,
  values: {'file': 'primary'},
  attachments: [
    ImportAttachmentInput(
      key: 'primary',
      name: '原文件',
      templateField: 'file',
      currentVersion: current,
      versions: [
        for (final (index, file) in originals.indexed)
          ImportAttachmentVersionInput(
            file.id,
            label: '来源版本${index + 1}',
            sourceNote: '源材料明确给出的修订标记。',
          ),
      ],
    ),
    ...extra,
  ],
  pendingRelations: {if (pending.isNotEmpty) 'related': pending},
);
