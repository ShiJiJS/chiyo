import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart';
import 'prototype_ui.dart';
import 'ui_palette.dart';

class ProposalQueue extends StatelessWidget {
  const ProposalQueue({
    super.key,
    required this.page,
    required this.focused,
    required this.search,
    required this.searchFocus,
    required this.selectedFocus,
    required this.filter,
    required this.onSearch,
    required this.onFilter,
    required this.onPage,
    required this.onSelect,
    this.queryFailed = false,
  });
  final ProposalPage page;
  final String? focused;
  final TextEditingController search;
  final FocusNode searchFocus, selectedFocus;
  final ProposalFilter filter;
  final ValueChanged<String> onSearch, onSelect;
  final bool queryFailed;
  final ValueChanged<ProposalFilter> onFilter;
  final ValueChanged<int> onPage;
  @override
  Widget build(BuildContext context) {
    final p = UiPalette.of(context);
    Text text(
      String value,
      double size, {
      Color? color,
      FontWeight weight = FontWeight.w400,
      String? family,
      double height = 1.5,
    }) => Text(
      value,
      style: prototypeText(
        context,
        size,
        color: color,
        weight: weight,
        family: family,
        height: height,
      ),
    );
    return Container(
      key: const ValueKey('proposal-queue'),
      decoration: BoxDecoration(
        color: p.rail,
        border: Border(right: BorderSide(color: p.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(21, 28, 21, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: 31.5 * MediaQuery.textScalerOf(context).scale(1),
                  ),
                  child: Row(
                    children: [
                      text('录入提案', 21, weight: FontWeight.w600),
                      const Spacer(),
                      text(
                        queryFailed ? '—' : '${page.allCount}',
                        24,
                        color: p.muted,
                        family: 'Georgia',
                        height: 1.2,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 22),
                Container(
                  constraints: const BoxConstraints(minHeight: 41.5),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 9.5,
                  ),
                  decoration: BoxDecoration(
                    color: p.canvas,
                    border: Border.all(color: p.line),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    children: [
                      PrototypeIcon(PrototypeIconGlyph.search, color: p.muted),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          key: const ValueKey('proposal-search'),
                          controller: search,
                          focusNode: searchFocus,
                          maxLength: 2000,
                          style: prototypeText(context, 13),
                          decoration: InputDecoration(
                            isCollapsed: true,
                            isDense: true,
                            filled: false,
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            contentPadding: EdgeInsets.zero,
                            counterText: '',
                            hintText: '搜索提案、提交方',
                            hintStyle: prototypeText(
                              context,
                              13,
                              color: p.muted,
                            ),
                          ),
                          onChanged: onSearch,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 22),
                Wrap(
                  children: [
                    for (final f in ProposalFilter.values)
                      Padding(
                        padding: const EdgeInsets.only(right: 21),
                        child: Container(
                          decoration: BoxDecoration(
                            border: filter == f
                                ? Border(
                                    bottom: BorderSide(
                                      color: p.accent,
                                      width: 2,
                                    ),
                                  )
                                : null,
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 8,
                          ),
                          child: TextButton(
                            key: ValueKey('proposal-filter-${f.name}'),
                            style: prototypeButton(
                              context,
                              size: 12,
                              foreground: filter == f ? p.strong : p.muted,
                              weight: filter == f
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                            ),
                            onPressed: () => onFilter(f),
                            child: Text(switch (f) {
                              ProposalFilter.pending =>
                                queryFailed
                                    ? '待确认'
                                    : '待确认 ${page.pendingCount}',
                              ProposalFilter.handled =>
                                queryFailed
                                    ? '已处理'
                                    : '已处理 ${page.allCount - page.pendingCount}',
                              ProposalFilter.all =>
                                queryFailed ? '全部' : '全部 ${page.allCount}',
                            }),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          Divider(height: 1, color: p.line),
          Expanded(
            child: ListView(
              primary: false,
              padding: EdgeInsets.zero,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(21, 17, 21, 12),
                  child: Row(
                    children: [
                      Expanded(child: text('提案与整理结果', 12, color: p.muted)),
                      text('最新提交优先', 12, color: p.muted),
                    ],
                  ),
                ),
                for (final entry in page.entries)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Material(
                      color: entry.id == focused
                          ? p.selected
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(
                        entry.id == focused ? 6 : 0,
                      ),
                      child: InkWell(
                        key: ValueKey('proposal-entry-${entry.id}'),
                        focusNode: entry.id == focused ? selectedFocus : null,
                        onTap: () => onSelect(entry.id),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 19,
                          ),
                          decoration: BoxDecoration(
                            border: entry.id == focused
                                ? Border.all(
                                    color: Color.lerp(p.line, p.accent, .3)!,
                                  )
                                : Border(
                                    top: const BorderSide(
                                      color: Colors.transparent,
                                    ),
                                    left: const BorderSide(
                                      color: Colors.transparent,
                                    ),
                                    right: const BorderSide(
                                      color: Colors.transparent,
                                    ),
                                    bottom: BorderSide(color: p.line),
                                  ),
                            borderRadius: BorderRadius.circular(
                              entry.id == focused ? 6 : 0,
                            ),
                          ),
                          child: Column(
                            children: [
                              ConstrainedBox(
                                constraints: BoxConstraints(
                                  minHeight:
                                      22.4 *
                                      MediaQuery.textScalerOf(context).scale(1),
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        entry.chatLabel.isEmpty
                                            ? '${entry.kindLabel}提案'
                                            : entry.chatLabel,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: prototypeText(
                                          context,
                                          14,
                                          weight: FontWeight.w700,
                                          height: 1.6,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 7),
                                    text(
                                      '${entry.createdAt.toLocal().hour.toString().padLeft(2, '0')}:${entry.createdAt.toLocal().minute.toString().padLeft(2, '0')}',
                                      11,
                                      color: p.muted,
                                      family: 'Consolas',
                                      height: 1.6,
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 7),
                              Row(
                                children: [
                                  Expanded(
                                    child: text(
                                      '${entry.kindLabel} · ${entry.count} 条信息${entry.changeCount == 0 ? '' : ' · ${entry.changeCount} 处修改'}',
                                      12,
                                      color: p.muted,
                                    ),
                                  ),
                                  text(
                                    entry.stateLabel,
                                    12,
                                    color:
                                        entry.pending ||
                                            entry.status ==
                                                ProposalStatus.conflicted
                                        ? p.statusAttention
                                        : p.muted,
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                if (page.entries.isEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(22, 30, 22, 30),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        text(queryFailed ? '提案查询失败' : '没有找到提案', 15),
                        const SizedBox(height: 8),
                        text(
                          queryFailed ? '请检查服务状态后重试。' : '调整关键词或查看全部提案。',
                          13,
                          color: p.muted,
                        ),
                        const SizedBox(height: 18),
                        TextButton(
                          style: prototypeButton(
                            context,
                            size: 13,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 13,
                              vertical: 7,
                            ),
                            side: BorderSide(color: p.line),
                          ),
                          onPressed: () {
                            search.clear();
                            onSearch('');
                            onFilter(ProposalFilter.all);
                          },
                          child: const Text('清除筛选'),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 12),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: p.line)),
            ),
            child: Row(
              children: [
                text(
                  queryFailed ? '查询失败' : '${page.total} 条提案',
                  12,
                  color: p.muted,
                ),
                const Spacer(),
                SizedBox(
                  width: 24,
                  height: 26,
                  child: TextButton(
                    style: prototypeButton(context, size: 20),
                    onPressed: page.offset == 0
                        ? null
                        : () => onPage(page.offset - page.limit),
                    child: const Tooltip(message: '上一页提案', child: Text('‹')),
                  ),
                ),
                const SizedBox(width: 7),
                text(
                  queryFailed
                      ? '— / —'
                      : '${page.offset ~/ page.limit + 1} / ${((page.total + page.limit - 1) ~/ page.limit).clamp(1, 999999)}',
                  12,
                  color: p.muted,
                ),
                const SizedBox(width: 7),
                SizedBox(
                  width: 24,
                  height: 26,
                  child: TextButton(
                    style: prototypeButton(context, size: 20),
                    onPressed: page.offset + page.limit >= page.total
                        ? null
                        : () => onPage(page.offset + page.limit),
                    child: const Tooltip(message: '下一页提案', child: Text('›')),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
