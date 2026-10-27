import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'workspace_source.dart';

enum SampleHostScenario { fingerprintChanged, missingFingerprint }

/// Resettable owner facts. This provider never observes a real host or grants
/// credential use; its fingerprints are deliberately fictional fixtures.
class SampleWorkspaceHosts implements WorkspaceHostSource {
  SampleWorkspaceHosts({
    required this.readable,
    required this.beforeWrite,
    required this.changed,
    required this.records,
    required this.plugin,
    required this.pluginVersion,
    required this.empty,
  });
  final Future<void> Function() readable;
  final void Function() beforeWrite, changed;
  final Iterable<WorkspaceDetail> Function() records;
  final WorkspacePlugin? Function() plugin;
  final int Function() pluginVersion;
  final bool Function() empty;
  static const _fixtureFingerprints = {
    'tokyo.beichen.example|2222': 'SHA256:DemoTokyoHostFingerprint',
    'hangzhou.beichen.example|22': 'SHA256:DemoHangzhouHostFingerprint',
  };
  final _observed = <String, String>{..._fixtureFingerprints};
  final _endpoints = <String, WorkspaceHostEndpoint>{};
  final _initialEndpoints = <String, WorkspaceHostEndpoint>{};
  final _trusted = <String, String?>{};
  final _initialTrusted = <String, String?>{};
  final _operations =
      <String, ({String intent, WorkspaceHostReceipt receipt})>{};
  int _version = 1;
  bool loseNextReply = false;

  String _id(WorkspaceHostEndpoint endpoint) =>
      sha256.convert(utf8.encode(endpoint.key)).toString();
  bool _server(WorkspaceDetail d) =>
      d.record.ref.kind == WorkspaceRecordKind.information &&
      d.record.type.id == 'server' &&
      d.definition['packageId'] == 'builtin.server';
  WorkspaceHostEndpoint? _endpoint(WorkspaceDetail d) =>
      d.fieldOverrides.keys.any((key) => key == 'host' || key == 'port')
      ? null
      : WorkspaceHostEndpoint.parse(d.values['host'], d.values['port']);

  void seed() {
    final azure = records()
        .where((d) => _server(d) && d.record.ref.id == 'azure')
        .firstOrNull;
    final endpoint = azure == null ? null : _endpoint(azure);
    if (endpoint?.key == 'tokyo.beichen.example|2222') {
      final id = _id(endpoint!);
      _endpoints[id] = endpoint;
      _initialEndpoints[id] = endpoint;
      _trusted[id] = _initialTrusted[id] = _fixtureFingerprints[endpoint.key];
    }
  }

  void clearCurrent() {
    _trusted.clear();
    _endpoints.clear();
    _operations.clear();
    _version++;
    loseNextReply = false;
  }

  void clear() {
    clearCurrent();
    _initialTrusted.clear();
    _initialEndpoints.clear();
    _observed
      ..clear()
      ..addAll(_fixtureFingerprints);
  }

  void reset() {
    _endpoints
      ..clear()
      ..addAll(_initialEndpoints);
    _trusted
      ..clear()
      ..addAll(_initialTrusted);
    _observed
      ..clear()
      ..addAll(_fixtureFingerprints);
    _operations.clear();
    _version++;
    loseNextReply = false;
  }

  /// Composition-root/test fault input, never a Widget-owned trust toggle.
  void observe(WorkspaceHostEndpoint endpoint, String? fingerprint) {
    if (fingerprint == null) {
      _observed.remove(endpoint.key);
    } else {
      _observed[endpoint.key] = fingerprint;
    }
    _version++;
    changed();
  }

  void demonstrate(SampleHostScenario scenario) {
    final detail = records()
        .where((d) => _server(d) && d.record.ref.id == 'azure')
        .firstOrNull;
    final endpoint = detail == null ? null : _endpoint(detail);
    if (endpoint == null) return;
    observe(
      endpoint,
      scenario == SampleHostScenario.fingerprintChanged
          ? 'SHA256:DemoRotatedTokyoFingerprint'
          : null,
    );
  }

  WorkspaceHostIdentity _projection(
    WorkspaceHostTarget target,
    WorkspaceHostEndpoint? endpoint,
    String name, {
    int? recordVersion,
  }) {
    final id = endpoint == null ? 'invalid:${target.key}' : _id(endpoint);
    final fingerprint = endpoint == null ? null : _observed[endpoint.key];
    final trusted = _trusted[id];
    final state = endpoint == null
        ? WorkspaceHostState.invalid
        : fingerprint == null
        ? WorkspaceHostState.missingFingerprint
        : trusted != null
        ? trusted == fingerprint
              ? WorkspaceHostState.trusted
              : WorkspaceHostState.changed
        : _trusted.containsKey(id)
        ? WorkspaceHostState.revoked
        : WorkspaceHostState.unconfirmed;
    return WorkspaceHostIdentity(
      target: target,
      name: name,
      identityId: id,
      endpoint: endpoint,
      state: state,
      version: _version,
      pluginVersion: pluginVersion(),
      pluginEnabled: plugin()?.enabled ?? false,
      recordVersion: recordVersion,
      fingerprint: fingerprint,
      trustedFingerprint: trusted,
    );
  }

  WorkspaceHostIdentity _read(WorkspaceHostTarget target) {
    if (empty()) throw const WorkspaceFailure('not_found', '主机资料已不可用。');
    if (target.record case final ref?) {
      final detail = records()
          .where((d) => d.record.ref == ref && _server(d))
          .firstOrNull;
      if (detail == null) {
        throw const WorkspaceFailure('not_found', '服务器资料已不存在。');
      }
      return _projection(
        target,
        _endpoint(detail),
        detail.record.name,
        recordVersion: detail.version,
      );
    }
    final endpoint = _endpoints[target.identityId];
    if (endpoint == null || !_trusted.containsKey(target.identityId)) {
      throw const WorkspaceFailure('not_found', '主机身份已不可用。');
    }
    return _projection(target, endpoint, '已保留的主机身份');
  }

  @override
  Future<WorkspaceHostIdentity> read(WorkspaceHostTarget target) async {
    await readable();
    return _read(target);
  }

  @override
  Future<List<WorkspaceHostIdentity>> load() async {
    await readable();
    if (empty()) return const [];
    final result = [
      for (final d in records().where(_server))
        _projection(
          WorkspaceHostTarget.record(d.record.ref),
          _endpoint(d),
          d.record.name,
          recordVersion: d.version,
        ),
    ];
    final visible = result.map((r) => r.identityId).toSet();
    for (final id in _trusted.keys.where((id) => !visible.contains(id))) {
      result.add(
        _projection(
          WorkspaceHostTarget.identity(id),
          _endpoints[id]!,
          '已保留的主机身份',
        ),
      );
    }
    return List.unmodifiable(result);
  }

  @override
  Future<WorkspaceHostReceipt> change(WorkspaceHostChange c) async {
    await readable();
    final seen = c.reviewed;
    final intent = sha256
        .convert(
          utf8.encode(
            jsonEncode([
              c.action.name,
              seen.target.key,
              seen.identityId,
              seen.version,
              seen.recordVersion,
              seen.pluginVersion,
              seen.fingerprint,
              seen.trustedFingerprint,
              c.acknowledgeChanged,
            ]),
          ),
        )
        .toString();
    if (_operations[c.operationId] case final old?) {
      if (old.intent != intent) {
        throw const WorkspaceFailure('operation_conflict', '操作身份已被其他请求使用。');
      }
      return old.receipt;
    }
    final current = _read(seen.target);
    if (current.version != seen.version ||
        current.recordVersion != seen.recordVersion ||
        current.pluginVersion != seen.pluginVersion ||
        current.identityId != seen.identityId ||
        current.fingerprint != seen.fingerprint ||
        current.trustedFingerprint != seen.trustedFingerprint) {
      throw const WorkspaceFailure('conflict', '主机或插件已变化，请重新读取并核对。');
    }
    if (c.action == WorkspaceHostAction.confirm) {
      if (!current.canConfirm) {
        throw const WorkspaceFailure('unavailable', '主机尚不能确认，请检查指纹与插件状态。');
      }
      if (current.state == WorkspaceHostState.changed &&
          !c.acknowledgeChanged) {
        throw const WorkspaceFailure('identity_changed', '请先核对变化后的指纹。');
      }
    } else if (!current.canRevoke) {
      throw const WorkspaceFailure('unavailable', '当前没有可撤销的确认。');
    }
    beforeWrite();
    _endpoints[current.identityId] = current.endpoint!;
    _trusted[current.identityId] = c.action == WorkspaceHostAction.confirm
        ? current.fingerprint
        : null;
    final receipt = WorkspaceHostReceipt(
      operationId: c.operationId,
      action: c.action,
      identityId: current.identityId,
      expectedVersion: current.version,
      version: ++_version,
      targetKey: current.target.key,
      expectedRecordVersion: current.recordVersion,
      expectedPluginVersion: current.pluginVersion,
    );
    _operations[c.operationId] = (intent: intent, receipt: receipt);
    changed();
    if (loseNextReply) {
      loseNextReply = false;
      throw const WorkspaceFailure('unknown_outcome', '主机身份操作结果未知，请先核对结果。');
    }
    return receipt;
  }

  @override
  Future<WorkspaceHostReceipt?> receipt(String operationId) async {
    await readable();
    return _operations[operationId]?.receipt;
  }
}
