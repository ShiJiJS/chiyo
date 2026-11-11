import 'package:flutter/material.dart';
import '../ui_palette.dart';

typedef ProposalItemTab = ({String id, String title, bool attention, Key key});

/// A single content surface with scrollable tabs, shared by pending and saved
/// proposals. Selection still belongs to the proposal controller.
class ProposalItemTabs extends StatefulWidget {
  const ProposalItemTabs({
    super.key,
    required this.items,
    required this.selected,
    required this.onSelected,
    this.enabled = true,
  });
  final List<ProposalItemTab> items;
  final String selected;
  final ValueChanged<String> onSelected;
  final bool enabled;

  @override
  State<ProposalItemTabs> createState() => _ProposalItemTabsState();
}

class _ProposalItemTabsState extends State<ProposalItemTabs>
    with TickerProviderStateMixin {
  late TabController _tabs;
  int get _index => widget.items
      .indexWhere((i) => i.id == widget.selected)
      .clamp(0, widget.items.length - 1);

  @override
  void initState() {
    super.initState();
    _tabs = TabController(
      length: widget.items.length,
      initialIndex: _index,
      vsync: this,
    );
  }

  @override
  void didUpdateWidget(ProposalItemTabs oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.items.length != widget.items.length) {
      _tabs.dispose();
      _tabs = TabController(
        length: widget.items.length,
        initialIndex: _index,
        vsync: this,
      );
    } else if (_tabs.index != _index) {
      _tabs.index = _index;
    }
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = UiPalette.of(context);
    return IgnorePointer(
      ignoring: !widget.enabled,
      child: TabBar(
        controller: _tabs,
        isScrollable: true,
        tabAlignment: TabAlignment.start,
        padding: EdgeInsets.zero,
        labelPadding: const EdgeInsets.symmetric(horizontal: 16),
        labelColor: c.accent,
        unselectedLabelColor: c.muted,
        labelStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        unselectedLabelStyle: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w400,
        ),
        indicatorColor: c.accent,
        indicatorWeight: 2,
        indicatorSize: TabBarIndicatorSize.tab,
        dividerColor: c.line,
        onTap: (index) => widget.onSelected(widget.items[index].id),
        tabs: [
          for (final item in widget.items)
            Tab(
              key: item.key,
              height: 48,
              child: Tooltip(
                message: item.attention ? '${item.title} · 待填密码' : item.title,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 260),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (item.attention) ...[
                        const SizedBox(width: 8),
                        Text(
                          '待填密码',
                          style: TextStyle(fontSize: 11, color: c.warning),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
