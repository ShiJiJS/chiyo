import 'dart:convert';
import 'dart:io';

import 'package:info_core/agent_server.dart';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

Matcher failure(String status) =>
    isA<AccessFailure>().having((e) => e.status, 'status', status);

class _Library {
  _Library(this.repository, this.service, this.file);
  final MemoryInformationRepository repository;
  final InformationService service;
  final InformationAttachmentRef file;
  static const name = FieldRef('career', 'name');
  static const resume = FieldRef('career', 'resume');
  static const note = FieldRef('career', 'note');
  InformationItem get item => service.owner.information.single;
  static Future<_Library> create() async {
    final repository = MemoryInformationRepository();
    final file = InformationAttachmentRef('private-file-identity', 2);
    await repository.save(
      InformationItem('career', '求职资料', '申请所需的个人资料', 1, [
        const InformationField('name', '姓名', '公开字段说明', '虚构姓名', 1),
        const InformationField(
          'note',
          '求职说明',
          '',
          '私有求职说明',
          1,
          kind: FieldKind.textNote,
        ),
        InformationField.file('resume', '简历', '原文件', file, 3),
      ]),
    );
    final service = InformationService(repository: repository);
    addTearDown(service.close);
    return _Library(repository, service, file);
  }
}

void main() {
  test(
    'file payloads round-trip as immutable references, never text or paths',
    () {
      final ref = InformationAttachmentRef('attachment-1', 2);
      final file = InformationField.file('resume', '简历', '原文件', ref, 3);
      expect(file.content, isA<InformationFile>());
      expect(file.attachment, ref);
      expect(() => file.value, throwsA(failure('file_delivery_required')));
      final decoded = InformationField.fromJson(
        jsonDecode(jsonEncode(file.toJson())) as Map<String, dynamic>,
      );
      expect(decoded.attachment, ref);
      expect(decoded.version, 3);
      expect(decoded.toJson().containsKey('value'), false);
      expect(
        decoded.withMetadata(description: '新说明', version: 4).attachment,
        ref,
      );
      for (final malformed in [
        {...file.toJson(), 'value': 'C:/private/resume.pdf'},
        {...file.toJson(), 'kind': 'futureKind'},
        {
          ...file.toJson(),
          'content': {'attachmentId': 'a', 'attachmentVersion': 0},
        },
        {
          ...file.toJson(),
          'content': {...ref.toJson(), 'path': 'C:/private'},
        },
        {...file.toJson(), 'version': 0},
        {...file.toJson(), 'content': null},
      ]) {
        expect(() => InformationField.fromJson(malformed), throwsA(anything));
      }
      final text = const InformationField(
        'notes',
        '说明',
        '',
        '  中文\n原样保留  ',
        2,
        kind: FieldKind.textNote,
      );
      expect(InformationField.fromJson(text.toJson()).value, text.value);
      expect(
        () => InformationField.fromJson({
          ...text.toJson(),
          'content': ref.toJson(),
        }),
        throwsA(anything),
      );
    },
  );

  test(
    'mixed snapshots retain file references and public catalog excludes them',
    () async {
      final library = await _Library.create();
      final roundTrip = informationFromJson(
        jsonDecode(jsonEncode(informationToJson(library.item)))
            as Map<String, dynamic>,
      );
      expect(roundTrip.fields.last.attachment, library.file);
      final catalog = library.service.agent.catalog();
      expect(((catalog.single['fields'] as List).last as Map)['kind'], 'file');
      final public = jsonEncode(catalog);
      for (final private in [
        'private-file-identity',
        'attachmentVersion',
        'content',
        '虚构姓名',
        '私有求职说明',
      ]) {
        expect(public.contains(private), false);
      }
    },
  );

  test(
    'ordinary owner edits and descriptions preserve the unchanged file payload',
    () async {
      final library = await _Library.create();
      final updated = await library.service.owner.editInformation(
        'career',
        1,
        name: '新的求职资料',
        description: '用途修正',
        changes: [const FieldChange.correct('name', '新的虚构姓名')],
        fieldDescriptions: {'resume': '用于申请的原文件'},
      );
      expect(updated.fields.first.value, '新的虚构姓名');
      expect(updated.fields.last.attachment, library.file);
      expect(updated.fields.last.id, 'resume');
      expect(updated.fields.last.version, 4);
      expect(
        library
            .service
            .owner
            .informationRevisions
            .single
            .item
            .fields
            .last
            .attachment,
        library.file,
      );
    },
  );

  test(
    'reviewed text proposals retain files and reject file overwrites atomically',
    () async {
      final library = await _Library.create();
      final service = library.service;
      final session = service.agent.openSession('Synthetic mixed information');
      final id = await service.agent.submitUpdate(
        session,
        UpdateInput('career', 1, [const FieldChange.correct('name', '提案姓名')]),
      );
      expect(
        service.owner.previewUpdate(id).after.fields.last.attachment,
        library.file,
      );
      await service.owner.confirmUpdate(id, 1);
      expect(library.item.fields.first.value, '提案姓名');
      expect(library.item.fields.last.attachment, library.file);
      await expectLater(
        service.owner.editInformation(
          'career',
          2,
          name: library.item.name,
          description: library.item.description,
          changes: [const FieldChange.correct('resume', 'pretend-file-bytes')],
        ),
        throwsA(failure('unsupported_file_write')),
      );
      expect(library.item.version, 2);
      expect(library.item.fields.last.attachment, library.file);
    },
  );

  test(
    'file proposals fail explicitly before recording or serializing write plans',
    () async {
      final library = await _Library.create();
      final service = library.service;
      final session = service.agent.openSession('Synthetic file writes');
      final input = FieldInput.file('简历', '', library.file);
      await expectLater(
        service.agent.submitImport(session, [
          ImportItemInput('新资料', '', [input]),
        ]),
        throwsA(failure('unsupported_file_write')),
      );
      await expectLater(
        service.agent.submitUpdate(
          session,
          UpdateInput('career', 1, [FieldChange.add(input)]),
        ),
        throwsA(failure('unsupported_file_write')),
      );
      for (final value in [
        {'name': '简历', 'kind': 'file', 'value': 'fake-path'},
        {'name': '简历', 'kind': 'file', 'content': library.file.toJson()},
      ]) {
        expect(
          () => FieldInput.fromJson(value),
          throwsA(failure('unsupported_file_write')),
        );
      }
      expect(service.owner.importProposals, isEmpty);
      expect(service.owner.updateProposals, isEmpty);
      expect(library.item.version, 1);
    },
  );

  test(
    'ordinary authorization reads text but requires separate file delivery without leaking unapproved kind',
    () async {
      final library = await _Library.create();
      final service = library.service;
      final session = service.agent.openSession('Synthetic mixed request');
      final request = service.agent.request(
        session,
        'Read name and original resume',
        [_Library.name, _Library.resume, _Library.note],
      );
      service.owner.approve(request.id, [_Library.name, _Library.resume]);
      final grant = service.agent.claim(session, request.id);
      expect(await service.agent.read(grant.token, _Library.name), '虚构姓名');
      await expectLater(
        service.agent.read(grant.token, _Library.resume),
        throwsA(failure('file_delivery_required')),
      );
      await expectLater(
        service.agent.read(grant.token, _Library.note),
        throwsA(failure('unauthorized')),
      );
      await expectLater(
        service.agent.read('unknown-token', _Library.resume),
        throwsA(failure('unauthorized')),
      );
      expect(
        library.repository.accessRecords
            .where((r) => r.outcome == AccessOutcome.fileDeliveryRequired)
            .length,
        1,
      );
      expect(
        service.agent.claim(session, request.id).expiresAt,
        grant.expiresAt,
      );
      expect(library.repository.accessRecords.last.itemId, isNull);
      expect(library.repository.accessRecords.last.fieldId, isNull);
    },
  );

  test(
    'recycle restores the reference with a new field identity and does not revive old access',
    () async {
      final library = await _Library.create();
      final service = library.service;
      final session = service.agent.openSession('Synthetic recycle');
      final request = service.agent.request(session, 'Original resume', [
        _Library.resume,
      ]);
      service.owner.approve(request.id, [_Library.resume]);
      final grant = service.agent.claim(session, request.id);
      final entry = await service.owner.deleteInformation(
        'career',
        1,
        fieldId: 'resume',
      );
      expect(entry.snapshot!.fields.single.attachment, library.file);
      final roundTrip = RecycleEntry.fromJson(
        jsonDecode(jsonEncode(entry.toJson())) as Map<String, dynamic>,
      );
      expect(roundTrip.snapshot!.fields.single.attachment, library.file);
      final restored = await service.owner.restoreRecycled(entry.id);
      final file = restored.fields.singleWhere((f) => f.kind == FieldKind.file);
      expect(file.attachment, library.file);
      expect(file.id, isNot('resume'));
      await expectLater(
        service.agent.read(grant.token, FieldRef('career', file.id)),
        throwsA(failure('unauthorized')),
      );
    },
  );

  test(
    'revision comparisons and restoration retain the selected historical reference',
    () async {
      final library = await _Library.create();
      await library.service.owner.editInformation(
        'career',
        1,
        name: library.item.name,
        description: '新说明',
      );
      final current = library.item;
      await library.repository.save(
        InformationItem(current.id, current.name, current.description, 3, [
          ...current.fields.take(2),
          InformationField.file(
            'resume',
            '简历',
            '新版本',
            InformationAttachmentRef('private-file-identity', 3),
            4,
          ),
        ]),
      );
      final preview = library.service.owner.previewRevision('career', 1, 3);
      expect(preview.changes.any((c) => c.after?.id == 'resume'), true);
      expect(preview.restored.fields.last.attachment, library.file);
      final restored = await library.service.owner.restoreRevision(
        'career',
        1,
        3,
      );
      expect(restored.fields.last.attachment, library.file);
      expect(restored.fields.last.version, 5);
    },
  );

  test(
    'file template definitions contain no payload and legacy value application requires a file',
    () async {
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      addTearDown(service.close);
      final template = await service.owner.createTemplate('求职', '', [
        const TemplateFieldInput('简历', '申请所需文件', kind: FieldKind.file),
      ]);
      expect(template.fields.single.kind, FieldKind.file);
      await expectLater(
        service.owner.createInformationFromTemplate(
          template.id,
          1,
          '求职资料',
          '',
          {template.fields.single.id: 'C:/not-a-real-import.pdf'},
        ),
        throwsA(failure('attachment_missing')),
      );
      expect(service.owner.information, isEmpty);
    },
  );

  test(
    'legacy HTTP catalog/request fail explicitly on file fields until attachment transport is enabled',
    () async {
      final library = await _Library.create();
      final service = library.service;
      final server = await AgentServer.start(service.agent, port: 0);
      final http = HttpClient();
      addTearDown(() async {
        http.close(force: true);
        await server.close();
      });
      Future<Map<String, dynamic>> call(
        String path,
        Map<String, Object?> body,
      ) async {
        final request = await http.post('127.0.0.1', server.port, path);
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
        final response = await request.close();
        return jsonDecode(await utf8.decodeStream(response))
            as Map<String, dynamic>;
      }

      expect((await call('/catalog', {}))['status'], 'unsupported_capability');
      final session = service.agent.openSession('Synthetic legacy client');
      expect(
        (await call('/request', {
          'sessionSecret': 'unknown',
          'purpose': 'Test',
          'fields': [_Library.resume.toJson()],
        }))['status'],
        'unauthorized',
      );
      expect(
        (await call('/request', {
          'sessionSecret': session,
          'purpose': 'Test',
          'fields': [_Library.resume.toJson()],
        }))['status'],
        'unsupported_capability',
      );
      final invalid = await call('/import/submit', {
        'sessionSecret': session,
        'items': [
          {
            'name': '文件提案',
            'fields': [
              {'name': '简历', 'kind': 'file', 'value': 'fake-path'},
            ],
          },
        ],
      });
      expect(invalid['status'], 'unsupported_file_write');
      expect(service.owner.requests, isEmpty);
      expect(service.owner.importProposals, isEmpty);
    },
  );
}
