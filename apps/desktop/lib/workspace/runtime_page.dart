import 'dart:async';
import 'package:flutter/material.dart';
import '../desktop_controls.dart';
import '../ui_palette.dart';
import 'library_widgets.dart';
import 'runtime_controller.dart';
import 'settings_controller.dart';
import 'settings_page.dart' show SettingsPreferenceRow;
import 'settings_layout.dart';
import 'workspace_source.dart';

class WorkspaceRuntimePage extends StatelessWidget {
  const WorkspaceRuntimePage({
    super.key,
    required this.controller,
    required this.preferences,
    required this.onRequest,
    this.onModalChanged,
  });
  final WorkspaceRuntimeController controller;
  final WorkspaceSettingsController preferences;
  final ValueChanged<String> onRequest;
  final ValueChanged<bool>? onModalChanged;
  Future<void> _quit(BuildContext context) async {
    if (!controller.available || preferences.frozen) return;
    onModalChanged?.call(true);
    try {
      await showDesktopDialog<void>(
        context,
        builder: (_) => _QuitFlow(controller: controller),
      );
    } finally {
      onModalChanged?.call(false);
    }
  }

  Future<void> _maintenance(BuildContext context, bool materials) async {
    if (!controller.available || preferences.frozen) return;
    controller.begin();
    onModalChanged?.call(true);
    String? target;
    try {
      target = await showDesktopDialog<String>(
        context,
        builder: (_) =>
            _MaintenanceFlow(controller: controller, materials: materials),
      );
    } finally {
      onModalChanged?.call(false);
    }
    if (target != null) onRequest(target);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([controller, preferences]),
    builder: (context, _) {
      final m = controller,
          v = m.value,
          p = preferences,
          c = UiPalette.of(context);
      final active = m.available && !p.frozen,
          canOperate = m.canMaintain && !p.frozen;
      final backgroundReady =
          p.value != null &&
          p.draft != null &&
          !p.loading &&
          p.readFailure == null &&
          !p.frozen &&
          p.draft!
              .copyWith(background: p.value!.background)
              .sameValues(p.value!);
      return SettingsPageContent(
        scrollKey: const ValueKey('runtime-page-scroll'),
        title: '应用运行',
        description: '查看本机服务、登记材料和关闭方式。材料回收与外部进程是否结束分别核对。',
        children: [
          if (m.loading) const LinearProgressIndicator(),
          if (m.readFailure != null)
            Text(
              m.readFailure!.message,
              style: libraryText(context, 14, color: c.danger),
            ),
          SettingsCard(
            children: [
              SettingsPreferenceRow(
                title: v == null
                    ? '正在核对本机服务…'
                    : v.serviceAvailable
                    ? '本机服务运行中'
                    : v.phase == WorkspaceRuntimePhase.saveFailed
                    ? '退出保存未完成'
                    : '本机服务暂不可用',
                description:
                    v?.serviceReason ?? 'Agent 从这里提交申请；实际读取信息和使用凭据仍需你的授权。',
                control: DesktopButton(
                  key: const ValueKey('runtime-refresh'),
                  onPressed: m.frozen ? null : m.load,
                  child: const Text('重新读取状态'),
                ),
              ),
              SettingsPreferenceRow(
                title: '临时凭据材料',
                description: v == null
                    ? '正在核对已登记的执行…'
                    : v.materials.isEmpty
                    ? '暂无已登记材料。活动任务使用的文件保留至进程组结束。'
                    : '已登记 ${v.materials.length} 项执行。核查只处理身份已确认结束的材料，不重跑命令或终止进程。',
                control: DesktopButton(
                  key: const ValueKey('runtime-materials'),
                  onPressed: active ? () => _maintenance(context, true) : null,
                  child: const Text('查看材料'),
                ),
              ),
              SettingsPreferenceRow(
                title: '普通附件维护',
                description: v == null
                    ? '正在核对已登记副本…'
                    : '撤销、到期或范围失效后回收已登记副本；活动授权的副本保留。当前原文和保留版本不因副本核查被删除。',
                control: DesktopButton(
                  key: const ValueKey('runtime-attachments'),
                  onPressed: active ? () => _maintenance(context, false) : null,
                  child: const Text('核查附件'),
                ),
              ),
              SettingsPreferenceRow(
                title: '关闭窗口后继续运行',
                description: v?.menuBarAvailable == false
                    ? '菜单栏入口不可用。继续运行时会保留窗口，避免无法重新打开。'
                    : '收起到 Mac 菜单栏，继续接收申请；关闭窗口不会延长授权期限。关闭此选项后，关闭窗口需要先确认完全退出。',
                control: p.value == null || p.draft == null
                    ? Text(
                        p.readFailure == null ? '正在读取…' : '暂不可用',
                        style: libraryText(context, 14, color: c.muted),
                      )
                    : Switch(
                        key: const ValueKey('runtime-background'),
                        value: p.draft!.background,
                        onChanged: backgroundReady && canOperate
                            ? (value) => p.setBackground(value)
                            : null,
                      ),
              ),
              if (p.readFailure != null) ...[
                Text(
                  p.readFailure!.message,
                  style: libraryText(context, 14, color: c.danger),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: DesktopButton(
                    key: const ValueKey('runtime-preferences-retry'),
                    onPressed: p.frozen ? null : p.load,
                    child: const Text('重新读取关闭方式'),
                  ),
                ),
              ],
              if (!backgroundReady && p.dirty)
                Text(
                  '其他设置仍有未保存或冲突的选择，请先完成原设置。',
                  style: libraryText(
                    context,
                    13,
                    color: c.warning,
                    height: 1.8,
                  ),
                ),
              if (p.writeFailure != null) ...[
                Text(
                  p.writeFailure!.message,
                  style: libraryText(context, 14, color: c.danger),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: DesktopButton(
                    key: const ValueKey('runtime-background-retry'),
                    onPressed: p.uncertain
                        ? (p.busy ? null : p.reconcile)
                        : p.canSave
                        ? p.save
                        : null,
                    child: Text(p.uncertain ? '核对原设置操作' : '重试保存设置'),
                  ),
                ),
              ],
              SettingsPreferenceRow(
                title: '关闭工作窗口',
                description: v?.windowHidden == true
                    ? '工作窗口已收起；可从菜单栏重新打开，当前会话与期限保持。'
                    : '继续运行时只收起工作窗口；完全退出会另行确认。',
                control: DesktopButton(
                  key: const ValueKey('runtime-close-window'),
                  onPressed: canOperate && p.value != null
                      ? () => v!.windowHidden
                            ? m.write(WorkspaceRuntimeAction.showWindow)
                            : p.value!.background
                            ? m.write(WorkspaceRuntimeAction.hideWindow)
                            : _quit(context)
                      : null,
                  child: Text(v?.windowHidden == true ? '重新打开窗口' : '关闭窗口'),
                ),
              ),
              SettingsPreferenceRow(
                title: '完全退出应用',
                divider: false,
                description:
                    '先保存退出事实，再停止本机服务并结束会话授权。已启动的外部程序可能继续运行；使用中的材料和未确认副本不保证立即回收。',
                control: DesktopButton(
                  key: const ValueKey('runtime-quit'),
                  onPressed: active ? () => _quit(context) : null,
                  child: Text(
                    v?.phase == WorkspaceRuntimePhase.saveFailed
                        ? '重试保存并退出'
                        : '完全退出',
                  ),
                ),
              ),
            ],
          ),
          if (m.failure != null)
            Text(
              m.failure!.message,
              key: const ValueKey('runtime-error'),
              style: libraryText(context, 14, color: c.danger, height: 1.9),
            ),
          if (m.uncertain)
            Align(
              alignment: Alignment.centerLeft,
              child: DesktopButton(
                key: const ValueKey('runtime-reconcile'),
                onPressed: m.busy ? null : m.reconcile,
                child: const Text('核对原运行操作'),
              ),
            ),
          if (m.result?.action == WorkspaceRuntimeAction.hideWindow ||
              m.result?.action == WorkspaceRuntimeAction.showWindow)
            Text(
              m.result!.windowHidden ? '工作窗口已收起，服务继续接收申请。' : '工作窗口已重新打开。',
              key: const ValueKey('runtime-window-result'),
              style: libraryText(context, 14, color: c.accent, height: 1.8),
            ),
        ],
      );
    },
  );
}

class _QuitFlow extends StatefulWidget {
  const _QuitFlow({required this.controller});
  final WorkspaceRuntimeController controller;
  @override
  State<_QuitFlow> createState() => _QuitFlowState();
}

class _QuitFlowState extends State<_QuitFlow> {
  WorkspaceRuntimeController get m => widget.controller;
  bool _mayPop = false, _closing = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(m.prepareQuit());
    });
  }

  Future<void> _close() async {
    if (_closing || m.frozen) return;
    _closing = true;
    if (!await m.closeQuit() || !mounted) {
      _closing = false;
      return;
    }
    setState(() => _mayPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.pop(context);
    });
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: m,
    builder: (context, _) {
      final c = UiPalette.of(context), p = m.quitPreview, r = m.result;
      return PopScope(
        canPop: _mayPop,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _close();
        },
        child: DesktopDialog(
          width: 740,
          title: const Text('完全退出应用'),
          closeEnabled: !m.frozen && !_closing,
          onClose: _close,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '保存退出事实、停止本机服务并结束会话授权。退出不等于终止已启动的外部程序，也不保证收回已读取的副本。',
                style: libraryText(context, 15, height: 1.9),
              ),
              const SizedBox(height: 18),
              if (m.preparing || m.busy) const LinearProgressIndicator(),
              if (p != null) ...[
                Text(
                  '将结束 ${p.sessions} 个会话中的 ${p.grants} 项有效授权；${p.pendingRequests} 条待处理申请失效。',
                  key: const ValueKey('runtime-quit-scope'),
                  style: libraryText(context, 15, height: 1.9),
                ),
                const SizedBox(height: 14),
                Text(
                  '${p.materials} 项材料、${p.copies} 份副本仍登记保留；${p.unconfirmedProcesses} 个外部进程尚未确认结束。',
                  style: libraryText(
                    context,
                    14,
                    color: c.warning,
                    height: 1.9,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  '身份未知或使用中的文件保持登记。下次启动继续核查，不重新执行命令、不恢复旧授权。',
                  style: libraryText(context, 14, color: c.muted, height: 1.9),
                ),
              ],
              if (m.failure != null) ...[
                const SizedBox(height: 16),
                Text(
                  m.failure!.message,
                  key: const ValueKey('runtime-quit-error'),
                  style: libraryText(context, 14, color: c.danger, height: 1.9),
                ),
              ],
              if (r?.action == WorkspaceRuntimeAction.quit) ...[
                const SizedBox(height: 18),
                Text(
                  switch (r!.phase) {
                    WorkspaceRuntimePhase.saveFailed =>
                      '退出审计尚未保存，资料库仍保持打开；新申请已停止，已结束的授权不会恢复。请重新核对后重试保存。',
                    WorkspaceRuntimePhase.terminationFailed =>
                      '退出事实已保存，本机服务已停止；应用进程退出未完成，可以重试退出应用。',
                    WorkspaceRuntimePhase.stopped =>
                      '退出事实已保存，本机服务已停止，当前会话授权已结束。',
                    WorkspaceRuntimePhase.running => '运行状态需要重新核对。',
                  },
                  key: const ValueKey('runtime-quit-result'),
                  style: libraryText(
                    context,
                    15,
                    color: r.phase == WorkspaceRuntimePhase.stopped
                        ? c.accent
                        : c.danger,
                    height: 1.9,
                  ),
                ),
              ],
            ],
          ),
          actions: [
            if (m.uncertain)
              DesktopButton(
                key: const ValueKey('runtime-quit-reconcile'),
                onPressed: m.busy ? null : m.reconcile,
                child: const Text('核对原退出操作'),
              ),
            if (!m.uncertain &&
                !m.preparing &&
                p == null &&
                m.value?.closed != true)
              DesktopButton(
                key: const ValueKey('runtime-quit-preview-retry'),
                onPressed: m.available ? m.prepareQuit : null,
                child: const Text('重新核对退出范围'),
              ),
            if (p != null)
              DesktopButton(
                key: const ValueKey('runtime-quit-confirm'),
                kind: DesktopButtonKind.primary,
                onPressed: m.canQuit
                    ? () => m.write(WorkspaceRuntimeAction.quit)
                    : null,
                child: const Text('保存并完全退出'),
              ),
            DesktopButton(
              key: const ValueKey('runtime-quit-cancel'),
              onPressed: m.frozen || _closing ? null : _close,
              child: Text(
                m.value?.closed == true
                    ? '关闭'
                    : m.shutdownGate
                    ? '返回运行设置'
                    : '继续运行',
              ),
            ),
          ],
        ),
      );
    },
  );
}

class _MaintenanceFlow extends StatefulWidget {
  const _MaintenanceFlow({required this.controller, required this.materials});
  final WorkspaceRuntimeController controller;
  final bool materials;
  @override
  State<_MaintenanceFlow> createState() => _MaintenanceFlowState();
}

class _MaintenanceFlowState extends State<_MaintenanceFlow> {
  int _page = 0;
  bool _mayPop = false;
  WorkspaceRuntimeController get m => widget.controller;
  void _close([String? request]) {
    if (m.frozen) return;
    setState(() => _mayPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.pop(context, request);
    });
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: m,
    builder: (context, _) {
      final c = UiPalette.of(context),
          materials = widget.materials,
          v = m.value;
      final count = materials
              ? v?.materials.length ?? 0
              : v?.copies.length ?? 0,
          pages = ((count + 4) ~/ 5).clamp(1, 1 << 30),
          page = _page.clamp(0, pages - 1);
      final action = materials
              ? WorkspaceRuntimeAction.checkMaterials
              : WorkspaceRuntimeAction.checkAttachments,
          r = m.result;
      return PopScope(
        canPop: _mayPop,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _close();
        },
        child: DesktopDialog(
          width: 860,
          title: Text(materials ? '临时凭据材料' : '普通附件维护'),
          closeEnabled: !m.frozen,
          onClose: _close,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                materials
                    ? '只核查已登记的材料；活动进程或身份未确认时保留。回收不重跑命令、不终止进程，也不改变授权期限。'
                    : '只处理已登记副本；有效授权继续保留，撤销、到期或范围失效后再回收。登记路径移除不承诺收回已读取内容。',
                style: libraryText(context, 14, color: c.muted, height: 1.9),
              ),
              const SizedBox(height: 18),
              if (m.loading || m.busy) const LinearProgressIndicator(),
              if (count == 0 && m.readFailure == null && !m.loading)
                Text(
                  materials ? '暂无已登记的临时材料。' : '暂无已登记的附件副本。',
                  key: const ValueKey('runtime-maintenance-empty'),
                  style: libraryText(context, 15, height: 1.9),
                ),
              if (materials && v != null)
                for (final e in v.materials.skip(page * 5).take(5))
                  SettingsPreferenceRow(
                    title: e.plan.label,
                    description:
                        '${libraryLocalDateTime(e.createdAt)} · ${e.resultLabel} · ${!e.processStarted
                            ? '目标程序未启动'
                            : e.processEnded
                            ? '进程组已确认结束'
                            : '进程组尚未确认结束'} · ${e.cleanup.label}',
                    control: DesktopButton(
                      key: ValueKey(
                        'runtime-material-request-${e.operationId}',
                      ),
                      onPressed: m.frozen || m.shutdownGate
                          ? null
                          : () => _close(e.requestId),
                      child: const Text('查看原申请'),
                    ),
                  ),
              if (!materials && v != null)
                for (final e in v.copies.skip(page * 5).take(5))
                  SettingsPreferenceRow(
                    title: '${e.name} · v${e.fileVersion}',
                    description:
                        '${e.state.label} · 副本期限 ${libraryLocalDateTime(e.expiresAt)}${e.reason == null ? '' : ' · ${e.reason}'}',
                    control: DesktopButton(
                      key: ValueKey('runtime-copy-request-${e.id}'),
                      onPressed: m.frozen || m.shutdownGate
                          ? null
                          : () => _close(e.requestId),
                      child: const Text('查看原申请'),
                    ),
                  ),
              if (v != null && !v.serviceAvailable)
                Text(
                  v.serviceReason ?? '本机服务不可用，核查暂不可用。',
                  style: libraryText(
                    context,
                    14,
                    color: c.warning,
                    height: 1.9,
                  ),
                ),
              if (m.readFailure != null)
                Text(
                  m.readFailure!.message,
                  style: libraryText(context, 14, color: c.danger),
                ),
              if (m.failure != null)
                Text(
                  m.failure!.message,
                  key: const ValueKey('runtime-maintenance-error'),
                  style: libraryText(context, 14, color: c.danger, height: 1.9),
                ),
              if (r?.action == action)
                Text(
                  '已核查 ${r!.checked} 项，释放 ${r.released} 项登记，仍保留 ${r.retained} 项。',
                  key: const ValueKey('runtime-maintenance-result'),
                  style: libraryText(
                    context,
                    14,
                    color: r.retained > 0 ? c.warning : c.accent,
                    height: 1.9,
                  ),
                ),
            ],
          ),
          actions: [
            if (pages > 1) ...[
              DesktopButton(
                onPressed: m.frozen || page == 0
                    ? null
                    : () => setState(() => _page = page - 1),
                child: const Text('上一页'),
              ),
              Text('${page + 1} / $pages'),
              DesktopButton(
                onPressed: m.frozen || page + 1 >= pages
                    ? null
                    : () => setState(() => _page = page + 1),
                child: const Text('下一页'),
              ),
            ],
            if (m.uncertain)
              DesktopButton(
                key: const ValueKey('runtime-maintenance-reconcile'),
                onPressed: m.busy ? null : m.reconcile,
                child: const Text('核对原核查操作'),
              )
            else
              DesktopButton(
                key: const ValueKey('runtime-maintenance-check'),
                kind: DesktopButtonKind.primary,
                onPressed: m.canMaintain ? () => m.write(action) : null,
                child: const Text('重新核查'),
              ),
            DesktopButton(
              key: const ValueKey('runtime-maintenance-close'),
              onPressed: m.frozen ? null : _close,
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    },
  );
}
