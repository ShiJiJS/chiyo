import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart';
import 'ui.dart';

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
    final colors = UiPalette.of(context);
    return Material(
      color: colors.rail,
      child: Container(
        decoration: BoxDecoration(
          border: Border(right: BorderSide(color: colors.line)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  PageHeading('请求收件箱', subtitle: '${page.pendingCount} 条待处理'),
                  DesktopTextField(
                    key: const ValueKey('inbox-search'),
                    maxLength: 2000,
                    controller: searchController,
                    focusNode: searchFocus,
                    decoration: InputDecoration(
                      hintText: '搜索聊天、信息名称',
                      prefixIcon: const Icon(Icons.search, size: 17),
                      suffixIcon: searchController.text.isEmpty
                          ? null
                          : IconButton(
                              tooltip: '清除搜索',
                              onPressed: () {
                                searchController.clear();
                                onSearch('');
                              },
                              icon: const Icon(Icons.close, size: 16),
                            ),
                    ),
                    onChanged: onSearch,
                  ),
                  Wrap(
                    spacing: 6,
                    children: [
                      for (final f in InboxFilter.values)
                        TextButton(
                          key: ValueKey('inbox-filter-${f.name}'),
                          onPressed: () => onFilter(f),
                          style: TextButton.styleFrom(
                            foregroundColor: filter == f
                                ? colors.strong
                                : colors.muted,
                            backgroundColor: filter == f
                                ? colors.selected
                                : null,
                          ),
                          child: Text(switch (f) {
                            InboxFilter.all => '全部',
                            InboxFilter.pending => '待处理',
                            InboxFilter.handled => '已处理',
                          }),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text('最新请求优先', style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 10),
                ],
              ),
            ),
            const Divider(),
            Expanded(
              child: page.entries.isEmpty
                  ? const EmptyWorkspace(
                      icon: Icons.search_off,
                      title: '没有找到请求',
                      description: '试试聊天名或信息名称，或清除筛选。',
                    )
                  : Scrollbar(
                      controller: scrollController,
                      thumbVisibility: true,
                      child: ListView.builder(
                        controller: scrollController,
                        key: PageStorageKey(
                          'inbox-${filter.name}-${searchController.text}-${page.offset}',
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 10,
                        ),
                        itemCount: page.entries.length,
                        itemBuilder: (context, index) {
                          final entry = page.entries[index];
                          final selected = entry.id == focused;
                          return Material(
                            color: selected
                                ? colors.selected
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(6),
                            child: InkWell(
                              key: ValueKey('request-${entry.id}'),
                              onTap: () => onSelected(entry.id),
                              borderRadius: BorderRadius.circular(6),
                              child: Container(
                                decoration: BoxDecoration(
                                  border: Border(
                                    bottom: BorderSide(color: colors.line),
                                  ),
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 15,
                                ),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Text(
                                      entry.chatLabel,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.titleSmall,
                                    ),
                                    const SizedBox(height: 7),
                                    Text(
                                      '${entry.organization == null ? '信息读取' : '分类整理'} · ${stateLabel(entry)}',
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodySmall,
                                    ),
                                    Text(
                                      uiTime(entry.createdAt),
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodySmall,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
            ),
            const Divider(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      page.total == 0
                          ? '0 条请求'
                          : '${page.offset + 1}–${(page.offset + page.entries.length)} / ${page.total}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  IconButton(
                    tooltip: '上一页请求',
                    onPressed: page.offset == 0
                        ? null
                        : () => onPage(page.offset - page.limit),
                    icon: const Icon(Icons.chevron_left),
                  ),
                  IconButton(
                    tooltip: '下一页请求',
                    onPressed: page.offset + page.limit >= page.total
                        ? null
                        : () => onPage(page.offset + page.limit),
                    icon: const Icon(Icons.chevron_right),
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
