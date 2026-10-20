@TestOn('mac-os')
library;

import 'package:test/test.dart';
import 'mixed_lifecycle_windows_test.dart' as lifecycle;

// Reuse the full assertions with real Darwin workers/files and SQLCipher.
// Focused input is a controlled queue probe; Keychain and real Codex events
// have separate acceptance tickets and are not implied by this fixture.
void main() => lifecycle.main(runOnMacOS: true);
