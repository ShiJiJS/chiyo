import 'dart:async';
import 'package:flutter/material.dart';
import '../desktop_controls.dart';
import 'workspace_source.dart';

Future<void> showAttachmentSeparation(
  BuildContext context,
  WorkspaceSource source,
  WorkspaceDetail detail,
  String fieldId,
  String filename,
) => showDesktopDialog<void>(
  context,
  builder: (_) => _Separation(
    source: source,
    detail: detail,
    fieldId: fieldId,
    filename: filename,
  ),
);

class _Separation extends StatefulWidget {
  const _Separation({
    required this.source,
    required this.detail,
    required this.fieldId,
    required this.filename,
  });
  final WorkspaceSource source;
  final WorkspaceDetail detail;
  final String fieldId, filename;
  @override
  State<_Separation> createState() => _SeparationState();
}

class _SeparationState extends State<_Separation> {
  late final _name = TextEditingController(text: widget.filename);
  final _operation = workspaceFileOperationId();
  List<WorkspacePluginTemplate> _templates = [];
  String? _selected, _error, _submittedName, _submittedTemplate;
  bool _loading = true, _saving = false;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final templates = await (widget.source as WorkspaceAttachmentSeparation)
          .attachmentSeparationTemplates();
      if (!mounted) return;
      _templates = [
        for (final t in templates)
          if ((t.definition['fields'] as List? ?? []).length == 1 &&
              ((t.definition['fields'] as List).single as Map)['type'] ==
                  'file' &&
              (t.definition['relations'] as List? ?? []).any(
                (r) =>
                    r['key'] == 'related' &&
                    ((r['targetTemplates'] as List? ?? []).isEmpty ||
                        (r['targetTemplates'] as List).contains(
                          widget.detail.record.type.id,
                        )),
              ))
            t,
      ];
      if (_templates.isNotEmpty) {
        _selected = _templates.first.type.id;
      } else {
        _error = '没有可用的文件资料模板，请先在设置中检查插件。';
      }
    } catch (_) {
      if (mounted) _error = '模板暂时无法读取，请关闭后重试。';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    if (_saving || _selected == null || _name.text.trim().isEmpty) return;
    _submittedName ??= _name.text.trim();
    _submittedTemplate ??= _selected;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await (widget.source as WorkspaceAttachmentSeparation).separateAttachment(
        operationId: _operation,
        record: widget.detail.record.ref,
        fieldId: widget.fieldId,
        expectedVersion: widget.detail.version,
        name: _submittedName!,
        templateId: _submittedTemplate!,
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e is WorkspaceFailure
              ? e.message
              : '保存结果尚未确认。再次保存会核对同一次操作，不会重复创建资料。';
        });
      }
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => DesktopDialog(
    title: const Text('存为独立文件资料'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('文件及全部历史版本会转入新资料，并关联“${widget.detail.record.name}”。原资料的其他内容保持不变。'),
        const SizedBox(height: 18),
        TextField(
          controller: _name,
          readOnly: _submittedName != null,
          maxLength: 200,
          decoration: const InputDecoration(labelText: '资料名称'),
        ),
        const SizedBox(height: 12),
        if (_loading)
          const Text('正在读取文件模板…')
        else
          DropdownButtonFormField<String>(
            initialValue: _selected,
            decoration: const InputDecoration(labelText: '资料类型'),
            items: [
              for (final t in _templates)
                DropdownMenuItem(value: t.type.id, child: Text(t.type.name)),
            ],
            onChanged: _submittedTemplate != null
                ? null
                : (v) => setState(() => _selected = v),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(_error!),
          ),
      ],
    ),
    actions: [
      DesktopButton(
        onPressed: _saving ? null : () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
      DesktopButton(
        onPressed: _loading || _saving || _selected == null ? null : _save,
        child: Text(_saving ? '正在保存…' : '保存'),
      ),
    ],
  );
}
