import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';

void main(List<String> args) {
  final folder = WindowsPrivateFiles.directory(Directory(args[0]));
  WindowsPrivateFiles.reserve(File('${folder.path}/shared.lock'));
  final writer = int.parse(args[1]);
  WindowsPrivateFiles.writeSecret(
    File('${folder.path}/state.json'),
    jsonEncode({'writer': writer, 'payload': List.filled(1000, writer)}),
  );
}
