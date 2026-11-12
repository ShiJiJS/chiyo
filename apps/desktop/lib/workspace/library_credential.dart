import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../desktop_controls.dart';
import '../desktop_feedback.dart';
import '../prototype_icons.dart';
import '../ui_palette.dart';
import 'credential_mutation.dart';
import 'library_credential_editor.dart';
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
  String? _revealed;
  List<WorkspaceRecordSummary> _links = [];
  List<WorkspaceCredentialUseRequest> _requests = [];
  WorkspaceFailure? _failure, _requestFailure, _linksFailure;
  bool _loading = true, _refreshing = true, _busy = false;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(LibraryCredential oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ref != widget.ref || oldWidget.source != widget.source) {
      _detail = null;
      _links = [];
      _requests = [];
      _requestFailure = null;
      _linksFailure = null;
    }
    if (oldWidget.ref != widget.ref ||
        oldWidget.source != widget.source ||
        oldWidget.revision != widget.revision) {
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final generation = ++_generation;
    _revealed = null;
    setState(() {
      _loading = _detail == null;
      _refreshing = true;
      _failure = null;
    });
    try {
      final detail = await widget.source.credentials.read(widget.ref);
      List<WorkspaceRecordSummary> links = [];
      WorkspaceFailure? linksFailure;
      try {
        links = await widget.source.readSummaries(detail.allLinks);
      } catch (error) {
        linksFailure = error is WorkspaceFailure
            ? error
            : const WorkspaceFailure('unavailable', '关联资料暂不可读取。');
      }
      List<WorkspaceCredentialUseRequest> requests = [];
      WorkspaceFailure? requestFailure;
      try {
        requests = await widget.source.credentials.requests(ref: widget.ref);
      } catch (error) {
        requestFailure = error is WorkspaceFailure
            ? error
            : const WorkspaceFailure('unavailable', '使用申请记录暂不可读取。');
      }
      if (mounted && generation == _generation) {
        setState(() {
          _detail = detail;
          _links = links;
          _linksFailure = linksFailure;
          _requests = requests;
          _requestFailure = requestFailure;
          _loading = false;
          _refreshing = false;
        });
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _failure = error is WorkspaceFailure
              ? error
              : const WorkspaceFailure('unavailable', '凭据资料暂不可读取。');
          _loading = false;
          _refreshing = false;
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

  Future<void> _readSecret({required bool copy}) async {
    final source = widget.source.credentials;
    final detail = _detail;
    if (_busy || detail == null || source is! WorkspaceCredentialRevealSource) {
      return;
    }
    final generation = _generation;
    setState(() => _busy = true);
    try {
      final secret = await (source as WorkspaceCredentialRevealSource)
          .readStringMaterial(widget.ref, detail.materialVersion);
      if (!mounted || generation != _generation) return;
      if (copy) {
        await Clipboard.setData(ClipboardData(text: secret));
        if (mounted) DesktopFeedback.show(context, '已复制凭据');
      } else {
        setState(() => _revealed = secret);
      }
    } catch (error) {
      if (mounted) {
        DesktopFeedback.show(
          context,
          error is WorkspaceFailure ? error.message : '凭据原文暂不可读取。',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
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
    // A mutation or change notification may finish before the detail projection
    // has refreshed. Review the current version instead of opening a stale form.
    final detail = await widget.source.credentials.read(widget.ref);
    if (!mounted) return;
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
  Future<void> _history() => _modal(() async {
    await showDesktopDialog<void>(
      context,
      builder: (_) => _CredentialHistory(
        source: widget.source.credentials,
        ref: widget.ref,
      ),
    );
  });
  String _purpose(WorkspaceCredentialDetail detail) {
    final description = detail.record.description;
    final explanation = detail.delivery == WorkspaceCredentialDelivery.storage
        ? '凭据原文由知予保管；当前不支持运行时使用。'
        : detail.delivery == WorkspaceCredentialDelivery.focus
        ? '凭据原文由知予保存，使用需单独审批。'
        : '凭据原文由知予保存，使用时交给执行器。';
    if (description.isEmpty) return explanation;
    final separator = '。！？.!?'.contains(description[description.length - 1])
        ? ''
        : '。';
    return '$description$separator$explanation';
  }

  Widget _section(
    String title,
    Widget child, {
    required String id,
    double gap = 12,
  }) => Padding(
    padding: const EdgeInsets.only(top: 27),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LibraryReadingText(
          key: ValueKey('credential-section-$id-title'),
          span: TextSpan(text: title),
          style: libraryText(context, 17, weight: FontWeight.w700, height: 1.5),
        ),
        SizedBox(height: gap),
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
    final enabled = !_busy && !_refreshing && _failure == null;
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
        Padding(
          padding: const EdgeInsets.only(top: 20),
          child: Container(
            key: const ValueKey('credential-summary'),
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: c.credentialSurface,
              border: Border.all(color: c.line),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Row(
              children: [
                PrototypeIcon(
                  PrototypeIconGlyph.shield,
                  size: 19,
                  color: c.ink,
                ),
                const SizedBox(width: 15),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        detail.filename ?? detail.format,
                        key: const ValueKey('credential-summary-title'),
                        style: libraryText(
                          context,
                          14,
                          weight: FontWeight.w700,
                        ),
                      ),
                      Wrap(
                        key: const ValueKey('credential-summary-format'),
                        spacing: 10,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          if (detail.form == WorkspaceCredentialForm.string &&
                              widget.source.credentials
                                  is WorkspaceCredentialRevealSource) ...[
                            DesktopButton(
                              key: const ValueKey('credential-reveal'),
                              kind: DesktopButtonKind.quiet,
                              onPressed: enabled
                                  ? () {
                                      if (_revealed != null) {
                                        setState(() => _revealed = null);
                                      } else {
                                        unawaited(_readSecret(copy: false));
                                      }
                                    }
                                  : null,
                              child: Text(_revealed == null ? '查看' : '隐藏'),
                            ),
                            DesktopButton(
                              key: const ValueKey('credential-copy'),
                              kind: DesktopButtonKind.quiet,
                              onPressed: enabled
                                  ? () => _readSecret(copy: true)
                                  : null,
                              child: const Text('复制'),
                            ),
                          ],
                          if (detail.filename != null)
                            Text(
                              detail.format,
                              style: libraryText(context, 13, color: c.warning),
                            ),
                          SelectableText(
                            _revealed ?? detail.mask,
                            key: const ValueKey('credential-mask'),
                            semanticsLabel: '凭据内容已隐藏',
                            style: libraryText(
                              context,
                              13,
                              color: c.warning,
                            ).copyWith(fontFamily: 'Menlo'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 15),
                Container(
                  key: const ValueKey('credential-status'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: detail.canRequestUse
                        ? c.successSurface
                        : c.credentialSurface,
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Text(
                    !detail.enabled
                        ? '已停用'
                        : detail.canRequestUse
                        ? '可使用'
                        : detail.delivery == WorkspaceCredentialDelivery.focus
                        ? '本机填充未启用'
                        : detail.delivery == WorkspaceCredentialDelivery.storage
                        ? '仅保管'
                        : '使用暂不可用',
                    style: libraryText(
                      context,
                      13,
                      color: detail.canRequestUse ? c.success : c.warning,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        _section(
          '用途与内容',
          LibraryReadingText(
            key: const ValueKey('credential-purpose'),
            span: TextSpan(text: _purpose(detail)),
            style: libraryText(context, 14, height: 1.95),
          ),
          id: 'purpose',
        ),
        if (detail.account.isNotEmpty)
          _section(
            '账号',
            LibraryReadingText(
              key: const ValueKey('credential-account-value'),
              span: TextSpan(text: detail.account),
              style: libraryText(context, 14),
            ),
            id: 'account',
          ),
        if (detail.unavailableReason != null)
          Text(
            detail.unavailableReason!,
            style: libraryText(context, 14, color: c.warning),
          ),
        ExpansionTile(
          key: const ValueKey('credential-advanced'),
          tilePadding: EdgeInsets.zero,
          shape: const Border(),
          collapsedShape: const Border(),
          title: Text('高级详情', style: libraryText(context, 14, color: c.muted)),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '凭据版本 ${detail.materialVersion}',
                style: libraryText(context, 13, color: c.muted),
              ),
            ),
            _section(
              '使用方式',
              detail.delivery == WorkspaceCredentialDelivery.storage
                  ? Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 15,
                        vertical: 13,
                      ),
                      decoration: BoxDecoration(
                        color: c.credentialSurface,
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: Text(
                        detail.unavailableReason!,
                        style: libraryText(
                          context,
                          13,
                          color: c.warning,
                          height: 1.8,
                        ),
                      ),
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        LayoutBuilder(
                          builder: (context, bounds) {
                            final columns =
                                bounds.maxWidth >= 480 &&
                                    MediaQuery.textScalerOf(context).scale(1) <
                                        1.6
                                ? 2
                                : 1;
                            return Wrap(
                              spacing: 34,
                              runSpacing: 22,
                              children: [
                                for (final (id, label, value) in [
                                  ('delivery', '注入方式', detail.delivery.label),
                                  if (detail.binding.isNotEmpty)
                                    ('binding', '引用名称', detail.binding),
                                ])
                                  SizedBox(
                                    width:
                                        (bounds.maxWidth - 34 * (columns - 1)) /
                                        columns,
                                    child: Column(
                                      key: ValueKey('credential-$id-fact'),
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        LibraryReadingText(
                                          key: ValueKey('credential-$id-label'),
                                          span: TextSpan(text: label),
                                          style: libraryText(
                                            context,
                                            13,
                                            color: c.muted,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        LibraryReadingText(
                                          key: ValueKey('credential-$id-value'),
                                          lineFontSize: 14,
                                          span: TextSpan(text: value),
                                          style: id == 'binding'
                                              ? libraryText(
                                                  context,
                                                  13,
                                                  weight: FontWeight.w500,
                                                ).copyWith(fontFamily: 'Menlo')
                                              : libraryText(
                                                  context,
                                                  14,
                                                  weight: FontWeight.w500,
                                                ),
                                        ),
                                      ],
                                    ),
                                  ),
                              ],
                            );
                          },
                        ),
                        const SizedBox(height: 24),
                        LibraryReadingText(
                          key: const ValueKey('credential-use-note'),
                          span: TextSpan(
                            text:
                                detail.unavailableReason ??
                                '凭据使用单独审批；在授权期内可按批准方式重复使用。',
                          ),
                          style: libraryText(
                            context,
                            14,
                            color: detail.unavailableReason == null
                                ? c.muted
                                : c.warning,
                          ),
                        ),
                      ],
                    ),
              id: 'use',
              gap: detail.delivery == WorkspaceCredentialDelivery.storage
                  ? 18
                  : 13,
            ),
          ],
        ),
        _section(
          '关联资料',
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_linksFailure case final failure?)
                Text(
                  '关联资料未能读取：${failure.message}',
                  key: const ValueKey('credential-link-read-failure'),
                  style: libraryText(context, 13, color: c.warning),
                ),
              if (_linksFailure == null)
                for (final (index, ref) in detail.allLinks.indexed)
                  if (_links.where((r) => r.ref == ref).firstOrNull
                      case final linked?)
                    LibraryRelationRow(
                      record: linked,
                      first: index == 0,
                      onPressed: () => widget.onOpen(ref),
                    )
                  else
                    Text(
                      '关联资料已不可用。',
                      style: libraryText(context, 13, color: c.muted),
                    ),
              if (_linksFailure == null && detail.allLinks.isEmpty)
                Text(
                  '尚未关联资料。',
                  style: libraryText(context, 13, color: c.muted),
                ),
              if (detail.referencingInformation.isNotEmpty)
                Text(
                  '其他资料对这项凭据的引用，可打开对应资料修改。',
                  style: libraryText(context, 12, color: c.muted),
                ),
            ],
          ),
          id: 'relations',
        ),
        if (detail.privateNote.isNotEmpty)
          _section(
            '私有备注',
            LibraryReadingText(
              span: TextSpan(text: detail.privateNote),
              style: libraryText(context, 14, height: 1.8),
            ),
            id: 'private-note',
          ),
        Padding(
          padding: const EdgeInsets.only(top: 27),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              DesktopButton(
                key: const ValueKey('credential-replace'),
                onPressed: enabled ? _replace : null,
                child: const Text('更新凭据内容'),
              ),
              DesktopButton(
                key: const ValueKey('credential-toggle'),
                onPressed: enabled ? _toggle : null,
                child: Text(detail.enabled ? '停用凭据' : '重新启用'),
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
        ),
        if (_requestFailure case final failure?)
          Padding(
            padding: const EdgeInsets.only(top: 20),
            child: Text(
              '使用申请记录未能读取：${failure.message}',
              key: const ValueKey('credential-request-read-failure'),
              style: libraryText(context, 13, color: c.warning),
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
                          '${request.purpose} · 材料v${request.materialVersion} · ${request.validityLabel}',
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
            id: 'requests',
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
    final result = await _mutation.submitCommand(
      (id) => WorkspaceCredentialToggle(
        operationId: id,
        ref: _current.record.ref,
        expectedRecordVersion: _current.recordVersion,
        expectedMaterialVersion: _current.materialVersion,
        enabled: _enabled,
      ),
      widget.source.setEnabled,
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
                ? '重新启用后Agent可重新申请使用；旧授权不会恢复。'
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
                  grant.expiresAt == null
                      ? '不限时（限本聊天）'
                      : '到期时间（本地）：${libraryLocalDateTime(grant.expiresAt!)}',
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
