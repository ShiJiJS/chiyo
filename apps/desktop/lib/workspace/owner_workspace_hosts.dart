import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:info_core/info_core.dart' as core;
import '../information_files.dart';
import 'workspace_source.dart';
import 'workspace_information_codec.dart';

class _HostLine {
  _HostLine(this.raw, this.pattern, this.algorithm, this.key, this.marker);
  final String raw, pattern, algorithm, key;
  final String? marker;
  String get fingerprint =>
      'SHA256:${base64Encode(sha256.convert(base64Decode(key)).bytes).replaceAll('=', '')}';
  Iterable<WorkspaceHostEndpoint> get endpoints sync* {
    for (final pattern in this.pattern.split(',')) {
      // Wildcards, hashed names and certificate authorities are imported intact
      // for OpenSSH; they cannot be asserted as one observed server identity.
      if (pattern.contains(RegExp(r'[|*?!]')) || marker == '@cert-authority') {
        continue;
      }
      final m = RegExp(r'^\[(.+)\]:(\d+)$').firstMatch(pattern);
      final e = WorkspaceHostEndpoint.parse(m?[1] ?? pattern, m?[2] ?? '22');
      if (e != null) yield e;
    }
  }

  String withMarker(String? marker) =>
      '${marker == null ? '' : '$marker '}$pattern $algorithm $key';
}

class _HostSelection {
  _HostSelection(this.file, List<int> bytes) : bytes = List.unmodifiable(bytes);
  final WorkspaceHostFile file;
  final List<int> bytes;
}

/// Explicitly imported known_hosts is the real SSH receiver trust source.
/// This adapter does not probe hosts or invent network observations.
class OwnerWorkspaceHosts implements WorkspaceHostSource {
  OwnerWorkspaceHosts({
    required this.owner,
    required this.changed,
    this.picker = const NativeInformationFilePicker(),
  }) : _scope = owner.captureLibraryScope();
  final core.OwnerAccess owner;
  final void Function() changed;
  final InformationFilePicker picker;
  final core.OwnerLibraryScope _scope;
  final _selections = <String, _HostSelection>{};
  bool _closed = false;
  void dispose() {
    _closed = true;
    _selections.clear();
  }

  void _check() {
    if (_closed || !_scope.isCurrent || !owner.serviceAvailable) {
      throw const WorkspaceFailure('unavailable', '主机记录窗口或资料库已变化，请重新打开。');
    }
  }

  Future<T> _run<T>(Future<T> Function() f) async {
    _check();
    try {
      return await owner.inLibraryScope(_scope, f);
    } on WorkspaceFailure {
      rethrow;
    } on core.AccessFailure catch (e) {
      throw WorkspaceFailure(e.status, '主机记录或原操作已变化，请重新核对。');
    } on Object {
      throw const WorkspaceFailure('unknown_outcome', '主机记录结果尚未确认，请核对原操作。');
    }
  }

  bool get _enabled =>
      owner.installedTemplatePackages
          .where((p) => p.id == 'builtin.server')
          .firstOrNull
          ?.enabled ??
      true;
  String _digest(List<int> bytes) => sha256.convert(bytes).toString();
  String _id(WorkspaceHostEndpoint e) => _digest(utf8.encode(e.key));
  List<_HostLine> _lines(List<int> bytes) => [
    for (final raw in const LineSplitter().convert(utf8.decode(bytes)))
      if (raw.trim().isNotEmpty && !raw.trim().startsWith('#'))
        () {
          final parts = raw.trim().split(RegExp(r'\s+'));
          final offset = parts.first.startsWith('@') ? 1 : 0;
          return _HostLine(
            raw,
            parts[offset],
            parts[offset + 1],
            parts[offset + 2],
            offset == 0 ? null : parts.first,
          );
        }(),
  ];
  Future<int> _version() async =>
      (await owner.additionalApprovalRevision('ssh-trust')) + 1;
  @override
  Future<WorkspaceHostImportStatus?> importedFile() => _run(() async {
    final current = owner.sshKnownHosts;
    return current == null
        ? null
        : WorkspaceHostImportStatus(
            name: current.name,
            digest: _digest(current.bytes),
            entryCount: _lines(current.bytes).length,
            version: await _version(),
          );
  });
  Future<WorkspaceHostFile?> pick() => _run(() async {
    if (!_enabled) throw const WorkspaceFailure('unavailable', '请先启用服务器插件。');
    final path = await picker.choose();
    if (path == null) return null;
    _check();
    if (_selections.length >= 32) {
      throw const WorkspaceFailure('selection_busy', '请先关闭已有文件预览。');
    }
    final file = File(path);
    final before = await file.stat();
    if (before.type != FileSystemEntityType.file ||
        before.size < 1 ||
        before.size > 1048576) {
      throw const WorkspaceFailure(
        'invalid_file',
        '请选择不超过1MB的 known_hosts 普通文件。',
      );
    }
    final bytes = <int>[];
    await for (final chunk in file.openRead()) {
      if (bytes.length + chunk.length > 1048576) {
        throw const WorkspaceFailure('invalid_file', '文件超过1MB。');
      }
      bytes.addAll(chunk);
    }
    final after = await file.stat();
    if (before.size != after.size ||
        before.modified != after.modified ||
        bytes.length != before.size) {
      throw const WorkspaceFailure('conflict', '读取期间文件已变化，请重新选择。');
    }
    final name = file.uri.pathSegments.last;
    core.validateSshKnownHosts(name, bytes);
    _check();
    final selected = WorkspaceHostFile(
      workspaceOperationId(),
      name,
      bytes.length,
    );
    _selections[selected.selectionId] = _HostSelection(selected, bytes);
    return selected;
  });
  @override
  Future<WorkspaceHostImportPreview> previewImport(String id) => _run(() async {
    if (!_enabled) throw const WorkspaceFailure('unavailable', '请先启用服务器插件。');
    final s = _selections[id];
    if (s == null) {
      throw const WorkspaceFailure('selection_unavailable', '文件选择已释放，请重新选择。');
    }
    return WorkspaceHostImportPreview(
      file: s.file,
      digest: _digest(s.bytes),
      version: await _version(),
      pluginVersion: owner.templatePackageVersion,
      previous: await importedFile(),
      entries: [
        for (final l in _lines(s.bytes))
          WorkspaceHostFileEntry(
            l.pattern,
            l.algorithm,
            l.fingerprint,
            l.marker,
          ),
      ],
    );
  });
  @override
  Future<void> releaseImport(String id) async {
    _selections.remove(id);
  }

  WorkspaceHostImportReceipt _importReceipt(core.InformationApprovalReceipt r) {
    final m = r.metadata;
    if (m['kind'] != 'ssh-import') {
      throw const WorkspaceFailure('conflict', '此原操作不是主机文件导入。');
    }
    return WorkspaceHostImportReceipt(
      operationId: r.operationId,
      selectionId: m['selectionId'] as String,
      expectedVersion: m['expectedVersion'] as int,
      expectedPluginVersion: m['pluginVersion'] as int,
      result: WorkspaceHostImportStatus(
        name: m['name'] as String,
        digest: m['digest'] as String,
        entryCount: m['entryCount'] as int,
        version: r.revision + 1,
      ),
    );
  }

  @override
  Future<WorkspaceHostImportReceipt?> importReceipt(String id) =>
      _run(() async {
        final r = await owner.additionalApprovalReceipt(id);
        return r == null ? null : _importReceipt(r);
      });
  @override
  Future<WorkspaceHostImportReceipt> importFile(
    WorkspaceHostImportChange c,
  ) => _run(() async {
    final old = await importReceipt(c.operationId);
    if (old != null) {
      if (!old.matches(c)) {
        throw const WorkspaceFailure('conflict', '原操作不能用于另一份文件。');
      }
      return old;
    }
    final now = await previewImport(c.preview.file.selectionId), p = c.preview;
    if (now.version != p.version ||
        now.pluginVersion != p.pluginVersion ||
        now.digest != p.digest ||
        now.file.name != p.file.name ||
        now.previous?.digest != p.previous?.digest) {
      throw const WorkspaceFailure('conflict', '主机记录、文件或插件已变化，请重新预览。');
    }
    final selected = _selections[p.file.selectionId]!;
    final snapshotId = owner.sshKnownHosts?.id;
    final token = _digest(
      utf8.encode(
        jsonEncode([
          snapshotId,
          p.version,
          p.pluginVersion,
          p.digest,
          p.file.selectionId,
        ]),
      ),
    );
    void validate() {
      _check();
      if (!_enabled ||
          owner.sshKnownHosts?.id != snapshotId ||
          owner.templatePackageVersion != p.pluginVersion ||
          !identical(_selections[p.file.selectionId], selected)) {
        throw const core.AccessFailure('scope_changed');
      }
    }

    final receipt = await owner.performAdditionalApproval(
      operationId: c.operationId,
      requestId: 'ssh-trust',
      kind: 'ssh',
      action: core.InformationApprovalAction.approve,
      reviewToken: token,
      commandDigest: token,
      validate: validate,
      metadata: {
        'kind': 'ssh-import',
        'selectionId': p.file.selectionId,
        'expectedVersion': p.version,
        'pluginVersion': p.pluginVersion,
        'name': p.file.name,
        'digest': p.digest,
        'entryCount': p.entries.length,
      },
      decide: () async {
        await owner.configureSshKnownHosts(selected.file.name, selected.bytes);
      },
    );
    _selections.remove(p.file.selectionId);
    changed();
    return _importReceipt(receipt);
  });
  WorkspaceHostIdentity _project(
    WorkspaceHostTarget target,
    WorkspaceHostEndpoint? endpoint,
    String name,
    int version, {
    int? recordVersion,
  }) {
    final matching = endpoint == null
        ? <_HostLine>[]
        : [
            for (final l in _lines(owner.sshKnownHosts?.bytes ?? []))
              if (l.endpoints.any((e) => e.key == endpoint.key)) l,
          ];
    final revoked = matching.any((l) => l.marker == '@revoked');
    final fingerprints = matching.map((l) => l.fingerprint).toSet().toList()
      ..sort();
    final fingerprint = fingerprints.isEmpty ? null : fingerprints.join('\n');
    return WorkspaceHostIdentity(
      target: target,
      name: name,
      identityId: endpoint == null ? 'invalid:${target.key}' : _id(endpoint),
      endpoint: endpoint,
      state: endpoint == null
          ? WorkspaceHostState.invalid
          : fingerprint == null
          ? WorkspaceHostState.missingFingerprint
          : revoked
          ? WorkspaceHostState.revoked
          : WorkspaceHostState.trusted,
      version: version,
      pluginVersion: owner.templatePackageVersion,
      pluginEnabled: _enabled,
      recordVersion: recordVersion,
      fingerprint: fingerprint,
      trustedFingerprint: revoked ? null : fingerprint,
    );
  }

  Future<WorkspaceHostIdentity> _read(WorkspaceHostTarget target) async {
    final version = await _version();
    if (target.record case final ref?) {
      final item = owner.information
          .where(
            (i) =>
                i.id == ref.id && ref.kind == WorkspaceRecordKind.information,
          )
          .firstOrNull;
      if (item == null || item.layout?.typeId != 'server') {
        throw const WorkspaceFailure('not_found', '服务器资料已移除或类型变化。');
      }
      final detail = WorkspaceInformationCodec().decode(item);
      if (detail.definition['packageId'] != null &&
          detail.definition['packageId'] != 'builtin.server') {
        throw const WorkspaceFailure('unsupported', '此模板没有注册主机身份面板。');
      }
      return _project(
        target,
        WorkspaceHostEndpoint.parse(
          detail.values['host'],
          detail.values['port'],
        ),
        item.name,
        version,
        recordVersion: item.version,
      );
    }
    final endpoints = {
      for (final l in _lines(owner.sshKnownHosts?.bytes ?? []))
        for (final e in l.endpoints) _id(e): e,
    };
    final endpoint = endpoints[target.identityId];
    if (endpoint == null) {
      throw const WorkspaceFailure('not_found', '主机身份已不在导入记录中。');
    }
    return _project(target, endpoint, '导入的主机身份', version);
  }

  @override
  Future<WorkspaceHostIdentity> read(WorkspaceHostTarget target) =>
      _run(() => _read(target));
  @override
  Future<List<WorkspaceHostIdentity>> load() => _run(() async {
    final result = <WorkspaceHostIdentity>[];
    for (final item in owner.information.where(
      (i) => i.layout?.typeId == 'server',
    )) {
      result.add(
        await _read(
          WorkspaceHostTarget.record(
            WorkspaceRecordRef(WorkspaceRecordKind.information, item.id),
          ),
        ),
      );
    }
    final visible = result.map((r) => r.identityId).toSet();
    final endpoints = {
      for (final l in _lines(owner.sshKnownHosts?.bytes ?? []))
        for (final e in l.endpoints) _id(e): e,
    };
    for (final id in endpoints.keys.where((id) => !visible.contains(id))) {
      result.add(await _read(WorkspaceHostTarget.identity(id)));
    }
    return List.unmodifiable(result);
  });
  String _changeDigest(WorkspaceHostChange c) => _digest(
    utf8.encode(
      jsonEncode([
        c.action.name,
        c.reviewed.target.key,
        c.reviewed.identityId,
        c.reviewed.version,
        c.reviewed.pluginVersion,
        c.reviewed.recordVersion,
        c.reviewed.fingerprint,
        c.reviewed.trustedFingerprint,
        c.acknowledgeChanged,
      ]),
    ),
  );
  WorkspaceHostReceipt _receipt(core.InformationApprovalReceipt r) {
    final m = r.metadata;
    if (m['kind'] != 'ssh-identity') {
      throw const WorkspaceFailure('conflict', '此原操作不是主机身份变更。');
    }
    return WorkspaceHostReceipt(
      operationId: r.operationId,
      action: WorkspaceHostAction.values.byName(m['action'] as String),
      identityId: m['identityId'] as String,
      expectedVersion: m['expectedVersion'] as int,
      version: r.revision + 1,
      targetKey: m['targetKey'] as String,
      expectedPluginVersion: m['pluginVersion'] as int,
      expectedRecordVersion: m['recordVersion'] as int?,
    );
  }

  @override
  Future<WorkspaceHostReceipt?> receipt(String id) => _run(() async {
    final r = await owner.additionalApprovalReceipt(id);
    return r == null ? null : _receipt(r);
  });
  @override
  Future<WorkspaceHostReceipt> change(WorkspaceHostChange c) => _run(() async {
    final digest = _changeDigest(c);
    final old = await owner.additionalApprovalReceipt(c.operationId);
    if (old != null) {
      if (old.commandDigest != digest) {
        throw const WorkspaceFailure('conflict', '原操作不能用于另一份身份变更。');
      }
      return _receipt(old);
    }
    final seen = c.reviewed, current = await _read(seen.target);
    if (current.version != seen.version ||
        current.pluginVersion != seen.pluginVersion ||
        current.identityId != seen.identityId ||
        current.recordVersion != seen.recordVersion ||
        current.fingerprint != seen.fingerprint ||
        current.trustedFingerprint != seen.trustedFingerprint) {
      throw const WorkspaceFailure('conflict', '主机、资料或插件已变化，请重新核对。');
    }
    if (c.action == WorkspaceHostAction.confirm
        ? !current.canConfirm
        : !current.canRevoke) {
      throw const WorkspaceFailure('unavailable', '当前没有可执行的主机身份变更。');
    }
    final snapshot = owner.sshKnownHosts!;
    final endpoint = current.endpoint!;
    final lines = _lines(snapshot.bytes);
    // A comma-shared or CA line has a wider boundary than one endpoint. Keep
    // import as the explicit full-file replacement route in that case.
    if (lines.any(
      (l) =>
          l.endpoints.any((e) => e.key == endpoint.key) &&
          l.pattern.split(',').length != 1,
    )) {
      throw const WorkspaceFailure(
        'scope_changed',
        '该行包含多个主机，不能单独改变一个地址；请导入核对后的完整文件。',
      );
    }
    final bytes = utf8.encode(
      '${[for (final l in lines) l.endpoints.any((e) => e.key == endpoint.key) ? l.withMarker(c.action == WorkspaceHostAction.revoke ? '@revoked' : null) : l.raw].join('\n')}\n',
    );
    void validate() {
      _check();
      if (owner.sshKnownHosts?.id != snapshot.id ||
          owner.templatePackageVersion != seen.pluginVersion ||
          seen.target.record != null &&
              !owner.information.any(
                (i) =>
                    i.id == seen.target.record!.id &&
                    i.version == seen.recordVersion,
              )) {
        throw const core.AccessFailure('scope_changed');
      }
    }

    final receipt = await owner.performAdditionalApproval(
      operationId: c.operationId,
      requestId: 'ssh-trust',
      kind: 'ssh',
      action: c.action == WorkspaceHostAction.confirm
          ? core.InformationApprovalAction.approve
          : core.InformationApprovalAction.revoke,
      reviewToken: digest,
      commandDigest: digest,
      validate: validate,
      metadata: {
        'kind': 'ssh-identity',
        'action': c.action.name,
        'identityId': seen.identityId,
        'targetKey': seen.target.key,
        'expectedVersion': seen.version,
        'pluginVersion': seen.pluginVersion,
        'recordVersion': seen.recordVersion,
      },
      decide: () async {
        await owner.configureSshKnownHosts(snapshot.name, bytes);
      },
    );
    changed();
    return _receipt(receipt);
  });
}
