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
      return result;
    } on InformationFileFailure catch (error) {
      return Map<String, dynamic>.from(error.toJson());
    }
  }
}
