part of 'agent_client.dart';

extension _InformationFileClient on AgentClient {
  Future<Map<String, dynamic>> _executeInformationFileCommand(
    Map<String, dynamic> submitted,
  ) async {
    final input = <String, dynamic>{'protocolVersion': 2, ...submitted};
    try {
      if (utf8.encode(jsonEncode(input)).length > 16384) {
        throw const InformationFileFailure('limit_exceeded');
      }
      final fetching = input['command'] == 'file-fetch';
      if (fetching) {
        InformationFileFetchInput.fromJson(input);
      } else {
        InformationFileDeliveryInput.fromJson(input);
      }
      if (_session == null) {
        throw const InformationFileFailure('not_authorized');
      }
      final capabilities = await _call('/capabilities', {});
      if (capabilities['status'] == 'service_unavailable') {
        throw const InformationFileFailure('service_unavailable');
      }
      if (capabilities['protocolVersions'] is! List ||
          !(capabilities['protocolVersions'] as List).contains(2) ||
          capabilities['capabilities'] is! List ||
          !(capabilities['capabilities'] as List).contains(
            'information-attachments.v1',
          )) {
        throw const InformationFileFailure('unsupported_capability');
      }
      final action = (input['command'] as String).substring('file-'.length);
      if (fetching &&
          _remote != null &&
          deviceFileStateDirectory == null &&
          (capabilities['capabilities'] as List).contains(
            'information-device-delivery.v1',
          )) {
        throw const InformationFileFailure('unsupported_capability');
      }
      final result = await _call('/information-file/$action', {
        'sessionSecret': _session,
        ...input,
      }, timeout: const Duration(seconds: 30));
      if (result.length == 1 && result['status'] == 'service_unavailable') {
        if (action == 'status') {
          throw const InformationFileFailure('service_unavailable');
        }
        return {
          ...const InformationFileFailure(
            'delivery_unknown',
            operationClaimed: true,
          ).toJson(),
          if (fetching) 'operationId': input['operationId'],
          if (!fetching) 'deliveryId': input['deliveryId'],
        };
      }
      if (_remote != null &&
          result['status'] == 'ok' &&
          result['delivery'] is Map &&
          (result['delivery'] as Map)['deviceDelivery'] == true) {
        final directory = deviceFileStateDirectory;
        if (directory == null && fetching) {
          throw const InformationFileFailure(
            'unsupported_capability',
            operationClaimed: true,
          );
        }
        if (directory != null) {
          final files = DeviceInformationFiles(
            _remote.profile,
            directory,
            workerExecutable: _runtimeWorkerExecutable,
          );
          if (fetching) return await files.fetch(_session!, input, result);
          if (action == 'release') {
            return await files.release(_session!, result);
          }
        }
      }
      return result;
    } on InformationFileFailure catch (error) {
      return Map<String, dynamic>.from(error.toJson());
    } on Object {
      return Map<String, dynamic>.from(
        const InformationFileFailure(
          'delivery_io_failed',
          operationClaimed: true,
        ).toJson(),
      );
    }
  }
}
