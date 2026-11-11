import 'dart:io';

import 'package:info_remote/agent_connection.dart';
import 'package:info_remote/automatic_connection.dart';
import 'package:info_remote/local_library_configuration.dart';
import 'package:info_remote/owner_client.dart';
import 'package:test/test.dart';

void main() {
  test('concurrent first opens select one durable library identity', () async {
    final root = await Directory.systemTemp.createTemp(
      'chiyo-local-identity-race-',
    );
    addTearDown(() => root.delete(recursive: true));
    final opened = await Future.wait(
      List.generate(
        8,
        (_) => LocalLibraryConfiguration.open('${root.path}/profile'),
      ),
    );
    expect(opened.map((c) => c.libraryId).toSet(), hasLength(1));
    expect(
      (await LocalLibraryConfiguration.open(opened.first.directory)).libraryId,
      opened.first.libraryId,
    );
  });
  test(
    'local descriptors keep independent identities and cannot become unpinned remote connections',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'chiyo-local-profile-',
      );
      addTearDown(() => root.delete(recursive: true));
      final first = await LocalLibraryConfiguration.open('${root.path}/a');
      final second = await LocalLibraryConfiguration.open('${root.path}/b');
      expect(first.libraryId, isNot(second.libraryId));
      expect(
        (await LocalLibraryConfiguration.open(first.directory)).libraryId,
        first.libraryId,
      );
      final profile = first.connection(12345);
      expect(profile.isLocal, true);
      expect(profile.address.host, '127.0.0.1');
      expect(
        AgentConnectionProfile.fromPrivateJson(
          profile.toPrivateJson(),
        ).toPrivateJson(),
        profile.toPrivateJson(),
      );
      await first.publish(profile);
      final found = await discoverAgentConnection(
        environment: {'CHIYO_CONNECTION_DIRECTORY': first.directory},
      );
      expect((await AgentConnectionProfile.read(found!)).isLocal, true);
      expect(
        (await AutomaticConnectionStore(
          first.directory,
        ).readOwner())!['libraryId'],
        first.libraryId,
      );
      expect(
        () => AgentConnectionProfile.fromPrivateJson({
          ...profile.toPrivateJson(),
          'role': 'agent',
          'version': 1,
        }),
        throwsFormatException,
      );
      for (final address in [
        'http://example.invalid:12345',
        'https://127.0.0.1:12345',
        'http://localhost:12345',
        'http://127.0.0.1:12345/private',
      ]) {
        expect(
          () => AgentConnectionProfile.fromPrivateJson({
            ...profile.toPrivateJson(),
            'address': address,
          }),
          throwsFormatException,
        );
      }
      await expectLater(second.publish(profile), throwsA(isA<RemoteFailure>()));
      await File('${first.directory}/local-library.json').delete();
      await Directory(first.libraryDirectory).create();
      await File(
        '${first.libraryDirectory}/preserve.db',
      ).writeAsString('preserve fixture');
      await expectLater(
        LocalLibraryConfiguration.open(first.directory),
        throwsA(
          isA<RemoteFailure>().having(
            (e) => e.code,
            'code',
            'local_identity_missing',
          ),
        ),
      );
      expect(
        await File('${first.libraryDirectory}/preserve.db').readAsString(),
        'preserve fixture',
      );
    },
  );
}
