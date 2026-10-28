import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/workspace/sample_workspace_fixture.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

const resume = WorkspaceRecordRef(WorkspaceRecordKind.information, 'resume');
const azure = WorkspaceRecordRef(WorkspaceRecordKind.information, 'azure');
Matcher failure(String code) =>
    throwsA(isA<WorkspaceFailure>().having((e) => e.code, 'code', code));

void main() {
  test(
    'distinct resume/file groups and generic names come from metadata without file reads',
    () async {
      final source = SampleWorkspaceSource(
        readAsset: (_) => throw StateError('Metadata must not read assets'),
      );
      addTearDown(source.dispose);
      final catalog = await source.loadCatalog();
      expect(catalog.types.any((t) => t.id == 'resume'), isFalse);
      expect(catalog.creatableTypes.any((t) => t.id == 'resume'), isFalse);
      expect(catalog.types.singleWhere((t) => t.id == 'generic').name, '通用信息');
      final grouped = await source.queryRecords(
        const WorkspaceQuery(grouping: WorkspaceGrouping.type, limit: 500),
      );
      expect(grouped.groupCounts, {
        'server': 3,
        'service': 8,
        'profile': 1,
        'credential': 7,
        'resume': 2,
        'file': 4,
        'generic': 1,
        'document': 5,
      });
      final files = await source.queryRecords(
        const WorkspaceQuery(typeId: 'file'),
      );
      final resumes = await source.queryRecords(
        const WorkspaceQuery(typeId: 'resume'),
      );
      expect(files.total, 6);
      expect(resumes.total, 2);
      expect(resumes.items.map((r) => r.ref.id).toSet(), {
        'resume',
        'resume-en',
      });
      expect(
        resumes.items.every(
          (r) => r.ref.kind == WorkspaceRecordKind.information,
        ),
        isTrue,
      );
      expect(
        (await source.queryRecords(
          const WorkspaceQuery(keyword: '简历文件'),
        )).total,
        2,
      );
      expect(
        (await source.queryRecords(
          const WorkspaceQuery(keyword: '通用信息'),
        )).total,
        1,
      );
    },
  );

  test(
    'file-target relations include resume attachments and retain ordinary typed identities',
    () async {
      final data = jsonDecode(sampleWorkspaceJson) as Map<String, dynamic>;
      final row =
          (data['records'] as List).singleWhere((r) => r['id'] == 'azure')
              as Map;
      final rule =
          (row['definition']['relations'] as List).singleWhere(
                (r) => r['key'] == 'docs',
              )
              as Map;
      rule['targetTemplates'] = ['file'];
      final source = SampleWorkspaceSource(fixtureJson: jsonEncode(data));
      addTearDown(source.dispose);
      final candidates = await source.queryRelationCandidates(
        const WorkspaceRelationQuery(
          source: azure,
          typeId: 'server',
          key: 'docs',
        ),
      );
      expect(candidates.total, 6);
      expect(candidates.items.any((r) => r.ref == resume), isTrue);
      expect(
        candidates.items.every((r) => workspaceFileTypeIds.contains(r.type.id)),
        isTrue,
      );
    },
  );

  test(
    'resume replacement retains ordinary file identity and field ownership',
    () async {
      final source = SampleWorkspaceSource(
        readAsset: (path) => File(path).readAsBytes(),
      );
      addTearDown(source.dispose);
      final detail = await source.readDetail(resume);
      final before = await source.loadFileHistory(resume, 'file');
      expect(detail.record.type.id, 'resume');
      expect(detail.definition['name'], '简历文件');
      await source.changeFile(
        WorkspaceFileChange(
          operationId: 'resume-replace',
          record: resume,
          fieldKey: 'file',
          expectedRecordVersion: detail.version,
          expectedFileVersion: before.current.ref.version,
          kind: WorkspaceFileChangeKind.replace,
          selectionId: 'image',
        ),
      );
      final after = await source.loadFileHistory(resume, 'file');
      expect(after.versions.length, before.versions.length + 1);
      expect((await source.readDetail(resume)).record.type.id, 'resume');
      expect(
        (await source.readDetail(resume)).fieldIds['file'],
        detail.fieldIds['file'],
      );
      final ref = await source.importFile(
        WorkspaceFileImport(
          operationId: 'ordinary-file',
          selectionId: 'pdf-v2',
          name: '简历名字不决定类型.pdf',
        ),
      );
      expect((await source.readDetail(ref)).record.type.id, 'file');
      expect(
        (await source.queryRecords(const WorkspaceQuery(typeId: 'file'))).total,
        7,
      );
      expect(
        (await source.queryRecords(
          const WorkspaceQuery(typeId: 'resume'),
        )).total,
        2,
      );
    },
  );
}
