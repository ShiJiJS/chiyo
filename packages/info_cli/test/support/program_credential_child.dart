import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final mode = args.first;
  final bytes = switch (mode) {
    'program_stdin' => await stdin.fold<List<int>>(
      [],
      (all, next) => all..addAll(next),
    ),
    'program_env' => utf8.encode(Platform.environment['SYNTHETIC_SECRET']!),
    _ => await File(args[1]).readAsBytes(),
  };
  stdout.writeln('received:${bytes.length}');
  stdout.add(bytes);
  await stdout.flush();
  stderr.add(bytes);
  await stderr.flush();
  if (mode == 'program_file') stdout.writeln('\nmaterial:${args[1]}');
}
