import 'dart:io';
import 'package:info_remote/agent_connection.dart';
import 'package:test/test.dart';

void main() {
  test('Agent profiles reject owner identities and unsafe endpoints', () {
    final token = '${'a' * 22}.${'b' * 43}';
    for (final value in [
      'http://localhost:47126',
      'https://user@localhost',
      'https://localhost/path',
      'https://localhost/?query',
      'https://localhost:0',
    ]) {
      expect(
        () => AgentConnectionProfile(
          address: Uri.parse(value),
          deviceToken: token,
          serverId: 'synthetic-server-id',
        ),
        throwsFormatException,
      );
    }
    expect(
      () => AgentConnectionProfile(
        address: Uri.parse('https://localhost'),
        deviceToken: 'owner-token-is-not-a-device-token',
        serverId: 'synthetic-server-id',
      ),
      throwsFormatException,
    );
    final profile = AgentConnectionProfile(
      address: Uri.parse('https://localhost'),
      deviceToken: token,
      serverId: 'synthetic-server-id',
    );
    expect(
      () => AgentConnectionProfile.fromPrivateJson({
        ...profile.toPrivateJson(),
        'role': 'owner',
      }),
      throwsFormatException,
    );
    expect(
      () => AgentConnectionProfile.fromPrivateJson({
        ...profile.toPrivateJson(),
        'token': 'owner',
      }),
      throwsFormatException,
    );
  });
  test(
    'private profile replacement never follows links and unsafe reads are rejected',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'chiyo-agent-profile-',
      );
      addTearDown(() => root.delete(recursive: true));
      final profile = AgentConnectionProfile(
        address: Uri.parse('https://localhost:47126'),
        deviceToken: '${'a' * 22}.${'b' * 43}',
        serverId: 'synthetic-server-id',
      );
      final directory = Directory('${root.path}/private');
      final file = await profile.saveIn(directory);
      expect((await file.stat()).mode & 0x3f, 0);
      expect((await directory.stat()).mode & 0x3f, 0);
      expect(
        (await AgentConnectionProfile.read(file)).deviceToken ==
            profile.deviceToken,
        isTrue,
      );
      await Process.run('/bin/chmod', ['644', file.path]);
      await expectLater(
        AgentConnectionProfile.read(file),
        throwsFormatException,
      );
      final unrelated = File('${root.path}/unrelated');
      await unrelated.writeAsString('DO_NOT_CHANGE');
      await file.delete();
      await Link(file.path).create(unrelated.path);
      await expectLater(
        AgentConnectionProfile.read(file),
        throwsFormatException,
      );
      await profile.saveIn(directory);
      expect(await unrelated.readAsString(), 'DO_NOT_CHANGE');
      expect(
        await FileSystemEntity.type(file.path, followLinks: false),
        FileSystemEntityType.file,
      );
      final linkedDirectory = Directory('${root.path}/linked');
      await Link(linkedDirectory.path).create(directory.path);
      await expectLater(profile.saveIn(linkedDirectory), throwsFormatException);
      await Process.run('/bin/chmod', ['755', directory.path]);
      await expectLater(
        AgentConnectionProfile.read(file),
        throwsFormatException,
      );
    },
    skip: !Platform.isMacOS && !Platform.isLinux,
  );
}
