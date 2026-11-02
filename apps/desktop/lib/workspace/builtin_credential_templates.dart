import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:info_core/info_core.dart' as core;

/// Host-owned material forms. Neither CLI nor Skill carries this registry.
Iterable<core.InformationTemplateDescription>
builtinCredentialTemplates() sync* {
  for (final kind in ['accountPassword', 'token', 'file']) {
    final file = kind == 'file';
    final definition = <String, Object?>{
      'recordKind': 'credential',
      'credential': {
        'form': file ? 'file' : 'string',
        'secretKind': kind,
        'suggestedBinding': file
            ? 'CREDENTIAL_FILE'
            : kind == 'accountPassword'
            ? 'ACCOUNT_PASSWORD'
            : 'SERVICE_TOKEN',
      },
      'fields': <Object?>[],
      'sections': <Object?>[],
      'relations': [
        {'key': 'related', 'label': '关联资料或凭据', 'targetTemplates': <String>[]},
      ],
      'instructions': switch (kind) {
        'accountPassword' =>
          '用于账号登录密码，包括密码管理器生成后设为登录密码的内容。尚未见过的密码由主人在提案内填写，不让主人发到聊天。若已从指定资料实际看到，则由Agent填写并说明已进入上下文；不要为了录入先去读取原本未见的密码。',
        'token' =>
          'API Key、Token等非人设密码由Agent提交，说明秘密可能已进入上下文；不要要求主人打开文件复制，也不要把秘密放进名称、普通字段或日志。',
        _ =>
          '完整私钥、登录会话等文件由Agent给CLI原文件路径，程序接收并加密保管，不要求主人重新选择，不要求Agent为录入读取文件原文。',
      },
      'example': {
        'name': file
            ? '业务服务器私钥'
            : kind == 'accountPassword'
            ? '笔记服务登录密码'
            : '笔记服务 API Token',
        'summary': file ? '用于连接业务服务器的凭据文件。' : '用于笔记服务的身份验证。',
        'values': <String, Object?>{},
      },
    };
    yield core.InformationTemplateDescription(
      id: 'credential.$kind',
      name: file
          ? '凭据文件'
          : kind == 'accountPassword'
          ? '账号密码'
          : 'API Key / Token',
      version: '1',
      digest: sha256.convert(utf8.encode(jsonEncode(definition))).toString(),
      enabled: true,
      definition: definition,
    );
  }
}
