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
  await integrationDriver(
    timeout: const Duration(minutes: 4),
    writeResponseOnFailure: true,
    responseDataCallback: (data) async {
      await File(
        path,
      ).writeAsString(const JsonEncoder.withIndent('  ').convert(data));
    },
  );
}
