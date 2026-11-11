import 'dart:async';
import 'package:flutter/material.dart';
import '../desktop_controls.dart';
import '../desktop_feedback.dart';
import '../ui_palette.dart';
import 'library_history_dialog.dart';
import 'library_credential_lifecycle.dart';
import 'library_widgets.dart';
import 'workspace_source.dart';
import 'record_mutation.dart';
import 'recycled_attachment_preview.dart';
import 'library_batch_recycle_dialog.dart';

Future<WorkspaceRecordReceipt?> showLibraryRecycle(
  BuildContext context,
  WorkspaceSource source, {
  WorkspaceDetail? current,
  WorkspaceRecycleEntry? entry,
}) =>
    (current?.record.ref ?? entry?.record.ref)?.kind ==
        WorkspaceRecordKind.credential
    ? showCredentialRecycle(
        context,
        source,
        ref: current?.record.ref,
        entry: entry,
      )
    : showDesktopDialog<WorkspaceRecordReceipt>(
        context,
        builder: (_) =>
            _RecycleDialog(source: source, current: current, entry: entry),
      );

class _RecycleDialog extends StatefulWidget {
  const _RecycleDialog({required this.source, this.current, this.entry});
  final WorkspaceSource source;
  final WorkspaceDetail? current;
  final WorkspaceRecycleEntry? entry;
  @override
  State<_RecycleDialog> createState() => _RecycleDialogState();
}

class _RecycleDialogState extends State<_RecycleDialog> {
  WorkspaceArchive? _archive;
  WorkspaceCatalog? _catalog;
  WorkspaceFailure? _readFailure;
  late final RecordMutation _mutation;
  WorkspaceFailure? get _failure => _mutation.failure ?? _readFailure;
  bool get _busy => _mutation.busy;
  bool get _locked => _mutation.frozen;
  String? _notice;
  int? _currentVersion;
  bool _loading = true, _purge = false;
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
      _readFailure = null;
      _notice = null;
      _purge = false;
    });
    try {
      final catalog = await widget.source.loadCatalog();
      final archive = widget.entry != null
          ? await widget.source.readRecycled(widget.entry!.id)
          : null;
      // Fresh read detects an object changed while the confirmation was open.
      final current = widget.current != null
          ? await widget.source.readDetail(widget.current!.record.ref)
          : null;
      int? liveVersion;
      if (widget.entry?.wholeItem == false) {
        try {
          liveVersion = (await widget.source.readDetail(
            widget.entry!.record.ref,
          )).version;
        } on WorkspaceFailure catch (e) {
          if (e.code != 'not_found') rethrow;
        }
      }
      if (!mounted || generation != _generation) return;
      setState(() {
        _catalog = catalog;
        _currentVersion = liveVersion;
        _archive =
            archive ??
            WorkspaceArchive(
              detail: current!,
              archivedAt: current.record.updatedAt,
              directoryName: catalog.directories
                  .where((d) => d.id == current.record.directoryId)
                  .firstOrNull
                  ?.name,
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
            '暂时无法读取资料，请重试。',
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
      Navigator.pop(context, receipt);
    } else if (!_mutation.uncertain) {
      setState(() => _notice = '已确认尚未提交，可重新执行已核对的操作。');
    }
  }

  Future<void> _submit() async {
    if (!_mutation.canSubmit || _archive == null || _catalog == null) return;
    final current = _archive!.detail, entry = widget.entry;
    _notice = null;
    final change = WorkspaceRecordChange(
      operationId: '',
      ref: current.record.ref,
      expectedVersion: entry?.version ?? current.version,
      expectedCatalogVersion: _catalog!.version,
      expectedCurrentVersion: _currentVersion,
      entryId: entry?.id,
      action: entry == null
          ? WorkspaceRecordAction.recycle
          : _purge
          ? WorkspaceRecordAction.purge
          : WorkspaceRecordAction.restoreRecycled,
    );
    final result = await _mutation.submit(
      WorkspaceOperationIntent.change(change),
      (id) => widget.source.changeRecord(
        WorkspaceRecordChange(
          operationId: id,
          ref: change.ref,
          expectedVersion: change.expectedVersion,
          expectedCatalogVersion: change.expectedCatalogVersion,
          expectedCurrentVersion: change.expectedCurrentVersion,
          entryId: change.entryId,
          action: change.action,
        ),
      ),
    );
    if (mounted && result != null) Navigator.pop(context, result);
  }

  @override
  Widget build(BuildContext context) {
    final deleting = widget.entry == null, c = UiPalette.of(context);
    return PopScope<WorkspaceRecordReceipt>(
      canPop: !_locked,
      child: DesktopDialog(
        key: ValueKey('recycle-mode-$_purge'),
        title: Text(
          deleting
              ? '移到回收站'
              : _purge
              ? widget.entry?.wholeItem == false
                    ? '永久清理回收字段'
                    : '永久清理资料'
              : '回收内容',
        ),
        content: SizedBox(
          width: 680,
          child: _loading
              ? const Text('正在读取资料…')
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_archive != null) ...[
                      Text(
                        _archive!.detail.record.name,
                        style: libraryText(
                          context,
                          19,
                          weight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        deleting
                            ? '回收后从信息库移除，30天内可在回收站恢复。旧授权不会恢复。'
                            : _purge
                            ? widget.entry?.wholeItem == false
                                  ? '清理这批旧字段及包含它们的旧版本，保留当前资料和其他版本。此操作无法撤销。'
                                  : '永久清理后无法从回收站或内容版本恢复。请核对以上资料名称。'
                            : widget.entry?.wholeItem == false
                            ? '这里只恢复回收字段，不覆盖当前资料。同位置已有新字段时保留两份内容；恢复使用新身份，不恢复旧授权。当前资料${_currentVersion == null ? '已不可用，仍可永久清理' : 'v$_currentVersion'}。'
                            : '内容将在回收后30天到期。恢复不会重新启用旧授权；已移除的目录、标签及关联不会复活。',
                        style: TextStyle(color: _purge ? c.danger : c.muted),
                      ),
                      const SizedBox(height: 20),
                      if (!deleting && !_purge && widget.entry!.wholeItem)
                        Text(
                          '恢复后位置：${directoryPath(_catalog!, _catalog!.directories.any((d) => d.id == _archive!.detail.record.directoryId) ? _archive!.detail.record.directoryId : null)}',
                          style: libraryText(context, 13),
                        ),
                      if (!deleting && !_purge)
                        LibrarySnapshotView(
                          archive: _archive!,
                          fileBuilder: widget.source is! WorkspaceRecycledFiles
                              ? null
                              : (key) => RecycledAttachmentPreview(
                                  source: widget.source,
                                  entryId: widget.entry!.id,
                                  fieldKey: key,
                                ),
                        ),
                    ],
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
              key: const ValueKey('library-recycle-reconcile'),
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
                  key: const ValueKey('library-recycle-error'),
                  style: TextStyle(color: c.danger),
                ),
              ),
            ),
          if (_failure != null)
            DesktopButton(
              onPressed: _locked ? null : _reload,
              child: const Text('重新读取'),
            ),
          if (!deleting && !_purge)
            DesktopButton(
              key: const ValueKey('library-recycle-purge'),
              kind: DesktopButtonKind.danger,
              onPressed: _locked || _loading || _archive == null
                  ? null
                  : () => setState(() {
                      _mutation.acceptCurrentVersion();
                      _purge = true;
                      _readFailure = null;
                      _notice = null;
                    }),
              child: const Text('永久清理…'),
            ),
          DesktopButton(
            onPressed: _locked
                ? null
                : () {
                    if (_purge) {
                      setState(() => _purge = false);
                    } else {
                      Navigator.maybePop(context);
                    }
                  },
            child: Text(_purge ? '返回查看' : '取消'),
          ),
          DesktopButton(
            key: const ValueKey('library-recycle-submit'),
            kind: deleting || _purge
                ? DesktopButtonKind.danger
                : DesktopButtonKind.primary,
            busy: _busy,
            onPressed:
                _loading ||
                    _archive == null ||
                    _failure != null ||
                    (!_purge &&
                        widget.entry?.wholeItem == false &&
                        _currentVersion == null)
                ? null
                : _submit,
            child: Text(
              deleting
                  ? '移到回收站'
                  : _purge
                  ? '确认永久清理'
                  : widget.entry?.wholeItem == false
                  ? '恢复字段'
                  : '恢复资料',
            ),
          ),
        ],
      ),
    );
  }
}

class LibraryRecyclePage extends StatefulWidget {
  const LibraryRecyclePage({
    super.key,
    required this.source,
    required this.onBack,
    required this.onOpen,
    this.onModalChanged,
  });
  final WorkspaceSource source;
  final VoidCallback onBack;
  final ValueChanged<WorkspaceRecordRef> onOpen;
  final ValueChanged<bool>? onModalChanged;
  @override
  State<LibraryRecyclePage> createState() => _LibraryRecyclePageState();
}

class _LibraryRecyclePageState extends State<LibraryRecyclePage> {
  late StreamSubscription<WorkspaceRecordRef?> _subscription;
  WorkspaceRecycleResults? _results;
  WorkspaceFailure? _failure;
  bool _loading = true;
  int _generation = 0, _offset = 0;
  final _search = TextEditingController();
  WorkspaceRecordRef? _restored;
  @override
  void initState() {
    super.initState();
    _subscription = widget.source.changes.listen((_) => _load());
    _load();
  }

  @override
  void dispose() {
    ++_generation;
    unawaited(_subscription.cancel());
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _failure = null;
    });
    try {
      final results = await widget.source.queryRecycled(
        keyword: _search.text,
        offset: _offset,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _results = results;
        _offset = results.offset;
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
            '暂时无法读取回收站，请重试。',
          ),
        );
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _view(WorkspaceRecycleEntry entry) async {
    widget.onModalChanged?.call(true);
    try {
      final receipt = await showLibraryRecycle(
        context,
        widget.source,
        entry: entry,
      );
      if (!mounted || receipt == null) return;
      // A restore has a current summary; a permanent purge does not.
      final current = await widget.source.readSummaries([receipt.ref]);
      if (!mounted) return;
      setState(() => _restored = current.isEmpty ? null : receipt.ref);
      await _load();
      if (mounted) {
        DesktopFeedback.show(context, current.isEmpty ? '已永久清理资料' : '已恢复资料');
      }
    } on WorkspaceFailure catch (error) {
      if (mounted) setState(() => _failure = error);
    } catch (_) {
      if (mounted) {
        setState(
          () => _failure = const WorkspaceFailure(
            'unavailable',
            '操作已返回，请重新读取回收站核对结果。',
          ),
        );
      }
    } finally {
      widget.onModalChanged?.call(false);
    }
  }

  Future<void> _viewBatch(WorkspaceDirectoryRecycleBatch batch) async {
    widget.onModalChanged?.call(true);
    try {
      final receipt = await showLibraryBatchRecycle(
        context,
        widget.source,
        batchId: batch.id,
      );
      if (!mounted || receipt == null) return;
      setState(() => _restored = null);
      await _load();
      if (mounted) DesktopFeedback.show(context, '整批目录和内容已恢复');
    } finally {
      widget.onModalChanged?.call(false);
    }
  }

  Widget _batchRow(WorkspaceDirectoryRecycleBatch batch) => Container(
    padding: const EdgeInsets.symmetric(vertical: 18),
    decoration: BoxDecoration(
      border: Border(bottom: BorderSide(color: UiPalette.of(context).line)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          batch.title,
          style: libraryText(context, 16, weight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        Text(
          '整批回收 · ${batch.counts}\n保留至 ${batch.expiresAt.toLocal().toIso8601String().substring(0, 10)}',
          style: libraryText(context, 13, color: UiPalette.of(context).muted),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: DesktopButton(
            key: ValueKey('library-recycle-batch-${batch.id}'),
            onPressed: () => _viewBatch(batch),
            child: const Text('查看与整体恢复'),
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final c = UiPalette.of(context), results = _results;
    return Align(
      alignment: Alignment.topCenter,
      child: SizedBox(
        width: 1040,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 22, 28, 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: DesktopButton(
                      key: const ValueKey('library-recycle-back'),
                      kind: DesktopButtonKind.quiet,
                      onPressed: widget.onBack,
                      child: const Text('返回信息库'),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '回收站',
                    style: libraryText(context, 28, weight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '资料保留30天；恢复后旧授权不会恢复。',
                    style: libraryText(context, 14, color: c.muted),
                  ),
                  const SizedBox(height: 18),
                  DesktopTextField(
                    key: const ValueKey('library-recycle-search'),
                    controller: _search,
                    decoration: const InputDecoration(hintText: '查找回收资料'),
                    onChanged: (_) {
                      _offset = 0;
                      _load();
                    },
                  ),
                  if (_restored != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: DesktopButton(
                          onPressed: () => widget.onOpen(_restored!),
                          child: const Text('查看已恢复资料'),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: _loading
                  ? const Center(child: Text('正在读取回收站…'))
                  : _failure != null
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(_failure!.message),
                          const SizedBox(height: 12),
                          DesktopButton(
                            onPressed: _load,
                            child: const Text('重试'),
                          ),
                        ],
                      ),
                    )
                  : results == null || results.total == 0
                  ? Center(
                      child: Text(
                        _search.text.trim().isEmpty ? '回收站为空' : '没有匹配的回收资料',
                      ),
                    )
                  : ListView.builder(
                      key: const PageStorageKey('library-recycle-list'),
                      padding: const EdgeInsets.symmetric(horizontal: 28),
                      itemCount: results.rows.length,
                      itemBuilder: (context, index) {
                        final row = results.rows[index];
                        if (row.batch != null) return _batchRow(row.batch!);
                        final entry = row.entry!;
                        return Container(
                          padding: const EdgeInsets.symmetric(vertical: 18),
                          decoration: BoxDecoration(
                            border: Border(bottom: BorderSide(color: c.line)),
                          ),
                          child: Wrap(
                            spacing: 20,
                            runSpacing: 12,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              SizedBox(
                                width: 580,
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Text(
                                      entry.record.name,
                                      style: libraryText(
                                        context,
                                        16,
                                        weight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      '${entry.wholeItem ? '整条资料' : '部分字段'} · ${entry.record.type.name} · 原目录：${entry.directoryName ?? (entry.record.directoryId == null ? '未分类' : '原目录已移除')}\n回收于 ${libraryLocalDateTime(entry.deletedAt).substring(0, 10)}',
                                      style: libraryText(
                                        context,
                                        13,
                                        color: c.muted,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              DesktopButton(
                                key: ValueKey(
                                  'library-recycle-view-${entry.id}',
                                ),
                                onPressed: () => _view(entry),
                                child: const Text('查看与恢复'),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
            if (results != null && results.total > 25)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    Text(
                      '${results.offset + 1}–${results.offset + results.rows.length} / ${results.total}',
                    ),
                    DesktopButton(
                      onPressed: _loading || _offset == 0
                          ? null
                          : () {
                              _offset = (_offset - 25).clamp(0, results.total);
                              _load();
                            },
                      child: const Text('上一页'),
                    ),
                    DesktopButton(
                      onPressed: _loading || _offset + 25 >= results.total
                          ? null
                          : () {
                              _offset += 25;
                              _load();
                            },
                      child: const Text('下一页'),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
