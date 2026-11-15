part of 'chiyo_cli.dart';

extension _ChiyoSsh on ChiyoCli {
  Future<Map<String, dynamic>> _sshCommand(
    ChiyoInvocation i,
    AgentClient client,
  ) async {
    final action = i.path.substring(4).replaceAll(' ', '-');
    final o = i.options;
    final mutates = {
      'request',
      'open',
      'run',
      'input',
      'credential-request',
      'credential-use',
    }.contains(action);
    final input = <String, dynamic>{'command': 'ssh-$action'};
    if (action == 'request' || action == 'credential-request') {
      if (action == 'request' && o['input'] != null &&
          ['credential', 'version', 'purpose', 'title', 'summary', 'host', 'port', 'user', 'auth', 'validity'].any(o.wasParsed)) {
        throw const ChiyoUsageFailure('--input 不能和单项 SSH 申请参数混用。');
      }
      final business = action == 'request' && o['input'] != null
          ? await _businessInput(i, 100 * 1024)
          : null;
      if (business != null &&
          (business.keys.any(
                (key) => !{
                  'title',
                  'summary',
                  'purpose',
                  'credentialId',
                  'version',
                  'target',
                }.contains(key),
              ) ||
              business['credentialId'] is! String ||
              business['target'] is! Map<String, dynamic>)) {
        throw const ChiyoUsageFailure(
          'SSH 文件只填写 title、summary、credentialId、version 和 target。',
        );
      }
      final RequestPresentation presentation;
      try {
        presentation = RequestPresentation.fromJson(
          business ??
              {
                if (o['title'] != null) 'title': o['title'],
                if (o['summary'] != null)
                  'summary': o['summary']
                else
                  'purpose': o['purpose'],
              },
        );
      } on FormatException catch (error) {
        throw ChiyoUsageFailure(error.message);
      }
      final credential =
          business?['credentialId'] as String? ?? _required(i, 'credential');
      final previous = o['operation'] == null
          ? null
          : await _intents.read(o['operation'] as String);
      final explicitVersion =
          business?['version'] ??
          (o['version'] == null ? null : _integer(i, 'version', 1, 1 << 31));
      if (explicitVersion != null &&
          (explicitVersion is! int || explicitVersion < 1)) {
        throw const ChiyoUsageFailure('version 必须是正整数。');
      }
      final version =
          explicitVersion ??
          previous?.payload['version'] as int? ??
          await _credentialVersion(client, credential);
      final target = action != 'request'
          ? null
          : business != null
          ? SshSessionTarget.fromJson(
              business['target'] as Map<String, dynamic>,
            )
          : SshSessionTarget(
              host: _required(i, 'host'),
              port: _integer(i, 'port', 1, 65535),
              user: _required(i, 'user'),
              authentication: _required(i, 'auth'),
              credentialUse: 'login',
              validity: o['validity'] as String,
            );
      if (target != null && target.credentialUse != 'login') {
        throw const ChiyoUsageFailure(
          'SSH 登录申请的 credentialUse 必须为 login；sudo 需另行申请。',
        );
      }
      input.addAll({
        'credentialId': credential,
        'version': version,
        ...presentation.toProtocolJson(),
        'agentName': _activeContext.agentName,
        'externalChatId': _activeContext.chatId,
        'validity': target?.validity ?? o['validity'],
        if (target != null) 'target': target.toJson(),
      });
    }
    if (!{'request', 'open', 'capabilities'}.contains(action)) {
      input['sessionId'] = _required(i, 'session');
    }
    if (action == 'open' || action == 'credential-use') {
      input['requestId'] = _required(i, 'request');
    }
    if ({
      'input',
      'interrupt',
      'credential-request',
      'credential-use',
    }.contains(action)) {
      input['runId'] = _required(i, 'run');
    }
    if ((action == 'status' || action == 'output') && o['run'] != null) {
      input['runId'] = o['run'];
    }
    if (action.startsWith('credential-')) {
      input['actionId'] = _required(i, 'action');
    }
    if (action == 'run') input['text'] = _required(i, 'command');
    if (action == 'input') {
      if ((o['text'] == null) == (o['key'] == null)) {
        throw const ChiyoUsageFailure('提供 --text 或 --key；普通文本可加 --enter。');
      }
      if (o['key'] != null && o['enter'] == true) {
        throw const ChiyoUsageFailure('--enter 只用于 --text。');
      }
      input['text'] = o['key'] == null
          ? '${o['text']}${o['enter'] == true ? '\n' : ''}'
          : switch (o['key']) {
              'enter' => '\n',
              'tab' => '\t',
              _ => '\x04',
            };
    }
    if (action == 'output') input['cursor'] = _integer(i, 'cursor', 0, 1 << 53);
    if (action == 'close') input['force'] = o['force'];
    if (mutates) {
      // Keep only public scope/digests/lengths in intent logs. No ordinary input
      // text, password, private key or complete remote environment is retained.
      final summary = Map<String, dynamic>.from(input)..remove('text');
      if (input['text'] case final String text) {
        summary.addAll({
          'digest': chiyoIntentDigest(text),
          'byteLength': utf8.encode(text).length,
        });
      }
      final intent = await _intents.remember(
        'ssh-$action',
        summary,
        operationId: o['operation'] as String?,
      );
      input['operationId'] = intent.operationId;
    }
    return client.execute(input);
  }
}
