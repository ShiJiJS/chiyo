import 'dart:io';
import 'package:info_core/info_core.dart' as core;
import 'package:info_server/mounted_database_key_store.dart';
import 'package:info_server/server_configuration.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_workspace/owner_agent_templates.dart';
import 'package:info_workspace/owner_workspace_proposals.dart';
import 'package:info_workspace/workspace_information_codec.dart';
import 'package:info_workspace/workspace_source.dart';
import 'package:test/test.dart';

/// Minimal host reads required by the shared review adapter. HTTP transport and
/// the online App are separate work; this test proves the module has no Flutter
/// dependency and still uses the real encrypted whole-proposal transaction.
class _Library implements WorkspaceProposalLibrary {
  _Library(this.owner);
  final core.OwnerAccess owner;
  final _codec = WorkspaceInformationCodec();
  @override
  Future<WorkspaceCatalog> loadCatalog() async => WorkspaceCatalog(
    directories: [
      for (final d in owner.directories)
        WorkspaceDirectory(d.id, d.name, parentId: d.parentId),
    ],
    tags: [for (final t in owner.tags) WorkspaceTag(t.id, t.name)],
    types: const [WorkspaceType('document', 'Document', 'book')],
  );
  @override
  Future<WorkspaceDetail> readDetail(WorkspaceRecordRef ref) async =>
      _codec.decode(owner.information.singleWhere((i) => i.id == ref.id));
  @override
  Future<List<WorkspaceRecordSummary>> readSummaries(
    Iterable<WorkspaceRecordRef> refs,
  ) async {
    final wanted = refs.toSet();
    return [
      for (final item in owner.information)
        if (wanted.contains(
          WorkspaceRecordRef(WorkspaceRecordKind.information, item.id),
        ))
          _codec.summary(item),
    ];
  }

  @override
  Future<WorkspaceResults> queryRelationCandidates(
    WorkspaceRelationQuery query,
  ) async => WorkspaceResults(
    items: [for (final i in owner.information) _codec.summary(i)],
    total: owner.information.length,
    offset: 0,
  );
}

void main() {
  test(
    'shared owner review retains exact previews and admits mutually related rows once as a whole',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'shared-online-proposals-',
      );
      await initializeServerSecrets('${root.path}/secrets');
      final repo = await EncryptedInformationRepository.open(
        '${root.path}/data',
        MountedDatabaseKeyStore('${root.path}/secrets/database.key'),
      );
      final runtime = await core.OnlineInformationRuntime.open(
        repository: repo,
      );
      final owner = runtime.service.owner;
      owner.configureInformationTemplates(() => currentAgentTemplates(owner));
      final library = _Library(owner);
      final proposals = OwnerWorkspaceProposals(
        owner: owner,
        library: () => library,
        changed: () {},
      );
      addTearDown(() async {
        await runtime.close();
        await repo.close();
        await root.delete(recursive: true);
      });
      final session = runtime.service.agent.openSession(
        'Shared proposal validation',
      );
      final template =
          runtime.service.agent.readInformationTemplate('document')['template']
              as Map;
      final example =
          ((template['submissionExample'] as Map)['items'] as List).single
              as Map;
      final id = await runtime.run(
        () => runtime.service.agent.submitImport(session, [
          for (final key in ['a', 'b'])
            core.ImportItemInput.fromJson({
              ...Map<String, dynamic>.from(example),
              'key': key,
              'name': 'Synthetic $key',
              'suggestedDirectory': 'Existing/Notes',
              'relations': {
                'related': [
                  {'kind': 'information', 'itemKey': key == 'a' ? 'b' : 'a'},
                ],
              },
            }),
        ], operationId: 'shared-pair'),
      );
      final detail = await proposals.read(id);
      expect(detail.items, hasLength(2));
      expect(
        detail.items.every((i) => i.proposed.record.type.id == 'document'),
        true,
      );
      expect(owner.information, isEmpty);
      final locations = await proposals.catalog();
      expect(locations.directories.map((d) => d.name), ['Existing', 'Notes']);
      WorkspaceProposalChange decide(
        List<WorkspaceProposalItemReview> reviewed,
      ) => WorkspaceProposalChange(
        operationId: 'save-whole',
        proposalId: id,
        version: detail.summary.version,
        reviewToken: detail.reviewToken,
        action: WorkspaceProposalAction.confirm,
        reviewed: reviewed,
      );
      await expectLater(
        runtime.run(
          () => proposals.change(
            decide([WorkspaceProposalItemReview.fromItem(detail.items.first)]),
          ),
        ),
        throwsA(isA<WorkspaceFailure>()),
      );
      expect(owner.information, isEmpty);
      expect(owner.directories, isEmpty);
      final command = decide(
        detail.items.map(WorkspaceProposalItemReview.fromItem).toList(),
      );
      final receipt = await runtime.run(() => proposals.change(command));
      expect(receipt.records, hasLength(2));
      expect(owner.information, hasLength(2));
      expect(owner.directories.map((d) => d.name), ['Existing', 'Notes']);
      final once = await runtime.run(() => proposals.change(command));
      expect(
        once.records.map((r) => r.ref.key),
        receipt.records.map((r) => r.ref.key),
      );
      for (final record in receipt.records) {
        final actual = await library.readDetail(record.ref);
        final original = detail.items
            .singleWhere((i) => i.proposed.record.name == actual.record.name)
            .proposed;
        expect(actual.definition, original.definition);
        expect(actual.values, original.values);
        expect(actual.relations['related'], hasLength(1));
        expect(
          receipt.records.any(
            (r) =>
                r.ref == actual.relations['related']!.single &&
                r.ref != record.ref,
          ),
          true,
        );
      }
      expect(
        (await proposals.read(id)).summary.status,
        WorkspaceProposalStatus.completed,
      );
    },
  );
}
