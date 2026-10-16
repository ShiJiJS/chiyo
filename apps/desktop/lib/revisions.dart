import 'ui.dart';
import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart';
import 'organization.dart';
import 'recycle.dart';

class RevisionHistoryPage extends StatefulWidget {
  const RevisionHistoryPage({
    super.key,
    required this.owner,
    required this.itemId,
  });
  final OwnerAccess owner;
  final String itemId;
  @override
  State<RevisionHistoryPage> createState() => _RevisionHistoryPageState();
}

class _RevisionHistoryPageState extends State<RevisionHistoryPage> {
  List<InformationRevision>? _revisions;
  bool _failed = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final revisions = await widget.owner.revisionsFor(widget.itemId);
      if (mounted) {
        setState(() {
          _revisions = revisions;
          _failed = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _preview(InformationRevision revision) async {
    try {
      final current = widget.owner.information
          .where((i) => i.id == widget.itemId)
          .firstOrNull;
      if (current == null) {
        throw const AccessFailure('recycle_restore_required');
      }
      final preview = widget.owner.previewRevision(
        widget.itemId,
        revision.item.version,
        current.version,
      );
      await showDialog<bool>(
        context: context,
        builder: (_) => _RestoreRevision(owner: widget.owner, preview: preview),
      );
      await _load();
    } on AccessFailure catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_message(error.status))));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('无法打开修改历史，请检查存储状态。')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => DesktopSubpage(
    title: '修改历史',
    body: ListView(
      padding: UiSpace.page,
      children: [
        const Text('修改历史仅供你查看，默认保留 30 天。恢复会创建新的当前版本，不会回退授权、其他资料或应用设置。'),
        if (_failed) ...[
          const Text('历史读取或清理失败，请检查存储状态后重试。'),
          TextButton(onPressed: _load, child: const Text('重试')),
        ] else if (_revisions == null)
          const LinearProgressIndicator()
        else if (_revisions!.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 24),
            child: Text('最近 30 天没有修改历史。'),
          )
        else
          for (final revision in _revisions!)
            WorkspaceRecord(
              title: Text(
                '版本 ${revision.item.version} · ${revision.item.name}',
              ),
              subtitle: Text(
                '替换时间：${revision.replacedAt.toLocal()}\n保留至：${revision.replacedAt.add(const Duration(days: 30)).toLocal()}',
              ),
              trailing: TextButton(
                onPressed: () => _preview(revision),
                child: const Text('查看差异'),
              ),
            ),
      ],
    ),
  );
}

String _message(String status) => switch (status) {
  'recycle_restore_required' => '目标信息或字段已删除，请先在回收站明确恢复，再返回历史查看差异；已清理内容不能恢复。',
  'revision_conflict' => '当前信息已变化，请重新打开差异后确认。',
  'revision_unavailable' => '该修改版本已经过期或不可用，请刷新历史。',
  _ => '恢复失败，当前资料未更新，请检查存储状态后重试。',
};

class _RestoreRevision extends StatefulWidget {
  const _RestoreRevision({required this.owner, required this.preview});
  final OwnerAccess owner;
  final RevisionPreview preview;
  @override
  State<_RestoreRevision> createState() => _RestoreRevisionState();
}

class _RestoreRevisionState extends State<_RestoreRevision> {
  bool _busy = false;
  String? _error;
  Future<void> _restore() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final p = widget.preview;
      await widget.owner.restoreRevision(
        p.current.id,
        p.revision.item.version,
        p.current.version,
      );
      if (mounted) Navigator.pop(context, true);
    } on AccessFailure catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = _message(error.status);
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = _message('failed');
        });
      }
    }
  }

  Widget _difference(String title, String before, String after) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeading(title),
        InformationValue(name: '当前', value: before),
        InformationValue(name: '恢复后', value: after),
        const Divider(),
      ],
    ),
  );

  String _field(InformationField? field) => field == null
      ? '（不存在）'
      : '${field.name}\n${field.description}\n${field.kind == FieldKind.textNote ? '文本说明' : '结构字段'}\n${field.value}';

  @override
  Widget build(BuildContext context) {
    final p = widget.preview;
    return DesktopDialog(
      title: Text('恢复版本 ${p.revision.item.version} 的内容'),
      content: SizedBox(
        width: 650,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '确认后创建版本 ${p.restored.version}。仍有效的授权会读取恢复后的当前字段值；曾删除字段的旧授权不会复活。',
              ),
              if (p.current.name != p.restored.name)
                _difference('公开名称', p.current.name, p.restored.name),
              if (p.current.description != p.restored.description)
                _difference(
                  '公开描述',
                  p.current.description,
                  p.restored.description,
                ),
              if (p.current.directoryId != p.restored.directoryId)
                _difference(
                  '目录',
                  directoryPath(widget.owner, p.current.directoryId),
                  directoryPath(widget.owner, p.restored.directoryId),
                ),
              if (p.current.tagIds.toString() != p.restored.tagIds.toString())
                _difference('标签', _tags(p.current), _tags(p.restored)),
              for (final change in p.changes)
                _difference(
                  change.after?.name ?? change.before!.name,
                  _field(change.before),
                  _field(change.after),
                ),
              if (p.changes.any((c) => c.after == null))
                const Text('此次恢复会删除上面标注为“不存在”的当前字段，并放入回收站；它们在既有授权中立即失效。'),
              if (p.requiresRecycleRestore) ...[
                Text(_message('recycle_restore_required')),
                TextButton(
                  onPressed: () async {
                    final navigator = Navigator.of(context);
                    navigator.pop(false);
                    await navigator.push(
                      MaterialPageRoute<void>(
                        builder: (_) => RecyclePage(owner: widget.owner),
                      ),
                    );
                  },
                  child: const Text('打开回收站'),
                ),
              ],
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _busy || p.requiresRecycleRestore ? null : _restore,
          child: const Text('确认恢复为新版本'),
        ),
      ],
    );
  }

  String _tags(InformationItem item) => widget.owner.tags
      .where((t) => item.tagIds.contains(t.id))
      .map((t) => t.name)
      .join('、');
}
