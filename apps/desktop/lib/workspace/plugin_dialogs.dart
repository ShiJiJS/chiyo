import 'dart:async';
import 'package:flutter/material.dart';
import '../desktop_controls.dart';
import '../ui_palette.dart';
import 'library_widgets.dart';
import 'plugin_mutation.dart';
import 'plugin_widgets.dart';
import 'workspace_source.dart';

/// The composition root supplies host selection and releases unchosen leases.
Future<WorkspacePluginCandidate?> showPluginChoices(
  BuildContext context,
  Future<List<WorkspacePluginCandidate>> Function() read,
  Future<void> Function(String) release,
) async {
  final choices = await read();
  WorkspacePluginCandidate? selected;
  try {
    if (!context.mounted) return null;
    selected = await showDesktopDialog<WorkspacePluginCandidate>(
      context,
      builder: (context) => DesktopDialog(
        title: const Text('选择插件包'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final choice in choices)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: DesktopButton(
                  alignment: Alignment.centerLeft,
                  padding: const EdgeInsets.all(14),
                  onPressed: () => Navigator.pop(context, choice),
                  child: Text('${choice.filename} · ${choice.byteLength}字节'),
                ),
              ),
          ],
        ),
        actions: [
          DesktopButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    return selected;
  } finally {
    for (final c in choices) {
      if (c.selectionId != selected?.selectionId) await release(c.selectionId);
    }
  }
}

Future<WorkspacePluginReceipt?> showPluginInstall(
  BuildContext context,
  WorkspacePluginSource source,
  WorkspacePluginPicker? picker,
) => showDesktopDialog<WorkspacePluginReceipt>(
  context,
  builder: (_) => _PluginChange(source: source, picker: picker),
);

Future<WorkspacePluginReceipt?> showPluginMaintenance(
  BuildContext context,
  WorkspacePluginSource source,
  WorkspacePlugin package,
  WorkspacePluginAction action,
) => showDesktopDialog<WorkspacePluginReceipt>(
  context,
  builder: (_) =>
      _PluginChange(source: source, package: package, action: action),
);

class _PluginChange extends StatefulWidget {
  const _PluginChange({
    required this.source,
    this.picker,
    this.package,
    this.action = WorkspacePluginAction.install,
  });
  final WorkspacePluginSource source;
  final WorkspacePluginPicker? picker;
  final WorkspacePlugin? package;
  final WorkspacePluginAction action;
  @override
  State<_PluginChange> createState() => _PluginChangeState();
}

class _PluginChangeState extends State<_PluginChange> {
  late final PluginMutation _mutation;
  WorkspacePluginPreview? _preview;
  WorkspacePlugin? _package;
  int? _version;
  WorkspacePluginCandidate? _candidate;
  WorkspaceFailure? _readFailure;
  bool _loading = true;
  bool _showPrevious = false;
  String? _notice;
  int _generation = 0;
  bool get _install => widget.action == WorkspacePluginAction.install;
  bool get _locked => _mutation.frozen || _loading;
  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _mutation = PluginMutation(widget.source)..addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        if (_install) {
          _pick();
        } else {
          _reload();
        }
      }
    });
  }

  @override
  void dispose() {
    ++_generation;
    _mutation.dispose();
    if (_candidate case final c?) {
      unawaited(widget.source.releaseCandidate(c.selectionId));
    }
    super.dispose();
  }

  Future<void> _pick() async {
    if (_mutation.frozen) return;
    setState(() {
      _loading = true;
      _readFailure = null;
      _notice = null;
      _showPrevious = false;
    });
    try {
      final candidate = await widget.picker?.call();
      if (!mounted) {
        if (candidate != null) {
          await widget.source.releaseCandidate(candidate.selectionId);
        }
        return;
      }
      if (candidate == null) {
        if (_candidate == null) {
          Navigator.pop(context);
        } else {
          setState(() => _loading = false);
        }
        return;
      }
      if (_candidate case final old?) {
        await widget.source.releaseCandidate(old.selectionId);
      }
      _candidate = candidate;
      await _reload();
    } on WorkspaceFailure catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _readFailure = e;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _readFailure = const WorkspaceFailure(
            'unavailable',
            '暂时无法选择插件包，请重试。',
          );
        });
      }
    }
  }

  Future<void> _reload() async {
    if (_mutation.frozen) return;
    final generation = ++_generation;
    _mutation.reviewed();
    setState(() {
      _loading = true;
      _readFailure = null;
      _notice = null;
    });
    try {
      if (_install) {
        final preview = await widget.source.previewInstall(
          _candidate!.selectionId,
        );
        if (!mounted || generation != _generation) return;
        _preview = preview;
        _package = preview.package;
        _version = preview.catalogVersion;
      } else {
        final catalog = await widget.source.load();
        if (!mounted || generation != _generation) return;
        final package = catalog.packages
            .where((p) => p.id == widget.package!.id)
            .firstOrNull;
        if (package == null) {
          throw const WorkspaceFailure('not_found', '插件已移除，请关闭后重新读取。');
        }
        _package = package;
        _version = catalog.version;
      }
    } on WorkspaceFailure catch (e) {
      if (mounted && generation == _generation) _readFailure = e;
    } catch (_) {
      if (mounted && generation == _generation) {
        _readFailure = const WorkspaceFailure('unavailable', '暂时无法读取预览，请重试。');
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _submit() async {
    if (_locked ||
        _readFailure != null ||
        _package == null ||
        _version == null) {
      return;
    }
    _notice = null;
    final p = _package!;
    final result = await _mutation.submit(
      (id) => WorkspacePluginChange(
        operationId: id,
        action: widget.action,
        packageId: p.id,
        expectedVersion: _version!,
        expectedDigest: p.digest,
        selectionId: _candidate?.selectionId,
      ),
    );
    if (mounted && result != null) Navigator.pop(context, result);
  }

  Future<void> _reconcile() async {
    final result = await _mutation.reconcile();
    if (!mounted) return;
    if (result != null) {
      Navigator.pop(context, result);
    } else if (!_mutation.uncertain) {
      setState(() => _notice = '已确认尚未提交，可重新确认此操作。');
    }
  }

  String get _verb => switch (widget.action) {
    WorkspacePluginAction.install =>
      _preview?.previous == null ? '安装插件' : '更新插件',
    WorkspacePluginAction.enable => '启用插件',
    WorkspacePluginAction.disable => '停用插件',
    WorkspacePluginAction.remove => '移除插件',
  };
  @override
  Widget build(BuildContext context) {
    final c = UiPalette.of(context),
        failure = _mutation.failure ?? _readFailure,
        p = _package;
    return PopScope<WorkspacePluginReceipt>(
      canPop: !_mutation.frozen,
      child: DesktopDialog(
        title: Text(_install ? '$_verb预览' : _verb),
        content: SizedBox(
          width: 680,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_loading) const Text('正在读取插件…'),
              if (p != null) ...[
                Text(
                  p.name,
                  style: libraryText(context, 23, weight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Text(
                  'v${p.version} · ${p.author} · ${p.origin}',
                  style: libraryText(context, 13, color: c.muted),
                ),
                const SizedBox(height: 12),
                Text(p.description, style: libraryText(context, 14)),
                if (p.legacySource case final source?) ...[
                  const SizedBox(height: 12),
                  Text(
                    '来自旧版模板第${source['version']}版；保留${(source['definitionIds'] as Map).length}项字段定义来源对应。已有资料不会批量改写。',
                    style: libraryText(context, 13, color: c.muted),
                  ),
                ],
                const SizedBox(height: 16),
                if (_install) ...[
                  Text(
                    p.builtin
                        ? '来自随应用提供的内置定义，请核对版本与结构后更新。'
                        : '作者信息为包内自述，请核对来源与结构后安装。',
                    style: libraryText(context, 13, color: c.muted),
                  ),
                  const SizedBox(height: 8),
                  SelectableText(
                    'SHA256 ${p.digest}',
                    style: libraryText(context, 12, color: c.muted),
                  ),
                  if (_preview?.previous case final before?)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: Text(
                        'v${before.version} → v${p.version} · ${before.affectedRecords}项已有资料保持原快照',
                        style: libraryText(context, 14),
                      ),
                    ),
                  if (_preview?.previous case final before?) ...[
                    const SizedBox(height: 8),
                    SelectableText(
                      '原摘要 SHA256 ${before.digest}',
                      style: libraryText(context, 12, color: c.muted),
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: DesktopButton(
                        key: const ValueKey('plugin-previous-definition'),
                        kind: DesktopButtonKind.quiet,
                        onPressed: () =>
                            setState(() => _showPrevious = !_showPrevious),
                        child: Text(_showPrevious ? '收起已安装定义' : '查看已安装定义'),
                      ),
                    ),
                    if (_showPrevious)
                      for (final template in before.templates) ...[
                        Text(
                          '${template.type.name} · v${before.version}',
                          style: libraryText(
                            context,
                            16,
                            weight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 12),
                        PluginTemplatePreview(
                          template: template,
                          structure: true,
                        ),
                        const SizedBox(height: 12),
                        SelectableText(
                          template.definition['instructions'] as String? ?? '',
                          style: libraryText(context, 13),
                        ),
                        const SizedBox(height: 24),
                      ],
                  ],
                  for (final line in _preview?.differences ?? <String>[])
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(line),
                    ),
                  const SizedBox(height: 24),
                  for (final t in p.templates) ...[
                    Text(
                      t.type.name,
                      style: libraryText(context, 17, weight: FontWeight.w600),
                    ),
                    const SizedBox(height: 12),
                    PluginTemplatePreview(template: t, structure: true),
                    const SizedBox(height: 24),
                  ],
                ] else ...[
                  Text(
                    '${p.affectedRecords}项已有资料的内容、附件、关联与历史均保留。',
                    style: libraryText(context, 15),
                  ),
                  const SizedBox(height: 12),
                  Text(switch (widget.action) {
                    WorkspacePluginAction.disable =>
                      '停用后不再用于新建，已有资料按保留的字段继续查看和编辑。',
                    WorkspacePluginAction.remove =>
                      '移除包不会删除资料或撤销既有主机记录。已有资料仍可查看和编辑。',
                    _ => '启用后可用于后续新建；不会迁移已有资料，也不会自动确认主机身份。',
                  }, style: libraryText(context, 14, color: c.muted)),
                ],
              ],
            ],
          ),
        ),
        actions: [
          if (_notice != null)
            SizedBox(width: double.infinity, child: Text(_notice!)),
          if (failure != null)
            SizedBox(
              width: double.infinity,
              child: PluginFailureView(
                failure,
                key: const ValueKey('plugin-change-error'),
              ),
            ),
          if (_mutation.uncertain)
            DesktopButton(
              key: const ValueKey('plugin-reconcile'),
              onPressed: _mutation.busy ? null : _reconcile,
              child: const Text('核对结果'),
            ),
          if (!_mutation.uncertain &&
              (_readFailure != null || _mutation.failure?.code == 'conflict'))
            DesktopButton(
              onPressed: _loading ? null : _reload,
              child: const Text('重新预览'),
            ),
          if (_install)
            DesktopButton(
              key: const ValueKey('plugin-repick'),
              onPressed: _locked ? null : _pick,
              child: const Text('重新选择'),
            ),
          DesktopButton(
            onPressed: _mutation.frozen
                ? null
                : () => Navigator.maybePop(context),
            child: const Text('取消'),
          ),
          DesktopButton(
            key: const ValueKey('plugin-change-submit'),
            busy: _mutation.busy,
            kind: widget.action == WorkspacePluginAction.remove
                ? DesktopButtonKind.danger
                : DesktopButtonKind.primary,
            onPressed:
                _locked ||
                    _readFailure != null ||
                    p == null ||
                    !_mutation.canSubmit
                ? null
                : _submit,
            child: Text('确认$_verb'),
          ),
        ],
      ),
    );
  }
}
