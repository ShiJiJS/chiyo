import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_core/builtin_information_definitions.dart';
import 'template_package_decoder.dart';
import 'workspace_source.dart';

class _PackageSelection {
  _PackageSelection(this.filename, List<int> bytes)
    : bytes = List.unmodifiable(bytes);
  final String filename;
  final List<int> bytes;
}

/// Real declarative packages. Selection paths never enter workspace DTOs or
/// storage, and installed packages cannot register executable settings panels.
class OwnerWorkspaceTemplatePackages implements WorkspacePluginSource {
  OwnerWorkspaceTemplatePackages({required this.owner, required this.changed})
    : _scope = owner.captureLibraryScope();
  final core.OwnerAccess owner;
  final void Function() changed;
  final core.OwnerLibraryScope _scope;
  final _selections = <String, _PackageSelection>{};
  bool _closed = false;
  void _check() {
    if (_closed) throw const WorkspaceFailure('unavailable', '插件窗口已关闭。');
    if (!_scope.isCurrent) {
      throw const WorkspaceFailure('library_changed', '资料库已替换，请重新选择插件包。');
    }
    if (!owner.serviceAvailable) {
      throw const WorkspaceFailure('unavailable', '资料服务当前不可用。');
    }
  }

  void dispose() {
    _closed = true;
    _selections.clear();
  }

  Future<T> _run<T>(Future<T> Function() action) async {
    _check();
    try {
      return await owner.inLibraryScope(_scope, () async {
        final result = await action();
        _check();
        return result;
      });
    } on core.AccessFailure catch (e) {
      throw WorkspaceFailure(
        switch (e.status) {
          'catalog_changed' => 'conflict',
          _ => e.status,
        },
        switch (e.status) {
          'catalog_changed' => '插件目录已变化，请重新预览。',
          'package_version_conflict' => '同一版本内容不同，不能覆盖已安装包。',
          'definition_identity_conflict' => '字段形态变化需要新的字段身份，不能覆盖旧定义。',
          'builtin_package' => '内置包可以停用，不能移除。',
          'operation_conflict' => '原操作不能用于另一份插件变更。',
          'library_changed' => '资料库已替换，请重新打开插件设置。',
          _ => '插件操作尚未完成，请重试或核对原操作。',
        },
      );
    }
  }

  List<WorkspacePlugin> get packages {
    _check();
    final installed = {
      for (final p in owner.installedTemplatePackages) p.id: p,
    };
    final result = <WorkspacePlugin>[];
    for (final type in const ['server', 'service', 'profile']) {
      final id = 'builtin.$type',
          definition = builtinWorkspaceDefinitions[type]!;
      result.add(
        WorkspacePlugin(
          id: id,
          name: definition['name'] as String,
          version: '1.0.0',
          author: '知予',
          description: '内置资料模板；已有资料保留各自定义。',
          digest: definition['packageDigest'] as String,
          origin: '应用内置',
          builtin: true,
          enabled: installed[id]?.enabled ?? true,
          panels: type == 'server'
              ? const [WorkspacePluginPanel.sshTrust]
              : const [],
          templates: [
            WorkspacePluginTemplate(
              id: type,
              type: WorkspaceType(
                type,
                definition['name'] as String,
                definition['icon'] as String? ?? 'file',
              ),
              definition: {...definition, 'packageId': id},
            ),
          ],
        ),
      );
    }
    for (final p in installed.values.where((p) => !p.builtin)) {
      final d = p.definition!;
      var projected = WorkspacePlugin(
        id: d.id,
        name: d.name,
        version: d.version,
        author: d.author,
        description: d.description,
        digest: d.digest,
        origin: d.origin,
        enabled: p.enabled,
        templates: d.templates.map(
          (t) => WorkspacePluginTemplate(
            id: t.id,
            type: WorkspaceType(t.type.id, t.type.name, t.type.icon),
            definition: t.definition,
          ),
        ),
      );
      if (p.legacySource != null) {
        projected = projected.fromLegacy(p.legacySource!);
      }
      result.add(projected);
    }
    return [
      for (final p in result)
        p.project(
          affectedRecords:
              owner.information
                  .where(
                    (i) =>
                        p.templates.any((t) => t.type.id == i.layout?.typeId) ||
                        (i.layout?.snapshot['definition'] is Map &&
                            (i.layout!.snapshot['definition']
                                    as Map)['packageId'] ==
                                p.id),
                  )
                  .length +
              owner.credentials
                  .where(
                    (c) =>
                        p.templates.any((t) => t.type.id == c.template?.typeId),
                  )
                  .length,
        ),
    ];
  }

  Map<String, Map<String, Object?>> get templates {
    final current = packages;
    return {
      for (final e in builtinWorkspaceDefinitions.entries)
        if (!const {'server', 'service', 'profile'}.contains(e.key))
          e.key: e.value,
      for (final p in current.where((p) => p.enabled))
        for (final t in p.templates)
          if (t.definition['recordKind'] != 'credential')
            t.type.id: workspaceImmutableMap({
              ...t.definition,
              'id': t.type.id,
            }),
    };
  }

  WorkspaceTemplateState stateFor(String type, String? packageId) =>
      workspacePluginTemplateState(packages, type, packageId);

  Set<String> get _known => {
    for (final p in packages)
      for (final t in p.templates) '${p.id}/${t.id}',
  };
  WorkspacePluginCandidate _stage(_PackageSelection input) {
    _check();
    if (_selections.length >= 32) {
      throw const WorkspaceFailure('selection_busy', '请先关闭已有的插件预览。');
    }
    if (input.bytes.length > TemplatePackageDecoder.maxBytes) {
      throw const WorkspaceFailure('invalid_package', '插件包不能超过1 MiB。');
    }
    final id = workspaceOperationId();
    _selections[id] = input;
    return WorkspacePluginCandidate(id, input.filename, input.bytes.length);
  }

  WorkspacePluginCandidate stageBytes(String filename, List<int> bytes) {
    if (filename.isEmpty ||
        filename.length > 255 ||
        filename.contains('/') ||
        filename.contains('\\') ||
        filename.codeUnits.any((c) => c < 32)) {
      throw const WorkspaceFailure('invalid_package', '插件文件名无效。');
    }
    return _stage(_PackageSelection(filename, bytes));
  }

  @override
  Future<WorkspacePluginCatalog> load() => _run(
    () async => WorkspacePluginCatalog(owner.templatePackageVersion, packages),
  );
  WorkspacePlugin _decode(String id) {
    final candidate = _selections[id];
    if (candidate == null) {
      throw const WorkspaceFailure('selection_changed', '原文件选择已释放，请重新选择。');
    }
    final p = TemplatePackageDecoder().decode(
      candidate.bytes,
      origin: candidate.filename,
      knownTemplates: _known,
    );
    return p;
  }

  void _version(WorkspacePlugin next, WorkspacePlugin? old) {
    if (old == null) return;
    if (next.version == old.version) {
      throw WorkspaceFailure(
        next.digest == old.digest
            ? 'already_installed'
            : 'package_version_conflict',
        next.digest == old.digest ? '同一版本与内容已经安装。' : '同一版本的内容不同，不能覆盖。',
      );
    }
    for (final t in next.templates) {
      final previous = old.templates.where((p) => p.id == t.id).firstOrNull;
      final kinds = {
        for (final f in previous?.definition['fields'] as List? ?? [])
          f['key']: f['type'],
      };
      for (final f in t.definition['fields'] as List) {
        if (kinds.containsKey(f['key']) && kinds[f['key']] != f['type']) {
          throw const WorkspaceFailure(
            'definition_identity_conflict',
            '字段形态变化须使用新的字段身份。',
          );
        }
      }
    }
  }

  List<String> _differences(WorkspacePlugin next, WorkspacePlugin? old) {
    if (old == null) return ['新增${next.templates.length}个模板，安装后用于新建资料。'];
    final changes = <String>[
      '版本：${old.version} → ${next.version}；已有资料继续保留原快照。',
    ];
    final a = next.version.split('.').map(BigInt.parse).toList(),
        b = old.version.split('.').map(BigInt.parse).toList();
    for (var i = 0; i < 3; i++) {
      if (a[i] < b[i]) {
        changes.add('这是降级，请核对后再决定。');
        break;
      }
      if (a[i] > b[i]) break;
    }
    for (final t in next.templates) {
      final before = old.templates.where((p) => p.id == t.id).firstOrNull;
      if (before == null) {
        changes.add('新增模板：${t.type.name}');
        continue;
      }
      if (jsonEncode(before.definition) != jsonEncode(t.definition)) {
        changes.add('模板定义变化：${t.type.name}');
      }
    }
    for (final t in old.templates) {
      if (!next.templates.any((n) => n.id == t.id)) {
        changes.add('移除模板：${t.type.name}；已有资料保留。');
      }
    }
    return changes;
  }

  @override
  Future<WorkspacePluginPreview> previewInstall(String id) => _run(() async {
    final next = _decode(id),
        old = packages.where((p) => p.id == next.id).firstOrNull;
    _version(next, old);
    return WorkspacePluginPreview(
      selectionId: id,
      package: next,
      previous: old,
      catalogVersion: owner.templatePackageVersion,
      differences: _differences(next, old),
    );
  });
  @override
  Future<void> releaseCandidate(String id) async {
    _selections.remove(id);
  }

  @override
  Future<WorkspacePluginCandidate> prepareUpdate(
    WorkspacePluginUpdate update,
    int catalogVersion,
  ) => _run(() async {
    throw const WorkspaceFailure('not_found', '当前应用没有提供该内置更新；外部更新请重新选择插件文件。');
  });
  String _digest(WorkspacePluginChange c) => sha256
      .convert(
        utf8.encode(
          jsonEncode({
            'operationId': c.operationId,
            'action': c.action.name,
            'packageId': c.packageId,
            'expectedVersion': c.expectedVersion,
            'selectionId': c.selectionId,
            'expectedDigest': c.expectedDigest,
          }),
        ),
      )
      .toString();
  WorkspacePluginReceipt _receipt(core.TemplatePackageReceipt r) =>
      WorkspacePluginReceipt(
        operationId: r.command.operationId,
        action: WorkspacePluginAction.values.byName(r.command.action.name),
        packageId: r.command.packageId,
        expectedVersion: r.command.expectedVersion,
        version: r.version,
        digest: r.digest,
      );
  @override
  Future<WorkspacePluginReceipt?> receipt(String id) => _run(() async {
    final r = await owner.templatePackageReceipt(id);
    return r == null ? null : _receipt(r);
  });
  @override
  Future<WorkspacePluginReceipt> change(WorkspacePluginChange c) => _run(
    () async {
      final digest = _digest(c),
          previous = await owner.templatePackageReceipt(c.operationId);
      if (previous != null) {
        if (previous.command.commandDigest != digest) {
          throw const WorkspaceFailure('operation_conflict', '原操作不能更换插件意图。');
        }
        return _receipt(previous);
      }
      core.InstalledTemplatePackage? input;
      _PackageSelection? selected;
      if (c.action == WorkspacePluginAction.install) {
        final id = c.selectionId;
        if (id == null) {
          throw const WorkspaceFailure('selection_changed', '请先选择并预览插件文件。');
        }
        final p = _decode(id),
            old = packages.where((p) => p.id == c.packageId).firstOrNull;
        _version(p, old);
        if (p.id != c.packageId || p.digest != c.expectedDigest) {
          throw const WorkspaceFailure('conflict', '预览内容已变化，请重新核对。');
        }
        final selection = _selections[id]!;
        selected = selection;
        input = core.InstalledTemplatePackage(
          id: p.id,
          enabled: true,
          origin: selection.filename,
          bytes: selection.bytes,
        );
      } else if (c.selectionId != null) {
        throw const WorkspaceFailure('validation', '启停和移除不应携带文件选择。');
      }
      final receipt = await owner.changeTemplatePackage(
        core.TemplatePackageCommand(
          operationId: c.operationId,
          action: core.TemplatePackageAction.values.byName(c.action.name),
          packageId: c.packageId,
          expectedVersion: c.expectedVersion,
          commandDigest: digest,
          expectedDigest: c.expectedDigest,
        ),
        input: input,
        validate: () {
          _check();
          if (c.selectionId != null) {
            if (!identical(_selections[c.selectionId], selected)) {
              throw const WorkspaceFailure('selection_changed', '原选择已释放，尚未安装。');
            }
          }
        },
      );
      if (c.selectionId != null) _selections.remove(c.selectionId);
      changed();
      return _receipt(receipt);
    },
  );
}
