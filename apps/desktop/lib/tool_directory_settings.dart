import 'package:flutter/material.dart';
import 'prototype_ui.dart';
import 'settings_controls.dart';
import 'tool_directory_access.dart';
import 'bundled_tool_settings.dart';

class ToolDirectorySettings extends StatefulWidget {
  const ToolDirectorySettings({
    super.key,
    this.access = const NativeToolDirectoryAccess(),
  });
  final ToolDirectoryAccess access;
  @override
  State<ToolDirectorySettings> createState() => _ToolDirectorySettingsState();
}

class _ToolDirectorySettingsState extends State<ToolDirectorySettings> {
  ToolDirectorySnapshot? _snapshot;
  bool _busy = false;
  String? _error, _message;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _act(
    Future<ToolDirectorySnapshot?> Function() action, {
    String? success,
  }) async {
    if (_busy) return;
    final focus = FocusManager.instance.primaryFocus;
    setState(() {
      _busy = true;
      _error = null;
      _message = null;
    });
    try {
      final next = await action();
      if (mounted && next != null) {
        setState(() {
          _snapshot = next;
          _message = success;
        });
      }
    } on Object {
      if (mounted) {
        setState(() => _error = '操作未完成，已保留原有目录列表。请检查所选目录和应用存储后重试。');
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted &&
              focus?.context?.mounted == true &&
              focus!.canRequestFocus &&
              ModalRoute.of(context)?.isCurrent != false) {
            focus.requestFocus();
          }
        });
      }
    }
  }

  Future<void> _refresh() => _act(widget.access.read);
  Future<void> _choose([String? id]) => _act(
    () => widget.access.choose(replacing: id),
    success: '目录访问已保存。使用凭据仍需另行申请并由你批准。',
  );

  Future<void> _forget(ToolDirectory directory) async {
    final confirmed = await showSettingsDialog<bool>(
      context: context,
      builder: (context) => SettingsDialog(
        title: '移除保存的目录访问',
        actions: [
          settingsAction(context, '取消', () => Navigator.pop(context, false)),
          settingsAction(
            context,
            '确认移除',
            () => Navigator.pop(context, true),
            primary: true,
          ),
        ],
        child: Text(
          '应用下次启动不再恢复“${directory.name}”的访问。不会删除目录中的文件；已经运行的工具可能继续访问已打开的文件。',
        ),
      ),
    );
    if (confirmed == true && mounted) {
      await _act(
        () => widget.access.forget(directory.id),
        success: '已移除保存的目录访问。',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final directories = _snapshot?.directories ?? const <ToolDirectory>[];
    final disabled =
        _busy || _snapshot == null || _snapshot!.storageUnavailable;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const BundledToolSettings(),
        SettingsRow(
          'Mac 外部工具目录',
          '保存外部目录的文件访问。macOS 的目录选择不授予执行权限；GH 和 AWS 请使用上方的随包路径。',
          control: settingsAction(
            context,
            _busy ? '处理中…' : '选择工具目录',
            disabled ? null : () => _choose(),
            primary: true,
            key: const ValueKey('choose-tool-directory'),
          ),
        ),
        if (!_busy && _snapshot != null && directories.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('尚未保存外部目录。随包 GH、AWS 和系统 SSH 不需要在此添加。'),
          ),
        for (final directory in directories)
          SettingsRow(
            directory.name,
            '${directory.path}\n${directory.available ? '目录文件可访问；不代表其中的程序可执行。' : '目录访问已失效或暂不可用，请重新选择。'}',
            control: Wrap(
              spacing: 8,
              children: [
                settingsAction(
                  context,
                  '重新选择',
                  disabled ? null : () => _choose(directory.id),
                  key: ValueKey('reselect-tool-${directory.id}'),
                ),
                settingsAction(
                  context,
                  '移除',
                  disabled ? null : () => _forget(directory),
                  key: ValueKey('forget-tool-${directory.id}'),
                ),
              ],
            ),
          ),
        if (_snapshot?.storageUnavailable == true)
          const SettingsNotice(
            '目录设置无法读取',
            '已保留原有设置文件。请检查应用存储并重新打开应用；不会用空列表覆盖已有记录。',
            error: true,
          ),
        if (_error != null) SettingsNotice('目录访问未更新', _error!, error: true),
        if (_message != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              _message!,
              style: prototypeText(context, 13, height: 1.8),
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: settingsAction(context, '刷新目录状态', _busy ? null : _refresh),
        ),
      ],
    );
  }
}
