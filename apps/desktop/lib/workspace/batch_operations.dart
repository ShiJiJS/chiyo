import 'dart:convert';
import 'package:flutter/material.dart';
import 'approval_presentation.dart';
import '../desktop_controls.dart';
import '../ui_palette.dart';
import 'approvals_controller.dart';
import 'library_widgets.dart';
import 'workspace_source.dart';
import 'operation_pages_footer.dart';

/// One renderer is shared by request details and grant history. These buttons
/// query/acknowledge facts; they never submit input or launch another operation.
class BatchOperations extends StatefulWidget {
  const BatchOperations({super.key, required this.controller});
  final ApprovalsController controller;
  @override
  State<BatchOperations> createState() => _BatchOperationsState();
}

class _BatchOperationsState extends State<BatchOperations> {
  String? _request;
  int _shown = 20;
  final _expanded = <String>{};
  final _confirmed = <(String, int)>{};
  @override
  Widget build(BuildContext context) {
    final model = widget.controller, detail = widget.controller.detail;
    if (detail == null ||
        !detail.credentialBatch ||
        detail.batchOperations.isEmpty && detail.approved.isEmpty) {
      return const SizedBox.shrink();
    }
    if (_request != detail.request.id) {
      _request = detail.request.id;
      _shown = 20;
      _expanded.clear();
      _confirmed.clear();
    }
    final c = UiPalette.of(context);
    final operations = detail.batchOperations.toList()
      ..sort(
        (a, b) => CredentialOperationCursor.compare(
          a.createdAt,
          a.operationId,
          b.createdAt,
          b.operationId,
        ),
      );
    final names = {for (final s in detail.scopes) s.id: s.recordName};
    return Padding(
      padding: const EdgeInsets.only(top: 26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            detail.sshSession ? 'SSH 使用记录' : '填写记录',
            style: libraryText(context, 17, weight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            '批准与使用分别记录。刷新状态只读取已有结果，不会再次发送或执行。',
            style: libraryText(context, 13, color: c.muted, height: 1.8),
          ),
          const SizedBox(height: 12),
          if (operations.isEmpty)
            Text(
              detail.sshSession ? '尚无 SSH 使用记录。批准后，仍由 Agent 发起连接。' : '尚无填写记录。',
              style: libraryText(context, 14, color: c.muted),
            ),
          for (final o
              in detail.operationTotal == null
                  ? operations.take(_shown)
                  : operations)
            _operation(context, model, o, names),
          if (detail.operationTotal == null && operations.length > _shown)
            DesktopButton(
              kind: DesktopButtonKind.quiet,
              onPressed: () => setState(() => _shown += 20),
              child: Text('显示更多记录（剩余${operations.length - _shown}次）'),
            ),
          OperationPagesFooter(controller: widget.controller),
        ],
      ),
    );
  }

  Widget _operation(
    BuildContext context,
    ApprovalsController model,
    WorkspaceCredentialBatchOperation o,
    Map<String, String> names,
  ) {
    final c = UiPalette.of(context),
        expanded = _expanded.contains(o.operationId);
    final checked = _confirmed.contains((o.operationId, o.revision));
    final enabled = !model.frozen && !model.readingExecution(o.operationId);
    final canAcknowledge =
        model.source is WorkspaceCredentialBatchActions &&
        !o.fromBackup &&
        o.sshContext == null;
    final color = o.needsAttention
        ? c.warning
        : o.sshContext != null
        ? c.accent
        : o.state == 'filled'
        ? c.success
        : c.muted;
    return Container(
      key: ValueKey('batch-operation-${o.operationId}'),
      padding: const EdgeInsets.symmetric(vertical: 18),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            spacing: 14,
            runSpacing: 6,
            children: [
              Text(
                o.sshContext != null
                    ? o.operationLabel
                    : o.itemIds.map((id) => names[id] ?? '凭据').join('、'),
                style: libraryText(context, 15, weight: FontWeight.w600),
              ),
              Text(
                o.summaryLabel,
                style: libraryText(
                  context,
                  14,
                  color: color,
                  weight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            libraryLocalDateTime(o.createdAt),
            style: libraryText(context, 12, color: c.muted),
          ),
          if (o.sshContext case final ssh?) ...[
            Text(
              ssh.requiresMaterial
                  ? '所用凭据：${o.itemIds.map((id) => names[id] ?? '凭据').join('、')}'
                  : '本次沿用登录许可，没有再次领取私钥或密码。',
              style: libraryText(context, 13, color: c.muted, height: 1.8),
            ),
            if (o.state == 'filled')
              Text(switch (ssh.kind) {
                'run' => '已发送到这次 SSH 连接，尚无命令完成结果。',
                'input' => '已发送到原 SSH 运行，不代表运行已经结束。',
                'credential' => '密码已发送给原认证接收程序，不代表认证成功。',
                _ => '凭据已交给连接程序，不代表连接成功。',
              }, style: libraryText(context, 13, color: c.muted, height: 1.8)),
            if (o.needsAttention)
              Text(
                '尚未确认是否发送，请让 Agent 查询原连接或命令，不要重新发送。',
                style: libraryText(context, 13, color: c.warning, height: 1.8),
              ),
          ],
          if (o.errorLabel != null)
            Text(
              o.errorLabel!,
              style: libraryText(context, 13, color: color, height: 1.8),
            ),
          Wrap(
            spacing: 8,
            children: [
              DesktopButton(
                key: ValueKey('batch-details-${o.operationId}'),
                kind: DesktopButtonKind.quiet,
                leading: Icon(
                  expanded ? Icons.expand_less : Icons.expand_more,
                  size: 17,
                ),
                onPressed: model.frozen
                    ? null
                    : () => setState(
                        () => expanded
                            ? _expanded.remove(o.operationId)
                            : _expanded.add(o.operationId),
                      ),
                child: const Text('详情'),
              ),
              if (!o.fromBackup)
                OperationRefresh(
                  key: ValueKey('batch-query-${o.operationId}'),
                  controller: model,
                  operationId: o.operationId,
                  refresh: () => model.refreshBatchOperation(o.operationId),
                  observation: () {
                    final current = model.detail!.batchOperations.firstWhere(
                      (item) => item.operationId == o.operationId,
                    );
                    return jsonEncode(current.toJson()..remove('observedAt'));
                  },
                ),
            ],
          ),
          if (expanded) ...[
            SelectableText(
              [
                '操作 ${o.operationId}',
                if (o.sshContext case final ssh?) ...[
                  '操作类型：${o.operationLabel}',
                  'SSH 会话：${ssh.sessionId}',
                  if (ssh.runId != null) '运行编号：${ssh.runId}',
                  if (model.detail!.sshTarget case final target?)
                    '连接：${target.user}@${target.host}:${target.port}',
                ],
              ].join('\n'),
              style: libraryText(context, 12, color: c.muted),
            ),
            for (final id in o.itemIds)
              Text(
                '${names[id] ?? '凭据'}：${o.itemResultLabel(o.itemResults[id] ?? o.state)}',
                style: libraryText(context, 13, height: 1.8),
              ),
          ],
          if (expanded && o.sshContext != null)
            Text(
              '授权历史仅保留操作信息，不保存命令正文或输出。命令结果由 Agent 查询。',
              style: libraryText(context, 13, color: c.muted, height: 1.8),
            ),
          if (o.fromBackup)
            Text(
              '这是备份中的历史，不能恢复原聊天的许可。',
              style: libraryText(context, 13, color: c.muted, height: 1.8),
            ),
          if (o.attentionAcknowledgedAt != null)
            Text(
              '已由用户核对，原结果保持不变。',
              style: libraryText(context, 13, color: c.muted, height: 1.8),
            ),
          if (o.needsAttention && canAcknowledge) ...[
            const SizedBox(height: 10),
            Text(
              '结果未知不代表没有填写。确认原操作已停止，并检查目标内容后，才能解除后续填写限制。',
              style: libraryText(context, 13, color: c.warning, height: 1.8),
            ),
            DesktopButton(
              key: ValueKey('batch-checked-${o.operationId}'),
              kind: DesktopButtonKind.quiet,
              alignment: Alignment.centerLeft,
              leading: Icon(
                checked ? Icons.check_box : Icons.check_box_outline_blank,
                size: 19,
              ),
              onPressed: enabled
                  ? () => setState(
                      () => checked
                          ? _confirmed.remove((o.operationId, o.revision))
                          : _confirmed.add((o.operationId, o.revision)),
                    )
                  : null,
              child: const Text('我已确认原操作停止，并检查了目标'),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: DesktopButton(
                key: ValueKey('batch-acknowledge-${o.operationId}'),
                kind: DesktopButtonKind.primary,
                onPressed: enabled && checked
                    ? () => model.acknowledgeBatchOperation(o.operationId)
                    : null,
                child: const Text('确认已检查目标'),
              ),
            ),
          ],
          if (model.executionError(o.operationId) case final error?)
            Text(
              error,
              style: libraryText(context, 13, color: c.warning, height: 1.8),
            ),
        ],
      ),
    );
  }
}
