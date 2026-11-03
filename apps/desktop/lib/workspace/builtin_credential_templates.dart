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
          '用于账号登录密码，包括密码管理器生成后设为登录密码的内容。尚未见过的密码由主人在提案内填写，不让主人发到聊天。若已从指定资料实际看到，则由Agent填写并说明已进入上下文；不要为了录入先去读取原本未见的密码。明确账号缺少当前密码时也提交主人补填申请，说明所属服务和用户名；只有旧密码或哈希不算具备当前密码。把凭据直接关联到实际登录的服务器或应用，来源文档可作为额外关联。',
        'token' =>
          'API Key、Token等非人设密码由Agent提交，说明秘密可能已进入上下文；不要要求主人打开文件复制，也不要把秘密放进名称、普通字段或日志。来源是JSON或说明文档时，仍将认证所需Token作为字符串提交；可用本机命令在内存提取并通过stdin传递，无需回显。直接关联到所属服务或服务器；同一服务的网页密码与API Token分别录入。',
        _ =>
          '完整私钥、登录会话等认证程序直接使用的文件，由Agent给CLI原文件路径，程序接收并加密保管，不要求主人重新选择或读取原文。文件格式按认证用途判断：含密码或Token的JSON、Markdown只是来源容器，其中的字符串秘密使用账号密码或Token模板；保留原配置原件不能代替整理秘密。凭据必须直接关联实际所属服务器或应用，来源文档可以另加关联。',
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
