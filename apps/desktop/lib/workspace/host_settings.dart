import 'dart:async';
import 'package:flutter/material.dart';
import '../desktop_controls.dart';
import '../prototype_icons.dart';
import '../ui_palette.dart';
import 'host_mutation.dart';
import 'library_widgets.dart';
import 'workspace_source.dart';

// Observe failures immediately, including when a change removes this Widget
// before its next frame can subscribe to a replacement FutureBuilder future.
Future<AsyncSnapshot<T>> _hostRead<T>(Future<T> read) async {
  try {
    return AsyncSnapshot.withData(ConnectionState.done, await read);
  } catch (error, stack) {
    return AsyncSnapshot.withError(ConnectionState.done, error, stack);
  }
}

Future<void> showHostIdentity(
  BuildContext context,
  WorkspaceHostSource source,
  WorkspaceHostTarget target, {
  ValueChanged<WorkspaceRecordRef>? onRecord,
}) => showDesktopDialog<void>(
  context,
  builder: (_) =>
      _HostDialog(source: source, target: target, onRecord: onRecord),
);

/// Both views read host facts, never a record's historical hostTrusted boolean.
class HostIdentityButton extends StatefulWidget {
  const HostIdentityButton({
    super.key,
    required this.source,
    required this.record,
    required this.onPressed,
  });
  final WorkspaceSource source;
  final WorkspaceRecordRef record;
  final VoidCallback onPressed;
  @override
  State<HostIdentityButton> createState() => _HostIdentityButtonState();
}

class _HostIdentityButtonState extends State<HostIdentityButton> {
  late Future<AsyncSnapshot<WorkspaceHostIdentity>> _read;
  late StreamSubscription<WorkspaceRecordRef?> _subscription;
  void _load() {
    _read = _hostRead(
      widget.source.hosts.read(WorkspaceHostTarget.record(widget.record)),
    );
  }

  @override
  void initState() {
    super.initState();
    _load();
    _subscription = widget.source.changes.listen((_) {
      if (mounted) setState(_load);
    });
  }

  @override
  void dispose() {
    unawaited(_subscription.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      FutureBuilder<AsyncSnapshot<WorkspaceHostIdentity>>(
        future: _read,
        builder: (context, snapshot) => DesktopButton(
          key: const ValueKey('library-host-identity'),
          kind: DesktopButtonKind.quiet,
          onPressed: widget.onPressed,
          fontSize: 13,
          leading: const PrototypeIcon(PrototypeIconGlyph.shield, size: 16),
          child: Text(
            '主机身份 · ${snapshot.connectionState != ConnectionState.done
                ? '正在读取…'
                : snapshot.data!.hasError
                ? '暂不可用'
                : snapshot.data!.data!.state.label}',
          ),
        ),
      );
}

class HostSettingsPanel extends StatefulWidget {
  const HostSettingsPanel({
    super.key,
    required this.source,
    required this.changes,
    required this.onOpen,
    this.onImport,
    this.readGeneration = 0,
  });
  final WorkspaceHostSource source;
  final Stream<WorkspaceRecordRef?> changes;
  final ValueChanged<WorkspaceHostTarget> onOpen;
  final VoidCallback? onImport;
  final int readGeneration;
  @override
  State<HostSettingsPanel> createState() => _HostSettingsPanelState();
}

class _HostSettingsPanelState extends State<HostSettingsPanel> {
  late Future<AsyncSnapshot<List<WorkspaceHostIdentity>>> _read;
  late Future<AsyncSnapshot<WorkspaceHostImportStatus?>> _imported;
  late StreamSubscription<WorkspaceRecordRef?> _subscription;
  void _load() {
    _read = _hostRead(widget.source.load());
    _imported = _hostRead(widget.source.importedFile());
  }

  @override
  void initState() {
    super.initState();
    _load();
    _subscription = widget.changes.listen((_) {
      if (mounted) setState(_load);
    });
  }

  @override
  void didUpdateWidget(covariant HostSettingsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.readGeneration != widget.readGeneration) _load();
  }

  @override
  void dispose() {
    unawaited(_subscription.cancel());
    super.dispose();
  }

  Widget _row(BuildContext context, WorkspaceHostIdentity h) {
    final c = UiPalette.of(context);
    final details = Row(
      children: [
        const RecordIcon(WorkspaceType('server', '服务器', 'server'), size: 35),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                h.name,
                style: libraryText(context, 14, weight: FontWeight.w600),
              ),
              const SizedBox(height: 5),
              Text(
                h.endpoint?.label ?? '地址或端口不完整',
                style: libraryText(context, 12, color: c.muted),
              ),
            ],
          ),
        ),
      ],
    );
    final status = LibraryPill(
      h.state.label,
      key: ValueKey('host-state-${h.target.key}'),
      color: switch (h.state) {
        WorkspaceHostState.trusted => c.success,
        WorkspaceHostState.changed => c.danger,
        WorkspaceHostState.unconfirmed => c.warning,
        _ => c.muted,
      },
      background: switch (h.state) {
        WorkspaceHostState.trusted => c.successSurface,
        WorkspaceHostState.unconfirmed => c.credentialSurface,
        _ => c.nav,
      },
    );
    final action = DesktopButton(
      key: ValueKey('host-open-${h.target.key}'),
      onPressed: () => widget.onOpen(h.target),
      child: const Text('查看身份'),
    );
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 20),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.line)),
      ),
      child: MediaQuery.textScalerOf(context).scale(1) >= 1.6
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                details,
                const SizedBox(height: 12),
                Wrap(spacing: 12, runSpacing: 12, children: [status, action]),
              ],
            )
          : Row(
              children: [
                Expanded(child: details),
                const SizedBox(width: 12),
                status,
                const SizedBox(width: 12),
                action,
              ],
            ),
    );
  }

  Widget _heading(BuildContext context) {
    final label = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'SSH 主机信任',
          style: libraryText(context, 17, weight: FontWeight.w700, height: 1.5),
        ),
        const SizedBox(height: 7),
        Text(
          '核对地址、端口和指纹后再确认主机。身份确认不代表批准使用登录凭据。',
          style: libraryText(
            context,
            13,
            color: UiPalette.of(context).muted,
            height: 1.8,
          ),
        ),
      ],
    );
    final action = DesktopButton(
      key: const ValueKey('host-import'),
      onPressed: widget.onImport,
      fontSize: 12,
      child: const Text('导入 known_hosts'),
    );
    return MediaQuery.textScalerOf(context).scale(1) >= 1.6
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              label,
              const SizedBox(height: 12),
              Align(alignment: Alignment.centerLeft, child: action),
            ],
          )
        : Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: label),
              const SizedBox(width: 16),
              action,
            ],
          );
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _heading(context),
      const SizedBox(height: 20),
      FutureBuilder<AsyncSnapshot<WorkspaceHostImportStatus?>>(
        future: _imported,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Text('正在读取导入记录…');
          }
          if (snapshot.data!.hasError) {
            return Wrap(
              spacing: 12,
              children: [
                const Text('已导入文件记录暂不可读。'),
                DesktopButton(
                  key: const ValueKey('host-import-status-retry'),
                  onPressed: () => setState(_load),
                  child: const Text('重新读取导入记录'),
                ),
              ],
            );
          }
          final file = snapshot.data!.data;
          if (file == null) return const SizedBox.shrink();
          return Container(
            key: const ValueKey('host-import-status'),
            margin: const EdgeInsets.only(bottom: 20),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: UiPalette.of(context).rail,
              borderRadius: BorderRadius.circular(7),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '已导入 ${file.name} · ${file.entryCount} 条记录',
                  style: libraryText(context, 14, weight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                SelectableText(
                  'SHA256 ${file.digest}',
                  style: libraryText(
                    context,
                    12,
                    color: UiPalette.of(context).muted,
                  ),
                ),
              ],
            ),
          );
        },
      ),
      FutureBuilder<AsyncSnapshot<List<WorkspaceHostIdentity>>>(
        future: _read,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Text('正在读取主机身份…');
          }
          if (snapshot.data!.hasError) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('主机身份暂不可用。'),
                DesktopButton(
                  key: const ValueKey('hosts-retry'),
                  onPressed: () => setState(_load),
                  child: const Text('重新读取'),
                ),
              ],
            );
          }
          final hosts = snapshot.data!.data!;
          if (hosts.isEmpty) return const Text('还没有服务器或保留的主机身份。');
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!hosts.first.pluginEnabled) ...[
                Text(
                  '服务器插件已停用。仍可查看和撤销已有确认，重新确认前请先启用。',
                  style: libraryText(
                    context,
                    13,
                    color: UiPalette.of(context).muted,
                  ),
                ),
                const SizedBox(height: 16),
              ],
              for (final h in hosts) _row(context, h),
            ],
          );
        },
      ),
    ],
  );
}

class _HostDialog extends StatefulWidget {
  const _HostDialog({
    required this.source,
    required this.target,
    this.onRecord,
  });
  final WorkspaceHostSource source;
  final WorkspaceHostTarget target;
  final ValueChanged<WorkspaceRecordRef>? onRecord;
  @override
  State<_HostDialog> createState() => _HostDialogState();
}

class _HostDialogState extends State<_HostDialog> {
  late final HostMutation _mutation;
  WorkspaceHostIdentity? _host;
  WorkspaceFailure? _readFailure;
  bool _loading = true, _acknowledged = false;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    _mutation = HostMutation(widget.source)..addListener(_changed);
    unawaited(_load());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    if (_mutation.frozen) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _readFailure = null;
      _acknowledged = false;
    });
    try {
      final host = await widget.source.read(widget.target);
      if (!mounted || generation != _generation) return;
      _host = host;
      _mutation.reviewed();
    } catch (e) {
      if (!mounted || generation != _generation) return;
      _readFailure = e is WorkspaceFailure
          ? e
          : const WorkspaceFailure('unavailable', '暂时无法读取主机身份，请重试。');
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _submit(WorkspaceHostAction action) async {
    final result = await _mutation.submit(
      _host!,
      action,
      acknowledgeChanged: _acknowledged,
    );
    if (mounted && result != null) await _load();
  }

  Future<void> _reconcile() async {
    final result = await _mutation.reconcile();
    if (mounted && !_mutation.uncertain) {
      if (result != null) {
        await _load();
      } else {
        setState(
          () => _readFailure = const WorkspaceFailure(
            'not_committed',
            '已确认没有提交，请重新读取后再决定。',
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    ++_generation;
    _mutation.removeListener(_changed);
    _mutation.dispose();
    super.dispose();
  }

  Widget _fact(String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          label,
          style: libraryText(context, 12, color: UiPalette.of(context).muted),
        ),
        const SizedBox(height: 6),
        SelectableText(value, style: libraryText(context, 14, height: 1.7)),
      ],
    ),
  );
  @override
  Widget build(BuildContext context) {
    final h = _host;
    final ready =
        !_loading && _readFailure == null && h != null && _mutation.canSubmit;
    return PopScope(
      canPop: !_mutation.frozen,
      child: DesktopDialog(
        title: const Text('主机身份'),
        width: 640,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_loading) const Text('正在读取主机身份…'),
            if (h != null) ...[
              _fact('服务器', h.name),
              _fact('连接地址', h.endpoint?.label ?? '地址或端口不完整'),
              _fact('当前状态', h.state.label),
              _fact('当前公钥指纹', h.fingerprint ?? '尚未取得指纹，不能确认主机。'),
              if (h.trustedFingerprint != null)
                _fact('已确认的指纹', h.trustedFingerprint!),
              if (h.state == WorkspaceHostState.changed) ...[
                Text(
                  '指纹与上次确认不同。请通过可靠渠道核对，确认来源前不要继续连接。',
                  style: libraryText(
                    context,
                    14,
                    color: UiPalette.of(context).danger,
                  ),
                ),
                CheckboxListTile(
                  key: const ValueKey('host-acknowledge-change'),
                  value: _acknowledged,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('我已核对变化后的指纹'),
                  onChanged: ready
                      ? (v) => setState(() => _acknowledged = v!)
                      : null,
                ),
              ],
              if (!h.pluginEnabled) const Text('服务器插件已停用，启用前不能重新确认。'),
              const SizedBox(height: 12),
              Text(
                '确认仅用于核对这台主机的身份，不授予凭据使用许可。',
                style: libraryText(
                  context,
                  13,
                  color: UiPalette.of(context).muted,
                ),
              ),
            ],
            if (_readFailure != null || _mutation.failure != null)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text(
                  (_readFailure ?? _mutation.failure)!.message,
                  key: const ValueKey('host-error'),
                  style: libraryText(
                    context,
                    14,
                    color: UiPalette.of(context).danger,
                  ),
                ),
              ),
          ],
        ),
        actions: [
          DesktopButton(
            key: const ValueKey('host-close'),
            onPressed: _mutation.frozen ? null : () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
          if (h?.target.record != null && widget.onRecord != null)
            DesktopButton(
              key: const ValueKey('host-view-record'),
              onPressed: _mutation.frozen
                  ? null
                  : () {
                      Navigator.pop(context);
                      widget.onRecord!(h!.target.record!);
                    },
              child: const Text('查看资料'),
            ),
          if (!_mutation.uncertain)
            DesktopButton(
              key: const ValueKey('host-refresh'),
              onPressed: _mutation.frozen || _loading ? null : _load,
              child: const Text('重新读取'),
            ),
          if (_mutation.uncertain)
            DesktopButton(
              key: const ValueKey('host-reconcile'),
              busy: _mutation.busy,
              onPressed: _mutation.busy ? null : _reconcile,
              child: const Text('核对结果'),
            )
          else ...[
            if (h?.canRevoke == true)
              DesktopButton(
                key: const ValueKey('host-revoke'),
                onPressed: ready
                    ? () => _submit(WorkspaceHostAction.revoke)
                    : null,
                child: const Text('撤销确认'),
              ),
            DesktopButton(
              key: const ValueKey('host-confirm'),
              kind: DesktopButtonKind.primary,
              busy: _mutation.busy,
              onPressed:
                  ready &&
                      h.canConfirm &&
                      (h.state != WorkspaceHostState.changed || _acknowledged)
                  ? () => _submit(WorkspaceHostAction.confirm)
                  : null,
              child: const Text('确认主机身份'),
            ),
          ],
        ],
      ),
    );
  }
}
