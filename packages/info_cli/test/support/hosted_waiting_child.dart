import 'dart:io';

Future<void> main(List<String> args) async {
  stdout.writeln('synthetic hosted task ready');
  await stdout.flush();
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!await File(args.first).exists()) {
    if (DateTime.now().isAfter(deadline)) exit(70);
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
