import 'dart:io';
import 'package:info_remote/connection_profile.dart';
import 'package:info_remote/owner_client.dart';
import 'package:test/test.dart';

void main() {
  test(
    'private profiles persist atomically and never follow a substituted file link',
    () async {
      final root = await Directory.systemTemp.createTemp('chiyo-profile-');
      addTearDown(() => root.delete(recursive: true));
      final store = PrivateConnectionProfileStore('${root.path}/online');
      expect(await store.read(), isNull);
      const first = ConnectionProfile(
        address: 'https://first.invalid',
        token: 'synthetic-first-token',
        serverId: 'server-first',
      );
      await store.save(first);
      expect((await store.read())!.toJson(), first.toJson());
      final file = File('${root.path}/online/connection.json');
      expect((await file.stat()).mode & 0x3F, 0);
      expect((await Directory('${root.path}/online').stat()).mode & 0x3F, 0);
      const second = ConnectionProfile(
        address: 'https://second.invalid',
        token: 'synthetic-second-token',
        serverId: 'server-second',
        certificate: 'public synthetic certificate',
      );
      await store.save(second);
      expect((await store.read())!.toJson(), second.toJson());
      expect(await Directory('${root.path}/online').list().length, 1);
      final foreign = File('${root.path}/foreign');
      await foreign.writeAsString('preserve');
      await file.delete();
      await Link(file.path).create(foreign.path);
      await expectLater(store.read(), throwsA(isA<RemoteFailure>()));
      await store.save(first);
      expect(await foreign.readAsString(), 'preserve');
      expect((await store.read())!.toJson(), first.toJson());
    },
    skip: !Platform.isMacOS && !Platform.isLinux,
  );
}
