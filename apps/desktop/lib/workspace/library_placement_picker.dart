import 'package:flutter/material.dart';
import '../desktop_controls.dart';
import 'workspace_source.dart';

Future<WorkspaceLibraryPlacement?> showLibraryPlacementPicker(
  BuildContext context,
  WorkspaceSource source,
  WorkspaceLibrarySelection selection,
) => showDesktopDialog<WorkspaceLibraryPlacement>(
  context,
  builder: (_) => _PlacementPicker(source, selection),
);

class _PlacementPicker extends StatefulWidget {
  const _PlacementPicker(this.source, this.selection);
  final WorkspaceSource source;
  final WorkspaceLibrarySelection selection;
  @override
  State<_PlacementPicker> createState() => _PlacementPickerState();
}

class _PlacementPickerState extends State<_PlacementPicker> {
  List<WorkspaceLibraryPlacementTarget>? _targets;
  WorkspaceFailure? _failure;
  String _query = '';
  bool _after = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _targets = null;
      _failure = null;
    });
    try {
      final targets = await (widget.source as WorkspaceLibraryMove)
          .libraryPlacementTargets(widget.selection);
      if (mounted) setState(() => _targets = targets);
    } catch (e) {
      if (mounted) {
        setState(
          () => _failure = e is WorkspaceFailure
              ? e
              : const WorkspaceFailure('unavailable', '暂时无法读取目标，请重试。'),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    String normalized(String value) =>
        value.toLowerCase().replaceAll(RegExp(r'\s*/\s*'), '/');
    final query = normalized(_query.trim());
    final targets = _targets
        ?.where(
          (t) => normalized('${t.name} ${t.type} ${t.path}').contains(query),
        )
        .toList();
    return DesktopDialog(
      width: 680,
      title: const Text('调整顺序'),
      content: SizedBox(
        width: 620,
        height: MediaQuery.sizeOf(context).height * .52,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('选择一个对象作为参照。不同目录的对象会同时改变存放位置。'),
            const SizedBox(height: 10),
            DesktopSelect<bool>(
              key: const ValueKey('library-placement-side'),
              value: _after,
              items: const [
                DropdownMenuItem(value: false, child: Text('排在目标之前')),
                DropdownMenuItem(value: true, child: Text('排在目标之后')),
              ],
              onChanged: (value) => setState(() => _after = value ?? false),
            ),
            const SizedBox(height: 10),
            TextField(
              key: const ValueKey('library-placement-search'),
              decoration: const InputDecoration(labelText: '搜索名称或完整目录'),
              onChanged: (s) => setState(() => _query = s),
            ),
            if (_failure != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(_failure!.message),
              ),
            if (_failure == null && targets == null)
              const LinearProgressIndicator(),
            if (targets?.isEmpty == true)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('没有可选的目标'),
              ),
            Expanded(
              child: targets == null
                  ? const SizedBox()
                  : ListView.builder(
                      key: const ValueKey('library-placement-targets'),
                      itemCount: targets.length,
                      itemBuilder: (context, i) {
                        final t = targets[i];
                        return ListTile(
                          key: ValueKey('library-placement-${t.kind}:${t.id}'),
                          title: Text(t.name),
                          subtitle: Text('${t.type} · ${t.path}'),
                          onTap: () => Navigator.pop(
                            context,
                            t.placement(after: _after),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        if (_failure != null && _failure!.code != 'validation')
          DesktopButton(onPressed: _load, child: const Text('重新读取')),
        DesktopButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
      ],
    );
  }
}
