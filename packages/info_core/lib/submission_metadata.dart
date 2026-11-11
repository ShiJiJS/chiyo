/// Display metadata only. These values never identify an authorization session
/// or replace a device/session capability. Empty values remain valid for legacy
/// records; new command requirements are enforced by the transport.
bool validSubmissionMetadata({
  String title = '',
  String agentName = '',
  String purpose = '',
  String externalChatId = '',
}) {
  final singleLine = RegExp(r'[\x00-\x1f\x7f]');
  return [
        title,
        agentName,
        externalChatId,
      ].every((value) => value.length <= 200 && !singleLine.hasMatch(value)) &&
      purpose.length <= 2000 &&
      !purpose.contains('\u0000');
}

String submissionChatLabel(String label, String externalChatId) =>
    externalChatId.isEmpty || label.contains(externalChatId)
    ? label
    : '$label · $externalChatId';

/// Versioned submissions require explicit public provenance. Legacy stored
/// records and older transports remain readable without inventing missing data.
Map<String, String> submissionMetadataErrors(
  Map<String, dynamic> input, {
  bool proposal = false,
}) {
  if (!input.containsKey('submissionVersion')) return const {};
  if (input['submissionVersion'] != 1) {
    return const {'submissionVersion': '不支持的提交格式，请更新 CLI。'};
  }
  final errors = <String, String>{};
  for (final entry in {
    if (proposal) 'title': '提案主题',
    'agentName': 'Agent 名称',
    'externalChatId': '聊天标识',
    'purpose': '本次用途',
  }.entries) {
    final value = input[entry.key];
    if (value is! String || value.trim().isEmpty) {
      errors[entry.key] = '请填写${entry.value}。';
    } else if (value.length > (entry.key == 'purpose' ? 2000 : 200) ||
        (entry.key != 'purpose' &&
            RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) ||
        value.contains('\u0000')) {
      errors[entry.key] = '${entry.value}过长或含无效字符。';
    }
  }
  return errors;
}
