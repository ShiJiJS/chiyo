import 'dart:io';
import 'package:info_cli/chiyo_cli.dart';
import 'package:info_cli/chiyo_context.dart';
import 'package:info_core/agent_server.dart';
import 'package:info_core/info_core.dart';
import 'package:info_remote/agent_connection.dart';
import 'package:test/test.dart';

void main() {
  test('file help and parameter validation need no chat or App', () async {
    for (final verb in ['fetch', 'status', 'release']) {
      final result = await ChiyoCli(
        environment: {},
      ).run(['files', verb, '--help']);
      expect(result.exitCode, 0);
      expect(result.help, contains('用法：chiyo files $verb'));
    }
    for (final args in [
      ['files', 'fetch'],
      ['files', 'status'],
      ['files', 'status', '--operation', 'one', '--delivery', 'two'],
      ['files', 'release'],
    ]) {
      final result = await ChiyoCli(environment: {}).run([...args, '--json']);
      expect(result.exitCode, 2, reason: result.render());
    }
  });

  group('ordinary files from a generic private chat', () {
    late Directory root;
    late InformationService service;
    late MemoryInformationRepository repo;
    late AgentServer server;
    late File contextFile;
    late ChiyoContext context;
    late InformationItem item;
    late DateTime now;
    const original = 'Synthetic ordinary attachment\n中文原文';
    Future<ChiyoRunResult> cli(List<String> args) => ChiyoCli(
      environment: {'CHIYO_CONTEXT': contextFile.path},
    ).run([...args, '--json']);
    Map data(ChiyoRunResult result) => result.output['data'] as Map;
    late List<String> fetch;
    late String request;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('chiyo-ordinary-file-');
      now = DateTime.now().toUtc();
      repo = MemoryInformationRepository();
      service = InformationService(
        repository: repo,
        clock: () => now,
        informationDeliveryFiles: NativeInformationDeliveryFiles(),
      );
      final source = File('${root.path}/原始附件.txt');
      await source.writeAsString(original);
      final draft = await service.owner.beginInformationFileDraft();
      final stage = await service.owner.stageInformationFile(
        draft,
        source.path,
        mediaType: 'text/plain',
      );
      item = await service.owner.commitInformationDraft(
        draft,
        'owner-import',
        InformationDraftInput(
          name: 'Synthetic application',
          description: '',
          fields: [
            InformationDraftField.stagedFile('Attachment', '', stage.id),
            const InformationDraftField.text(
              'Private note',
              '',
              'not approved',
            ),
          ],
        ),
      );
      await service.owner.releaseInformationFileDraft(draft);
      const token =
          'AAAAAAAAAAAAAAAAAAAAAA.BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';
      server = await AgentServer.start(
        service.agent,
        port: 0,
        connectionToken: token,
        libraryId: 'synthetic-file-library',
        enableReusableCredentialUse: true,
        enableInformationFiles: true,
      );
      final profile = AgentConnectionProfile.local(
        port: server.port,
        deviceToken: token,
        libraryId: 'synthetic-file-library',
      );
      final profileFile = await profile.saveIn(
        Directory('${root.path}/profile'),
      );
      contextFile = File('${root.path}/chat/context.json');
      final opened = await ChiyoCli(environment: {}).run([
        'chat',
        'start',
        '--agent',
        'Ordinary Agent',
        '--id',
        'ordinary-file-chat',
        '--label',
        'Read a supplied attachment',
        '--connection',
        profileFile.path,
        '--context-out',
        contextFile.path,
        '--json',
      ]);
      expect(opened.exitCode, 0, reason: opened.render());
      context = await ChiyoContext.load(contextFile, environment: {});
      final requested = await cli([
        'access',
        'request',
        '--item',
        item.id,
        '--field',
        item.fields.first.id,
        '--purpose',
        'Read the original',
        '--operation',
        'request-original',
      ]);
      expect(requested.exitCode, 0, reason: requested.render());
      request = data(requested)['requestId'] as String;
      fetch = [
        'files',
        'fetch',
        '--request',
        request,
        '--item',
        item.id,
        '--field',
        item.fields.first.id,
        '--operation',
        'original-copy',
      ];
    });
    tearDown(() async {
      await server.close();
      await service.close();
      await root.delete(recursive: true);
    });

    void approve() => service.owner.approve(request, [
      FieldRef(item.id, item.fields.first.id),
    ], lifetime: const Duration(hours: 2));

    test(
      'flags read one native copy, recover it, list safe facts, and release it',
      () async {
        approve();
        final received = await cli(fetch);
        expect(received.exitCode, 0, reason: received.render());
        final delivery = data(received)['delivery'] as Map;
        expect(delivery['state'], 'ready');
        final path = delivery['path'] as String;
        final id = delivery['deliveryId'] as String;
        expect(await File(path).readAsString(), original);
        expect(repo.informationFileDeliveries, hasLength(1));
        final repeated = await cli(fetch);
        expect((data(repeated)['delivery'] as Map)['path'], path);
        final restored = await cli(['operations', 'retry', 'original-copy']);
        expect((data(restored)['delivery'] as Map)['path'], path);
        expect(repo.informationFileDeliveries, hasLength(1));
        final status = await cli([
          'files',
          'status',
          '--operation',
          'original-copy',
        ]);
        final shown = await cli(['operations', 'show', 'original-copy']);
        final listed = await cli(['operations', 'list', '--request', request]);
        expect(data(shown)['kind'], 'information-file');
        expect(data(shown)['deliveryId'], id);
        expect(
          (data(listed)['records'] as List).map((r) => r['id']),
          contains('original-copy'),
        );
        for (final result in [status, shown, listed]) {
          for (final hidden in [
            path,
            context.secret,
            original,
            'cleanupCapability',
          ]) {
            expect(result.render(), isNot(contains(hidden)));
          }
        }
        final changed = await cli([
          ...fetch.take(fetch.length - 2),
          '--field',
          item.fields.last.id,
          '--operation',
          'original-copy',
        ]);
        expect(changed.exitCode, 8);
        final other = service.agent.openSession('Read a supplied attachment');
        expect(
          service.agent.showOwnOperation(other, 'original-copy')['status'],
          'not_found',
        );
        final released = await cli(['files', 'release', '--delivery', id]);
        expect(released.exitCode, 0, reason: released.render());
        expect(await File(path).exists(), false);
        expect(
          (data(await cli(['files', 'status', '--delivery', id]))['delivery']
              as Map)['state'],
          'released',
        );
        final endedCopy = await cli(fetch);
        expect(endedCopy.exitCode, 5, reason: endedCopy.render());
        expect(endedCopy.render(), isNot(contains(path)));
        expect(repo.informationFileDeliveries, hasLength(1));
      },
    );

    test(
      'pending, unapproved fields, expired grants and ended chats cannot fetch',
      () async {
        final pending = await cli(fetch);
        expect(pending.exitCode, 4, reason: pending.render());
        expect(repo.informationFileDeliveries, isEmpty);
        approve();
        final unapproved = await cli([
          'access',
          'read',
          '--request',
          request,
          '--item',
          item.id,
          '--field',
          item.fields.last.id,
        ]);
        expect(unapproved.exitCode, 4, reason: unapproved.render());
        now = now.add(const Duration(hours: 3));
        final expired = await cli(fetch);
        expect(expired.exitCode, 4, reason: expired.render());
        expect(repo.informationFileDeliveries, isEmpty);
        await cli(['chat', 'end']);
        final ended = await cli(fetch);
        expect(ended.exitCode, 4, reason: ended.render());
        expect(repo.informationFileDeliveries, isEmpty);
      },
    );
  });
}
