import 'dart:io';

Future<void> main(List<String> args) async {
  stdout.writeln('ready');
  final release = File(args.single);
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (!await release.exists()) {
    if (DateTime.now().isAfter(deadline)) exit(70);
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  stdout.writeln('finished');
}
