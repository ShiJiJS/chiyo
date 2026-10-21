// Exercise the signed host's snapshot validator with actual AOT migration data.
import 'dart:convert';
import 'dart:io';

import 'macos-schema-upgrade-probe.dart' as fixture;

Future<void> main() async {
  final input = jsonDecode(await stdin.transform(utf8.decoder).join()) as Map;
  final original = input['original'] as Map;
  final migrated = input['migrated'] as Map;
  final reopened = input['reopened'] as Map;
  fixture.verifySchemaUpgradeSnapshot(
    migrated['beforeVerificationOperations'] as Map,
    original,
    migratingLegacy: true,
  );
  fixture.verifySchemaUpgradeSnapshot(
    reopened['beforeVerificationOperations'] as Map,
    migrated,
    migratingLegacy: false,
  );
  var refused = 0;
  void mustRefuse(Map snapshot, Map baseline, {bool migration = false}) {
    try {
      fixture.verifySchemaUpgradeSnapshot(
        snapshot,
        baseline,
        migratingLegacy: migration,
      );
    } on StateError {
      refused++;
      return;
    }
    throw StateError('Changed baseline unexpectedly accepted');
  }

  // Reproduce the original bug: old rows are not a post-verification baseline.
  mustRefuse(reopened['beforeVerificationOperations'] as Map, original);
  final tables =
      (reopened['beforeVerificationOperations'] as Map)['tables'] as Map;
  for (final name in tables.keys) {
    final changed =
        jsonDecode(jsonEncode(reopened['beforeVerificationOperations'])) as Map;
    ((changed['tables'] as Map)[name] as Map)['sha256'] = 'changed';
    mustRefuse(changed, migrated);
  }
  final missing =
      jsonDecode(jsonEncode(reopened['beforeVerificationOperations'])) as Map;
  (missing['tables'] as Map).remove('access_records');
  mustRefuse(missing, migrated);
  stdout.writeln(
    jsonEncode({
      'migrationAndReopenBaselinesAccepted': true,
      'changedTableCasesRefused': tables.length,
      'oldBaselineAndMissingTableRefused': refused == tables.length + 2,
    }),
  );
}
