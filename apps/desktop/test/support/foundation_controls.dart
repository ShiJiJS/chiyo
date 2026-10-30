// Test-only control surface, never reachable from the shipped preview.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/desktop_controls.dart';
import 'package:info_desktop/desktop_feedback.dart';
import 'package:info_desktop/ui_palette.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_desktop/workspace/workspace_records_controller.dart';
import 'package:info_desktop/workspace/mac_preview_desktop.dart';
import 'package:info_desktop/workspace/zhiyu_app.dart';
import 'workspace_fixtures.dart';

Future<void> openFoundationControls(
  WidgetTester t,
  MacPreviewDesktop? desktop,
) async {
  final context = t.element(find.byKey(const ValueKey('zhiyu-content')));
  final controller = t.widget<ZhiyuApp>(find.byType(ZhiyuApp)).controller;
  final source = fixtureSource(t);
  controller.setNavigationLocked(true);
  await desktop?.setNavigationEnabled(false);
  unawaited(
    showDesktopDialog<void>(
      context,
      builder: (context) => DesktopDialog(
        key: const ValueKey('foundation-controls'),
        title: const Text('共享控件检查'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ControlSample(
              source: source,
              failNextSave: () {
                source.nextSaveFailure = const WorkspaceFailure(
                  'sample_save_failed',
                  '保存失败，输入已保留，请重试。',
                );
              },
            ),
            for (var i = 0; i < 10; i++)
              const Padding(
                padding: EdgeInsets.only(top: 14),
                child: Text('共享控件的长正文与滚动检查。'),
              ),
          ],
        ),
        actions: [
          DesktopButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('完成'),
          ),
        ],
      ),
    ).whenComplete(() {
      controller.setNavigationLocked(false);
      unawaited(desktop?.setNavigationEnabled(true));
    }),
  );
}

class _ControlSample extends StatefulWidget {
  const _ControlSample({required this.source, required this.failNextSave});
  final WorkspaceSource source;
  final VoidCallback failNextSave;
  @override
  State<_ControlSample> createState() => _ControlSampleState();
}

class _ControlSampleState extends State<_ControlSample> {
  String _selection = '文本';
  late final WorkspaceRecordsController _records;
  final _name = TextEditingController();
  WorkspaceDetail? _draft;
  bool _dirty = false;
  static int _nextOperationId = 0;
  @override
  void initState() {
    super.initState();
    _records = WorkspaceRecordsController(widget.source)..addListener(_changed);
    unawaited(_records.load(const WorkspaceQuery(typeId: 'server')));
  }

  void _changed() {
    if (!mounted) return;
    final detail = _records.detail;
    if (!_dirty && !_name.value.composing.isValid && detail != null) {
      _draft = detail;
      if (_name.text != detail.record.name) _name.text = detail.record.name;
    }
    setState(() {});
  }

  Future<void> _save() async {
    final draft = _draft;
    if (draft == null) return;
    final submittedName = _name.text;
    final result = await _records.save(
      WorkspaceEdit(
        operationId: 'preview-control-${_nextOperationId++}',
        expectedVersion: draft.version,
        record: draft.record.copyWith(name: submittedName),
        values: const {},
      ),
    );
    if (!mounted) return;
    if (result case WorkspaceSaved(:final detail)) {
      _draft = detail;
      if (_name.text == submittedName) {
        _dirty = false;
        _name.text = detail.record.name;
      }
      DesktopFeedback.show(context, '已保存到预览资料');
    }
  }

  @override
  void dispose() {
    _records.removeListener(_changed);
    _records.dispose();
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          DesktopButton(
            key: const ValueKey('preview-action'),
            onPressed: _draft == null ? null : _save,
            busy: _records.saveState == WorkspaceSaveState.saving,
            child: const Text('保存'),
          ),
          const DesktopButton(onPressed: null, child: Text('不可用')),
          DesktopButton(
            tooltip: '字段的展示形式；普通文件与凭据分别管理。',
            kind: DesktopButtonKind.quiet,
            onPressed: () {},
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('字段形式'),
                SizedBox(width: 5),
                Icon(Icons.info_outline, size: 15),
              ],
            ),
          ),
        ],
      ),
      const SizedBox(height: 12),
      TextField(
        key: const ValueKey('preview-text-input'),
        controller: _name,
        enabled: _records.saveState != WorkspaceSaveState.saving,
        onChanged: (_) => _dirty = true,
        decoration: InputDecoration(
          labelText: '示例输入',
          errorText: _records.saveFailure?.fieldErrors['name'],
        ),
      ),
      if (_records.saveFailure != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            _records.saveFailure!.message,
            style: TextStyle(color: UiPalette.of(context).danger),
          ),
        ),
      if (_records.failure != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text('示例资料暂不可用：${_records.failure!.message}'),
        ),
      Align(
        alignment: Alignment.centerLeft,
        child: DesktopButton(
          kind: DesktopButtonKind.quiet,
          onPressed: widget.failNextSave,
          child: const Text('下次保存失败'),
        ),
      ),
      const SizedBox(height: 12),
      DesktopSelect<String>(
        isExpanded: true,
        value: _selection,
        onChanged: (value) => setState(() => _selection = value!),
        items: const [
          DropdownMenuItem(value: '文本', child: Text('文本')),
          DropdownMenuItem(value: '多行文本', child: Text('多行文本')),
          DropdownMenuItem(value: '文件', child: Text('文件')),
        ],
      ),
    ],
  );
}
