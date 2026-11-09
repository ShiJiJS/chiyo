import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_cli/agent_client.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_desktop/workspace/remote_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_server/mounted_database_key_store.dart';
import 'package:info_workspace/plugin_transport.dart';
import 'package:sqlite3/sqlite3.dart';
import '../../../server/test/support/device_credential_fixture.dart';
import '../../../server/test/support/device_test_receiver.dart';
import '../../../server/test/support/template_fixture.dart';

/// Synthetic content preparation only. Backup, native publication and restore
/// are exercised separately through the normal App controller and TLS service.
Future<void> prepareCompleteBackupLibrary(
  DeviceCredentialFixture f,
  RemoteWorkspaceSource source,
) async {
  final o = f.runtime.service.owner;
  final parent = await f.runtime.run(() => o.createDirectory('合成服务'));
  final child = await f.runtime.run(
    () => o.createDirectory('独立部署', parentId: parent.id),
  );
  final other = await f.runtime.run(() => o.createDirectory('合成文件'));
  final tag = await f.runtime.run(() => o.createTag('合成测试'));
  await f.runtime.run(
    () => o.createTemplate('旧版自定义模板', '测试兼容旧单机资料', [
      const core.TemplateFieldInput('正文', '', kind: core.FieldKind.textNote),
    ]),
  );
  final template = await source.loadTemplate('generic');
  final savedNote = await source.createRecord(
    WorkspaceCreate(
      operationId: 'complete-note',
      typeId: 'generic',
      expectedTemplateVersion: template['templateVersion'] as String,
      expectedTemplateDigest: template['packageDigest'] as String,
      directoryId: child.id,
      name: '合成服务说明',
      values: {'body': '## 合成说明\n\n- 保留原有格式和关联。'},
    ),
  );
  expect(savedNote, isA<WorkspaceSaved>());
  final note = (savedNote as WorkspaceSaved).detail.record;
  await f.runtime.run(
    () => o.organizeInformation(
      note.ref.id,
      directoryId: child.id,
      tagIds: [tag.id],
    ),
  );
  core.InformationItem? previous;
  for (var version = 1; version <= 2; version++) {
    await f.runtime.run(() async {
      final draft = await o.beginInformationFileDraft();
      try {
        final stage = await o.stageInformationBytes(
          draft,
          originalName: '合成资料.bin',
          bytes: Uint8List.fromList(
            List.generate(7 * 1024 * 1024, (i) => (i + version) % 251),
          ),
        );
        previous = await o.commitInformationDraft(
          draft,
          'complete-file-$version',
          core.InformationDraftInput(
            name: '合成多版本文件',
            description: '两版原文均保留',
            itemId: previous?.id,
            baseVersion: previous?.version,
            directoryId: other.id,
            fields: [
              core.InformationDraftField.stagedFile(
                '附件',
                '',
                stage.id,
                fieldId: previous?.fields.single.id,
              ),
            ],
          ),
        );
      } finally {
        await o.releaseInformationFileDraft(draft);
      }
    });
  }
  final detail = await source.readDetail(note.ref);
  await source.saveRecord(
    WorkspaceEdit(
      operationId: 'complete-related-note',
      expectedVersion: detail.version,
      record: detail.record,
      values: {...detail.values, 'body': '## 修改后说明\n\n- 引用同一文件的当前版本。'},
      relations: {
        'related': [
          WorkspaceRecordRef(WorkspaceRecordKind.information, previous!.id),
        ],
      },
    ),
  );
  await f.runtime.run(() async {
    await o.setRequestLifetime(const Duration(minutes: 47));
    var password = await o.createStringCredential(
      name: '合成密码',
      publicPurpose: '备份恢复测试',
      secret: 'SYNTHETIC_PASSWORD_V1',
    );
    password = await o.rotateStringCredential(
      password.id,
      password.revision,
      'SYNTHETIC_PASSWORD_V2',
    );
    await o.setCredentialLinks(password.id, password.revision, [note.ref.id]);
    var file = await o.createFileCredential(
      name: '合成凭据文件',
      publicPurpose: '只含合成材料',
      fileName: 'synthetic.key',
      bytes: [0, 128, 255, 1],
    );
    file = await o.rotateFileCredential(
      file.id,
      file.revision,
      fileName: 'synthetic.key',
      bytes: [255, 0, 128, 2],
    );
    await o.setCredentialLinks(file.id, file.revision, [note.ref.id]);
    final selection = core.LibrarySelection(directoryIds: [other.id]);
    // Place the file folder before the service folder. A separate subtree
    // below it exercises whole-directory recycling without removing live files.
    final place = core.LibraryMovePosition(
      core.LibraryEntryRef('directory', parent.id),
    );
    final move = await o.previewLibraryMove(selection, null, position: place);
    await o.moveLibrarySelection(
      'complete-order',
      selection,
      null,
      move.token,
      position: place,
    );
    final removedDirectory = await o.createDirectory(
      '整批回收目录',
      parentId: other.id,
    );
    await o.createInformation('整批回收资料', '', [
      const core.FieldInput('正文', '', 'SYNTHETIC_BATCH_RECYCLE'),
    ], directoryId: removedDirectory.id);
    final recycleSelection = core.LibrarySelection(
      directoryIds: [removedDirectory.id],
    );
    final recycle = await o.previewLibraryRecycle(recycleSelection);
    await o.recycleLibrarySelection(
      'complete-recycle',
      recycleSelection,
      recycle.token,
    );
    final retained = await o.createInformation('单条回收资料', '', [
      const core.FieldInput('正文', '', 'SYNTHETIC_RECYCLE_CONTENT'),
    ]);
    await o.deleteInformation(retained.id, retained.version);
    final session = f.runtime.service.agent.openSession('合成资料读取');
    final current = o.information.singleWhere((i) => i.id == note.ref.id);
    final field = core.FieldRef(current.id, current.fields.single.id);
    final requested = f.runtime.service.agent.request(session, '合成读取记录', [
      field,
    ]);
    o.approve(requested.id, [field]);
    final grant = f.runtime.service.agent.claim(session, requested.id);
    await f.runtime.service.agent.read(grant.token, field);
    final id = await f.runtime.service.agent.submitImport(session, [
      core.ImportItemInput('合成提案录入', '', [
        const core.FieldInput('值', '', 'SYNTHETIC_APPROVED_IMPORT'),
      ]),
    ]);
    final proposal = o.importProposals.singleWhere((p) => p.id == id);
    await o.confirmImport(id, proposal.version, proposal.items);
    f.runtime.service.agent.request(session, '不会成为恢复后有效权限', [field]);
  });
  // Install through the real production plugin path, with source and examples.
  final selected = await f.owner.request('POST', '/v1/owner/plugins/stage', {
    'filename': 'synthetic-template.json',
    'bytes': base64Encode(
      utf8.encode(jsonEncode(syntheticTemplatePackage('1.0.0'))),
    ),
  });
  final preview = pluginPreviewFromJson(
    await f.owner.request(
      'GET',
      '/v1/owner/plugins/previews/${selected['selectionId']}',
    ),
  );
  await source.plugins.change(
    WorkspacePluginChange(
      operationId: 'complete-plugin',
      action: WorkspacePluginAction.install,
      packageId: preview.package.id,
      expectedVersion: preview.catalogVersion,
      expectedDigest: preview.package.digest,
      selectionId: preview.selectionId,
    ),
  );
  await _runNativeToken(f, source);
}

Future<void> _runNativeToken(
  DeviceCredentialFixture f,
  RemoteWorkspaceSource source,
) async {
  final root = await f.root.resolveSymbolicLinks();
  final work = await Directory('$root/complete-execution').create();
  final executable = File('${work.path}/gh');
  await executable.writeAsString(syntheticCredentialReceiver, flush: true);
  expect(
    (await Process.run('/bin/chmod', ['700', executable.path])).exitCode,
    0,
  );
  final release = File('${work.path}/release');
  final counter = File('${work.path}/counter');
  // Flutter's test executable is not the Dart VM. Compile the current real
  // worker, as the shipping App does, rather than substituting a fake starter.
  final worker = '$root/info-runtime-worker';
  final compiler = File(
    '../../.tools/flutter/bin/cache/dart-sdk/bin/dart',
  ).absolute.path;
  final compilation = await Process.run(compiler, [
    'compile',
    'exe',
    '../../packages/info_cli/lib/runtime_worker.dart',
    '-o',
    worker,
  ]);
  expect(
    compilation.exitCode,
    0,
    reason: '${compilation.stdout}\n${compilation.stderr}',
  );
  final client = AgentClient.remote(
    f.profiles.first,
    deviceFileStateDirectory: Directory('$root/complete-private/device-files'),
    runtimeWorkerExecutable: worker,
  );
  try {
    final credential = await f.runtime.run(() async {
      final c = await f.runtime.service.owner.createStringCredential(
        name: '合成执行Token',
        publicPurpose: '',
        secret: 'SYNTHETIC_DEVICE_TOKEN',
      );
      return f.runtime.service.owner.updateCredentialMetadata(
        c.id,
        c.revision,
        name: c.name,
        publicPurpose: '',
        privateNote: '',
        suggestedBinding: 'material',
        discoverable: true,
      );
    });
    expect((await client.openLifecycleSession('合成真实执行'))['status'], 'ok');
    final launch = <String, dynamic>{
      'receiver': 'gh_token',
      'executable': executable.path,
      'argv': ['api', 'user', counter.path, release.path],
      'cwd': work.path,
      'env': {
        'GH_TOKEN': {'secret': 'material'},
      },
    };
    final request = await client.execute({
      'protocolVersion': 2,
      'command': 'request-use',
      'purpose': '测试本机执行历史恢复',
      'credentials': [
        {'alias': 'material', 'credentialId': credential.id, 'version': 1},
      ],
      'launch': launch,
    });
    expect(request['status'], 'pending', reason: jsonEncode(request));
    final review = await source.approvals.read(request['requestId'] as String);
    await source.approvals.change(
      WorkspaceApprovalChange(
        operationId: 'complete-execution-approval',
        requestId: review.request.id,
        reviewToken: review.reviewToken,
        action: WorkspaceApprovalAction.approve,
        selected: review.scopes.map((s) => s.id),
        credentialMinutes: 15,
      ),
    );
    await release.writeAsString('release');
    final accepted = await client.execute({
      'protocolVersion': 2,
      'command': 'run-use',
      'requestId': request['requestId'],
      'operationId': 'complete-real-execution',
      'launch': launch,
    });
    expect(accepted['status'], 'accepted', reason: jsonEncode(accepted));
    await client.drainCredentialExecutions();
    var result = <String, dynamic>{};
    final end = DateTime.now().add(const Duration(seconds: 30));
    do {
      result = await client.execute({
        'command': 'execution-status',
        'executionId': accepted['executionId'],
      });
      if (!{'preparing', 'running'}.contains(result['executionState'])) break;
      await Future<void>.delayed(const Duration(milliseconds: 40));
    } while (DateTime.now().isBefore(end));
    expect(result['executionState'], 'exited', reason: jsonEncode(result));
    expect(result['exitCode'], 0);
    expect(await counter.readAsLines(), ['started']);
  } finally {
    await release.writeAsString('release');
    await client.drainCredentialExecutions();
    client.close();
  }
}

/// Independent read-only inspection of the synthetic SQLCipher library. It
/// compares every column, decoded JSON value and attachment hashes. Runtime
/// permissions are checked separately because restore deliberately revokes them.
Future<Map<String, List<Map<String, Object?>>>> completeBackupRows(
  DeviceCredentialFixture f,
) async {
  final key = await MountedDatabaseKeyStore(
    '${f.root.path}/secrets/database.key',
  ).read();
  final db = sqlite3.open(
    '${f.root.path}/data/library.db',
    mode: OpenMode.readOnly,
  );
  try {
    db.execute(
      'PRAGMA key = "x\'${key!.map((v) => v.toRadixString(16).padLeft(2, '0')).join()}\'"',
    );
    const tables = [
      'information_directories',
      'information_tags',
      'field_templates',
      'settings',
      'information_items',
      'information_fields',
      'information_item_tags',
      'information_revisions',
      'recycle_entries',
      'recycle_facts',
      'managed_credentials',
      'credential_materials',
      'information_file_fields',
      'information_attachment_versions',
      'template_packages',
      'library_recycle_batches',
      'library_order_state',
    ];
    Object? normalize(String column, Object? value) {
      if (value is Uint8List) {
        return {
          'byteLength': value.length,
          'sha256': sha256.convert(value).toString(),
        };
      }
      if (value is String &&
          (column == 'payload' ||
              column == 'metadata' ||
              column.endsWith('_json'))) {
        return jsonDecode(value);
      }
      return value;
    }

    return {
      for (final table in tables)
        table: [
          for (final row in db.select('SELECT * FROM $table'))
            {
              for (final entry in row.entries)
                entry.key: normalize(entry.key, entry.value),
            },
        ],
    };
  } finally {
    db.close();
  }
}

Future<Map<String, Uint8List>> completeBackupAttachmentBytes(
  DeviceCredentialFixture f,
) async {
  final key = await MountedDatabaseKeyStore(
    '${f.root.path}/secrets/database.key',
  ).read();
  final db = sqlite3.open(
    '${f.root.path}/data/library.db',
    mode: OpenMode.readOnly,
  );
  try {
    db.execute(
      'PRAGMA key = "x\'${key!.map((v) => v.toRadixString(16).padLeft(2, '0')).join()}\'"',
    );
    return {
      for (final row in db.select(
        'SELECT attachment_id, version, body FROM information_attachment_versions WHERE body IS NOT NULL',
      ))
        '${row['attachment_id']}:${row['version']}': Uint8List.fromList(
          row['body'] as Uint8List,
        ),
    };
  } finally {
    db.close();
  }
}
