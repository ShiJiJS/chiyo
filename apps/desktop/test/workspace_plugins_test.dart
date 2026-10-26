import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/workspace/sample_plugin_fixture.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/template_package_decoder.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

const domainType = 'local.domain/domain';
Map<String, dynamic> package() =>
    jsonDecode(sampleDomainPackageJson) as Map<String, dynamic>;
void main() {
  WorkspacePlugin decode(Map<String, dynamic> p) =>
      TemplatePackageDecoder().decode(
        utf8.encode(jsonEncode(p)),
        origin: 'test.json',
        knownTemplates: {'builtin.server/server'},
      );
  Matcher invalid(String path) => isA<WorkspaceFailure>()
      .having((e) => e.code, 'code', 'invalid_package')
      .having((e) => e.fieldErrors.keys, 'path', contains(path));
  test(
    'scoped declarative definition is immutable and resolves only the host type alias',
    () {
      final p = decode(package()), t = p.templates.single;
      expect(p.id, 'local.domain');
      expect(t.type.id, domainType);
      expect((t.definition['relations'] as List).single['targetTemplates'], [
        'server',
      ]);
      expect(() => t.definition['name'] = 'changed', throwsUnsupportedError);
      expect(
        () =>
            ((t.definition['fields'] as List).first as Map)['type'] = 'secret',
        throwsUnsupportedError,
      );
    },
  );
  test(
    'byte, nesting and duplicate-key guards run before JSON can overwrite a definition',
    () {
      final d = TemplatePackageDecoder();
      expect(
        () => d.decode(
          List.filled(TemplatePackageDecoder.maxBytes + 1, 32),
          origin: 'large',
        ),
        throwsA(invalid(r'$')),
      );
      expect(() => d.decode([0xff], origin: 'utf8'), throwsA(invalid(r'$')));
      for (final text in [
        r'{"id":"first","\u0069d":"second"}',
        r'{"nested":{"a":1,"a":2}}',
      ]) {
        expect(
          () => d.decode(utf8.encode(text), origin: 'duplicate'),
          throwsA(isA<WorkspaceFailure>()),
        );
      }
      expect(
        () => d.decode(
          utf8.encode(
            '${List.filled(17, '[').join()}0${List.filled(17, ']').join()}',
          ),
          origin: 'depth',
        ),
        throwsA(isA<WorkspaceFailure>()),
      );
      for (final text in [
        '{} true',
        '{"id":}',
        '[1,]',
        '{"a":1,}',
        '{"a":"unterminated}',
      ]) {
        expect(
          () => d.decode(utf8.encode(text), origin: 'syntax'),
          throwsA(isA<WorkspaceFailure>()),
        );
      }
    },
  );
  test(
    'unknown execution/settings attributes, reserved IDs, field types and dangling references fail at explicit paths',
    () {
      final cases = <({String path, void Function(Map<String, dynamic>) edit})>[
        (path: r'$.script', edit: (p) => p['script'] = 'run()'),
        (
          path: r'$.settingsPanel',
          edit: (p) => p['settingsPanel'] = 'ssh-trust',
        ),
        (path: r'$.id', edit: (p) => p['id'] = 'builtin.server'),
        (path: r'$.hostApi', edit: (p) => p['hostApi'] = 2),
        (path: r'$.version', edit: (p) => p['version'] = 'v1.0.0'),
        (path: r'$.version', edit: (p) => p['version'] = '1.0.0-beta'),
        (path: r'$.version', edit: (p) => p['version'] = '01.0.0'),
        (
          path: r'$.templates[0].fields[0].type',
          edit: (p) => p['templates'][0]['fields'][0]['type'] = 'secret',
        ),
        (
          path: r'$.templates[0].icon',
          edit: (p) =>
              p['templates'][0]['icon'] = 'https://remote.example/image',
        ),
        (
          path: r'$.templates[0].relations[0].targetTemplates',
          edit: (p) =>
              p['templates'][0]['relations'][0]['targetTemplates'] = ['server'],
        ),
        (
          path: r'$.templates[0].sections[0].keys',
          edit: (p) => p['templates'][0]['sections'][0]['keys'] = ['missing'],
        ),
        (
          path: r'$.templates[0].sections[1].kind',
          edit: (p) => p['templates'][0]['sections'][1]['kind'] = 'html',
        ),
        (
          path: r'$.templates[0].fields[1].key',
          edit: (p) => p['templates'][0]['fields'][1]['key'] = 'domain',
        ),
        (
          path: r'$.templates[0].fields',
          edit: (p) => p['templates'][0]['fields'] = List.filled(
            41,
            p['templates'][0]['fields'][0],
          ),
        ),
        (
          path: r'$.templates[0].instructions',
          edit: (p) =>
              p['templates'][0]['instructions'] = List.filled(6000, '中').join(),
        ),
      ];
      for (final c in cases) {
        final p = package();
        c.edit(p);
        expect(() => decode(p), throwsA(invalid(c.path)), reason: c.path);
      }
    },
  );

  Future<WorkspacePluginPreview> preview(
    SampleWorkspaceSource s,
    String filename,
  ) async {
    final choices = await s.pluginChoices();
    final c = choices.singleWhere((c) => c.filename == filename);
    for (final other in choices) {
      if (other != c) await s.plugins.releaseCandidate(other.selectionId);
    }
    return s.plugins.previewInstall(c.selectionId);
  }

  Future<WorkspacePluginReceipt> install(
    SampleWorkspaceSource s,
    WorkspacePluginPreview p,
    String id,
  ) => s.plugins.change(
    WorkspacePluginChange(
      operationId: id,
      action: WorkspacePluginAction.install,
      packageId: p.package.id,
      expectedVersion: p.catalogVersion,
      selectionId: p.selectionId,
      expectedDigest: p.package.digest,
    ),
  );

  test(
    'install and update share normal create/edit while old snapshots, relations and history remain unchanged',
    () async {
      final s = SampleWorkspaceSource();
      addTearDown(s.dispose);
      final baseline = (await s.loadSummary()).records;
      final p = await preview(s, '域名管理-1.0.0.json');
      expect((await s.plugins.load()).packages, hasLength(3));
      await install(s, p, 'install-v1');
      final def = await s.loadTemplate(domainType);
      final candidates = await s.queryRelationCandidates(
        const WorkspaceRelationQuery(typeId: domainType, key: 'pointsTo'),
      );
      expect(candidates.items, isNotEmpty);
      expect(candidates.items.every((r) => r.type.id == 'server'), isTrue);

      final created =
          await s.createRecord(
                WorkspaceCreate(
                  operationId: 'create-domain',
                  typeId: domainType,
                  name: '虚构域名',
                  expectedTemplateVersion: '1.0.0',
                  expectedTemplateDigest: p.package.digest,
                  values: {
                    'domain': 'test.example',
                    'registrar': 'synthetic',
                    'expires': '2027-01-20',
                    'dns': 'synthetic',
                    'purpose': 'test',
                  },
                  relations: {
                    'pointsTo': [
                      const WorkspaceRecordRef(
                        WorkspaceRecordKind.information,
                        'azure',
                      ),
                    ],
                  },
                ),
              )
              as WorkspaceSaved;
      expect(created.detail.definition, def);
      expect(created.detail.record.type.icon, 'globe');
      final update = await preview(s, '域名管理-1.1.0.json');
      expect(update.differences, contains('新增字段：维护负责人'));
      await install(s, update, 'update-v2');
      final old = await s.readDetail(created.detail.record.ref);
      expect(old.definition, def);
      expect(old.version, 1);
      expect(old.relations, created.detail.relations);
      expect((await s.loadTemplate(domainType))['templateVersion'], '1.1.0');
      final stale = await s.createRecord(
        WorkspaceCreate(
          operationId: 'stale-form',
          typeId: domainType,
          name: 'stale',
          expectedTemplateVersion: '1.0.0',
          expectedTemplateDigest: p.package.digest,
          values: {'domain': 'stale.example'},
        ),
      );
      expect((stale as WorkspaceRejected).failure.code, 'conflict');
      final edited =
          await s.saveRecord(
                WorkspaceEdit(
                  operationId: 'edit-old-snapshot',
                  expectedVersion: old.version,
                  record: old.record,
                  values: {'domain': 'changed.example'},
                ),
              )
              as WorkspaceSaved;
      expect(edited.detail.definition, def);
      expect(await s.loadRevisions(old.record.ref), hasLength(1));
      expect((await s.loadSummary()).records, baseline + 1);
      await s.plugins.releaseCandidate(p.selectionId);
      await s.plugins.releaseCandidate(update.selectionId);
    },
  );
  test(
    'disabled and removed definitions cannot create but existing records remain editable and reinstallation preserves their snapshot',
    () async {
      final s = SampleWorkspaceSource();
      addTearDown(s.dispose);
      final p = await preview(s, '域名管理-1.0.0.json');
      await install(s, p, 'install');
      final saved =
          await s.createRecord(
                WorkspaceCreate(
                  operationId: 'create',
                  typeId: domainType,
                  name: 'keep',
                  values: {'domain': 'keep.example'},
                ),
              )
              as WorkspaceSaved;
      var catalog = await s.plugins.load();
      await s.plugins.change(
        WorkspacePluginChange(
          operationId: 'disable',
          action: WorkspacePluginAction.disable,
          packageId: p.package.id,
          expectedVersion: catalog.version,
          expectedDigest: p.package.digest,
        ),
      );
      expect(
        (await s.loadCatalog()).creatableTypes.any((t) => t.id == domainType),
        isFalse,
      );
      expect(
        (await s.loadCatalog()).types.any((t) => t.id == domainType),
        isTrue,
      );
      var current = await s.readDetail(saved.detail.record.ref);
      expect(current.templateState, WorkspaceTemplateState.disabled);
      final rejected = await s.createRecord(
        WorkspaceCreate(
          operationId: 'disabled-create',
          typeId: domainType,
          name: 'bad',
          values: {'domain': 'bad.example'},
        ),
      );
      expect(
        (rejected as WorkspaceRejected).failure.code,
        'template_unavailable',
      );
      final edited =
          await s.saveRecord(
                WorkspaceEdit(
                  operationId: 'edit-disabled',
                  expectedVersion: 1,
                  record: current.record,
                  values: {'domain': 'edited.example'},
                ),
              )
              as WorkspaceSaved;
      expect(edited.detail.templateState, WorkspaceTemplateState.disabled);
      catalog = await s.plugins.load();
      final remove = WorkspacePluginChange(
        operationId: 'remove',
        action: WorkspacePluginAction.remove,
        packageId: p.package.id,
        expectedVersion: catalog.version,
        expectedDigest: p.package.digest,
      );
      await s.plugins.change(remove);
      await s.plugins.releaseCandidate(p.selectionId);
      current = await s.readDetail(current.record.ref);
      expect(current.templateState, WorkspaceTemplateState.missing);
      expect(current.values['domain'], 'edited.example');
      expect(current.definition, saved.detail.definition);
      expect(
        (await s.plugins.change(remove)).action,
        WorkspacePluginAction.remove,
      );
      expect((await s.plugins.load()).packages, hasLength(3));
      final reinstall = await preview(s, '域名管理-1.0.0.json');
      await install(s, reinstall, 'reinstall');
      current = await s.readDetail(current.record.ref);
      expect(current.templateState, WorkspaceTemplateState.available);
      expect(current.definition, saved.detail.definition);
      expect(current.version, 2);
    },
  );
  test(
    'failed or conflicting commands are atomic, same-version different digest is rejected and a reviewed downgrade leaves instances alone',
    () async {
      final s = SampleWorkspaceSource();
      addTearDown(s.dispose);
      final p = await preview(s, '域名管理-1.0.0.json');
      s.nextSaveFailure = const WorkspaceFailure('offline', '失败');
      await expectLater(
        install(s, p, 'failed'),
        throwsA(isA<WorkspaceFailure>()),
      );
      expect((await s.plugins.load()).packages, hasLength(3));
      expect(await s.plugins.receipt('failed'), isNull);
      await install(s, p, 'install');
      await expectLater(
        preview(s, '域名管理-1.0.0-内容变更.json'),
        throwsA(
          isA<WorkspaceFailure>().having(
            (e) => e.code,
            'code',
            'package_version_conflict',
          ),
        ),
      );
      final update = await preview(s, '域名管理-1.1.0.json');
      final cat = await s.plugins.load(),
          server = cat.packages.firstWhere((p) => p.id == 'builtin.server');
      await s.plugins.change(
        WorkspacePluginChange(
          operationId: 'other-change',
          action: WorkspacePluginAction.disable,
          packageId: server.id,
          expectedVersion: cat.version,
          expectedDigest: server.digest,
        ),
      );
      await expectLater(
        install(s, update, 'stale-preview'),
        throwsA(
          isA<WorkspaceFailure>().having((e) => e.code, 'code', 'conflict'),
        ),
      );
      final fresh = await preview(s, '域名管理-1.1.0.json');
      await install(s, fresh, 'fresh-update');
      final downgrade = await preview(s, '域名管理-1.0.0.json');
      expect(downgrade.differences.first, contains('较早版本'));
      await install(s, downgrade, 'reviewed-downgrade');
      expect((await s.loadTemplate(domainType))['templateVersion'], '1.0.0');
      await expectLater(
        s.plugins.change(
          WorkspacePluginChange(
            operationId: 'install',
            action: WorkspacePluginAction.remove,
            packageId: p.package.id,
            expectedVersion: 999,
          ),
        ),
        throwsA(
          isA<WorkspaceFailure>().having(
            (e) => e.code,
            'code',
            'operation_conflict',
          ),
        ),
      );
      s.reset();
      expect((await s.plugins.load()).packages, hasLength(3));
      expect(await s.plugins.receipt('install'), isNull);
    },
  );
  test(
    'builtins can be disabled without mutating current material or immutable record definitions',
    () async {
      final s = SampleWorkspaceSource();
      addTearDown(s.dispose);
      const ref = WorkspaceRecordRef(
        WorkspaceRecordKind.information,
        'profile',
      );
      final old = await s.readDetail(ref), catalog = await s.plugins.load();
      final profile = catalog.packages.firstWhere(
        (p) => p.id == 'builtin.profile',
      );
      await expectLater(
        s.plugins.change(
          WorkspacePluginChange(
            operationId: 'remove-builtin',
            action: WorkspacePluginAction.remove,
            packageId: profile.id,
            expectedVersion: catalog.version,
            expectedDigest: profile.digest,
          ),
        ),
        throwsA(isA<WorkspaceFailure>()),
      );
      await s.plugins.change(
        WorkspacePluginChange(
          operationId: 'disable-profile',
          action: WorkspacePluginAction.disable,
          packageId: profile.id,
          expectedVersion: catalog.version,
          expectedDigest: profile.digest,
        ),
      );
      final current = await s.readDetail(ref);
      expect(current.definition, old.definition);
      expect(current.values, old.values);
      expect(current.version, old.version);
      expect(current.templateState, WorkspaceTemplateState.disabled);
    },
  );
  test(
    'changed content shape requires a new field identity and removed template definitions do not rewrite old instances',
    () async {
      final inputs = samplePluginInputs();
      final wrong = package();
      wrong['version'] = '1.1.0';
      wrong['templates'][0]['fields'][0]['type'] = 'number';
      wrong['templates'][0]['example']['values']['domain'] = '22';
      inputs['shape-change'] = (
        filename: '内容形态改变.json',
        bytes: utf8.encode(jsonEncode(wrong)),
      );
      final replacement = package();
      replacement['version'] = '1.2.0';
      replacement['templates'][0]['id'] = 'newDomain';
      inputs['replacement'] = (
        filename: '新定义身份.json',
        bytes: utf8.encode(jsonEncode(replacement)),
      );
      final s = SampleWorkspaceSource(pluginInputs: inputs);
      addTearDown(s.dispose);
      final initial = await preview(s, '域名管理-1.0.0.json');
      await install(s, initial, 'initial');
      final old =
          await s.createRecord(
                WorkspaceCreate(
                  operationId: 'old-record',
                  typeId: domainType,
                  name: '保留旧定义',
                  values: {'domain': 'snapshot.example'},
                ),
              )
              as WorkspaceSaved;
      await expectLater(
        preview(s, '内容形态改变.json'),
        throwsA(
          isA<WorkspaceFailure>().having(
            (e) => e.code,
            'code',
            'definition_identity_conflict',
          ),
        ),
      );
      final next = await preview(s, '新定义身份.json');
      await install(s, next, 'replace-definition');
      final retained = await s.readDetail(old.detail.record.ref);
      expect(retained.templateState, WorkspaceTemplateState.removedDefinition);
      expect(retained.definition, old.detail.definition);
      expect(retained.values, old.detail.values);
      expect(retained.version, 1);
      expect(
        (await s.loadCatalog()).creatableTypes.any((t) => t.id == domainType),
        isFalse,
      );
      expect(
        (await s.loadTemplate('local.domain/newDomain'))['id'],
        'newDomain',
      );
      final apiDecimal = package();
      apiDecimal['hostApi'] = 1.0;
      expect(decode(apiDecimal).id, 'local.domain');
    },
  );
}
