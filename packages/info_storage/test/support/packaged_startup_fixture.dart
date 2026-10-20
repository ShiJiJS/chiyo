// Synthetic damaged profiles for observing the actual packaged Windows app.
// This creates no default-profile data and never prints key material.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';

Future<Map<String, Object?>> digest(File file) async => {
  'exists': await file.exists(),
  if (await file.exists()) ...{
    'bytes': await file.length(),
    'sha256': sha256.convert(await file.readAsBytes()).toString(),
  },
};

Future<void> main(List<String> args) async {
  if (!Platform.isWindows || args.length != 1) {
    throw StateError('Windows and an explicit isolated root are required');
  }
  final root = Directory(args.single);
  final actual = await root.resolveSymbolicLinks();
  final temp = await Directory.systemTemp.resolveSymbolicLinks();
  if (root.absolute.path.toLowerCase() != actual.toLowerCase() ||
      !actual.toLowerCase().startsWith(
        '$temp${Platform.pathSeparator}'.toLowerCase(),
      ) ||
      !root.uri.pathSegments
          .where((s) => s.isNotEmpty)
          .last
          .startsWith('aim-packaged-startup-') ||
      await root.list().isEmpty == false) {
    throw StateError('Refusing a nonempty or unowned fixture directory');
  }
  final cases = <Map<String, Object?>>[];
  for (final name in [
    'missing-key',
    'damaged-key',
    'wrong-key',
    'corrupt-database',
  ]) {
    final local = Directory('${root.path}/$name');
    final library = Directory('${local.path}/AgentInfoManage');
    final envelope = File('${library.path}/database-key.dpapi');
    final database = File('${library.path}/library.db');
    final keys = WindowsDatabaseKeyStore(envelope.path);
    final repo = await EncryptedInformationRepository.open(library.path, keys);
    final service = InformationService(repository: repo);
    try {
      await service.owner.createInformation(
        'Packaged startup synthetic record',
        'Not user data',
        const [FieldInput('Host', '', 'synthetic.example.invalid')],
      );
    } finally {
      await service.close();
      await repo.close();
    }
    switch (name) {
      case 'missing-key':
        await envelope.delete();
      case 'damaged-key':
        await envelope.writeAsBytes(utf8.encode('SYNTHETIC_INVALID_ENVELOPE'));
      case 'wrong-key':
        await envelope.delete();
        final random = Random.secure();
        final replacement = List.generate(32, (_) => random.nextInt(256));
        try {
          await keys.create(replacement);
        } finally {
          replacement.fillRange(0, replacement.length, 0);
        }
      case 'corrupt-database':
        await database.writeAsBytes(List.filled(4096, 83));
    }
    cases.add({
      'case': name,
      'localAppData': local.path,
      'protectedFiles': {
        'AgentInfoManage/library.db': await digest(database),
        'AgentInfoManage/database-key.dpapi': await digest(envelope),
      },
    });
  }
  await File('${root.path}/fixtures.json').writeAsString(
    const JsonEncoder.withIndent('  ').convert({'cases': cases}),
    flush: true,
  );
  stdout.writeln('{"status":"synthetic_profiles_ready","cases":4}');
}
