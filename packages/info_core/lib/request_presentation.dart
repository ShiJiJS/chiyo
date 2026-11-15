/// Agent-authored display text, independent of the executable/target contract.
/// `purpose` remains the persisted summary for older readers and old records.
class RequestPresentation {
  const RequestPresentation._(this.title, this.summary);
  static const capability = 'request-presentation.v1';
  static const titleLimit = 80, summaryLimit = 600;
  final String title, summary;
  bool get structured => title.isNotEmpty;

  factory RequestPresentation.fromJson(Map<String, dynamic> input) {
    if (input.containsKey('summary') && input.containsKey('purpose')) {
      throw const FormatException('summary 和 purpose 不能同时填写。');
    }
    final modern = input.containsKey('title') || input.containsKey('summary');
    final title = input['title'];
    final summary = input[input.containsKey('summary') ? 'summary' : 'purpose'];
    if (modern &&
        (title is! String ||
            title.trim().isEmpty ||
            title.length > titleLimit ||
            RegExp(r'[\x00-\x1f\x7f]').hasMatch(title))) {
      throw const FormatException('title 请填写 1–80 字的单行标题。');
    }
    if (summary is! String ||
        (modern ? summary.trim().isEmpty : summary.isEmpty) ||
        summary.length > (modern ? summaryLimit : 2000) ||
        summary.contains('\u0000')) {
      throw FormatException(
        modern ? 'summary 请填写 1–600 字的用途概要。' : 'purpose 请填写 1–2000 字的用途说明。',
      );
    }
    return RequestPresentation._(modern ? title as String : '', summary);
  }

  /// No duplicate summary is stored. The old field is a wire/storage adapter.
  Map<String, Object?> toProtocolJson() => {
    if (structured) 'title': title,
    'purpose': summary,
  };
  Map<String, Object?> toJson() =>
      structured ? {'title': title, 'summary': summary} : {'purpose': summary};
}
