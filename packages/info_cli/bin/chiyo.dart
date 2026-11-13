import 'dart:io';
import 'package:info_cli/chiyo_cli.dart';

Future<void> main(List<String> args) async {
  final result = await ChiyoCli().run(args);
  stdout.writeln(result.render());
  exitCode = result.exitCode;
}
