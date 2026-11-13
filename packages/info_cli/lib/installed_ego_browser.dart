import 'dart:io';

/// Resolve an installed browser helper internally. Agent business input never
/// selects an executable; this does not inspect profiles or start the browser.
Future<String?> findInstalledEgoBrowser({
  Map<String, String>? environment,
}) async {
  final env = environment ?? Platform.environment;
  final candidates = <String>[];
  final name = Platform.isWindows ? 'ego-browser.exe' : 'ego-browser';
  if (Platform.isMacOS) {
    var home = env['HOME'];
    const container = '/Library/Containers/com.example.infoDesktop/Data';
    if (home != null && home.endsWith(container)) {
      home = home.substring(0, home.length - container.length);
    }
    if (home != null && Directory(home).isAbsolute) {
      candidates.add('$home/.local/bin/$name');
    }
  }
  final path = env['PATH'] ?? env['Path'] ?? '';
  for (final folder in path.split(Platform.isWindows ? ';' : ':')) {
    if (folder.isNotEmpty && Directory(folder).isAbsolute) {
      candidates.add('$folder/$name');
    }
  }
  if (Platform.isWindows) {
    candidates.addAll(await _windowsInstallCandidates(env));
  }
  for (final path in candidates) {
    try {
      final file = File(path);
      if (await FileSystemEntity.type(file.path) != FileSystemEntityType.file) {
        continue;
      }
      final resolved = File(await file.resolveSymbolicLinks());
      if (!Platform.isWindows && (await resolved.stat()).mode & 0x49 == 0) {
        continue;
      }
      return resolved.path;
    } on Object {
      // An unavailable optional helper does not substitute another target.
    }
  }
  return null;
}

/// Ego's Windows installer keeps the helper in a numbered Application folder.
/// Explorer-launched Apps can retain a PATH pointing at a removed old version.
/// Inspect only these vendor installation roots, never user browser profiles,
/// registry credentials, Skill links or arbitrary folders under AppData.
Future<List<String>> _windowsInstallCandidates(
  Map<String, String> environment,
) async {
  String? variable(String key) => environment.entries
      .where((e) => e.key.toLowerCase() == key.toLowerCase())
      .map((e) => e.value)
      .firstOrNull;
  final roots = <String>{};
  for (final key in const [
    'ProgramW6432',
    'ProgramFiles',
    'ProgramFiles(x86)',
  ]) {
    final base = variable(key);
    if (base != null && Directory(base).isAbsolute) {
      roots.add('$base/Citro Labs/ego lite/Application');
    }
  }
  final candidates = <String>[];
  for (final root in roots) {
    try {
      if (await FileSystemEntity.type(root, followLinks: false) !=
          FileSystemEntityType.directory) {
        continue;
      }
      final versions = <({String path, List<int> number})>[];
      var count = 0;
      await for (final entry in Directory(root).list(followLinks: false)) {
        if (++count > 256) {
          versions.clear();
          break;
        }
        final name = entry.path.replaceAll('\\', '/').split('/').last;
        if (entry is Directory &&
            RegExp(r'^[0-9]{1,9}(\.[0-9]{1,9}){3}$').hasMatch(name)) {
          versions.add((
            path: entry.path,
            number: name.split('.').map(int.parse).toList(),
          ));
        }
      }
      versions.sort((a, b) {
        for (var i = 0; i < 4; i++) {
          final result = b.number[i].compareTo(a.number[i]);
          if (result != 0) return result;
        }
        return a.path.compareTo(b.path);
      });
      for (final version in versions) {
        final helper = '${version.path}/ego-browser.exe';
        if (await FileSystemEntity.type(helper, followLinks: false) ==
            FileSystemEntityType.file) {
          candidates.add(helper);
        }
      }
    } on Object {
      /* An absent installation is an optional unavailable provider. */
    }
  }
  return candidates;
}
