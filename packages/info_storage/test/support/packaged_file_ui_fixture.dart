import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';

Future<void> main(List<String> args) async {
  if (args.length != 2)
    throw StateError('Explicit action and fixture required');
  final root = Directory(args[1]);
  final actual = await root.resolveSymbolicLinks();
  final temp = await Directory.systemTemp.resolveSymbolicLinks();
  if (root.absolute.path.toLowerCase() != actual.toLowerCase() ||
      !actual.toLowerCase().startsWith(
        '$temp${Platform.pathSeparator}'.toLowerCase(),
      ) ||
      !root.uri.pathSegments
          .where((s) => s.isNotEmpty)
          .last
          .startsWith('aim-packaged-file-ui-')) {
    throw StateError('Not an owned synthetic file UI fixture');
  }
  if (args.first == 'prepare' && !await root.list().isEmpty) {
    throw StateError('Fixture is not new');
  }
  final dir = '${root.path}/profile/AgentInfoManage';
  final repo = await EncryptedInformationRepository.open(
    dir,
    WindowsDatabaseKeyStore('$dir/database-key.dpapi'),
  );
  final service = InformationService(repository: repo);
  try {
    switch (args.first) {
      case 'prepare':
        await service.owner.setNotificationsEnabled(false);
        for (final version in [1, 2]) {
          await File(
            '${root.path}/synthetic-resume-v$version.txt',
          ).writeAsString('虚构简历第$version版，仅用于最终发行包文件界面验收。');
        }
        stdout.writeln(jsonEncode({'status': 'prepared'}));
      case 'inspect':
        final item = repo.items.single;
        final field = item.fields.single;
        final current = field.attachment!;
        final expected = await File(
          '${root.path}/synthetic-resume-v2.txt',
        ).readAsBytes();
        final actual = await repo.readInformationAttachmentChunk(
          current,
          0,
          expected.length,
        );
        final matches =
            actual.length == expected.length &&
            List.generate(
              actual.length,
              (i) => actual[i] == expected[i],
            ).every((same) => same);
        stdout.writeln(
          jsonEncode({
            'status': 'inspected',
            'information': repo.items.length,
            'version': item.version,
            'fileField': field.kind == FieldKind.file,
            'currentMatches': matches,
            'deliveries': repo.informationFileDeliveries.length,
            'noHeldCopies': repo.informationFileDeliveries.every(
              (delivery) => !delivery.holdsCopy,
            ),
          }),
        );
      default:
        throw StateError('Unknown fixture action');
    }
  } finally {
    await service.close();
    await repo.close();
  }
}
