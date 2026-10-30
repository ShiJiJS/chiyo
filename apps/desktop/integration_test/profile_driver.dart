import 'dart:convert';
import 'dart:io';
import 'package:integration_test/integration_test_driver.dart';

Future<void> main() async {
  final path = Platform.environment['ZHIYU_PROFILE_DRIVER_REPORT'];
  if (path == null || path.isEmpty) {
    throw StateError(
      'An explicit owned profile-driver report path is required',
    );
  }
  final seconds = int.parse(
    Platform.environment['ZHIYU_PROFILE_DRIVER_TIMEOUT_SECONDS'] ?? '240',
  );
  if (seconds < 60 || seconds > 900) throw StateError('Invalid driver timeout');
  await integrationDriver(
    timeout: Duration(seconds: seconds),
    writeResponseOnFailure: true,
    responseDataCallback: (data) async {
      await File(
        path,
      ).writeAsString(const JsonEncoder.withIndent('  ').convert(data));
    },
  );
}
