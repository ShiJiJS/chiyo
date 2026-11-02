part of 'agent_client.dart';

class _ImportFileClientFailure implements Exception {
  const _ImportFileClientFailure(this.result);
  final Map<String, dynamic> result;
}

extension _InformationImportClient on AgentClient {
  Future<Map<String, dynamic>> _executeUpdateCommand(
    Map<String, dynamic> input, {
    required bool revise,
  }) async {
    if (_session == null) return {'status': 'unauthorized'};
    if (input['update'] is! Map) return {'status': 'invalid_request'};
    final update = Map<String, dynamic>.from(input['update'] as Map);
    final attachments = update['attachments'];
    final hasFiles = attachments is List && attachments.isNotEmpty;
    if (hasFiles &&
        !revise &&
        (input['operationId'] is! String ||
            !RegExp(
              r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$',
            ).hasMatch(input['operationId'] as String))) {
      return {'status': 'invalid_operation_id'};
    }
    if (hasFiles || input.containsKey('operationId')) {
      final support = await _call('/capabilities', {});
      if (support['status'] != 'ok') return support;
      final capabilities = support['capabilities'] as List? ?? [];
      if (hasFiles &&
              (!capabilities.contains('information-file-upload.v1') ||
                  !capabilities.contains('information-file-update.v1')) ||
          !capabilities.contains('information-update-operations.v1')) {
        return {'status': 'unsupported_capability'};
      }
      final live = await _call('/session/check', {'sessionSecret': _session});
      if (live['status'] != 'ok') return live;
    }
    try {
      if (attachments != null) {
        update['attachments'] = await _prepareImportAttachments(
          attachments,
          rootOperation: revise
              ? 'update:${input['proposalId']}:${input['version']}'
              : 'update:${input['operationId'] ?? ''}',
          itemIndex: 0,
        );
      }
      UpdateInput.fromJson(update);
    } on _ImportFileClientFailure catch (e) {
      return e.result;
    } on Object {
      return {'status': 'invalid_request'};
    }
    return _call(revise ? '/update/revise' : '/update/submit', {
      'sessionSecret': _session,
      'update': update,
      if (revise) ...{
        'proposalId': input['proposalId'],
        'version': input['version'],
      } else if (input.containsKey('operationId'))
        'operationId': input['operationId'],
    });
  }

  Future<List<Map<String, dynamic>>> _prepareImportAttachments(
    Object? input, {
    required String rootOperation,
    required int itemIndex,
  }) async {
    if (input is! List || input.length > 50) {
      throw const _ImportFileClientFailure({'status': 'invalid_request'});
    }
    final result = <Map<String, dynamic>>[];
    var versionCount = 0;
    for (final raw in input) {
      final attachment = Map<String, dynamic>.from(raw as Map);
      final rawVersions = attachment['versions'];
      if (rawVersions is! List ||
          rawVersions.isEmpty ||
          rawVersions.length > 20) {
        throw const _ImportFileClientFailure({'status': 'invalid_request'});
      }
      final versions = <Map<String, dynamic>>[];
      for (final (index, rawVersion) in rawVersions.indexed) {
        if (++versionCount > 200) {
          throw const _ImportFileClientFailure({'status': 'invalid_request'});
        }
        final version = Map<String, dynamic>.from(rawVersion as Map);
        if (version.containsKey('filePath')) {
          if (version.keys.any(
                (k) => !{
                  'filePath',
                  'mediaType',
                  'label',
                  'sourceNote',
                }.contains(k),
              ) ||
              version['filePath'] is! String) {
            throw const _ImportFileClientFailure({
              'status': 'invalid_information_file',
            });
          }
          final operationId =
              'file-${sha256.convert(utf8.encode(jsonEncode([rootOperation, itemIndex, attachment['key'], index])))}';
          final upload = await _uploadImportOriginal(
            version['filePath'] as String,
            operationId,
            mediaType: version['mediaType'] as String?,
          );
          versions.add({
            'uploadId': upload['uploadId'],
            'label': version['label'] ?? '',
            'sourceNote': version['sourceNote'] ?? '',
          });
        } else {
          versions.add(version);
        }
      }
      attachment['versions'] = versions;
      // This validation accepts metadata only, never local paths or bytes.
      result.add(
        Map<String, dynamic>.from(
          ImportAttachmentInput.fromJson(attachment).submissionJson,
        ),
      );
    }
    return result;
  }

  Future<Map<String, dynamic>> _uploadImportOriginal(
    String path,
    String operationId, {
    String? mediaType,
  }) async {
    final file = File(path);
    late List<int> bytes;
    try {
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file ||
          stat.size > informationFileByteLimit) {
        throw const _ImportFileClientFailure({
          'status': 'invalid_information_file',
        });
      }
      final handle = await file.open();
      try {
        final length = await handle.length();
        if (length > informationFileByteLimit) {
          throw const _ImportFileClientFailure({'status': 'file_too_large'});
        }
        bytes = await handle.read(informationFileByteLimit + 1);
        final after = await file.stat();
        if (bytes.length != length ||
            await handle.length() != length ||
            after.modified != stat.modified) {
          throw const _ImportFileClientFailure({'status': 'source_changed'});
        }
      } finally {
        await handle.close();
      }
    } on _ImportFileClientFailure {
      rethrow;
    } on Object {
      throw const _ImportFileClientFailure({
        'status': 'invalid_information_file',
      });
    }
    final type = mediaType ?? ordinaryImportMediaType(path);
    final response = await _call('/import-file/submit', {
      'sessionSecret': _session,
      'operationId': operationId,
      'originalName': file.uri.pathSegments.last,
      'mediaType': type,
      'bytes': base64Encode(bytes),
    }, timeout: const Duration(seconds: 15));
    if (response['status'] == 'service_unavailable') {
      throw _ImportFileClientFailure({
        'status': 'upload_unknown',
        'operationId': operationId,
      });
    }
    if (response['status'] != 'ok') throw _ImportFileClientFailure(response);
    if (response['uploadId'] is! String ||
        response['byteLength'] != bytes.length ||
        response['sha256'] != sha256.convert(bytes).toString() ||
        response['originalName'] != file.uri.pathSegments.last ||
        response['mediaType'] != type) {
      throw _ImportFileClientFailure({
        'status': 'upload_unknown',
        'operationId': operationId,
      });
    }
    return response;
  }
}
