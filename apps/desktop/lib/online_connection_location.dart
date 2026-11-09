import 'package:info_core/macos_desktop_control.dart';

/// Select a named private connection configuration without changing the OS home
/// directory or reading another configuration. Names never contain paths.
String onlineConnectionDirectory(String base, List<String> arguments) {
  if (arguments.isEmpty) return base;
  if (arguments.length != 2 ||
      arguments.first != '--connection-profile' ||
      !MacDesktopControl.validProfileName(arguments.last)) {
    throw const FormatException('invalid_connection_profile');
  }
  return '$base/profiles/${arguments.last}';
}
