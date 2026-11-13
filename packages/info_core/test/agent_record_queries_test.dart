import 'dart:convert';
import 'package:info_core/info_core.dart';
import 'package:info_core/agent_server.dart';
import 'package:test/test.dart';

void main() {
  late InformationService service;
  late String first, second;
  setUp(() {
    service = InformationService.fictional();
    first = service.agent.openSession('same label');
    second = service.agent.openSession('same label');
  });
  tearDown(() => service.close());

  test(
    'list and show use private session, not matching agent/chat metadata',
    () async {
      final a = service.agent.request(
        first,
        'first purpose',
        [const FieldRef('demo-server', 'host')],
        operationId: 'same-op',
        agentName: 'Same agent',
        externalChatId: 'same-public-id',
      );
      final b = service.agent.request(
        second,
        'other purpose',
        [const FieldRef('demo-server', 'host')],
        operationId: 'same-op',
        agentName: 'Same agent',
        externalChatId: 'same-public-id',
      );
      final proposal = await service.agent.submitImport(
        first,
        [
          ImportItemInput('test item', '', [
            const FieldInput('body', '', 'PRIVATE-PROPOSED-VALUE'),
          ]),
        ],
        title: 'add test item',
        purpose: 'first import',
        operationId: 'import-1',
      );
      final rows = service.agent.queryOwnRequests(first)['records'] as List;
      expect(rows.map((r) => (r as Map)['id']).toSet(), {a.id, proposal});
      expect(service.agent.showOwnRequest(first, b.id), {
        'status': 'not_found',
      });
      expect(service.agent.showOwnRequest(second, proposal), {
        'status': 'not_found',
      });
      expect(jsonEncode(rows), isNot(contains('PRIVATE-PROPOSED-VALUE')));
      expect(jsonEncode(rows), isNot(contains(first)));
      expect(jsonEncode(rows), isNot(contains(second)));
      expect(
        (service.agent.queryOwnRequests(first, kind: 'import')['records']
                as List)
            .single['title'],
        'add test item',
      );
      final operations =
          service.agent.queryOwnOperations(first)['records'] as List;
      expect(operations.map((r) => (r as Map)['id']).toSet(), {
        'same-op',
        'import-1',
      });
      expect(
        service.agent.showOwnOperation(first, 'import-1')['requestId'],
        proposal,
      );
      expect(service.agent.showOwnOperation(second, 'import-1'), {
        'status': 'not_found',
      });
      final proposals = service.agent.queryOwnRequests(
        first,
        proposalsOnly: true,
        limit: 1,
      );
      expect(proposals['total'], 1);
      expect((proposals['records'] as List).single['id'], proposal);
      service.owner.deny(a.id);
      expect(
        (service.agent.queryOwnRequests(first, state: 'denied')['records']
                as List)
            .single['id'],
        a.id,
      );
      expect(service.agent.showOwnRequest(first, a.id)['status'], 'denied');
    },
  );

  test(
    'pagination is bounded and an ended or reopened chat cannot recover records',
    () {
      for (var i = 0; i < 3; i++) {
        service.agent.request(first, 'read $i', [
          const FieldRef('demo-server', 'host'),
        ]);
      }
      final page = service.agent.queryOwnRequests(first, limit: 1);
      expect(page['total'], 3);
      expect(page['nextOffset'], 1);
      final next = service.agent.queryOwnRequests(first, offset: 1, limit: 1);
      expect(next['records'], isNot(page['records']));
      expect(
        service.agent.queryOwnRequests(first, offset: 10)['records'],
        isEmpty,
      );
      for (final query in [
        () => service.agent.queryOwnRequests(first, limit: 0),
        () => service.agent.queryOwnRequests(first, kind: 'anything'),
        () => service.agent.queryOwnRequests(first, offset: -1),
      ]) {
        expect(query, throwsA(isA<AccessFailure>()));
      }
      service.agent.endSession(first);
      expect(
        () => service.agent.queryOwnRequests(first),
        throwsA(isA<AccessFailure>()),
      );
      final reopened = service.agent.openSession('same label');
      expect(service.agent.queryOwnRequests(reopened)['records'], isEmpty);
    },
  );

  test(
    'Agent-only protocol exposes only own queries and rejects malformed filters',
    () async {
      final request = service.agent.request(first, 'read host', [
        const FieldRef('demo-server', 'host'),
      ]);
      final protocol = AgentProtocol(service.agent);
      final list = await protocol.dispatch('/requests/list', {
        'sessionSecret': first,
      });
      expect((list['records'] as List).single['id'], request.id);
      expect(
        await protocol.dispatch('/requests/show', {
          'sessionSecret': second,
          'id': request.id,
        }),
        {'status': 'not_found'},
      );
      await expectLater(
        protocol.dispatch('/requests/list', {
          'sessionSecret': first,
          'limit': '20',
        }),
        throwsA(isA<AccessFailure>()),
      );
      await expectLater(
        protocol.dispatch('/requests/show', {
          'sessionSecret': first,
          'id': request.id,
          'approve': true,
        }),
        throwsA(isA<AccessFailure>()),
      );
    },
  );
}
