import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:integration_test/integration_test.dart';

/// Opt-in prerequisite for #44. Runs the production identity/version inspector
/// inside the signed sandbox, without shell credentials or external API calls.
/// A readable executable is not yet proof of approved credential delivery.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Mac sandbox inspects the selected external GH and AWS tools', (
    tester,
  ) async {
    expect(Platform.isMacOS, isTrue);
    const tools = {
      'gh_token': String.fromEnvironment('MAC_QA_GH_EXE'),
      'aws_shared_credentials': String.fromEnvironment('MAC_QA_AWS_EXE'),
    };
    final outcomes = <Map<String, Object?>>[];
    await tester.runAsync(() async {
      for (final entry in tools.entries) {
        expect(
          entry.value,
          startsWith('/'),
          reason: 'Supply both QA tool paths',
        );
        final outcome = <String, Object?>{'receiver': entry.key};
        outcomes.add(outcome);
        try {
          final file = await File(entry.value).open();
          await file.close();
          outcome['readable'] = true;
          await inspectCredentialExecutable(entry.value, entry.key);
          outcome['inspected'] = true;
        } on CredentialUseFailure catch (error) {
          outcome['errorCode'] = error.code;
        } on FileSystemException catch (error) {
          outcome['fileError'] = error.osError?.errorCode;
        }
      }
    });
    // Report both tools even when the first one is denied.
    // No environment values, credentials or raw executable output are logged.
    debugPrint('MAC_EXTERNAL_TOOL_PROBE=${jsonEncode(outcomes)}');
    expect(outcomes, hasLength(2));
    expect(
      outcomes.every((row) => row['inspected'] == true),
      isTrue,
      reason: 'The sandbox needs actual access to each selected tool.',
    );
  }, timeout: const Timeout(Duration(minutes: 2)));
}
