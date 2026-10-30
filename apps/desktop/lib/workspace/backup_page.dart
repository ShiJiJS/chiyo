import 'package:flutter/material.dart';
import '../desktop_controls.dart';
import '../ui_palette.dart';
import 'backup_controller.dart';
import 'library_widgets.dart';
import 'settings_page.dart' show SettingsPreferenceRow;
import 'settings_layout.dart';
import 'workspace_source.dart';

class WorkspaceBackupPage extends StatelessWidget {
  const WorkspaceBackupPage({
    super.key,
    required this.controller,
    required this.picker,
    required this.onLibrary,
    this.onModalChanged,
  });
  final BackupController controller;
  final WorkspaceBackupPicker picker;
  final VoidCallback onLibrary;
  final ValueChanged<bool>? onModalChanged;
  Future<void> _open(BuildContext context, WorkspaceBackupMode mode) async {
    if (!controller.available) return;
    controller.begin();
    onModalChanged?.call(true);
    bool? library;
    try {
      library = await showDesktopDialog<bool>(
        context,
        builder: (_) =>
            _BackupFlow(controller: controller, picker: picker, mode: mode),
      );
    } finally {
      onModalChanged?.call(false);
    }
    if (library == true) onLibrary();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final m = controller, v = m.value, c = UiPalette.of(context);
      return SettingsPageContent(
        scrollKey: const ValueKey('backup-page-scroll'),
        title: '备份与恢复',
        description: '使用独立恢复密钥保管完整备份。文件与密钥请分开保存；备份可能包含信息与凭据原文。',
        children: [
          if (m.loading) const LinearProgressIndicator(),
          if (m.readFailure != null) ...[
            Text(
              m.readFailure!.message,
              style: libraryText(context, 14, color: c.danger),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: DesktopButton(
                key: const ValueKey('backup-status-retry'),
                onPressed: m.frozen ? null : m.load,
                child: const Text('重新读取备份状态'),
              ),
            ),
          ],
          SettingsCard(
            children: [
              SettingsPreferenceRow(
                title: '独立恢复密钥',
                description: v == null
                    ? '正在核对备份配置…'
                    : v.keySaved
                    ? '恢复密钥已另存，可导出备份。'
                    : v.keyCreated
                    ? '恢复密钥已创建，尚未另存；请先独立保存。'
                    : '尚未创建恢复密钥。它与本机数据库密钥分开，换设备恢复需要它。',
                control: DesktopButton(
                  key: const ValueKey('backup-open-key'),
                  onPressed: m.available
                      ? () => _open(context, WorkspaceBackupMode.export)
                      : null,
                  child: const Text('管理恢复密钥'),
                ),
              ),
              SettingsPreferenceRow(
                title: '导出完整备份',
                description: v?.latestArchive == null
                    ? '保存当前信息、文件版本、分类、模板、设置及历史事实。'
                    : '最近生成：${v!.latestArchive!.name}',
                control: DesktopButton(
                  key: const ValueKey('backup-open-export'),
                  kind: DesktopButtonKind.primary,
                  onPressed: m.available
                      ? () => _open(context, WorkspaceBackupMode.export)
                      : null,
                  child: const Text('导出备份'),
                ),
              ),
              SettingsPreferenceRow(
                title: '恢复到空的信息库',
                divider: false,
                description: v == null
                    ? '正在核对目标库…'
                    : v.recipientEmpty
                    ? '当前目标库为空，可以选择备份和恢复密钥，再核对恢复范围。'
                    : '目标库非空：${v.blockers.join('、')}。不能覆盖或合并恢复，请使用独立空库。',
                control: DesktopButton(
                  key: const ValueKey('backup-open-restore'),
                  onPressed: m.available
                      ? () => _open(context, WorkspaceBackupMode.restore)
                      : null,
                  child: const Text('查看恢复流程'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 22),
          Text(
            '历史不会变回有效授权。恢复后 Agent 需要重新申请；活动会话、待审批、运行材料、输出和整理任务不随备份恢复。',
            style: libraryText(context, 14, color: c.muted, height: 1.9),
          ),
          if (m.cleanupNotice != null || v != null && v.cleanupCount > 0) ...[
            const SizedBox(height: 20),
            Text(
              m.cleanupNotice ?? '有 ${v!.cleanupCount} 份临时资源待清理，资料操作结果不受此状态替代。',
              style: libraryText(context, 14, color: c.warning, height: 1.8),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: DesktopButton(
                key: const ValueKey('backup-cleanup'),
                onPressed: m.available && v != null && v.cleanupCount > 0
                    ? () => m.write(WorkspaceBackupAction.cleanup)
                    : null,
                child: const Text('重试清理临时资源'),
              ),
            ),
          ],
          if (m.failure != null)
            Text(
              m.failure!.message,
              style: libraryText(context, 14, color: c.danger, height: 1.8),
            ),
          if (m.uncertain)
            Align(
              alignment: Alignment.centerLeft,
              child: DesktopButton(
                key: const ValueKey('backup-page-reconcile'),
                onPressed: m.busy ? null : m.reconcile,
                child: const Text('核对原备份操作'),
              ),
            ),
        ],
      );
    },
  );
}

class _BackupFlow extends StatefulWidget {
  const _BackupFlow({
    required this.controller,
    required this.picker,
    required this.mode,
  });
  final BackupController controller;
  final WorkspaceBackupPicker picker;
  final WorkspaceBackupMode mode;
  @override
  State<_BackupFlow> createState() => _BackupFlowState();
}

class _BackupFlowState extends State<_BackupFlow> {
  BackupController get m => widget.controller;
  bool _mayPop = false, _closing = false;
  Future<void> _close({bool library = false}) async {
    if (_closing || m.frozen) return;
    _closing = true;
    final done = await m.closeFlow();
    if (!mounted) return;
    if (!done) {
      _closing = false;
      return;
    }
    setState(() => _mayPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.pop(context, library);
    });
  }

  Widget _pick(
    BuildContext context,
    WorkspaceBackupPick kind,
    String label,
    WorkspaceBackupResource? value,
  ) => SettingsPreferenceRow(
    title: label,
    description: value?.name ?? '尚未选择',
    control: DesktopButton(
      key: ValueKey('backup-pick-${kind.name}'),
      onPressed: m.available ? () => m.pick(kind, widget.picker) : null,
      child: const Text('选择文件'),
    ),
  );
  Widget _counts(BuildContext context, WorkspaceBackupCounts counts) => Column(
    key: const ValueKey('backup-counts'),
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        '信息 ${counts[WorkspaceBackupCategory.information]} 条 · 凭据 ${counts[WorkspaceBackupCategory.credentials]} 项 · 凭据版本 ${counts[WorkspaceBackupCategory.materials]} 份',
        style: libraryText(context, 14, height: 1.9),
      ),
      Text(
        '目录 ${counts[WorkspaceBackupCategory.directories]} 个 · 标签 ${counts[WorkspaceBackupCategory.tags]} 个 · 类型定义 ${counts[WorkspaceBackupCategory.templates]} 份',
        style: libraryText(context, 14, height: 1.9),
      ),
      Text(
        '模板插件 ${counts[WorkspaceBackupCategory.plugins]} 个 · 旧版模板 ${counts[WorkspaceBackupCategory.legacyTemplates]} 份',
        style: libraryText(context, 14, height: 1.9),
      ),
      Text(
        '普通附件 ${counts[WorkspaceBackupCategory.files]} 个版本 · ${counts[WorkspaceBackupCategory.fileBytes]} 字节',
        style: libraryText(context, 14, height: 1.9),
      ),
      Text(
        '资料修订 ${counts[WorkspaceBackupCategory.revisions]} 条 · 回收对象 ${counts[WorkspaceBackupCategory.recycled]} 条',
        style: libraryText(context, 14, height: 1.9),
      ),
      Text(
        '授权历史 ${counts[WorkspaceBackupCategory.grants]} 条 · 操作事实 ${counts[WorkspaceBackupCategory.operations]} 条 · 主机信任 ${counts[WorkspaceBackupCategory.hosts]} 份',
        style: libraryText(context, 14, height: 1.9),
      ),
    ],
  );
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: m,
    builder: (context, _) {
      final c = UiPalette.of(context),
          v = m.value,
          export = widget.mode == WorkspaceBackupMode.export;
      return PopScope<bool>(
        canPop: _mayPop,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && !m.frozen) _close();
        },
        child: DesktopDialog(
          width: 840,
          title: Text(export ? '导出备份与恢复密钥' : '恢复到空的信息库'),
          closeEnabled: !m.frozen && !_closing,
          onClose: _close,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '恢复密钥独立于本机数据库密钥。完整备份与密钥请分开保管；删除当前内容不会擦除已导出的离线副本。',
                style: libraryText(context, 14, color: c.muted, height: 1.9),
              ),
              const SizedBox(height: 16),
              if (m.loading || m.busy && !m.choosing)
                const LinearProgressIndicator(),
              if (m.readFailure != null) ...[
                Text(
                  m.readFailure!.message,
                  style: libraryText(context, 14, color: c.danger),
                ),
                DesktopButton(
                  key: const ValueKey('backup-flow-status-retry'),
                  onPressed: m.frozen ? null : m.load,
                  child: const Text('重新读取状态'),
                ),
              ],
              if (export) ...[
                const SizedBox(height: 18),
                Text(
                  '1. 创建并独立保存恢复密钥',
                  style: libraryText(context, 18, weight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                Text(
                  v == null
                      ? '正在读取配置…'
                      : v.keySaved
                      ? '恢复密钥已另存。'
                      : v.keyCreated
                      ? '恢复密钥已创建，请先保存密钥文件。'
                      : '尚未创建恢复密钥。',
                  style: libraryText(context, 14, height: 1.8),
                ),
                if (v != null && !v.keyCreated)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: DesktopButton(
                      key: const ValueKey('backup-enable'),
                      onPressed: m.available
                          ? () => m.write(WorkspaceBackupAction.enableKey)
                          : null,
                      child: const Text('创建恢复密钥'),
                    ),
                  ),
                if (v?.keyCreated == true) ...[
                  Align(
                    alignment: Alignment.centerLeft,
                    child: DesktopButton(
                      key: const ValueKey('backup-key-reveal'),
                      onPressed: m.available ? m.toggleKey : null,
                      child: Text(m.revealedKey == null ? '显示恢复密钥' : '隐藏恢复密钥'),
                    ),
                  ),
                  if (m.revealedKey != null)
                    SelectableText(
                      m.revealedKey!,
                      style: libraryText(context, 13, height: 1.8),
                    ),
                  _pick(
                    context,
                    WorkspaceBackupPick.keyOutput,
                    '恢复密钥另存位置',
                    m.keyOutput,
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: DesktopButton(
                      key: const ValueKey('backup-save-key'),
                      onPressed: m.available && m.keyOutput != null
                          ? () => m.write(WorkspaceBackupAction.saveKey)
                          : null,
                      child: const Text('保存恢复密钥文件'),
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                Text(
                  '2. 导出完整备份',
                  style: libraryText(context, 18, weight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                Text(
                  '包含当前资料、保留版本和回收对象、普通附件原文、凭据材料、分类、模板、设置及历史事实；不恢复活跃访问能力。',
                  style: libraryText(context, 14, color: c.muted, height: 1.9),
                ),
                _pick(
                  context,
                  WorkspaceBackupPick.archiveOutput,
                  '备份另存位置',
                  m.archiveOutput,
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: DesktopButton(
                    key: const ValueKey('backup-export'),
                    kind: DesktopButtonKind.primary,
                    onPressed:
                        m.available &&
                            v?.keySaved == true &&
                            m.archiveOutput != null
                        ? () => m.write(WorkspaceBackupAction.export)
                        : null,
                    child: const Text('导出完整备份'),
                  ),
                ),
                if (v?.keySaved != true)
                  Text(
                    '另存恢复密钥成功后才能导出。',
                    style: libraryText(
                      context,
                      13,
                      color: c.muted,
                      height: 1.8,
                    ),
                  ),
              ] else if (m.result?.action != WorkspaceBackupAction.restore) ...[
                const SizedBox(height: 18),
                Text(
                  v == null
                      ? '正在核对目标库…'
                      : v.recipientEmpty
                      ? '当前目标库为空，可以检查备份。'
                      : '目标库非空，不能覆盖或合并恢复。${v.blockers.join('、')}仍存在。',
                  key: const ValueKey('backup-recipient-state'),
                  style: libraryText(
                    context,
                    14,
                    color: v?.recipientEmpty == true ? c.muted : c.warning,
                    height: 1.9,
                  ),
                ),
                _pick(
                  context,
                  WorkspaceBackupPick.archiveInput,
                  '备份文件',
                  m.archiveInput,
                ),
                _pick(
                  context,
                  WorkspaceBackupPick.keyInput,
                  '恢复密钥文件',
                  m.keyInput,
                ),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerLeft,
                  child: DesktopButton(
                    key: const ValueKey('backup-inspect'),
                    onPressed: m.canInspect ? m.inspect : null,
                    child: const Text('检查备份与恢复密钥'),
                  ),
                ),
                if (m.preview case final p?) ...[
                  const SizedBox(height: 22),
                  Text(
                    '恢复范围',
                    style: libraryText(context, 18, weight: FontWeight.w600),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '${p.formatLabel} · ${libraryLocalDateTime(p.createdAt)}',
                    style: libraryText(context, 13, color: c.muted),
                  ),
                  _counts(context, p.counts),
                  const SizedBox(height: 14),
                  Text(
                    '只向空库恢复。主题和期限设置随资料恢复；本机数据库密钥与本机备份配置不从原设备复制。原活跃会话、待审批、运行材料、输出、整理任务与结果不会在此生效。',
                    style: libraryText(
                      context,
                      14,
                      color: c.muted,
                      height: 1.9,
                    ),
                  ),
                ],
              ],
              if (m.failure != null) ...[
                const SizedBox(height: 18),
                Text(
                  m.failure!.message,
                  key: const ValueKey('backup-error'),
                  style: libraryText(context, 14, color: c.danger, height: 1.9),
                ),
              ],
              if (m.result case final r?) ...[
                const SizedBox(height: 20),
                Text(
                  switch (r.action) {
                    WorkspaceBackupAction.enableKey => '恢复密钥已创建，请独立另存。',
                    WorkspaceBackupAction.saveKey => '恢复密钥已另存，请与备份文件分开保管。',
                    WorkspaceBackupAction.export => '备份已生成：${r.resource!.name}',
                    WorkspaceBackupAction.restore =>
                      '资料已恢复。历史不表示有效授权，Agent 需要重新申请。',
                    WorkspaceBackupAction.cleanup => '临时资源已清理。',
                  },
                  key: const ValueKey('backup-result'),
                  style: libraryText(context, 15, color: c.accent, height: 1.9),
                ),
                if (r.counts != null) _counts(context, r.counts!),
              ],
              if (m.cleanupNotice != null ||
                  v != null && v.cleanupCount > 0) ...[
                const SizedBox(height: 18),
                Text(
                  m.cleanupNotice ??
                      '有 ${v!.cleanupCount} 份临时资源待清理。请返回备份设置重试清理；这不改变已确认的资料操作结果。',
                  style: libraryText(
                    context,
                    14,
                    color: c.warning,
                    height: 1.8,
                  ),
                ),
              ],
            ],
          ),
          actions: [
            if (!export &&
                m.preview != null &&
                m.result?.action != WorkspaceBackupAction.restore)
              DesktopButton(
                key: const ValueKey('backup-restore'),
                kind: DesktopButtonKind.primary,
                onPressed: m.canRestore
                    ? () => m.write(WorkspaceBackupAction.restore)
                    : null,
                child: const Text('确认恢复到空库'),
              ),
            if (m.uncertain)
              DesktopButton(
                key: const ValueKey('backup-reconcile'),
                onPressed: m.busy ? null : m.reconcile,
                child: const Text('核对原备份操作'),
              ),
            if (m.result?.action == WorkspaceBackupAction.restore)
              DesktopButton(
                key: const ValueKey('backup-open-library'),
                onPressed: m.frozen ? null : () => _close(library: true),
                child: const Text('前往信息库'),
              ),
            DesktopButton(
              key: const ValueKey('backup-flow-close'),
              onPressed: m.frozen || _closing ? null : _close,
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    },
  );
}
