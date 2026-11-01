import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/information_files.dart';
import 'package:info_desktop/workspace/owner_workspace_source.dart';
import 'package:info_desktop/workspace/owner_workspace_hosts.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

class _Keys implements DatabaseKeyStore {
  List<int>? value;
  @override
  Future<List<int>?> read() async => value;
  @override
  Future<void> create(List<int> bytes) async {
    value = List.of(bytes);
  }
}

class _Picker implements InformationFilePicker {
  String? path;
  @override
  Future<String?> choose() async => path;
  @override
  Future<String?> saveAs(String name) async => null;
}

void main() {
  late Directory root;
  late _Keys keys;
  late _Picker picker;
  late EncryptedInformationRepository repo;
  late core.InformationService service;
  late OwnerWorkspaceSource source;
  late OwnerWorkspaceHosts hosts;
  Future<void> open() async {
    repo = await EncryptedInformationRepository.open(root.path, keys);
    service = core.InformationService(repository: repo);
    hosts = OwnerWorkspaceHosts(
      owner: service.owner,
      changed: () {},
      picker: picker,
    );
    source = OwnerWorkspaceSource(
      owner: service.owner,
      hosts: hosts,
      refreshInterval: Duration.zero,
    );
  }

  Future<void> close() async {
    hosts.dispose();
    await source.dispose();
    await service.close();
    await repo.close();
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('owner-hosts-');
    keys = _Keys();
    picker = _Picker();
    await open();
  });
  tearDown(() async {
    await close();
    await root.delete(recursive: true);
  });
  Future<WorkspaceRecordRef> server() async {
    final d = await source.loadTemplate('server');
    final r = await source.createRecord(
      WorkspaceCreate(
        operationId: workspaceOperationId(),
        typeId: 'server',
        name: '合成服务器',
        expectedTemplateVersion: d['templateVersion'] as String?,
        expectedTemplateDigest: d['packageDigest'] as String?,
        values: {
          'host': 'synthetic.example',
          'port': '2222',
          'user': 'tester',
          'purpose': '合成验收',
        },
      ),
    );
    return (r as WorkspaceSaved).detail.record.ref;
  }

  Future<WorkspaceHostImportChange> select() async {
    final algorithm = utf8.encode('ssh-ed25519');
    final key = base64Encode([
      0,
      0,
      0,
      algorithm.length,
      ...algorithm,
      0,
      0,
      0,
      32,
      ...List.filled(32, 7),
    ]);
    final file = File('${root.path}/known_hosts');
    await file.writeAsString('[synthetic.example]:2222 ssh-ed25519 $key\n');
    picker.path = file.path;
    final selected = await hosts.pick();
    expect(selected!.selectionId, isNot(contains(root.path)));
    return WorkspaceHostImportChange(
      workspaceOperationId(),
      await hosts.previewImport(selected.selectionId),
    );
  }

  test(
    'explicit known_hosts import and endpoint revoke/confirm affect real receiver snapshot and survive reopen',
    () async {
      final ref = await server();
      final target = WorkspaceHostTarget.record(ref);
      expect(
        (await hosts.read(target)).state,
        WorkspaceHostState.missingFingerprint,
      );
      final change = await select();
      final receipt = await hosts.importFile(change);
      expect(receipt.matches(change), true);
      final imported = await hosts.read(target);
      expect(imported.state, WorkspaceHostState.trusted);
      expect((await hosts.load()).length, 1);
      expect(service.owner.sshKnownHosts, isNotNull);
      final revoke = WorkspaceHostChange(
        operationId: workspaceOperationId(),
        action: WorkspaceHostAction.revoke,
        reviewed: imported,
      );
      final revoked = await hosts.change(revoke);
      expect(revoked.version, greaterThan(revoked.expectedVersion));
      expect(
        utf8.decode(service.owner.sshKnownHosts!.bytes),
        startsWith('@revoked '),
      );
      expect((await hosts.read(target)).state, WorkspaceHostState.revoked);
      await close();
      await open();
      expect(
        (await hosts.importReceipt(change.operationId))!.matches(change),
        true,
      );
      expect((await hosts.change(revoke)).version, revoked.version);
      final now = await hosts.read(target);
      final confirmed = await hosts.change(
        WorkspaceHostChange(
          operationId: workspaceOperationId(),
          action: WorkspaceHostAction.confirm,
          reviewed: now,
        ),
      );
      expect(confirmed.version, greaterThan(now.version));
      expect((await hosts.read(target)).state, WorkspaceHostState.trusted);
      expect(
        utf8.decode(service.owner.sshKnownHosts!.bytes),
        isNot(contains('@revoked')),
      );
    },
  );
  test(
    'released selection and changed plugin catalog cannot silently import',
    () async {
      final c = await select();
      await hosts.releaseImport(c.preview.file.selectionId);
      await expectLater(hosts.importFile(c), throwsA(isA<WorkspaceFailure>()));
      expect(await hosts.importReceipt(c.operationId), isNull);
      final next = await select();
      await service.owner.changeTemplatePackage(
        core.TemplatePackageCommand(
          operationId: 'disable-server',
          action: core.TemplatePackageAction.disable,
          packageId: 'builtin.server',
          expectedVersion: service.owner.templatePackageVersion,
          commandDigest: 'a' * 64,
        ),
      );
      await expectLater(
        hosts.importFile(next),
        throwsA(isA<WorkspaceFailure>()),
      );
      expect(service.owner.sshKnownHosts, isNull);
    },
  );
}
