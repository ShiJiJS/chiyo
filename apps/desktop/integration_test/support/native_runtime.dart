import 'dart:io';
import 'package:integration_test/integration_test.dart';

/// Runtime evidence, independent of the launcher's requested build mode.
Map<String, Object> recordNativeRuntime(
  IntegrationTestWidgetsFlutterBinding binding,
  String directory,
) {
  const profile = bool.fromEnvironment('dart.vm.profile');
  const product = bool.fromEnvironment('dart.vm.product');
  if (const bool.fromEnvironment('ZHIYU_REQUIRED_PROFILE') && !profile) {
    throw StateError('This check requires a real Profile/AOT runtime');
  }
  final receipt = <String, Object>{
    'platform': Platform.operatingSystem,
    'profileMode': profile,
    'productMode': product,
    'debugMode': !profile && !product,
    'nativeEvidenceDirectory': directory,
  };
  binding.reportData = {'runtime': receipt};
  return receipt;
}
