part of 'chiyo_cli.dart';

Map<String, dynamic> _publicProposalTemplate(Map<String, dynamic> template) {
  Map<String, dynamic> example(Object? raw) {
    final original = Map<String, dynamic>.from(raw as Map);
    final result = <String, dynamic>{
      for (final key in ['title', 'purpose', 'items'])
        if (original.containsKey(key)) key: original[key],
    };
    if (result['items'] is List) {
      result['items'] = [
        for (final raw in result['items'] as List)
          {
            for (final e in (raw as Map).entries)
              if (!{'templateVersion', 'templateDigest'}.contains(e.key))
                e.key as String: e.value,
          },
      ];
    }
    return result;
  }

  return {
    ...template,
    if (template['submissionExample'] != null)
      'submissionExample': example(template['submissionExample']),
    if (template['submissionExamples'] is List)
      'submissionExamples': [
        for (final e in template['submissionExamples'] as List) example(e),
      ],
    'workflow': {
      'check': 'chiyo proposals check --input proposal.json --json',
      'submit':
          'chiyo proposals submit --check CHECK_ID --input proposal.json --json',
      'description':
          '只填写业务内容。CLI 自动取得模板版本并绑定当前聊天；检查不会创建提案。文件相对于此 JSON 所在目录解析；标准输入的路径相对于当前目录。提交时使用检查返回的 checkId，内容、附件或模板变化后重新检查。',
    },
  };
}

extension _ChiyoProposals on ChiyoCli {
  Future<void> _proposalSupport(AgentClient client) async {
    final result = await client.execute({'command': 'capabilities'});
    if (result['status'] != 'ok' ||
        !(result['capabilities'] as List? ?? []).contains(
          'information-proposal-precheck.v1',
        )) {
      throw const _PublicFailure(
        'unsupported_capability',
        '当前服务不支持提案预检，请先更新服务。',
        3,
      );
    }
  }

  /// Canonical business input is frozen separately from public template
  /// definitions and file hashes. Passwords and document contents never enter
  /// the local intent/check journal.
  Future<Map<String, dynamic>> _proposalSource(
    Map<String, dynamic> raw,
    String kind,
    String? sourcePath,
  ) async {
    final allowed = {
      'title',
      'purpose',
      if (kind == 'import') 'items',
      if (kind == 'update') 'update',
      if (kind == 'delete') ...['itemId', 'baseVersion', 'fieldId'],
    };
    if (raw.keys.any((k) => !allowed.contains(k)) ||
        [
          'title',
          'purpose',
        ].any((k) => raw[k] is! String || (raw[k] as String).trim().isEmpty) ||
        !validSubmissionMetadata(
          title: raw['title'] as String,
          purpose: raw['purpose'] as String,
        )) {
      throw const ChiyoUsageFailure('业务文件只填写提案主题、用途和内容，不填写内部协议、聊天标识或操作编号。');
    }
    final source = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(raw)) as Map,
    );
    final base = sourcePath == null
        ? Directory.current
        : File(sourcePath).absolute.parent;
    void path(Map<String, dynamic> value) {
      final p = value['filePath'];
      if (p == null) return;
      if (p is! String || p.isEmpty || p.contains('\u0000')) {
        throw const ChiyoUsageFailure('filePath 必须是有效的文件路径。');
      }
      value['filePath'] = File(p).isAbsolute
          ? p
          : base.uri.resolveUri(File(p).uri).toFilePath();
    }

    for (final row in _proposalRows(source, kind)) {
      final attachments = row['attachments'];
      if (attachments != null) {
        if (attachments is! List || attachments.length > 50) {
          throw const ChiyoUsageFailure('附件列表不正确。');
        }
        for (final attachment in attachments) {
          if (attachment is! Map<String, dynamic> ||
              attachment['versions'] is! List) {
            throw const ChiyoUsageFailure('附件需要版本列表。');
          }
          for (final version in attachment['versions'] as List) {
            if (version is! Map<String, dynamic> ||
                !version.containsKey('filePath') ||
                version.keys.any(
                  (k) => !{
                    'filePath',
                    'mediaType',
                    'label',
                    'sourceNote',
                  }.contains(k),
                )) {
              throw const ChiyoUsageFailure(
                '附件版本填写 filePath，可附 mediaType、label 和 sourceNote；不要填写上传编号。',
              );
            }
            path(version);
          }
        }
      }
      if (row['credential'] case final Map<String, dynamic> credential) {
        path(credential);
      }
    }
    return source;
  }

  List<Map<String, dynamic>> _proposalRows(
    Map<String, dynamic> source,
    String kind,
  ) {
    if (kind == 'delete') return [];
    if (kind == 'update') {
      if (source['update'] is! Map<String, dynamic>) {
        throw const ChiyoUsageFailure('修改提案需要 update 对象。');
      }
      return [source['update'] as Map<String, dynamic>];
    }
    final rows = source['items'];
    if (rows is! List ||
        rows.isEmpty ||
        rows.length > 20 ||
        rows.any((r) => r is! Map<String, dynamic>)) {
      throw const ChiyoUsageFailure('新增提案需要 1–20 项 items。');
    }
    return rows.cast<Map<String, dynamic>>();
  }

  Future<({String sha256, int byteLength})> _proposalFile(
    String path,
    int limit,
  ) async {
    try {
      final file = File(path), before = await File(path).stat();
      if (before.type != FileSystemEntityType.file || before.size > limit) {
        throw const FormatException();
      }
      var size = 0;
      final digest = await sha256
          .bind(
            file.openRead().map((chunk) {
              size += chunk.length;
              if (size > limit) throw const FormatException();
              return chunk;
            }),
          )
          .single;
      final after = await file.stat();
      if (size != before.size ||
          after.size != size ||
          after.modified != before.modified) {
        throw const FormatException();
      }
      return (sha256: digest.toString(), byteLength: size);
    } on Object {
      throw const _PublicFailure(
        'source_changed',
        '来源文件不可用、超过大小限制或读取时发生变化，请核对后重新检查。',
        8,
      );
    }
  }

  Future<
    ({
      Map<String, dynamic> input,
      Map<String, dynamic> files,
      List<Map<String, dynamic>> templates,
    })
  >
  _prepareProposal(
    AgentClient client,
    Map<String, dynamic> source,
    String kind,
  ) async {
    final input = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(source)) as Map,
    );
    final files = <String, dynamic>{},
        templates = <String, Map<String, dynamic>>{};
    for (final row in _proposalRows(input, kind)) {
      final id = row['templateId'];
      if (kind == 'import' && id is! String) {
        throw const ChiyoUsageFailure(
          '每项新增内容都需要 templateId；先查询 templates list 和 templates examples。',
        );
      }
      if (id != null) {
        if (id is! String || id.isEmpty) {
          throw const ChiyoUsageFailure('templateId 不正确。');
        }
        var template = templates[id];
        if (template == null) {
          final result = await client.execute({
            'command': 'template-read',
            'templateId': id,
          });
          if (result['status'] != 'ok' ||
              result['template'] is! Map<String, dynamic>) {
            throw _PublicFailure(
              result['status'] as String? ?? 'template_missing',
              '模板不可用，请重新查询当前资料库的模板。',
              3,
            );
          }
          template = result['template'] as Map<String, dynamic>;
          if (template['version'] is! String ||
              template['digest'] is! String ||
              template['definition'] is! Map) {
            throw const _PublicFailure(
              'invalid_response',
              '模板信息不完整，请检查服务版本。',
              3,
            );
          }
          templates[id] = template;
        }
        for (final key in ['version', 'digest']) {
          final target = key == 'version'
              ? 'templateVersion'
              : 'templateDigest';
          if (row.containsKey(target) && row[target] != template[key]) {
            throw const _PublicFailure(
              'template_changed',
              '业务文件指定的模板已变化，请查看新模板后重新检查。',
              8,
            );
          }
          row[target] = template[key];
        }
      }
      for (final attachment in row['attachments'] as List? ?? []) {
        final a = attachment as Map<String, dynamic>;
        for (final version in a['versions'] as List) {
          final v = version as Map<String, dynamic>,
              path = version['filePath'] as String;
          final pin = await _proposalFile(path, informationFileByteLimit);
          files[path] = {'sha256': pin.sha256, 'byteLength': pin.byteLength};
          v.remove('filePath');
          v.addAll({
            'originalName': File(path).uri.pathSegments.last,
            'mediaType': v['mediaType'] ?? ordinaryImportMediaType(path),
            'byteLength': pin.byteLength,
            'sha256': pin.sha256,
          });
        }
      }
      if (row['credential'] case final Map<String, dynamic> credential) {
        if (credential.containsKey('filePath')) {
          if (credential.keys.any(
                (k) => !{
                  'source',
                  'contextExposed',
                  'filePath',
                  'account',
                }.contains(k),
              ) ||
              credential['source'] != 'agentFile') {
            throw const ChiyoUsageFailure('凭据文件格式不正确。');
          }
          final path = credential['filePath'] as String;
          final pin = await _proposalFile(path, 1048576);
          final handle = await File(path).open();
          late List<int> bytes;
          try {
            bytes = await handle.read(1048577);
            if (bytes.length > 1048576 ||
                await handle.length() != bytes.length) {
              throw const _PublicFailure('source_changed', '凭据文件已变化，请重新检查。', 8);
            }
          } finally {
            await handle.close();
          }
          if (pin.sha256 != sha256.convert(bytes).toString() ||
              pin.byteLength != bytes.length) {
            throw const _PublicFailure('source_changed', '凭据文件已变化，请重新检查。', 8);
          }
          files[path] = {'sha256': pin.sha256, 'byteLength': pin.byteLength};
          credential.remove('filePath');
          credential.addAll({
            'fileName': File(path).uri.pathSegments.last,
            'bytes': base64Encode(bytes),
          });
          bytes.fillRange(0, bytes.length, 0);
        }
        try {
          CredentialImportInput.fromJson(credential);
        } on Object {
          throw const ChiyoUsageFailure('凭据来源或内容格式不正确，请查询此凭据模板的填写示例。');
        }
      }
    }
    input.addAll({
      'agentName': _activeContext.agentName,
      'externalChatId': _activeContext.chatId,
    });
    return (input: input, files: files, templates: templates.values.toList());
  }

  Future<Map<String, dynamic>> _proposal(
    ChiyoInvocation i,
    AgentClient client,
  ) async {
    await _proposalSupport(client);
    final kind = i.options['kind'] as String;
    final sourcePath = i.options['input'] == '-'
        ? null
        : File(i.options['input'] as String).absolute.path;
    final source = await _proposalSource(
      await _businessInput(i, 6000000),
      kind,
      sourcePath,
    );
    if (i.path == 'proposals check') {
      final prepared = await _prepareProposal(client, source, kind);
      final result = await client.execute({
        'command': 'proposals-check',
        'kind': kind,
        'input': prepared.input,
      });
      if (result['status'] != 'ok') return result;
      final payload = <String, dynamic>{
        'kind': kind,
        'sourceDigest': chiyoIntentDigest(source),
        'files': prepared.files,
        'templates': prepared.templates,
      };
      final checked = await _intents.remember(
        'proposal-check',
        payload,
        operationId: 'check-${chiyoIntentDigest(payload)}',
      );
      return {
        ...result,
        'checkId': checked.operationId,
        'templates': [
          for (final t in prepared.templates)
            {'id': t['id'], 'version': t['version'], 'digest': t['digest']},
        ],
        'next':
            'chiyo proposals submit --kind $kind --check ${checked.operationId} --input FILE',
      };
    }
    final checked = await _intents.read(_required(i, 'check'));
    if (checked == null ||
        checked.kind != 'proposal-check' ||
        checked.payload['kind'] != kind ||
        checked.payload['sourceDigest'] != chiyoIntentDigest(source)) {
      return {'status': 'check_changed'};
    }
    final intent = await _intents.remember('proposal-submit', {
      'checkId': checked.operationId,
      'sourceDigest': checked.payload['sourceDigest'],
      'sourcePath': ?sourcePath,
      'kind': kind,
    }, operationId: i.options['operation'] as String?);
    return _submitCheckedProposal(client, intent, checked, source);
  }

  Future<Map<String, dynamic>> _submitCheckedProposal(
    AgentClient client,
    ChiyoIntent intent,
    ChiyoIntent checked,
    Map<String, dynamic> source,
  ) async {
    final kind = checked.payload['kind'] as String;
    final prepared = await _prepareProposal(client, source, kind);
    if (chiyoIntentDigest(prepared.files) !=
            chiyoIntentDigest(checked.payload['files']) ||
        chiyoIntentDigest(prepared.templates) !=
            chiyoIntentDigest(checked.payload['templates'])) {
      return {
        'status':
            chiyoIntentDigest(prepared.files) !=
                chiyoIntentDigest(checked.payload['files'])
            ? 'source_changed'
            : 'template_changed',
        'operationId': intent.operationId,
      };
    }
    final result = await client.execute({
      'command': 'proposals-check',
      'kind': kind,
      'input': prepared.input,
    });
    if (result['status'] != 'ok') {
      return {...result, 'operationId': intent.operationId};
    }
    // Delete's old protocol has no creation idempotency. Do not silently send
    // through it; the new capability is required before enabling this branch.
    if (kind == 'delete') {
      return {
        'status': 'unsupported_capability',
        'operationId': intent.operationId,
      };
    }
    final submission = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(source)) as Map,
    );
    final pins = {for (final t in prepared.templates) t['id'] as String: t};
    for (final row in _proposalRows(submission, kind)) {
      if (row['templateId'] case final String id) {
        row.addAll({
          'templateVersion': pins[id]!['version'],
          'templateDigest': pins[id]!['digest'],
        });
      }
    }
    final response = await client.execute(
      {
        ...submission,
        'command': '$kind-submit',
        'operationId': intent.operationId,
        'agentName': _activeContext.agentName,
        'externalChatId': _activeContext.chatId,
        'submissionVersion': 1,
      },
      checkedSourceFiles: {
        for (final e in prepared.files.entries)
          e.key: (
            sha256: (e.value as Map)['sha256'] as String,
            byteLength: e.value['byteLength'] as int,
          ),
      },
    );
    return {
      ...response,
      'operationId': intent.operationId,
      'checkId': checked.operationId,
      if (response['status'] == 'service_unavailable')
        'status': 'request_unknown',
    };
  }

  Future<Map<String, dynamic>> _recoverProposal(
    AgentClient client,
    ChiyoIntent intent,
  ) async {
    final original = await client.execute({
      'command': 'operations-show',
      'id': intent.operationId,
    });
    if (original['status'] != 'not_found') {
      return {...original, 'operationId': intent.operationId};
    }
    final path = intent.payload['sourcePath'];
    if (path is! String) {
      return {
        'status': 'source_required',
        'operationId': intent.operationId,
        'message': '原内容来自标准输入；请带原检查编号和操作编号重新提供同一份内容。',
      };
    }
    final checked = await _intents.read(intent.payload['checkId'] as String);
    if (checked == null || checked.kind != 'proposal-check') {
      return {'status': 'check_changed', 'operationId': intent.operationId};
    }
    final raw = decodeProtocolObject(
      await _read(File(path).openRead(), 6000000),
      maxBytes: 6000000,
    );
    final source = await _proposalSource(
      raw,
      intent.payload['kind'] as String,
      path,
    );
    if (chiyoIntentDigest(source) != intent.payload['sourceDigest']) {
      return {'status': 'source_changed', 'operationId': intent.operationId};
    }
    await _proposalSupport(client);
    return _submitCheckedProposal(client, intent, checked, source);
  }
}
