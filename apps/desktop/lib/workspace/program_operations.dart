import 'package:flutter/material.dart';
import '../desktop_controls.dart';
import '../ui_palette.dart';
import 'approvals_controller.dart';
import 'library_widgets.dart';
import 'program_plan.dart';
import 'workspace_source.dart';

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
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
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
            style: libraryText(context, 17, weight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          if (operations.isEmpty)
            Text(
              '尚无执行记录。',
              style: libraryText(
                context,
                14,
                color: UiPalette.of(context).muted,
              ),
            ),
          for (final operation in operations.take(_shown))
            _operation(context, operation, names),
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
                operation.plan.executable.split(RegExp(r'[/\\]')).last,
                style: libraryText(context, 15, weight: FontWeight.w600),
              ),
              Text(
                operation.resultLabel,
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
            libraryLocalDateTime(operation.createdAt),
            style: libraryText(context, 12, color: c.muted),
          ),
          Text(
              operation.fromBackup ? '备份中的执行历史' : operation.state == 'unknown'
                ? '${operation.processLabel} · ${operation.cleanupLabel}' : operation.cleanupLabel,
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
                DesktopButton(
                  key: ValueKey('program-query-${operation.operationId}'),
                  kind: DesktopButtonKind.quiet,
                  busy: model.readingExecution(operation.operationId),
                  onPressed:
                      model.frozen ||
                          model.loading ||
                          model.reading ||
                          model.readingExecution(operation.operationId)
                      ? null
                      : () => model.refreshProgramOperation(
                          operation.operationId,
                        ),
                  child: const Text('查询结果'),
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
