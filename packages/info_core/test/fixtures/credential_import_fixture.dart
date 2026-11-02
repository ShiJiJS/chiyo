import 'package:info_core/info_core.dart';

InformationTemplateDescription credentialTemplate(
  String kind, {
  String? digest,
}) => InformationTemplateDescription(
  id: 'credential.$kind',
  name: '合成凭据',
  version: '1',
  digest: digest ?? 'c' * 64,
  enabled: true,
  definition: {
    'recordKind': 'credential',
    'credential': {
      'form': kind == 'file' ? 'file' : 'string',
      'secretKind': kind,
      'suggestedBinding': 'TEST_CREDENTIAL',
    },
    'fields': [],
    'sections': [],
    'relations': [
      {'key': 'related', 'label': '关联', 'targetTemplates': []},
    ],
    'instructions': '只提交合成凭据；账号密码私下填写，已见秘密说明暴露。',
    'example': {'name': '合成凭据', 'summary': '用于合成服务。', 'values': {}},
  },
);

void configureCredentialImports(InformationService service, {String? digest}) =>
    service.owner.configureInformationTemplates(
      () => InformationTemplateCatalog(
        version: 1,
        plugins: [],
        templates: [
          for (final k in ['accountPassword', 'token', 'file'])
            credentialTemplate(k, digest: digest),
          InformationTemplateDescription(
            id: 'note',
            name: '合成说明',
            version: '1',
            digest: 'a' * 64,
            enabled: true,
            definition: {
              'fields': [
                {'key': 'body', 'label': '正文', 'type': 'text'},
              ],
              'sections': [],
              'relations': [
                {'key': 'related', 'label': '关联'},
              ],
              'instructions': '填写说明。',
              'example': {
                'name': '示例',
                'values': {'body': '示例正文'},
              },
            },
          ),
        ],
      ),
    );

ImportItemInput credentialInput(
  String key,
  String kind,
  CredentialImportInput credential, {
  List<ImportPendingReference> pending = const [],
}) => ImportItemInput(
  key,
  '合成服务的登录材料。',
  [],
  key: key,
  templateId: 'credential.$kind',
  templateVersion: '1',
  templateDigest: 'c' * 64,
  credential: credential,
  pendingRelations: {if (pending.isNotEmpty) 'related': pending},
);
