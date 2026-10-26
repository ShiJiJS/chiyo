import 'dart:convert';
import 'package:flutter/material.dart';
import '../desktop_controls.dart';
import '../ui_palette.dart';
import 'library_widgets.dart';
import 'workspace_source.dart';

Future<bool?> showLibraryHistory(
  BuildContext context,
  WorkspaceSource source,
  WorkspaceRecordRef ref,
) => showDesktopDialog<bool>(
  context,
  builder: (_) => _HistoryDialog(source: source, ref: ref),
);

/// Selectable read-only snapshots, including composite legacy values.
Map<String, String> librarySnapshot(WorkspaceArchive archive) {
  final detail = archive.detail, record = detail.record;
  String value(Object? v) => v == null || v == ''
      ? '未填写'
      : v is String
      ? v
      : const JsonEncoder.withIndent('  ').convert(v);
  final labels = <String, String>{
    for (final f in detail.definition['fields'] as List? ?? [])
      f['key'] as String: f['label'] as String? ?? f['key'] as String,
  };
  return {
    '名称': record.name,
    '用途': value(record.description),
    '目录':
        archive.directoryName ??
        (record.directoryId == null ? '未分类' : '已移除目录（${record.directoryId}）'),
    '标签': record.tags.isEmpty
        ? '无标签'
        : record.tags.map((t) => t.name).join('、'),
    for (final e in detail.values.entries)
      '字段：${labels[e.key] ?? e.key}${labels[e.key] != null && labels[e.key] != e.key ? '（${e.key}）' : ''}':
          value(e.value),
    for (final e in detail.relations.entries)
      '关联：${e.key}': e.value.isEmpty
          ? '无关联'
          : e.value
                .map((r) => '${archive.targets[r]?.name ?? '不可用目标'}（${r.key}）')
                .join('\n'),
    '资料结构': const JsonEncoder.withIndent('  ').convert(detail.definition),
  };
}

class LibrarySnapshotView extends StatelessWidget {
  const LibrarySnapshotView({super.key, required this.archive});
  final WorkspaceArchive archive;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final e in librarySnapshot(archive).entries)
        Padding(
          padding: const EdgeInsets.only(bottom: 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                e.key,
                style: libraryText(
                  context,
                  13,
                  color: UiPalette.of(context).muted,
                ),
              ),
              const SizedBox(height: 5),
              SelectableText(
                e.value,
                style: libraryText(context, 14, height: 1.7),
              ),
            ],
          ),
        ),
    ],
  );
}

class _HistoryDialog extends StatefulWidget {
  const _HistoryDialog({required this.source, required this.ref});
  final WorkspaceSource source;
  final WorkspaceRecordRef ref;
  @override
  State<_HistoryDialog> createState() => _HistoryDialogState();
}

class _HistoryDialogState extends State<_HistoryDialog> {
  List<WorkspaceRevision>? _revisions;
  WorkspaceDetail? _current;
  WorkspaceRevisionPreview? _preview;
  WorkspaceArchive? _currentArchive;
  WorkspaceFailure? _failure;
  bool _loading = true, _busy = false;
  int _generation = 0;
  String? _operation;
  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _preview = null;
      _failure = null;
      _operation = null;
    });
    try {
      final current = await widget.source.readDetail(widget.ref);
      final revisions = await widget.source.loadRevisions(widget.ref);
      if (!mounted || generation != _generation) return;
      setState(() {
        _current = current;
        _revisions = revisions;
      });
    } on WorkspaceFailure catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _failure = error);
      }
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(
          () => _failure = const WorkspaceFailure(
            'unavailable',
            '暂时无法读取内容版本，请重试。',
          ),
        );
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _select(WorkspaceRevision revision) async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _preview = null;
      _failure = null;
      _operation = null;
    });
    try {
      final preview = await widget.source.previewRevision(
        widget.ref,
        revision.version,
        expectedVersion: _current!.version,
      );
      final catalog = await widget.source.loadCatalog();
      final targets = await widget.source.readSummaries(
        preview.current.relations.values.expand((r) => r),
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _preview = preview;
        _currentArchive = WorkspaceArchive(
          detail: preview.current,
          archivedAt: preview.current.record.updatedAt,
          directoryName: catalog.directories
              .where((d) => d.id == preview.current.record.directoryId)
              .firstOrNull
              ?.name,
          targets: {for (final r in targets) r.ref: r},
        );
      });
    } on WorkspaceFailure catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _failure = error);
      }
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(
          () =>
              _failure = const WorkspaceFailure('unavailable', '暂时无法比较内容，请重试。'),
        );
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _restore() async {
    if (_busy || _preview == null || !_preview!.canRestore) return;
    final preview = _preview!;
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      await widget.source.changeRecord(
        WorkspaceRecordChange(
          operationId: _operation ??= UniqueKey().toString(),
          ref: widget.ref,
          expectedVersion: preview.current.version,
          expectedCatalogVersion: preview.catalogVersion,
          action: WorkspaceRecordAction.restoreRevision,
          revisionVersion: preview.archive.detail.version,
        ),
      );
      final current = await widget.source.readDetail(widget.ref);
      if (current.version <= preview.current.version) {
        throw const WorkspaceFailure('unknown_outcome', '恢复结果需要重新读取核对。');
      }
      if (mounted) Navigator.pop(context, true);
    } on WorkspaceFailure catch (error) {
      if (mounted) setState(() => _failure = error);
    } catch (_) {
      if (mounted) {
        setState(
          () => _failure = const WorkspaceFailure(
            'unknown_outcome',
            '恢复结果暂时无法确认，请先重新读取，不要重复提交。',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _comparison(WorkspaceRevisionPreview preview) {
    final before = librarySnapshot(_currentArchive!),
        old = librarySnapshot(preview.archive);
    final c = UiPalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '当前 v${preview.current.version} → 恢复为 v${preview.restored.version}',
          style: libraryText(context, 17, weight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Text(
          '恢复后会生成新版本，当前内容仍可在历史中查看。旧授权不会恢复。',
          style: libraryText(context, 13, color: c.muted),
        ),
        for (final notice in preview.notices)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(notice, style: TextStyle(color: c.warning)),
          ),
        if (!preview.canRestore)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '包含已移除字段：${preview.missingFields.join('、')}。请先在回收站显式恢复。',
              style: TextStyle(color: c.danger),
            ),
          ),
        const SizedBox(height: 20),
        for (final key in {...before.keys, ...old.keys})
          Container(
            padding: const EdgeInsets.symmetric(vertical: 15),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: c.line)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  key,
                  style: libraryText(context, 14, weight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Text(
                  '当前${before[key] == old[key] ? ' · 未变化' : ''}',
                  style: libraryText(context, 12, color: c.muted),
                ),
                SelectableText(
                  before[key] ?? '无此内容',
                  style: libraryText(context, 14, height: 1.7),
                ),
                const SizedBox(height: 10),
                Text(
                  '历史 v${preview.archive.detail.version}',
                  style: libraryText(context, 12, color: c.muted),
                ),
                SelectableText(
                  old[key] ?? '无此内容',
                  style: libraryText(context, 14, height: 1.7),
                ),
              ],
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => PopScope<bool>(
    canPop: !_busy,
    child: DesktopDialog(
      key: ValueKey('history-mode-${_preview?.archive.detail.version}'),
      title: const Text('内容版本'),
      content: SizedBox(
        width: 680,
        child: _loading
            ? const Text('正在读取内容版本…')
            : _preview != null
            ? _comparison(_preview!)
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_current != null)
                    Text(
                      '${_current!.record.name} · 当前 v${_current!.version}',
                      style: libraryText(context, 17, weight: FontWeight.w600),
                    ),
                  const SizedBox(height: 14),
                  if (_revisions?.isEmpty ?? false)
                    const Text('尚无历史版本。编辑保存后可在这里比较和恢复。'),
                  for (final r in _revisions ?? <WorkspaceRevision>[])
                    DesktopButton(
                      key: ValueKey('library-version-${r.version}'),
                      kind: DesktopButtonKind.quiet,
                      alignment: Alignment.centerLeft,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      onPressed: () => _select(r),
                      child: Text(
                        'v${r.version} · ${r.record.name}\n${r.archivedAt.toIso8601String().substring(0, 16).replaceFirst('T', ' ')}',
                      ),
                    ),
                ],
              ),
      ),
      actions: [
        if (_failure != null)
          SizedBox(
            width: double.infinity,
            child: Semantics(
              liveRegion: true,
              child: Text(
                _failure!.message,
                key: const ValueKey('library-history-error'),
                style: TextStyle(color: UiPalette.of(context).danger),
              ),
            ),
          ),
        if (_failure != null || _preview != null)
          DesktopButton(
            onPressed: _busy ? null : _reload,
            child: const Text('重新读取版本'),
          ),
        DesktopButton(
          onPressed: _busy ? null : () => Navigator.maybePop(context),
          child: const Text('关闭'),
        ),
        if (_preview != null)
          DesktopButton(
            key: const ValueKey('library-restore-version'),
            kind: DesktopButtonKind.primary,
            busy: _busy,
            onPressed:
                _loading ||
                    !_preview!.canRestore ||
                    ['conflict', 'unknown_outcome'].contains(_failure?.code)
                ? null
                : _restore,
            child: const Text('恢复此版本'),
          ),
      ],
    ),
  );
}
