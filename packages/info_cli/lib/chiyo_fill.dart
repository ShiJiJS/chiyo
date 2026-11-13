part of 'chiyo_cli.dart';

extension _ChiyoFill on ChiyoCli {
  DeviceCredentialBatchClient get _batchClient {
    final profile = _activeContext.connection;
    if (profile == null) {
      throw const _PublicFailure(
        'unsupported_capability',
        '此旧聊天尚不支持新的填写方式，请用当前版本建立聊天；旧批准仍按原方式使用。',
        3,
      );
    }
    final directory = environment['CHIYO_CONNECTION_DIRECTORY'];
    return DeviceCredentialBatchClient(
      profile,
      directory: directory == null ? null : Directory(directory),
    );
  }

  Future<Map<String, dynamic>> _requestFill(ChiyoInvocation i) async {
    final o = i.options;
    final Map<String, dynamic> body;
    if (o['input'] != null) {
      body = await _businessInput(i, 100 * 1024);
    } else {
      final via = _required(i, 'via');
      body = {
        'purpose': _required(i, 'purpose'),
        'items': [
          {
            'credentialId': _required(i, 'credential'),
            if (o['version'] != null)
              'version': int.parse(o['version'] as String),
            'destination': {
              'via': via,
              if (via != 'focus') ...{
                'url': _required(i, 'url'),
                'form': _required(i, 'form'),
                'selector': _required(i, 'selector'),
                if (via == 'ego') ...{
                  'space': int.parse(_required(i, 'space')),
                  'page': _required(i, 'page'),
                } else ...{
                  'browser': _required(i, 'browser'),
                  'tab': _required(i, 'tab'),
                },
              },
            },
          },
        ],
      };
    }
    _validateFillBusiness(body);
    final intent = await _intents.remember('fill-request', {
      'input': {
        ...body,
        'agentName': _activeContext.agentName,
        'externalChatId': _activeContext.chatId,
        'submissionVersion': 1,
      },
    }, operationId: o['operation'] as String?);
    return _continueFill(intent);
  }

  Future<Map<String, dynamic>> _runFill(ChiyoInvocation i) async {
    final items = (i.options['item'] as List<String>).toList()..sort();
    if (items.toSet().length != items.length ||
        items.any((id) => !RegExp(r'^b(?:[1-9]|1[0-9]|20)$').hasMatch(id))) {
      throw const ChiyoUsageFailure('条目 ID 必须使用申请返回的 b1 等编号，不能重复。');
    }
    final intent = await _intents.remember('fill-run', {
      'requestId': _required(i, 'request'),
      if (items.isNotEmpty) 'itemIds': items,
    }, operationId: i.options['operation'] as String?);
    return _continueFill(intent);
  }

  Future<Map<String, dynamic>> _continueFill(
    ChiyoIntent intent, {
    bool recover = false,
  }) async {
    final run = intent.kind == 'fill-run';
    final response = await _batchClient.execute(
      _activeContext.secret,
      run && recover
          ? {'command': 'batch-status', 'operationId': intent.operationId}
          : {
              'command': run ? 'batch-run' : 'batch-request',
              'operationId': intent.operationId,
              ...intent.payload,
            },
    );
    if (run && recover && response['status'] == 'not_found' ||
        response['status'] == 'service_unavailable' &&
            (response['errorCode'] == null ||
                {
                  'service_unavailable',
                  'audit_unavailable',
                }.contains(response['errorCode']))) {
      return {
        'status': run ? 'operation_unknown' : 'request_unknown',
        'operationId': intent.operationId,
        if (run) 'requestId': intent.payload['requestId'],
      };
    }
    return {...response, 'operationId': intent.operationId};
  }
}

void _validateFillBusiness(Map<String, dynamic> body) {
  Never invalid() => throw const ChiyoUsageFailure(
    '填写文件只包含 purpose 和 items；每项指定 credentialId、可选 version 和 destination。目标仅填写真实浏览器位置或 focus，不提供密码、内部程序或已准备的证明。',
  );
  final purpose = body['purpose'], items = body['items'];
  if (body.length != 2 ||
      purpose is! String ||
      purpose.trim().isEmpty ||
      purpose.length > 2000 ||
      items is! List ||
      items.isEmpty ||
      items.length > 20) {
    invalid();
  }
  for (final item in items) {
    if (item is! Map<String, dynamic> ||
        item.keys.any(
          (k) => !{'credentialId', 'version', 'destination'}.contains(k),
        ) ||
        item['credentialId'] is! String ||
        (item['credentialId'] as String).trim().isEmpty ||
        (item['credentialId'] as String).length > 200 ||
        item.containsKey('version') &&
            (item['version'] is! int || (item['version'] as int) < 1) ||
        item['destination'] is! Map<String, dynamic>) {
      invalid();
    }
    final d = item['destination'] as Map<String, dynamic>;
    final via = d['via'];
    if (via == 'focus') {
      if (d.length != 1) invalid();
      continue;
    }
    if (!{'ego', 'chrome'}.contains(via) ||
        d.length != 6 ||
        d.keys.any(
          (k) => !{
            'via',
            'url',
            'form',
            'selector',
            if (via == 'ego') ...['space', 'page'] else ...['browser', 'tab'],
          }.contains(k),
        )) {
      invalid();
    }
    BrowserFormTarget.fromJson({
      'provider': via,
      'instanceId': 'unobserved',
      'structureDigest': '0' * 64,
      'url': d['url'],
      'form': d['form'],
      'field': d['selector'],
      'pageId': d[via == 'ego' ? 'page' : 'tab'],
      if (via == 'ego') 'space': d['space'] else 'browserAddress': d['browser'],
    });
  }
}
