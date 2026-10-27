import 'package:flutter/material.dart';
import '../desktop_controls.dart';
import '../ui_palette.dart';
import 'library_widgets.dart';
import 'proposal_batch.dart';
import 'workspace_source.dart';

class ProposalBatchDialog extends StatelessWidget {
  const ProposalBatchDialog({super.key, required this.batch});
  final ProposalBatch batch;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: batch,
    builder: (context, _) {
      final c = UiPalette.of(context), entries = batch.entries;
      return PopScope<String>(
        canPop: !batch.frozen,
        child: DesktopDialog(
          key: const ValueKey('proposal-batch-dialog'),
          title: const Text('批量提案审阅'),
          closeEnabled: !batch.frozen,
          width: 800,
          content: SizedBox(
            height: MediaQuery.sizeOf(context).height * .49,
            child: ListView(
              key: const ValueKey('proposal-batch-list'),
              children: [
                Text(
                  '按清单顺序逐项处理，各份提案独立提交。已成功的结果不会因后一项失败而回滚；遇到未知结果先核对原操作。',
                  style: libraryText(context, 14, color: c.muted, height: 1.9),
                ),
                if (batch.busy)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: LinearProgressIndicator(),
                  ),
                for (final (index, e) in entries.indexed)
                  Container(
                    key: ValueKey('proposal-batch-row-${e.summary.id}'),
                    margin: const EdgeInsets.only(top: 18),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    decoration: BoxDecoration(
                      border: Border(top: BorderSide(color: c.line)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Wrap(
                          alignment: WrapAlignment.spaceBetween,
                          spacing: 12,
                          runSpacing: 8,
                          children: [
                            Text(
                              '${index + 1}. ${e.summary.title}',
                              style: libraryText(
                                context,
                                16,
                                weight: FontWeight.w600,
                              ),
                            ),
                            Semantics(
                              liveRegion: true,
                              child: Text(
                                e.status.label,
                                key: ValueKey(
                                  'proposal-batch-state-${e.summary.id}',
                                ),
                                style: libraryText(
                                  context,
                                  13,
                                  color:
                                      e.status ==
                                              ProposalBatchStatus.completed ||
                                          e.status ==
                                              ProposalBatchStatus.rejected
                                      ? c.success
                                      : e.status ==
                                                ProposalBatchStatus.unknown ||
                                            e.status ==
                                                ProposalBatchStatus.failed
                                      ? c.danger
                                      : c.muted,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 7),
                        Text(
                          '${e.summary.kind.label} · 提案v${e.summary.version} · ${e.action == WorkspaceProposalAction.confirm ? '确认已审阅范围' : '拒绝此提案'}',
                          style: libraryText(
                            context,
                            13,
                            color: c.muted,
                            height: 1.8,
                          ),
                        ),
                        if (e.names.isNotEmpty)
                          Text(
                            '审阅范围：${e.names.join('、')}',
                            style: libraryText(
                              context,
                              13,
                              color: c.muted,
                              height: 1.8,
                            ),
                          ),
                        if (e.receipt != null)
                          Text(
                            '已记录本次决定${e.receipt!.records.isEmpty ? '' : '，涉及${e.receipt!.records.length}份资料'}。',
                            style: libraryText(context, 13, height: 1.8),
                          ),
                        if (e.failure != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 7),
                            child: Text(
                              e.failure!.message,
                              style: libraryText(
                                context,
                                13,
                                color: c.danger,
                                height: 1.8,
                              ),
                            ),
                          ),
                        if (e.status == ProposalBatchStatus.notSubmitted)
                          Text(
                            '本次原操作已确认未提交。只有明确重试才会创建新操作，其他未开始项不会自动执行。',
                            style: libraryText(
                              context,
                              13,
                              color: c.muted,
                              height: 1.8,
                            ),
                          ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            DesktopButton(
                              key: ValueKey(
                                'proposal-batch-open-${e.summary.id}',
                              ),
                              kind: DesktopButtonKind.quiet,
                              onPressed: batch.frozen
                                  ? null
                                  : () => Navigator.pop(context, e.summary.id),
                              child: Text(e.terminal ? '查看提案结果' : '返回此提案审阅'),
                            ),
                            if ([
                              ProposalBatchStatus.failed,
                              ProposalBatchStatus.notSubmitted,
                            ].contains(e.status))
                              DesktopButton(
                                key: ValueKey(
                                  'proposal-batch-retry-${e.summary.id}',
                                ),
                                onPressed: batch.frozen
                                    ? null
                                    : () => batch.retry(e.summary.id),
                                child: const Text('明确重试此项'),
                              ),
                            if (!batch.started) ...[
                              DesktopButton(
                                onPressed: batch.frozen || index == 0
                                    ? null
                                    : () => batch.move(e.summary.id, -1),
                                child: const Text('上移'),
                              ),
                              DesktopButton(
                                onPressed:
                                    batch.frozen || index + 1 == entries.length
                                    ? null
                                    : () => batch.move(e.summary.id, 1),
                                child: const Text('下移'),
                              ),
                            ],
                            DesktopButton(
                              key: ValueKey(
                                'proposal-batch-remove-${e.summary.id}',
                              ),
                              kind: DesktopButtonKind.quiet,
                              onPressed: batch.frozen
                                  ? null
                                  : () => batch.remove(e.summary.id),
                              child: const Text('移出清单'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            if (batch.uncertain)
              DesktopButton(
                key: const ValueKey('proposal-batch-reconcile'),
                kind: DesktopButtonKind.primary,
                onPressed: batch.busy ? null : batch.reconcile,
                child: const Text('核对本批次原操作'),
              ),
            if (!batch.uncertain && batch.pendingCount > 0)
              DesktopButton(
                key: const ValueKey('proposal-batch-run'),
                kind: DesktopButtonKind.primary,
                onPressed: batch.busy ? null : batch.runPending,
                child: Text(
                  '${batch.started ? '继续处理' : '开始处理'}${batch.pendingCount}项',
                ),
              ),
            DesktopButton(
              key: const ValueKey('proposal-batch-clear'),
              kind: DesktopButtonKind.quiet,
              onPressed: batch.frozen || entries.isEmpty ? null : batch.clear,
              child: const Text('清空本批次'),
            ),
            DesktopButton(
              key: const ValueKey('proposal-batch-close'),
              onPressed: batch.frozen ? null : () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    },
  );
}
