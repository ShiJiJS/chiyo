import 'dart:io';
import 'agent_bundle_observation.dart';
import 'macos_agent_bundle.dart';
import 'windows_agent_bundle.dart';
export 'agent_bundle_observation.dart';

/// Observe only the current executable's package. Never discover a different
/// installation, private connection, host registration or chat association.
class AgentBundle {
  AgentBundle({String? executable})
    : _mac = MacAgentBundle(executable: executable),
      _windows = WindowsAgentBundle(executable: executable);
  final MacAgentBundle _mac;
  final WindowsAgentBundle _windows;
  Future<AgentBundleObservation> read({bool rehash = false}) {
    if (Platform.isWindows) return _windows.read(rehash: rehash);
    if (Platform.isMacOS) return _mac.read(rehash: rehash);
    return Future.value(const AgentBundleObservation(status: 'not_packaged'));
  }
}
