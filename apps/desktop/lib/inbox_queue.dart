import 'mac_text_field_accessibility.dart';
import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart';
import 'ui.dart';
import 'prototype_ui.dart';

/// Shared bounded inbox surface; detail/draft state remains with its workspace.
class InboxQueue extends StatelessWidget {
  const InboxQueue({
    super.key,
    required this.page,
    required this.focused,
    required this.searchController,
    required this.searchFocus,
    required this.filter,
    required this.onSearch,
    required this.onFilter,
    required this.onPage,
    required this.onSelected,
    required this.stateLabel,
    required this.scrollController,
  });
  final InboxPage page;
  final String? focused;
  final TextEditingController searchController;
  final FocusNode searchFocus;
  final InboxFilter filter;
  final ValueChanged<String> onSearch, onSelected;
  final ValueChanged<InboxFilter> onFilter;
  final ValueChanged<int> onPage;
  final String Function(InboxEntry) stateLabel;
  final ScrollController scrollController;
  @override
  Widget build(BuildContext context) {
    final c = UiPalette.of(context);
    final muted = prototypeText(context, 11, color: c.muted);
    return Material(
      color: c.rail,
      child: Container(
        decoration: BoxDecoration(
          border: Border(right: BorderSide(color: c.line)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(21, 29, 21, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Text(
                        '请求收件箱',
                        style: prototypeText(
                          context,
                          21,
                          weight: FontWeight.w700,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        '${page.total}',
                        style: prototypeText(
                          context,
                          24,
                          color: c.muted,
                          family: 'Georgia',
                          height: 1.2,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 22),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 9.5,
                    ),
                    decoration: BoxDecoration(
                      color: c.canvas,
                      border: Border.all(color: c.line),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      children: [
                        PrototypeIcon(
                          PrototypeIconGlyph.search,
                          color: c.muted,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: MacTextFieldAccessibility(
                            label: '搜索聊天、信息名称',
                            child: TextField(
                              key: const ValueKey('inbox-search'),
                              controller: searchController,
                              focusNode: searchFocus,
                              maxLength: 2000,
                              style: prototypeText(context, 13),
                              decoration: InputDecoration(
                                isCollapsed: true,
                                isDense: true,
                                border: InputBorder.none,
                                enabledBorder: InputBorder.none,
                                focusedBorder: InputBorder.none,
                                filled: false,
                                hintText: '搜索聊天、信息名称',
                                hintStyle: prototypeText(
                                  context,
                                  13,
                                  color: c.muted,
                                ),
                                counterText: '',
                                contentPadding: EdgeInsets.zero,
                              ),
                              onChanged: onSearch,
                            ),
                          ),
                        ),
                        if (searchController.text.isEmpty)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              border: Border.all(color: c.line),
                              borderRadius: BorderRadius.circular(3),
                            ),
                            child: Text(
                              '/',
                              style: prototypeText(
                                context,
                                12,
                                color: c.muted,
                                family: 'Consolas',
                                height: 1.2,
                              ),
                            ),
                          )
                        else
                          SizedBox(
                            width: 18,
                            height: 20,
                            child: TextButton(
                              style: prototypeButton(
                                context,
                                size: 14,
                                iconOnly: true,
                              ),
                              onPressed: () {
                                searchController.clear();
                                onSearch('');
                              },
                              child: const Text(
                                '×',
                                textScaler: TextScaler.noScaling,
                                semanticsLabel: '清除搜索',
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 22),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (final f in InboxFilter.values) ...[
                        Container(
                          decoration: BoxDecoration(
                            border: Border(
                              bottom: BorderSide(
                                color: filter == f
                                    ? c.accent
                                    : Colors.transparent,
                                width: 2,
                              ),
                            ),
                          ),
                          child: TextButton(
                            key: ValueKey('inbox-filter-${f.name}'),
                            onPressed: () => onFilter(f),
                            style: prototypeButton(
                              context,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 8,
                              ),
                              foreground: filter == f ? c.strong : c.muted,
                              radius: 6,
                            ),
                            child: Text(
                              switch (f) {
                                InboxFilter.all => '全部 ${page.allCount}',
                                InboxFilter.pending =>
                                  '待处理 ${page.pendingCount}',
                                InboxFilter.handled =>
                                  '已处理 ${page.allCount - page.pendingCount}',
                              },
                              style: prototypeText(
                                context,
                                12,
                                color: filter == f ? c.strong : c.muted,
                                weight: filter == f
                                    ? FontWeight.w700
                                    : FontWeight.w400,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: c.line),
            Padding(
              padding: const EdgeInsets.fromLTRB(21, 18, 21, 12),
              child: Row(
                children: [
                  Text('今天的请求', style: muted),
                  const Spacer(),
                  Text('最新请求优先', style: muted),
                ],
              ),
            ),
            Expanded(
              child: page.entries.isEmpty
                  ? const EmptyWorkspace(
                      icon: Icons.search_off,
                      title: '没有找到请求',
                      description: '试试聊天名或信息名称，或清除筛选。',
                    )
                  : Scrollbar(
                      controller: scrollController,
                      thumbVisibility: page.total > 100,
                      child: ListView.builder(
                        primary: false,
                        controller: scrollController,
                        key: PageStorageKey(
                          'inbox-${filter.name}-${searchController.text}-${page.offset}',
                        ),
                        padding: EdgeInsets.zero,
                        itemCount: page.entries.length,
                        itemBuilder: (context, index) {
                          final entry = page.entries[index];
                          final chosen = entry.id == focused;
                          final count =
                              entry.access?.fields.length ??
                              (entry.credentialUse != null ? 1 : null) ??
                              entry.organization!.itemVersions.length;
                          return Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: Material(
                              color: chosen ? c.selected : Colors.transparent,
                              borderRadius: BorderRadius.circular(
                                chosen ? 6 : 0,
                              ),
                              child: InkWell(
                                key: ValueKey('request-${entry.id}'),
                                onTap: () => onSelected(entry.id),
                                borderRadius: BorderRadius.circular(6),
                                child: Container(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: chosen ? 16 : 16.5,
                                  ),
                                  decoration: BoxDecoration(
                                    border: chosen
                                        ? Border.all(
                                            color: Color.lerp(
                                              c.line,
                                              c.accent,
                                              .3,
                                            )!,
                                          )
                                        : Border(
                                            bottom: BorderSide(color: c.line),
                                          ),
                                    borderRadius: BorderRadius.circular(
                                      chosen ? 6 : 0,
                                    ),
                                  ),
                                  child: Column(
                                    children: [
                                      Row(
                                        children: [
                                          if (entry.pending) ...[
                                            Container(
                                              width: 5,
                                              height: 5,
                                              decoration: BoxDecoration(
                                                color:
                                                    c.accent ==
                                                        const Color(0xff333333)
                                                    ? const Color(0xff59595f)
                                                    : const Color(0xffae822c),
                                                shape: BoxShape.circle,
                                              ),
                                            ),
                                            const SizedBox(width: 7),
                                          ],
                                          Expanded(
                                            child: Text(
                                              entry.chatLabel,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: prototypeText(
                                                context,
                                                13,
                                                weight: FontWeight.w700,
                                                height: 1.6,
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 7),
                                          Text(
                                            _time(entry.createdAt),
                                            style: prototypeText(
                                              context,
                                              11,
                                              color: c.muted,
                                              family: 'Consolas',
                                              height: 1.6,
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 7),
                                      Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              '${entry.organization?.agentName.isNotEmpty == true ? entry.organization!.agentName : 'Agent'} · ${entry.credentialUse != null
                                                  ? '使用凭据'
                                                  : entry.organization == null
                                                  ? '读取信息'
                                                  : '整理资料'}',
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: muted,
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Text(
                                            entry.pending
                                                ? '$count ${entry.credentialUse != null
                                                      ? '项凭据'
                                                      : entry.organization == null
                                                      ? '个字段'
                                                      : '条信息'}'
                                                : stateLabel(entry),
                                            style: muted,
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
            ),
            Divider(height: 1, color: c.line),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      page.total == 0
                          ? '0 条请求'
                          : '显示 ${page.offset + 1}–${page.offset + page.entries.length} / ${page.total} 条',
                      style: muted,
                    ),
                  ),
                  SizedBox(
                    width: 24,
                    height: 26,
                    child: TextButton(
                      style: prototypeButton(context, size: 20, iconOnly: true),
                      onPressed: page.offset == 0
                          ? null
                          : () => onPage(page.offset - page.limit),
                      child: const Tooltip(
                        message: '上一页请求',
                        child: Text('‹', textScaler: TextScaler.noScaling),
                      ),
                    ),
                  ),
                  const SizedBox(width: 7),
                  Text(
                    '${page.offset ~/ page.limit + 1} / ${((page.total + page.limit - 1) ~/ page.limit).clamp(1, 999999)}',
                    style: muted,
                  ),
                  const SizedBox(width: 7),
                  SizedBox(
                    width: 24,
                    height: 26,
                    child: TextButton(
                      style: prototypeButton(context, size: 20, iconOnly: true),
                      onPressed: page.offset + page.limit >= page.total
                          ? null
                          : () => onPage(page.offset + page.limit),
                      child: const Tooltip(
                        message: '下一页请求',
                        child: Text('›', textScaler: TextScaler.noScaling),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _time(DateTime value) {
    final d = value.toLocal();
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }
}
