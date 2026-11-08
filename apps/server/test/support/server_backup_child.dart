// Process identity for an isolated crash test; the service entry is unchanged.
import 'dart:convert';
import 'dart:io';
import '../../bin/server.dart' as service;

Future<void> main(List<String> args) async {
  stdout.writeln(jsonEncode({'fixturePid': pid}));
  await stdout.flush();
  await service.main(['serve', args.single]);
}
