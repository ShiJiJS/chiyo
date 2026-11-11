import 'package:flutter/material.dart';
import '../desktop_controls.dart';
import '../ui_palette.dart';
import 'library_widgets.dart';
import 'workspace_source.dart';

typedef GrantHistoryFilters = ({
  WorkspaceGrantFilter state,
  WorkspaceApprovalKind? kind,
  int? days,
});

String grantFilterLabel(WorkspaceGrantFilter value) => switch (value) {
  WorkspaceGrantFilter.all => '全部',
  WorkspaceGrantFilter.active => '有效',
  WorkspaceGrantFilter.ended => '已结束',
};

/// Edits a draft inside the popup; applying it performs one history query.
class GrantHistoryFiltersPopup extends StatefulWidget {
  const GrantHistoryFiltersPopup({super.key, required this.initial});
  final GrantHistoryFilters initial;
  @override
  State<GrantHistoryFiltersPopup> createState() =>
      _GrantHistoryFiltersPopupState();
}

class _GrantHistoryFiltersPopupState extends State<GrantHistoryFiltersPopup> {
  late GrantHistoryFilters _draft = widget.initial;

  Widget _section<T>(
    String title,
    T selected,
    Map<T, String> choices,
    ValueChanged<T> select,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(title, style: libraryHeading(context, 14)),
      const SizedBox(height: 10),
      Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final entry in choices.entries)
            ChoiceChip(
              checkmarkColor: UiPalette.of(context).accent,
              key: ValueKey('grant-choice-$title-${entry.key}'),
              label: Text(entry.value),
              selected: selected == entry.key,
              onSelected: (_) => setState(() => select(entry.key)),
            ),
        ],
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => Padding(
    key: const ValueKey('grant-filters-popover'),
    padding: const EdgeInsets.all(18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text('筛选记录', style: libraryHeading(context, 17))),
            IconButton(
              tooltip: '关闭筛选',
              onPressed: () => Navigator.of(context).pop(),
              icon: Icon(
                Icons.close,
                size: 18,
                color: UiPalette.of(context).muted,
              ),
            ),
          ],
        ),
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _section(
                  '状态',
                  _draft.state,
                  {
                    for (final v in WorkspaceGrantFilter.values)
                      v: grantFilterLabel(v),
                  },
                  (v) =>
                      _draft = (state: v, kind: _draft.kind, days: _draft.days),
                ),
                const SizedBox(height: 20),
                _section<WorkspaceApprovalKind?>(
                  '类型',
                  _draft.kind,
                  {
                    null: '所有类型',
                    for (final v in WorkspaceApprovalKind.values) v: v.label,
                  },
                  (v) => _draft = (
                    state: _draft.state,
                    kind: v,
                    days: _draft.days,
                  ),
                ),
                const SizedBox(height: 20),
                _section<int?>(
                  '时间',
                  _draft.days,
                  {null: '所有时间', 1: '最近1天', 7: '最近7天', 30: '最近30天'},
                  (v) => _draft = (
                    state: _draft.state,
                    kind: _draft.kind,
                    days: v,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            DesktopButton(
              kind: DesktopButtonKind.quiet,
              onPressed: () => setState(
                () => _draft = (
                  state: WorkspaceGrantFilter.all,
                  kind: null,
                  days: null,
                ),
              ),
              child: const Text('重置'),
            ),
            const Spacer(),
            DesktopButton(
              key: const ValueKey('grant-filters-apply'),
              kind: DesktopButtonKind.primary,
              onPressed: () => Navigator.of(context).pop(_draft),
              child: const Text('应用筛选'),
            ),
          ],
        ),
      ],
    ),
  );
}
