import 'dart:async';
import 'package:flutter/material.dart';
import '../desktop_controls.dart';
import '../desktop_feedback.dart';
import '../desktop_motion.dart';
import '../ui_palette.dart';
import '../prototype_icons.dart';
import 'sample_workspace_source.dart';
import 'workspace_controller.dart';
import 'workspace_source.dart';
import 'zhiyu_app.dart';
import 'mac_preview_desktop.dart';

/// Only the isolated composition root knows which provider is a sample.
/// U02–U07 register their production widgets through pageBuilder.
class PreviewWorkspace extends StatefulWidget {
  const PreviewWorkspace({super.key, this.pageBuilder, this.desktop});
  final WorkspacePageBuilder? pageBuilder;
  final MacPreviewDesktop? desktop;
  @override
  State<PreviewWorkspace> createState() => _PreviewWorkspaceState();
}

class _PreviewWorkspaceState extends State<PreviewWorkspace> {
  late final SampleWorkspaceSource _source;
  late final WorkspaceController _controller;
  final _guideFocus = FocusNode();
  @override
  void initState() {
    super.initState();
    _source = SampleWorkspaceSource();
    _controller = WorkspaceController(_source);
    widget.desktop?.onNavigate = (page) => _controller.navigate(page);
    unawaited(_controller.refresh());
  }

  @override
  void dispose() {
    _guideFocus.dispose();
    _controller.dispose();
    _source.dispose();
    widget.desktop?.dispose();
    super.dispose();
  }

  void _scenario(SampleWorkspaceScenario value) {
    _source.setScenario(value);
    unawaited(_controller.refresh());
  }

  void _guide(BuildContext context) {
    unawaited(widget.desktop?.setNavigationEnabled(false));
    unawaited(
      showDesktopDialog<void>(
        context,
        returnFocus: _guideFocus,
        builder: (dialogContext) => DesktopDialog(
          title: const Text('设计说明与界面检查'),
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('按已确认的知予工作台布局制作。当前窗口使用独立示例数据，重启或重置后恢复初始内容。'),
              const SizedBox(height: 22),
              const Text('阅读外观', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 10),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final value in Brightness.values)
                    DesktopButton(
                      key: ValueKey('preview-theme-${value.name}'),
                      onPressed: () {
                        _controller.setBrightness(value);
                        Navigator.pop(dialogContext);
                      },
                      child: Text(value == Brightness.light ? '明亮' : '黑暗'),
                    ),
                ],
              ),
              const SizedBox(height: 22),
              const Text('读取状态', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 10),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final value in SampleWorkspaceScenario.values)
                    DesktopButton(
                      key: ValueKey('preview-scenario-${value.name}'),
                      onPressed: () {
                        _scenario(value);
                        Navigator.pop(dialogContext);
                      },
                      child: Text(switch (value) {
                        SampleWorkspaceScenario.ready => '正常资料',
                        SampleWorkspaceScenario.empty => '空资料',
                        SampleWorkspaceScenario.waiting => '持续等待',
                        SampleWorkspaceScenario.failure => '读取失败',
                      }),
                    ),
                ],
              ),
              const SizedBox(height: 22),
              const Text(
                '按钮和表单',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 10),
              const _ControlSample(),
            ],
          ),
          actions: [
            DesktopButton(
              onPressed: () {
                _source.reset();
                unawaited(_controller.refresh());
                Navigator.pop(dialogContext);
                DesktopFeedback.show(context, '已重置预览资料');
              },
              child: const Text('重置预览资料'),
            ),
            DesktopButton(
              kind: DesktopButtonKind.primary,
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('完成'),
            ),
          ],
        ),
      ).whenComplete(() async {
        if (mounted) await widget.desktop?.setNavigationEnabled(true);
      }),
    );
  }

  @override
  Widget build(BuildContext context) => ZhiyuApp(
    controller: _controller,
    windowTitle: MacPreviewDesktop.windowTitle,
    trailingBuilder: (context) => DesktopButton(
      key: const ValueKey('preview-guide'),
      focusNode: _guideFocus,
      kind: DesktopButtonKind.quiet,
      fontSize: 12,
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
      onPressed: () => _guide(context),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('设计说明'),
          const SizedBox(width: 7),
          SizedBox(
            width: 19,
            height: 24.1875,
            child: Align(
              alignment: Alignment.topCenter,
              child: PrototypeIcon(
                PrototypeIconGlyph.arrow,
                size: 19,
                color: UiPalette.of(context).ink,
              ),
            ),
          ),
        ],
      ),
    ),
    pageBuilder:
        widget.pageBuilder ??
        (context, location) => _FoundationPage(
          controller: _controller,
          onRetry: () => _scenario(SampleWorkspaceScenario.ready),
        ),
  );
}

class _ControlSample extends StatefulWidget {
  const _ControlSample();
  @override
  State<_ControlSample> createState() => _ControlSampleState();
}

class _ControlSampleState extends State<_ControlSample> {
  String _selection = '文本';
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
            onPressed: () => DesktopFeedback.show(context, '已保存到预览资料'),
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
      const TextField(
        key: ValueKey('preview-text-input'),
        decoration: InputDecoration(labelText: '示例输入'),
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

/// Temporary U01 surface, replaced by the module page builders in U02–U07.
/// It exercises the public loading contract, not a copy of the HTML prototype.
class _FoundationPage extends StatelessWidget {
  const _FoundationPage({required this.controller, required this.onRetry});
  final WorkspaceController controller;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) {
    final c = UiPalette.of(context);
    return DesktopEntrance(
      key: ValueKey(controller.location.page),
      child: Center(
        child: Container(
          width: 620,
          margin: const EdgeInsets.all(28),
          padding: const EdgeInsets.all(32),
          decoration: BoxDecoration(
            color: c.paper,
            border: Border.all(color: c.line),
            borderRadius: BorderRadius.circular(10),
          ),
          child: SingleChildScrollView(
            primary: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  controller.location.page.label,
                  style: Theme.of(context).textTheme.headlineLarge,
                ),
                const SizedBox(height: 16),
                switch (controller.load) {
                  WorkspaceLoad.idle || WorkspaceLoad.loading => const Row(
                    children: [
                      SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      SizedBox(width: 10),
                      Text('正在读取…'),
                    ],
                  ),
                  WorkspaceLoad.error => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(controller.failure!.message),
                      const SizedBox(height: 16),
                      DesktopButton(
                        onPressed: onRetry,
                        child: const Text('重试'),
                      ),
                    ],
                  ),
                  WorkspaceLoad.empty => const Text('暂无资料'),
                  WorkspaceLoad.ready => Text(
                    '${controller.summary!.records} 项资料 · '
                    '${controller.summary!.pending} 条待处理请求 · ${controller.summary!.proposals} 条录入提案',
                  ),
                },
              ],
            ),
          ),
        ),
      ),
    );
  }
}
