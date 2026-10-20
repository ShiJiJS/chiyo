import 'ui.dart';
import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart';
import 'organization.dart';
import 'recycle.dart';
import 'prototype_dialog.dart';
import 'prototype_ui.dart';
import 'information_field_preview.dart';

class RevisionHistoryPage extends StatefulWidget {
  const RevisionHistoryPage({
    super.key,
    required this.owner,
    required this.itemId,
    this.asDialog = false,
  });
  final OwnerAccess owner;
  final String itemId;
  final bool asDialog;
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
        barrierColor: const Color(0x4f241b27),
        builder: (_) => _RestoreRevision(
          owner: widget.owner,
          preview: preview,
          asDialog: widget.asDialog,
        ),
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
  Widget build(BuildContext context) => _surface(
    ListView(
      shrinkWrap: widget.asDialog,
      physics: widget.asDialog ? const NeverScrollableScrollPhysics() : null,
      padding: widget.asDialog ? EdgeInsets.zero : UiSpace.page,
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
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '替换时间：${revision.replacedAt.toLocal()}\n保留至：${revision.replacedAt.add(const Duration(days: 30)).toLocal()}',
                  ),
                  for (final field in revision.item.fields.where(
                    (f) => f.kind == FieldKind.file,
                  ))
                    Text(
                      '${field.name} · 文件版本 ${field.attachment!.attachmentVersion}',
                    ),
                ],
              ),
              trailing: TextButton(
                onPressed: () => _preview(revision),
                child: const Text('查看差异'),
              ),
            ),
      ],
    ),
  );
  Widget _surface(Widget body) => widget.asDialog
      ? PrototypeDialog(
          flow: true,
          scrollGutter: 0,
          title: '修改历史与恢复',
          onClose: () => Navigator.pop(context),
          body: _dialogBody(),
        )
      : DesktopSubpage(title: '修改历史', body: body);
  Widget _dialogBody() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: prototypeCh(context, 14, 48)),
          child: Text(
            '旧值只对用户可见。恢复建立一个新版本；被移除后恢复的字段使用新身份，旧授权不会重新生效。',
            style: prototypeText(
              context,
              14,
              height: 1.85,
              color: UiPalette.of(context).muted,
            ),
          ),
        ),
      ),
      const SizedBox(height: 12),
      Text(
        '修改历史保留 30 天，与回收站分别清理。',
        style: prototypeText(context, 12, color: UiPalette.of(context).muted),
      ),
      if (_failed) ...[
        const Text('历史读取或清理失败，请重试。'),
        TextButton(
          onPressed: _load,
          style: prototypeSecondary(context),
          child: const Text('重试'),
        ),
      ] else if (_revisions == null)
        const LinearProgressIndicator()
      else if (_revisions!.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 20),
          child: Text('最近 30 天没有修改历史。'),
        )
      else
        for (final revision in _revisions!)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 23),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: UiPalette.of(context).line),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${revision.item.name} · 版本 ${revision.item.version}',
                        style: prototypeText(
                          context,
                          14,
                          weight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        revision.item.description,
                        style: prototypeText(context, 13),
                      ),
                      for (final field in revision.item.fields.where(
                        (f) => f.kind == FieldKind.file,
                      ))
                        Text(
                          '${field.name} · 文件版本 ${field.attachment!.attachmentVersion}',
                          style: prototypeText(
                            context,
                            13,
                            height: 1.8,
                            color: UiPalette.of(context).muted,
                          ),
                        ),
                      const SizedBox(height: 6),
                      Text(
                        '替换时间：${uiTime(revision.replacedAt)}',
                        style: prototypeText(
                          context,
                          12,
                          color: UiPalette.of(context).muted,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                TextButton(
                  style: prototypeSecondary(context),
                  onPressed: () => _preview(revision),
                  child: const Text('恢复为新版本'),
                ),
              ],
            ),
          ),
    ],
  );
}

String _message(String status) => switch (status) {
  'recycle_restore_required' => '目标信息或字段已删除，请先在回收站明确恢复，再返回历史查看差异；已清理内容不能恢复。',
  'revision_conflict' => '当前信息已变化，请重新打开差异后确认。',
  'revision_unavailable' => '该修改版本已经过期或不可用，请刷新历史。',
  'attachment_missing' => '该版本的原文件已不可用，请刷新历史；未恢复不完整内容。',
  'attachment_integrity_failed' => '原文件校验失败，未恢复。请检查备份或存储后重试。',
  _ => '恢复失败，当前资料未更新，请检查存储状态后重试。',
};

class _RestoreRevision extends StatefulWidget {
  const _RestoreRevision({
    required this.owner,
    required this.preview,
    this.asDialog = false,
  });
  final OwnerAccess owner;
  final RevisionPreview preview;
  final bool asDialog;
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

  Widget _difference(
    String title,
    String before,
    String after, {
    bool code = false,
    Widget? beforeContent,
    Widget? afterContent,
  }) => Padding(
    padding: const EdgeInsets.only(top: 18),
    child: Container(
      decoration: BoxDecoration(
        border: Border.all(color: UiPalette.of(context).line),
        borderRadius: BorderRadius.circular(5),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            color: UiPalette.of(context).canvas,
            child: Text(
              title,
              style: prototypeText(context, 13, weight: FontWeight.w600),
            ),
          ),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final cell in [('当前', before), ('恢复后', after)])
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 17,
                      ),
                      decoration: BoxDecoration(
                        color: cell.$1 == '当前'
                            ? UiPalette.of(context).paper
                            : UiPalette.of(context).rail,
                        border: Border(
                          top: BorderSide(color: UiPalette.of(context).line),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            cell.$1,
                            style: prototypeText(
                              context,
                              12,
                              color: UiPalette.of(context).muted,
                            ),
                          ),
                          const SizedBox(height: 8),
                          (cell.$1 == '当前' ? beforeContent : afterContent) ??
                              SelectableText(
                                cell.$2,
                                style: prototypeText(
                                  context,
                                  13,
                                  family: code && cell.$2 != '（不存在）'
                                      ? 'Consolas'
                                      : null,
                                  height: 1.6,
                                ),
                              ),
                        ],
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

  String _field(InformationField? field) =>
      field == null ? '（不存在）' : informationFieldValueLabel(field);

  @override
  Widget build(BuildContext context) {
    final p = widget.preview;
    return PrototypeDialog(
      flow: true,
      title: '恢复版本 ${p.revision.item.version} 的内容',
      onClose: _busy ? null : () => Navigator.pop(context),
      body: SizedBox(
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
              for (final change in p.changes) ...[
                if (change.before?.description != change.after?.description)
                  _difference(
                    '${change.after?.name ?? change.before!.name} · 字段公开说明',
                    change.before?.description ?? '（不存在）',
                    change.after?.description ?? '（不存在）',
                  ),
                _difference(
                  change.after?.name ?? change.before!.name,
                  _field(change.before),
                  _field(change.after),
                  beforeContent: change.before?.kind == FieldKind.file
                      ? InformationFieldContent(
                          owner: widget.owner,
                          field: change.before!,
                        )
                      : null,
                  afterContent: change.after?.kind == FieldKind.file
                      ? InformationFieldContent(
                          owner: widget.owner,
                          field: change.after!,
                        )
                      : null,
                  code:
                      (change.after ?? change.before!).kind ==
                      FieldKind.structured,
                ),
              ],
              if (p.changes.any((c) => c.after == null))
                const Text('此次恢复会删除上面标注为“不存在”的当前字段，并放入回收站；它们在既有授权中立即失效。'),
              if (p.requiresRecycleRestore) ...[
                Text(_message('recycle_restore_required')),
                TextButton(
                  onPressed: () async {
                    final navigator = Navigator.of(context);
                    navigator.pop(false);
                    if (widget.asDialog) {
                      await showDialog<void>(
                        context: navigator.context,
                        barrierColor: const Color(0x4f241b27),
                        builder: (_) =>
                            RecyclePage(owner: widget.owner, asDialog: true),
                      );
                      return;
                    }
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
          style: prototypeSecondary(context),
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          style: prototypePrimary(context),
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
