import 'package:info_core/info_core.dart';

/// Browser exceptions can contain evaluated source and are never public errors.
class BrowserFillFailure implements Exception {
  const BrowserFillFailure(this.code);
  final String code;
  @override
  String toString() => 'BrowserFillFailure($code)';
}

class BrowserFormInspection {
  const BrowserFormInspection(this.target, this.structure);
  final BrowserFormTarget target;
  final Map<String, dynamic> structure;
}

String browserReceiptCode(Map<String, dynamic> receipt) =>
    const {
      'destination_changed',
      'ambiguous_form',
      'ambiguous_field',
      'not_password_field',
      'unavailable_target',
      'form_changed',
      'unsupported_password_value',
      'value_not_retained',
      'browser_operation_failed',
    }.contains(receipt['code'])
    ? receipt['code'] as String
    : 'browser_operation_failed';
