import 'dart:convert';
import 'package:flutter/material.dart';
import '../desktop_controls.dart';
import '../desktop_motion.dart';
import '../ui_palette.dart';
import 'approvals_controller.dart';
import 'library_widgets.dart';
import 'workspace_source.dart';
import 'batch_operations.dart';
import 'program_operations.dart';

/// One grant can have many independent operations. Owner only reads results.
class ApprovalExecutions extends StatelessWidget {
  const ApprovalExecutions({super.key, required this.controller});
  final ApprovalsController controller;
  @override
  Widget build(BuildContext context) {
    final detail = controller.detail!, c = UiPalette.of(context);
    if (detail.programPlan != null) {
      return ProgramOperations(controller: controller);
    }
    if (detail.credentialBatch) return BatchOperations(controller: controller);
    if (detail.credentialExpiresAt == null &&
        !detail.credentialSessionBound &&
        detail.executions.isEmpty) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: 26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '凭据使用记录',
            style: libraryText(context, 17, weight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          if (detail.executions.isEmpty)
            Text(
              '尚无使用记录。批准不等于已经启动程序。',
              style: libraryText(context, 14, color: c.muted),
            ),
          for (final e in detail.executions) _operation(context, e),
          if (detail.executions.isNotEmpty)
            Text(
              '每条操作独立记录；查询不会启动程序、再次填充或延长授权期限。',
              style: libraryText(context, 13, color: c.muted, height: 1.9),
            ),
        ],
      ),
    );
  }

  Widget _operation(BuildContext context, WorkspaceApprovalExecution e) {
    final c = UiPalette.of(context),
        key = 'execution:${e.operationId}',
        expanded = controller.draft!.expanded.contains(key),
        unknown = e.state == WorkspaceExecutionState.unknown,
        color = unknown
            ? c.warning
            : e.state == WorkspaceExecutionState.exited
            ? (e.exitCode == 0 ? c.success : c.danger)
            : e.state == WorkspaceExecutionState.prepareFailed ||
                  e.state == WorkspaceExecutionState.startFailed
            ? c.danger
            : c.accent;
    return DesktopEntrance(
      key: ValueKey('approval-operation-${e.operationId}'),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 18),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: c.line)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              spacing: 15,
              runSpacing: 8,
              children: [
                Text(
                  e.plan.label,
                  style: libraryText(context, 15, weight: FontWeight.w600),
                ),
                Text(
                  e.resultLabel,
                  style: libraryText(
                    context,
                    14,
                    color: color,
                    weight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '操作 ${e.operationId}',
              style: libraryText(context, 12, color: c.muted),
            ),
            Text(
              '${libraryLocalDateTime(e.createdAt)} · ${e.credential.credentialName} · 材料v${e.credential.materialVersion}',
              style: libraryText(context, 13, color: c.muted, height: 1.9),
            ),
            Text(
              e.fromBackup
                  ? '备份中的原设备进程事实；本机不接管原进程或临时材料。'
                  : '进程：${!e.processStarted
                        ? e.state == WorkspaceExecutionState.unknown
                              ? '是否启动尚未确认'
                              : '未启动'
                        : e.processEnded
                        ? '已确认结束'
                        : '尚未确认结束'} · 临时材料：${e.cleanup.label}',
              style: libraryText(context, 13, color: c.muted, height: 1.9),
            ),
            if (unknown) ...[
              const SizedBox(height: 8),
              Text(
                e.fromBackup
                    ? '原设备的未知结果保留为历史事实；此处不能验证原进程，也不会重新执行。'
                    : '尚不能确认执行结果。进程结束或材料已清理不代表执行成功；请查询原操作，不要重跑。',
                style: libraryText(context, 13, color: c.warning, height: 1.9),
              ),
            ] else if (!e.fromBackup &&
                (e.state == WorkspaceExecutionState.prepareFailed ||
                    e.state == WorkspaceExecutionState.startFailed))
              Text(
                '本次未启动程序，不代表授权已失效。后续操作仍需独立检查会话、版本和期限。',
                style: libraryText(context, 13, color: c.muted, height: 1.9),
              ),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                DesktopButton(
                  key: ValueKey('approval-operation-plan-${e.operationId}'),
                  kind: DesktopButtonKind.quiet,
                  onPressed: controller.frozen
                      ? null
                      : () => controller.expand(key),
                  child: Text(expanded ? '收起本次启动计划' : '查看本次启动计划'),
                ),
                DesktopButton(
                  key: ValueKey('approval-operation-refresh-${e.operationId}'),
                  kind: DesktopButtonKind.quiet,
                  busy: controller.readingExecution(e.operationId),
                  onPressed:
                      controller.frozen ||
                          controller.loading ||
                          controller.reading ||
                          controller.readingExecution(e.operationId)
                      ? null
                      : () => controller.refreshExecution(e.operationId),
                  child: Text(e.fromBackup ? '重新读取历史事实' : '查询原操作'),
                ),
              ],
            ),
            if (expanded) ...[
              const SizedBox(height: 10),
              SelectableText(
                '${e.plan.executable} ${e.plan.arguments.map((a) => a.contains(RegExp(r"\s")) ? jsonEncode(a) : a).join(' ')}',
                style: libraryText(context, 13, height: 1.9),
              ),
              Text(
                '接收方：${e.plan.id} · ${e.credential.delivery.label}\n工作位置：${e.plan.workingDirectory}\n引用：${e.plan.binding}\n授权：${e.grantId}',
                style: libraryText(context, 13, color: c.muted, height: 1.9),
              ),
            ],
            if (controller.executionError(e.operationId) case final error?) ...[
              const SizedBox(height: 8),
              Text(
                error,
                style: libraryText(context, 13, color: c.danger, height: 1.9),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
