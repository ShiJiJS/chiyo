/// Select a named private connection configuration without changing the OS home
/// directory or reading another configuration. Names never contain paths.
String onlineConnectionDirectory(String base, List<String> arguments) {
  if (arguments.isEmpty) return base;
  if (arguments.length != 2 ||
      arguments.first != '--connection-profile' ||
      !RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$').hasMatch(arguments.last)) {
    throw const FormatException('invalid_connection_profile');
  }
  return '$base/profiles/${arguments.last}';
}
