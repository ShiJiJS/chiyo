import 'dart:async';
import 'package:flutter/material.dart';
import '../desktop_controls.dart';
import '../desktop_feedback.dart';
import '../prototype_icons.dart';
import '../ui_palette.dart';
import 'credential_mutation.dart';
import 'library_credential_editor.dart';
import 'library_credential_use.dart';
import 'library_widgets.dart';
import 'workspace_source.dart';

class LibraryCredential extends StatefulWidget {
  const LibraryCredential({
    super.key,
    required this.ref,
    required this.revision,
    required this.source,
    required this.onOpen,
    this.onModalChanged,
    this.picker,
    this.onApproval,
  });
  final WorkspaceRecordRef ref;
  final int revision;
  final WorkspaceSource source;
  final ValueChanged<WorkspaceRecordRef> onOpen;
  final ValueChanged<bool>? onModalChanged;
  final WorkspaceCredentialPicker? picker;
  final ValueChanged<String>? onApproval;
  @override
  State<LibraryCredential> createState() => _LibraryCredentialState();
}

class _LibraryCredentialState extends State<LibraryCredential> {
  WorkspaceCredentialDetail? _detail;
  List<WorkspaceRecordSummary> _links = [];
  List<WorkspaceCredentialUseRequest> _requests = [];
  WorkspaceFailure? _failure;
  bool _loading = true, _busy = false;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(LibraryCredential oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ref != widget.ref) {
      _detail = null;
      _links = [];
      _requests = [];
    }
    if (oldWidget.ref != widget.ref || oldWidget.revision != widget.revision) {
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = _detail == null;
      _failure = null;
    });
    try {
      final detail = await widget.source.credentials.read(widget.ref);
      final links = await widget.source.readSummaries(detail.linkedInformation);
      final requests = await widget.source.credentials.requests(
        ref: widget.ref,
      );
      if (mounted && generation == _generation) {
        setState(() {
          _detail = detail;
          _links = links;
          _requests = requests;
          _loading = false;
        });
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _failure = error is WorkspaceFailure
              ? error
              : const WorkspaceFailure('unavailable', '凭据资料暂不可读取。');
          _loading = false;
        });
      }
    }
  }

  Future<void> _modal(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    DesktopFeedback.dismiss(context);
    widget.onModalChanged?.call(true);
    try {
      await action();
    } catch (error) {
      if (mounted) {
        setState(
          () => _failure = error is WorkspaceFailure
              ? error
              : const WorkspaceFailure('unavailable', '操作暂不可用，请重试。'),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
      widget.onModalChanged?.call(false);
    }
  }

  Future<void> _replace() => _modal(() async {
    final catalog = await widget.source.loadCatalog();
    if (!mounted) return;
    final ref = await showLibraryCredentialEditor(
      context,
      widget.source,
      catalog,
      ref: widget.ref,
      replace: true,
      picker: widget.picker,
    );
    if (ref != null && mounted) {
      DesktopFeedback.show(context, '已更换凭据材料');
      await _load();
    }
  });
  Future<void> _toggle() => _modal(() async {
    final detail = _detail;
    if (detail == null) return;
    final result = await showDesktopDialog<bool>(
      context,
      builder: (_) =>
          _CredentialToggle(source: widget.source.credentials, detail: detail),
    );
    if (result == true && mounted) {
      DesktopFeedback.show(context, detail.enabled ? '凭据已停用' : '凭据已重新启用');
      await _load();
    }
  });
  Future<void> _use() => _modal(() async {
    final result = await showDesktopDialog<bool>(
      context,
      builder: (_) => CredentialUseDialog(
        source: widget.source.credentials,
        ref: widget.ref,
        onApproval: widget.onApproval,
      ),
    );
    if (result == true && mounted) await _load();
  });
  Future<void> _history() => _modal(() async {
    await showDesktopDialog<void>(
      context,
      builder: (_) => _CredentialHistory(
        source: widget.source.credentials,
        ref: widget.ref,
      ),
    );
  });
  Widget _section(String title, Widget child) => Padding(
    padding: const EdgeInsets.only(top: 27),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: libraryText(context, 17, weight: FontWeight.w600, height: 1.5),
        ),
        const SizedBox(height: 12),
        child,
      ],
    ),
  );
  @override
  Widget build(BuildContext context) {
    final c = UiPalette.of(context), detail = _detail;
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Text('正在读取凭据资料…'),
      );
    }
    if (detail == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_failure?.message ?? '凭据资料不可用。'),
          DesktopButton(
            key: const ValueKey('credential-retry'),
            onPressed: _load,
            child: const Text('重新读取凭据'),
          ),
        ],
      );
    }
    final enabled = !_busy && _failure == null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_failure != null) ...[
          Text(
            _failure!.message,
            style: libraryText(context, 13, color: c.danger),
          ),
          DesktopButton(
            key: const ValueKey('credential-retry'),
            onPressed: _load,
            child: const Text('重新读取凭据'),
          ),
        ],
        Container(
          margin: const EdgeInsets.symmetric(vertical: 20),
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: c.credentialSurface,
            border: Border.all(color: c.line),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Wrap(
            spacing: 15,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              PrototypeIcon(PrototypeIconGlyph.shield, color: c.warning),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    detail.filename ?? 'Token 字符串',
                    style: libraryText(context, 15, weight: FontWeight.w600),
                  ),
                  Text(
                    '${detail.format} · 材料v${detail.materialVersion}',
                    style: libraryText(context, 13, color: c.warning),
                  ),
                ],
              ),
              Text(
                !detail.enabled
                    ? '已停用'
                    : detail.canRequestUse
                    ? '可使用'
                    : detail.delivery == WorkspaceCredentialDelivery.focus
                    ? '本机填充未启用'
                    : '仅保管',
                style: libraryText(
                  context,
                  13,
                  color: detail.canRequestUse ? c.success : c.warning,
                ),
              ),
            ],
          ),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            DesktopButton(
              key: const ValueKey('credential-replace'),
              onPressed: enabled ? _replace : null,
              child: const Text('更换材料'),
            ),
            DesktopButton(
              key: const ValueKey('credential-toggle'),
              onPressed: enabled ? _toggle : null,
              child: Text(detail.enabled ? '停用凭据' : '重新启用'),
            ),
            DesktopButton(
              key: const ValueKey('credential-use'),
              kind: DesktopButtonKind.primary,
              onPressed: enabled && detail.canRequestUse ? _use : null,
              child: const Text('申请使用'),
            ),
            DesktopButton(
              key: const ValueKey('credential-history'),
              onPressed: _busy ? null : _history,
              child: const Text('使用记录'),
            ),
            DesktopButton(
              key: const ValueKey('credential-refresh'),
              onPressed: _busy ? null : _load,
              child: const Text('刷新凭据资料'),
            ),
          ],
        ),
        _section(
          '用途与内容',
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                detail.record.description,
                style: libraryText(context, 14, height: 1.8),
              ),
              const SizedBox(height: 12),
              SelectableText(
                detail.mask,
                key: const ValueKey('credential-mask'),
                semanticsLabel: '凭据内容已隐藏',
                style: libraryText(context, 16).copyWith(fontFamily: 'Menlo'),
              ),
              if (detail.privateNote.isNotEmpty) ...[
                const SizedBox(height: 14),
                Text('私有备注', style: libraryText(context, 13, color: c.muted)),
                SelectableText(
                  detail.privateNote,
                  style: libraryText(context, 14, height: 1.8),
                ),
              ],
            ],
          ),
        ),
        _section(
          '使用方式',
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(detail.delivery.label, style: libraryText(context, 14)),
              if (detail.binding.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text('引用名称', style: libraryText(context, 13, color: c.muted)),
                SelectableText(
                  detail.binding,
                  style: libraryText(context, 13).copyWith(fontFamily: 'Menlo'),
                ),
              ],
              const SizedBox(height: 12),
              Text(
                detail.unavailableReason ?? '凭据使用单独审批；在授权期内可按批准方式重复使用。',
                style: libraryText(
                  context,
                  13,
                  color: detail.unavailableReason == null ? c.muted : c.warning,
                  height: 1.8,
                ),
              ),
            ],
          ),
        ),
        _section(
          '关联资料',
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final ref in detail.linkedInformation)
                if (_links.where((r) => r.ref == ref).firstOrNull
                    case final linked?)
                  DesktopButton(
                    kind: DesktopButtonKind.quiet,
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    onPressed: () => widget.onOpen(ref),
                    child: Row(
                      children: [
                        RecordIcon(linked.type),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(linked.name),
                              Text(
                                linked.description,
                                style: libraryText(context, 13, color: c.muted),
                              ),
                            ],
                          ),
                        ),
                        const PrototypeIcon(PrototypeIconGlyph.chev),
                      ],
                    ),
                  )
                else
                  Text(
                    '关联资料已不可用。',
                    style: libraryText(context, 13, color: c.muted),
                  ),
              if (detail.linkedInformation.isEmpty)
                Text(
                  '尚未关联资料。',
                  style: libraryText(context, 13, color: c.muted),
                ),
            ],
          ),
        ),
        if (_requests.isNotEmpty)
          _section(
            '使用申请',
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final request in _requests)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          '${request.session.label} · ${request.state.label}',
                          style: libraryText(
                            context,
                            14,
                            weight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          '${request.purpose} · 材料v${request.materialVersion} · 申请${request.minutes}分钟',
                          style: libraryText(context, 13, color: c.muted),
                        ),
                        if (widget.onApproval != null)
                          DesktopButton(
                            key: ValueKey(
                              'credential-open-request-${request.id}',
                            ),
                            kind: DesktopButtonKind.quiet,
                            onPressed: () =>
                                widget.onApproval!(request.approvalId),
                            child: const Text('查看审批请求'),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _CredentialToggle extends StatefulWidget {
  const _CredentialToggle({required this.source, required this.detail});
  final WorkspaceCredentialSource source;
  final WorkspaceCredentialDetail detail;
  @override
  State<_CredentialToggle> createState() => _CredentialToggleState();
}

class _CredentialToggleState extends State<_CredentialToggle> {
  late WorkspaceCredentialDetail _current = widget.detail;
  late final _enabled = !widget.detail.enabled;
  late final _mutation = CredentialMutation(
    widget.source,
    expectedRef: widget.detail.record.ref,
  )..addListener(_changed);
  bool _reading = false;
  String? _error;
  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _mutation.dispose();
    super.dispose();
  }

  void _close() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.pop(context, true);
    });
  }

  Future<void> _save() async {
    final result = await _mutation.submit(
      (id) => widget.source.setEnabled(
        WorkspaceCredentialToggle(
          operationId: id,
          ref: _current.record.ref,
          expectedRecordVersion: _current.recordVersion,
          expectedMaterialVersion: _current.materialVersion,
          enabled: _enabled,
        ),
      ),
    );
    if (mounted && result != null) _close();
  }

  Future<void> _lookup() async {
    if (await _mutation.reconcile() != null && mounted) _close();
  }

  Future<void> _reload() async {
    setState(() => _reading = true);
    try {
      final current = await widget.source.read(_current.record.ref);
      if (mounted) {
        setState(() {
          _current = current;
          _reading = false;
          _error = null;
          _mutation.acceptCurrentVersion();
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _reading = false;
          _error = error is WorkspaceFailure ? error.message : '无法读取当前凭据。';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_mutation.busy && !_reading,
    child: DesktopDialog(
      title: Text(_enabled ? '重新启用凭据' : '停用凭据'),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('${_current.record.name} · 材料v${_current.materialVersion}'),
          const SizedBox(height: 12),
          Text('当前：${_current.enabled ? '已启用' : '已停用'}'),
          const SizedBox(height: 12),
          Text(
            _enabled
                ? '重新启用后可重新申请使用；旧授权不会恢复。'
                : '停用后不能发起新的使用；它不删除历史，也不自动结束已经启动的操作。',
          ),
        ],
      ),
      actions: [
        if (_mutation.failure case final failure?)
          SizedBox(
            width: double.infinity,
            child: Text(
              failure.message,
              style: libraryText(
                context,
                13,
                color: UiPalette.of(context).danger,
              ),
            ),
          ),
        if (_error != null)
          SizedBox(width: double.infinity, child: Text(_error!)),
        if (_mutation.uncertain)
          DesktopButton(
            onPressed: _mutation.busy ? null : _lookup,
            child: const Text('核对此次操作'),
          ),
        if (_mutation.failure?.code == 'conflict')
          DesktopButton(
            onPressed: _reading ? null : _reload,
            child: const Text('重新读取核对'),
          ),
        DesktopButton(
          onPressed: _mutation.busy || _reading
              ? null
              : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        DesktopButton(
          key: const ValueKey('credential-toggle-submit'),
          kind: DesktopButtonKind.primary,
          busy: _mutation.busy,
          onPressed:
              _mutation.canSubmit && !_reading && _current.enabled != _enabled
              ? _save
              : null,
          child: Text(_enabled ? '重新启用' : '停用凭据'),
        ),
      ],
    ),
  );
}

class _CredentialHistory extends StatefulWidget {
  const _CredentialHistory({required this.source, required this.ref});
  final WorkspaceCredentialSource source;
  final WorkspaceRecordRef ref;
  @override
  State<_CredentialHistory> createState() => _CredentialHistoryState();
}

class _CredentialHistoryState extends State<_CredentialHistory> {
  List<WorkspaceCredentialUseHistory>? _history;
  String? _error;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final history = await widget.source.history(widget.ref);
      if (mounted) setState(() => _history = history);
    } catch (error) {
      if (mounted) {
        setState(
          () =>
              _error = error is WorkspaceFailure ? error.message : '使用记录暂不可读取。',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => DesktopDialog(
    title: const Text('凭据使用记录'),
    content: _error != null
        ? Text(_error!)
        : _history == null
        ? const Text('正在读取使用记录…')
        : _history!.isEmpty
        ? const Text('还没有使用记录。')
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final grant in _history!) ...[
                Text(
                  '${grant.credentialName} · 材料v${grant.materialVersion}',
                  style: libraryText(context, 16, weight: FontWeight.w600),
                ),
                Text(
                  '${grant.session.label} · ${grant.state} · ${grant.delivery.label}',
                  style: libraryText(
                    context,
                    13,
                    color: UiPalette.of(context).muted,
                  ),
                ),
                Text(grant.purpose),
                Text(
                  '到期时间（本地）：${libraryLocalDateTime(grant.expiresAt)}',
                  style: libraryText(
                    context,
                    13,
                    color: UiPalette.of(context).muted,
                  ),
                ),
                const SizedBox(height: 12),
                for (final operation in grant.operations)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(operation.description),
                              Text(
                                libraryLocalDateTime(operation.at),
                                style: libraryText(
                                  context,
                                  13,
                                  color: UiPalette.of(context).muted,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(operation.result),
                      ],
                    ),
                  ),
                const SizedBox(height: 18),
              ],
            ],
          ),
    actions: [
      if (_error != null)
        DesktopButton(onPressed: _load, child: const Text('重试')),
      DesktopButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
    ],
  );
}
