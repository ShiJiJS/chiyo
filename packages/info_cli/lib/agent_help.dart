/// Public usage metadata, available without connecting or opening a session.
Map<String, dynamic> agentCommandHelp() => {
  'status': 'ok',
  'submissionCapability': 'submission-metadata.v1',
  'submissionFields': {
    'agentName': '当前 Agent 名称，最多200字。Codex 同包入口自动填写，也可明确提供。',
    'externalChatId':
        '当前聊天标识，最多200字。通用 CLI 在 session 或每次申请提供；Codex 同包入口使用当前聊天标识。此值不能作为授权证明。',
    'purpose': '本次用途，最多2000字。',
    'title': '新增、修改、删除和整理提案的一句主题，最多200字、不含换行。例：补齐 NAS 应用清单。',
  },
  'sourceNotice':
      '填写实际名称和当前聊天标识。主题和说明中不放密码、Token、私钥或资料正文。插件模板决定 items/update 的具体结构。',
  'approvalTiming':
      '新申请默认等待2小时；设置可改为30分钟或1/2/4/8/24小时，只影响新申请。批准后默认可用2小时，可选2/4/8/24小时。以返回的实际到期时间为准，重试不续期；SSH另可由用户批准本聊天内不限时。',
  'commands': {
    'session': '通用 CLI 建立新会话；提供 chatLabel 和 externalChatId。',
    'request': '提供 purpose、fields、operationId。',
    'request-use': '提供 purpose，按凭据协议填写 credentials 和 launch/fill。',
    'import-submit':
        '提供 title、purpose、operationId、items。items 来自当前 template-read。',
    'update-submit': '提供 title、purpose、operationId、update，修改已保存资料。',
    'delete-submit': '提供 title、purpose、itemId、baseVersion，提交删除提案，用户确认后才移到回收站。',
    'organize-request': '提供 title、purpose、itemIds，申请限定范围的整理。',
    'import-revise/update-revise': '修改原待审内容；保留原提案的主题与来源，重新核对并审批。',
  },
  'examples': [
    {
      'command': 'session',
      'chatLabel': '核对 NAS 应用',
      'externalChatId': 'example-current-chat',
    },
    {
      'command': 'request',
      'agentName': 'Example Agent',
      'purpose': '核对 NAS 的主机地址',
      'operationId': 'replace-with-unique-request-id',
      'fields': [
        {'itemId': 'ITEM_ID', 'fieldId': 'FIELD_ID'},
      ],
    },
  ],
  'proposalMetadataExample': {
    'agentName': 'Example Agent',
    'externalChatId': 'example-current-chat',
    'title': '补齐 NAS 应用清单',
    'purpose': '整理用户提供的应用信息',
  },
  'templateExample':
      '用当前 template-read 的完整 submissionExample 填写 items，再替换本次主题与来源。',
};
