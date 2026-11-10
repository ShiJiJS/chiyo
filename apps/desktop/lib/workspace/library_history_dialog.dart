import 'dart:convert';
import 'package:flutter/material.dart';
import '../desktop_controls.dart';
import '../ui_palette.dart';
import 'library_widgets.dart';
import 'workspace_source.dart';
import 'record_mutation.dart';
import 'library_document.dart';
import 'template_record_content.dart';

Future<bool?> showLibraryHistory(
  BuildContext context,
  WorkspaceSource source,
  WorkspaceRecordRef ref,
) => showDesktopDialog<bool>(
  context,
  builder: (_) => _HistoryDialog(source: source, ref: ref),
);

/// Selectable read-only snapshots, including composite legacy values.
Map<String, String> librarySnapshot(
  WorkspaceArchive archive, {
  bool includeEntries = true,
  bool includeTargetIds = false,
}) {
  final detail = archive.detail, record = detail.record;
  String value(Object? v) => v == null || v == ''
      ? '未填写'
      : v is String
      ? v
      : const JsonEncoder.withIndent('  ').convert(v);
  final labels = <String, String>{
    for (final f in workspaceFields(detail))
      f['key'] as String: f['label'] as String? ?? f['key'] as String,
  };
  final relationLabels = <String, String>{
    for (final r
        in workspaceEditingDefinition(detail)['relations'] as List? ?? [])
      r['key'] as String: r['label'] as String? ?? r['key'] as String,
    'credentials': '凭据',
  };
  String relationLabel(String key) {
    final label = relationLabels[key] ?? key;
    return detail.relations.keys
                .where((k) => (relationLabels[k] ?? k) == label)
                .length >
            1
        ? '$label（$key）'
        : label;
  }

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
      if (includeEntries ||
          !workspaceFields(
            detail,
          ).any((f) => f['key'] == e.key && f['type'] == 'entries'))
        '字段：${labels[e.key] ?? e.key}${e.key.startsWith('retained:')
            ? '（保留${detail.retainedFields.indexWhere((f) => f['key'] == e.key) + 1}）'
            : labels[e.key] != null && labels[e.key] != e.key
            ? '（${e.key}）'
            : ''}': value(
          e.value,
        ),
    for (final e in detail.relations.entries)
      '关联：${relationLabel(e.key)}': e.value.isEmpty
          ? '无关联'
          : e.value
                .map(
                  (r) => archive.targets[r] == null
                      ? '不可用目标（${r.key}）'
                      : '${archive.targets[r]!.name}${includeTargetIds ? '（${r.key}）' : ''}',
                )
                .join('\n'),
    '资料结构': const JsonEncoder.withIndent('  ').convert(detail.definition),
  };
}

class LibrarySnapshotView extends StatefulWidget {
  const LibrarySnapshotView({super.key, required this.archive});
  final WorkspaceArchive archive;
  @override
  State<LibrarySnapshotView> createState() => _LibrarySnapshotViewState();
}

class _LibrarySnapshotViewState extends State<LibrarySnapshotView> {
  final _reading = DocumentReadingController();
  @override
  void dispose() {
    _reading.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final archive = widget.archive;
    final detail = archive.detail;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(detail.record.name, style: libraryHeading(context, 20)),
        const SizedBox(height: 8),
        Text(
          '${detail.record.type.name} · ${archive.directoryName ?? '未分类'}',
          style: libraryText(context, 13, color: UiPalette.of(context).muted),
        ),
        Text(
          '保存于 ${libraryLocalDateTime(archive.archivedAt)}',
          style: libraryText(context, 12, color: UiPalette.of(context).muted),
        ),
        if (detail.record.description.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              detail.record.description,
              style: libraryText(context, 14),
            ),
          ),
        TemplateRecordContent(
          detail: detail,
          relations: _ArchiveRelations(archive),
          onOpen: null,
          documentController: _reading,
          fileBuilder: (key) {
            final raw = detail.values[key];
            final version = raw is Map ? raw['version'] : null;
            final name = raw is Map ? raw['filename'] : null;
            return ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.insert_drive_file_outlined),
              title: Text(name is String ? name : detail.record.name),
              subtitle: Text(version == null ? '已保存的附件' : '附件 · 第 $version 版'),
            );
          },
          credentialBuilder: (_) => const Text('凭据内容不在历史预览中展示。'),
        ),
      ],
    );
  }
}

class _ArchiveRelations implements WorkspaceRelationSource {
  _ArchiveRelations(this.archive);
  final WorkspaceArchive archive;
  @override
  Future<List<WorkspaceRecordSummary>> readSummaries(
    Iterable<WorkspaceRecordRef> refs,
  ) async => [
    for (final ref in refs)
      if (archive.targets[ref] != null) archive.targets[ref]!,
  ];
  @override
  Future<WorkspaceResults> queryRelationCandidates(
    WorkspaceRelationQuery query,
  ) async => WorkspaceResults(items: const [], total: 0, offset: 0);
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
  WorkspaceFailure? _readFailure;
  late final RecordMutation _mutation;
  WorkspaceFailure? get _failure => _mutation.failure ?? _readFailure;
  bool get _busy => _mutation.busy;
  bool get _locked => _mutation.frozen;
  String? _notice;
  bool _loading = true;
  int _generation = 0;
  void _mutationChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    ++_generation;
    _mutation.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _mutation = RecordMutation(widget.source)..addListener(_mutationChanged);
    _reload();
  }

  Future<void> _reload() async {
    if (_locked) return;
    _mutation.acceptCurrentVersion();
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _preview = null;
      _readFailure = null;
      _notice = null;
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
        setState(() => _readFailure = error);
      }
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(
          () => _readFailure = const WorkspaceFailure(
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
    if (_locked) return;
    _mutation.acceptCurrentVersion();
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _preview = null;
      _readFailure = null;
      _notice = null;
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
        setState(() => _readFailure = error);
      }
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(
          () => _readFailure = const WorkspaceFailure(
            'unavailable',
            '暂时无法比较内容，请重试。',
          ),
        );
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _reconcile() async {
    final receipt = await _mutation.reconcile();
    if (!mounted) return;
    if (receipt != null) {
      Navigator.pop(context, true);
    } else if (!_mutation.uncertain) {
      setState(() => _notice = '已确认尚未提交，可重新恢复所选版本。');
    }
  }

  Future<void> _restore() async {
    if (!_mutation.canSubmit || _preview == null || !_preview!.canRestore) {
      return;
    }
    final preview = _preview!;
    _notice = null;
    final intent = WorkspaceOperationIntent(
      kind: WorkspaceOperationKind.restoreRevision,
      ref: widget.ref,
      expectedVersion: preview.current.version,
      expectedCatalogVersion: preview.catalogVersion,
      revisionVersion: preview.archive.detail.version,
    );
    final result = await _mutation.submit(
      intent,
      (id) => widget.source.changeRecord(
        WorkspaceRecordChange(
          operationId: id,
          ref: widget.ref,
          expectedVersion: preview.current.version,
          expectedCatalogVersion: preview.catalogVersion,
          action: WorkspaceRecordAction.restoreRevision,
          revisionVersion: preview.archive.detail.version,
        ),
      ),
    );
    if (mounted && result != null) Navigator.pop(context, true);
  }

  Widget _comparison(WorkspaceRevisionPreview preview) {
    final before = librarySnapshot(_currentArchive!),
        old = librarySnapshot(preview.archive),
        beforeIdentity = librarySnapshot(
          _currentArchive!,
          includeTargetIds: true,
        ),
        oldIdentity = librarySnapshot(preview.archive, includeTargetIds: true);
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
        for (final key in {
          ...before.keys,
          ...old.keys,
        }.where((k) => k != '资料结构'))
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
                  '当前${beforeIdentity[key] == oldIdentity[key]
                      ? ' · 未变化'
                      : key.startsWith('关联：')
                      ? ' · 关联对象有变化'
                      : ''}',
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
        ExpansionTile(
          key: const ValueKey('history-structure-details'),
          tilePadding: EdgeInsets.zero,
          title: Text(
            before['资料结构'] == old['资料结构']
                ? '资料结构与关联标识（结构未变化）'
                : '资料结构与关联标识（结构有变化，展开核对）',
            style: libraryText(context, 14, weight: FontWeight.w600),
          ),
          children: [
            if (before['资料结构'] != old['资料结构']) ...[
              const Text('当前资料结构'),
              SelectableText(before['资料结构']!),
              const SizedBox(height: 10),
              Text('历史 v${preview.archive.detail.version} 的资料结构'),
            ],
            SelectableText(old['资料结构']!),
            for (final key in {
              ...beforeIdentity.keys,
              ...oldIdentity.keys,
            }.where((k) => k.startsWith('关联：'))) ...[
              const SizedBox(height: 12),
              Text('$key · 对象标识'),
              Text('当前：${beforeIdentity[key] ?? '无此关联'}'),
              Text('历史：${oldIdentity[key] ?? '无此关联'}'),
            ],
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => PopScope<bool>(
    canPop: !_locked,
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
                      onPressed: _locked ? null : () => _select(r),
                      child: Text(
                        'v${r.version} · ${r.record.name}\n${r.archivedAt.toIso8601String().substring(0, 16).replaceFirst('T', ' ')}',
                      ),
                    ),
                ],
              ),
      ),
      actions: [
        if (_notice != null)
          SizedBox(
            width: double.infinity,
            child: Semantics(liveRegion: true, child: Text(_notice!)),
          ),
        if (_mutation.uncertain)
          DesktopButton(
            key: const ValueKey('library-history-reconcile'),
            onPressed: _busy ? null : _reconcile,
            child: const Text('核对结果'),
          ),
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
            onPressed: _locked ? null : _reload,
            child: const Text('重新读取版本'),
          ),
        DesktopButton(
          onPressed: _locked ? null : () => Navigator.maybePop(context),
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
