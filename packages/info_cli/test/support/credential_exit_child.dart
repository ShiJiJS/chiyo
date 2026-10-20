import 'dart:io';

Future<void> main() async {
  await Future<void>.delayed(const Duration(milliseconds: 250));
  exitCode = 7;
}
