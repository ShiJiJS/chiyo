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
    credentialBatchErrorCodes.contains(receipt['code'])
    ? receipt['code'] as String
    : 'browser_operation_failed';

String browserDispatchError(Object error) {
  final code = error is BrowserFillFailure
      ? error.code
      : error is CredentialUseFailure
      ? error.code
      : null;
  return browserReceiptCode({'code': code});
}
