import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../anchored_surface.dart';
import '../desktop_controls.dart';
import '../ui_palette.dart';
import 'library_widgets.dart';
import 'workspace_source.dart';

Widget _relationIdentity(BuildContext context, WorkspaceRecordSummary record) =>
    Row(
      children: [
        RecordIcon(record.type, size: 29),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                record.name,
                style: libraryText(context, 14, weight: FontWeight.w600),
              ),
              Text(
                '${record.type.name} · ${record.description}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: libraryText(
                  context,
                  12,
                  color: UiPalette.of(context).muted,
                ),
              ),
            ],
          ),
        ),
      ],
    );

/// Metadata identities remain in the form when the candidate menu closes.
/// All changes are drafts until the containing record is explicitly saved.
class LibraryRelationPicker extends StatefulWidget {
  const LibraryRelationPicker({
    super.key,
    required this.source,
    required this.typeId,
    required this.relationKey,
    required this.label,
    required this.selected,
    required this.onChanged,
    this.record,
    this.enabled = true,
    this.errorText,
  });
  final WorkspaceSource source;
  final String typeId, relationKey, label;
  final WorkspaceRecordRef? record;
  final List<WorkspaceRecordRef> selected;
  final ValueChanged<List<WorkspaceRecordRef>> onChanged;
  final bool enabled;
  final String? errorText;
  @override
  State<LibraryRelationPicker> createState() => _LibraryRelationPickerState();
}

class _LibraryRelationPickerState extends State<LibraryRelationPicker> {
  final _triggerFocus = FocusNode();
  final _popup = AnchoredSurfaceController();
  bool _open = false, _selectedLoading = false;
  int _selectedGeneration = 0;
  String? _selectedError;
  Map<WorkspaceRecordRef, WorkspaceRecordSummary> _summaries = {};

  @override
  void initState() {
    super.initState();
    unawaited(_readSelected());
  }

  @override
  void didUpdateWidget(covariant LibraryRelationPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!listEquals(oldWidget.selected, widget.selected)) {
      unawaited(_readSelected());
    }
    if (!widget.enabled && _open) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _popup.close?.call());
    }
  }

  @override
  void dispose() {
    ++_selectedGeneration;
    final close = _popup.close;
    if (close != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => close());
    }
    _triggerFocus.dispose();
    super.dispose();
  }

  Future<void> _readSelected() async {
    final generation = ++_selectedGeneration;
    _selectedLoading = widget.selected.isNotEmpty;
    _selectedError = null;
    if (widget.selected.isEmpty) {
      _summaries = {};
      return;
    }
    try {
      final summaries = await widget.source.readSummaries(widget.selected);
      if (!mounted || generation != _selectedGeneration) return;
      setState(() => _summaries = {for (final r in summaries) r.ref: r});
    } catch (_) {
      if (mounted && generation == _selectedGeneration) {
        setState(() => _selectedError = '关联名称暂时无法读取；已选范围保留。');
      }
    } finally {
      if (mounted && generation == _selectedGeneration) {
        setState(() => _selectedLoading = false);
      }
    }
  }

  Future<void> _show(BuildContext trigger) async {
    if (!widget.enabled || _open) return;
    setState(() => _open = true);
    try {
      await showAnchoredSurface<void>(
        trigger,
        controller: _popup,
        width: 520,
        height: 460 * MediaQuery.textScalerOf(context).scale(1),
        builder: (_) => _RelationCandidates(
          source: widget.source,
          typeId: widget.typeId,
          relationKey: widget.relationKey,
          label: widget.label,
          record: widget.record,
          selected: widget.selected,
          onChanged: (refs) {
            if (mounted && widget.enabled) widget.onChanged(refs);
          },
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _open = false);
        _triggerFocus.requestFocus();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = UiPalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          runSpacing: 8,
          children: [
            Text(
              '${widget.label} · 已选${widget.selected.length}项',
              style: libraryText(context, 14, weight: FontWeight.w600),
            ),
            Builder(
              builder: (trigger) => DesktopButton(
                key: ValueKey('library-relation-choose-${widget.relationKey}'),
                focusNode: _triggerFocus,
                onPressed: widget.enabled ? () => _show(trigger) : null,
                child: const Text('选择已有资料'),
              ),
            ),
          ],
        ),
        if (_selectedError != null) ...[
          Text(
            _selectedError!,
            style: libraryText(context, 13, color: c.danger),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: DesktopButton(
              onPressed: _readSelected,
              child: const Text('重读关联名称'),
            ),
          ),
        ],
        for (final ref in widget.selected)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              children: [
                Expanded(
                  child: _summaries[ref] != null
                      ? _relationIdentity(context, _summaries[ref]!)
                      : Text(
                          _selectedLoading
                              ? '正在读取关联资料…'
                              : _selectedError != null
                              ? '关联名称暂不可用'
                              : '关联目标已不可用',
                          style: libraryText(context, 13, color: c.muted),
                        ),
                ),
                const SizedBox(width: 8),
                DesktopButton(
                  key: ValueKey(
                    'library-relation-remove-${widget.relationKey}-${ref.key}',
                  ),
                  kind: DesktopButtonKind.quiet,
                  onPressed: widget.enabled
                      ? () => widget.onChanged(
                          widget.selected.where((r) => r != ref).toList(),
                        )
                      : null,
                  child: const Text('移除'),
                ),
              ],
            ),
          ),
        if (widget.errorText != null)
          Text(
            widget.errorText!,
            style: libraryText(context, 13, color: c.danger),
          ),
      ],
    );
  }
}

class _RelationCandidates extends StatefulWidget {
  const _RelationCandidates({
    required this.source,
    required this.typeId,
    required this.relationKey,
    required this.label,
    required this.selected,
    required this.onChanged,
    this.record,
  });
  final WorkspaceSource source;
  final String typeId, relationKey, label;
  final WorkspaceRecordRef? record;
  final List<WorkspaceRecordRef> selected;
  final ValueChanged<List<WorkspaceRecordRef>> onChanged;
  @override
  State<_RelationCandidates> createState() => _RelationCandidatesState();
}

class _RelationCandidatesState extends State<_RelationCandidates> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  late List<WorkspaceRecordRef> _selected;
  bool _loading = false;
  int _generation = 0;
  WorkspaceResults? _results;
  WorkspaceFailure? _failure;
  static const _pageSize = 15;

  @override
  void initState() {
    super.initState();
    _selected = List.of(widget.selected);
    unawaited(_load(0));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    ++_generation;
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> _load(int offset) async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _failure = null;
    });
    try {
      final results = await widget.source.queryRelationCandidates(
        WorkspaceRelationQuery(
          typeId: widget.typeId,
          key: widget.relationKey,
          source: widget.record,
          keyword: _search.text,
          offset: offset,
          limit: _pageSize,
        ),
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _results = results;
        _loading = false;
      });
    } on WorkspaceFailure catch (failure) {
      if (mounted && generation == _generation) {
        setState(() {
          _failure = failure;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() {
          _failure = const WorkspaceFailure('unavailable', '暂时无法查找关联资料。');
          _loading = false;
        });
      }
    }
  }

  void _select(WorkspaceRecordRef ref) {
    setState(
      () => _selected = _selected.contains(ref)
          ? _selected.where((r) => r != ref).toList()
          : [..._selected, ref],
    );
    widget.onChanged(List.unmodifiable(_selected));
  }

  @override
  Widget build(BuildContext context) {
    final c = UiPalette.of(context), results = _results;
    Widget body;
    if (_failure != null) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _failure!.message,
                style: libraryText(context, 13, color: c.danger),
              ),
              const SizedBox(height: 10),
              DesktopButton(
                onPressed: _loading ? null : () => _load(results?.offset ?? 0),
                child: const Text('重试查找'),
              ),
            ],
          ),
        ),
      );
    } else if (results != null && results.items.isEmpty) {
      body = const Center(
        child: Padding(
          padding: EdgeInsets.all(12),
          child: Text('没有匹配的关联资料；可调整查找。'),
        ),
      );
    } else {
      body = ListView(
        padding: const EdgeInsets.fromLTRB(7, 0, 7, 7),
        children: [
          for (final record in results?.items ?? <WorkspaceRecordSummary>[])
            Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: DesktopButton(
                key: ValueKey(
                  'library-relation-option-${widget.relationKey}-${record.ref.key}',
                ),
                kind: DesktopButtonKind.quiet,
                selected: _selected.contains(record.ref),
                onPressed: _loading ? null : () => _select(record.ref),
                padding: const EdgeInsets.all(9),
                child: Row(
                  children: [
                    Expanded(child: _relationIdentity(context, record)),
                    const SizedBox(width: 8),
                    Text(
                      _selected.contains(record.ref) ? '已选' : '选择',
                      style: libraryText(context, 12, color: c.accent),
                    ),
                  ],
                ),
              ),
            ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: libraryText(context, 13, weight: FontWeight.w600),
                ),
              ),
              const SizedBox(width: 8),
              DesktopButton(
                key: ValueKey('library-relation-done-${widget.relationKey}'),
                kind: DesktopButtonKind.quiet,
                onPressed: () => Navigator.pop(context),
                child: const Text('完成选择'),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: DesktopTextField(
            key: ValueKey('library-relation-search-${widget.relationKey}'),
            controller: _search,
            focusNode: _searchFocus,
            onChanged: (_) => unawaited(_load(0)),
            decoration: const InputDecoration(
              labelText: '查找已有资料',
              hintText: '名称、用途、类型或标签',
            ),
          ),
        ),
        if (_loading)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              '正在查找关联资料…',
              style: libraryText(context, 12, color: c.muted),
            ),
          ),
        Expanded(child: body),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Wrap(
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 5,
            children: [
              Text(
                '找到${_failure == null ? results?.total ?? 0 : '—'}项 · 共选${_selected.length}项',
                style: libraryText(context, 12, color: c.muted),
              ),
              DesktopButton(
                onPressed:
                    !_loading &&
                        _failure == null &&
                        results != null &&
                        results.offset > 0
                    ? () => _load(
                        (results.offset - _pageSize).clamp(0, results.total),
                      )
                    : null,
                child: const Text('上一页'),
              ),
              DesktopButton(
                onPressed:
                    !_loading &&
                        _failure == null &&
                        results != null &&
                        results.offset + _pageSize < results.total
                    ? () => _load(results.offset + _pageSize)
                    : null,
                child: const Text('下一页'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
