import 'package:flutter/material.dart';
import '../desktop_controls.dart';
import '../ui_palette.dart';
import 'approvals_controller.dart';
import 'library_widgets.dart';
import 'workspace_source.dart';

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
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final names = {for (final s in detail.scopes) s.id: s.recordName};
    return Padding(
      padding: const EdgeInsets.only(top: 26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '填写记录',
            style: libraryText(context, 17, weight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          if (operations.isEmpty)
            Text('尚无填写记录。', style: libraryText(context, 14, color: c.muted)),
          for (final o in operations.take(_shown))
            _operation(context, model, o, names),
          if (operations.length > _shown)
            DesktopButton(
              kind: DesktopButtonKind.quiet,
              onPressed: () => setState(() => _shown += 20),
              child: Text('显示更多记录（剩余${operations.length - _shown}次）'),
            ),
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
        model.source is WorkspaceCredentialBatchActions && !o.fromBackup;
    final color = o.needsAttention
        ? c.warning
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
                o.itemIds.map((id) => names[id] ?? '凭据').join('、'),
                style: libraryText(context, 15, weight: FontWeight.w600),
              ),
              Text(
                WorkspaceCredentialBatchOperation.resultLabel(o.state),
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
                DesktopButton(
                  key: ValueKey('batch-query-${o.operationId}'),
                  kind: DesktopButtonKind.quiet,
                  busy: model.readingExecution(o.operationId),
                  onPressed: enabled
                      ? () => model.refreshBatchOperation(o.operationId)
                      : null,
                  child: const Text('查询结果'),
                ),
            ],
          ),
          if (expanded) ...[
            SelectableText(
              '操作 ${o.operationId}',
              style: libraryText(context, 12, color: c.muted),
            ),
            for (final id in o.itemIds)
              Text(
                '${names[id] ?? '凭据'}：${WorkspaceCredentialBatchOperation.resultLabel(o.itemResults[id] ?? o.state)}',
                style: libraryText(context, 13, height: 1.8),
              ),
          ],
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
