part of 'info_core.dart';

/// Shared local/remote input loop. The caller owns preparation, durable intent,
/// material acquisition, terminal audit and disposal. Authorization is checked
/// immediately before each bounded native batch, including the first one.
Future<FocusedFillBatchResult> sendPreparedFocusedFill(
  PreparedFocusedFill prepared,
  List<int> secretBytes, {
  required Future<void> Function() beforeBatch,
}) async {
  List<int>? units;
  var anySent = false, nativeInFlight = false;
  try {
    units = List<int>.of(utf8.decode(secretBytes).codeUnits);
    if (units.isEmpty ||
        units.length > 4096 ||
        units.any((c) => c < 32 || c == 127)) {
      throw const CredentialUseFailure('unsupported_secret');
    }
    for (var start = 0; start < units.length;) {
      var end = min(start + 16, units.length);
      if (end < units.length &&
          units[end - 1] >= 0xd800 &&
          units[end - 1] <= 0xdbff &&
          units[end] >= 0xdc00 &&
          units[end] <= 0xdfff) {
        end--;
      }
      await beforeBatch();
      final batch = List<int>.of(units.sublist(start, end));
      FocusedFillBatchResult result;
      try {
        nativeInFlight = true;
        result = await prepared.sendBatch(batch);
        nativeInFlight = false;
      } finally {
        batch.fillRange(0, batch.length, 0);
      }
      if (result.state == FocusedFillState.sent && result.errorCode != null) {
        return const FocusedFillBatchResult(
          FocusedFillState.unknown,
          'fill_unknown',
        );
      }
      if (result.state != FocusedFillState.sent) {
        final state = result.state == FocusedFillState.checking
            ? FocusedFillState.unknown
            : result.state == FocusedFillState.refused && anySent
            ? FocusedFillState.partial
            : result.state;
        return FocusedFillBatchResult(
          state,
          focusedFillErrorCodes.contains(result.errorCode)
              ? result.errorCode
              : 'fill_unknown',
        );
      }
      anySent = true;
      start = end;
    }
    return const FocusedFillBatchResult(FocusedFillState.sent);
  } on Object catch (error) {
    return FocusedFillBatchResult(
      nativeInFlight
          ? FocusedFillState.unknown
          : anySent
          ? FocusedFillState.partial
          : FocusedFillState.refused,
      error is CredentialUseFailure &&
              focusedFillErrorCodes.contains(error.code)
          ? error.code
          : 'fill_unknown',
    );
  } finally {
    units?.fillRange(0, units.length, 0);
  }
}
