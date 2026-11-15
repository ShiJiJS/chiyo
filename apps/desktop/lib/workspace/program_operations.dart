import 'dart:convert';
import 'package:flutter/material.dart';
import 'approval_presentation.dart';
import '../desktop_controls.dart';
import '../ui_palette.dart';
import 'approvals_controller.dart';
import 'library_widgets.dart';
import 'program_plan.dart';
import 'workspace_source.dart';
import 'operation_pages_footer.dart';

class ProgramOperations extends StatefulWidget {
  const ProgramOperations({super.key, required this.controller});
  final ApprovalsController controller;
  @override
  State<ProgramOperations> createState() => _ProgramOperationsState();
}

class _ProgramOperationsState extends State<ProgramOperations> {
  String? _request;
  int _shown = 20;
  final _expanded = <String>{};
  @override
  Widget build(BuildContext context) {
    final detail = widget.controller.detail;
    if (detail == null ||
        detail.programPlan == null ||
        detail.programOperations.isEmpty && detail.approved.isEmpty) {
      return const SizedBox.shrink();
    }
    if (_request != detail.request.id) {
      _request = detail.request.id;
      _shown = 20;
      _expanded.clear();
    }
    final operations = detail.programOperations.toList()
      ..sort(
        (a, b) => CredentialOperationCursor.compare(
          a.createdAt,
          a.operationId,
          b.createdAt,
          b.operationId,
        ),
      );
    final names = {
      for (final scope in detail.scopes) scope.record.id: scope.recordName,
    };
    return Padding(
      padding: const EdgeInsets.only(top: 26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '程序执行记录',
            style: libraryText(context, 15, weight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(
            '批准与执行分别记录。刷新状态只读取已有结果，不会再次运行。',
            style: libraryText(
              context,
              13,
              color: UiPalette.of(context).muted,
              height: 1.8,
            ),
          ),
          const SizedBox(height: 12),
          if (operations.isEmpty)
            Text(
              '尚无执行记录。批准后，仍由 Agent 发起执行。',
              style: libraryText(
                context,
                14,
                color: UiPalette.of(context).muted,
              ),
            ),
          for (final operation
              in detail.operationTotal == null
                  ? operations.take(_shown)
                  : operations)
            _operation(context, operation, names),
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
    WorkspaceCredentialProgramOperation operation,
    Map<String, String> names,
  ) {
    final model = widget.controller, c = UiPalette.of(context);
    final expanded = _expanded.contains(operation.operationId);
    final color = operation.state == 'unknown'
        ? c.warning
        : operation.state == 'exited'
        ? operation.exitCode == 0
              ? c.success
              : c.danger
        : {'prepare_failed', 'start_failed'}.contains(operation.state)
        ? c.danger
        : c.accent;
    return Container(
      key: ValueKey('program-operation-${operation.operationId}'),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border.all(color: c.line),
        borderRadius: BorderRadius.circular(8),
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
                '运行 ${operation.plan.programName}',
                style: libraryText(context, 15, weight: FontWeight.w600),
              ),
              LibraryPill(
                operation.resultLabel,
                color: color,
                background:
                    operation.state == 'exited' && operation.exitCode == 0
                    ? c.successSurface
                    : c.rail,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            libraryLocalDateTime(operation.createdAt),
            style: libraryText(context, 12, color: c.muted),
          ),
          Text(
            operation.fromBackup
                ? '备份中的执行历史'
                : operation.state == 'unknown'
                ? '${operation.processLabel} · ${operation.cleanupLabel}'
                : operation.cleanupLabel,
            style: libraryText(context, 13, color: c.muted, height: 1.8),
          ),
          if (operation.state == 'exited')
            Text(
              operation.exitCode == 0
                  ? '退出码为 0，程序未报告执行错误；不等于已经确认 Agent 说明的任务完成。'
                  : '程序以非零退出码结束，请结合原程序输出核对。',
              style: libraryText(context, 13, color: c.muted, height: 1.8),
            ),
          if (operation.errorLabel != null && !operation.fromBackup)
            Text(
              operation.errorLabel!,
              style: libraryText(context, 13, color: color, height: 1.8),
            ),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              DesktopButton(
                key: ValueKey('program-details-${operation.operationId}'),
                kind: DesktopButtonKind.quiet,
                leading: Icon(
                  expanded ? Icons.expand_less : Icons.expand_more,
                  size: 17,
                ),
                onPressed: model.frozen
                    ? null
                    : () => setState(
                        () => expanded
                            ? _expanded.remove(operation.operationId)
                            : _expanded.add(operation.operationId),
                      ),
                child: Text(expanded ? '收起本次执行' : '查看本次执行'),
              ),
              if (!operation.fromBackup &&
                  model.source is WorkspaceCredentialProgramActions)
                OperationRefresh(
                  key: ValueKey('program-query-${operation.operationId}'),
                  controller: model,
                  operationId: operation.operationId,
                  refresh: () =>
                      model.refreshProgramOperation(operation.operationId),
                  observation: () {
                    final current = model.detail!.programOperations.firstWhere(
                      (o) => o.operationId == operation.operationId,
                    );
                    return jsonEncode(current.toJson()..remove('observedAt'));
                  },
                ),
            ],
          ),
          if (expanded) ...[
            const SizedBox(height: 10),
            ProgramPlan(plan: operation.plan, names: names),
            SelectableText(
              '操作 ${operation.operationId}',
              style: libraryText(context, 12, color: c.muted),
            ),
          ],
          if (model.executionError(operation.operationId) case final error?)
            Text(
              error,
              style: libraryText(context, 13, color: c.warning, height: 1.8),
            ),
        ],
      ),
    );
  }
}
