import 'package:flutter/material.dart';
import '../desktop_controls.dart';
import '../ui_palette.dart';
import 'library_widgets.dart';
import 'proposal_reading.dart';
import 'workspace_source.dart';

class OrganizationReading extends StatelessWidget {
  const OrganizationReading({
    super.key,
    required this.report,
    required this.onRecord,
    this.onHistory,
    this.onRefresh,
  });
  final WorkspaceOrganizationReport report;
  final ValueChanged<WorkspaceRecordRef>? onRecord;
  final ValueChanged<String>? onHistory;
  final VoidCallback? onRefresh;
  @override
  Widget build(BuildContext context) {
    final c = UiPalette.of(context),
        applied = report.outcome == WorkspaceOrganizationOutcome.applied;
    String location(WorkspaceOrganizationLocation l) =>
        '目录：${l.directoryName}\n标签：${l.tags.isEmpty ? '无' : l.tags.map((t) => t.name).join('、')}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        proposalSection(
          context,
          report.legacyReview ? '旧版方案审阅' : '整理结果',
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                report.outcome.label,
                key: const ValueKey('organization-outcome'),
                style: libraryText(
                  context,
                  16,
                  weight: FontWeight.w600,
                  color: applied ? c.success : c.warning,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                report.legacyReview
                    ? '这份旧版方案保留主人确认或拒绝的流程，不会升级为自动应用许可。只涉及下方整批目录与标签，不包含字段内容。'
                    : applied
                    ? '已依据先前的整理授权自动应用，无需再次确认。仅调整目录与标签，未修改字段内容。'
                    : report.outcome == WorkspaceOrganizationOutcome.unknown
                    ? '原操作结果尚无法确认。这里只读取原结果，不会重新执行整理。'
                    : '本次没有应用整理建议，当前资料保留原有内容。结果只读，不能再次批准。',
                style: libraryText(context, 14, height: 1.9),
              ),
              if (report.reason != null)
                Text(
                  report.reason!,
                  style: libraryText(context, 13, color: c.muted, height: 1.9),
                ),
              if (report.approvedAt != null)
                Text(
                  '批准于${libraryLocalDateTime(report.approvedAt!)} · 固定到期${libraryLocalDateTime(report.expiresAt!)}',
                  style: libraryText(context, 12, color: c.muted, height: 1.9),
                ),
              if (report.historyId != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: DesktopButton(
                    key: const ValueKey('organization-history'),
                    kind: DesktopButtonKind.quiet,
                    onPressed: onHistory == null
                        ? null
                        : () => onHistory!(report.historyId!),
                    child: const Text('查看原整理授权与操作记录'),
                  ),
                ),
              if (report.outcome == WorkspaceOrganizationOutcome.unknown)
                Align(
                  alignment: Alignment.centerLeft,
                  child: DesktopButton(
                    key: const ValueKey('organization-refresh'),
                    onPressed: onRefresh,
                    child: const Text('重新读取原整理结果'),
                  ),
                ),
            ],
          ),
        ),
        for (final m in report.members)
          proposalSection(
            context,
            m.name,
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '固定资料v${m.baseVersion}${m.resultVersion == null ? '' : ' · 本次结果v${m.resultVersion}'}${m.changed ? '' : ' · 分类无变化'}',
                  style: libraryText(context, 12, color: c.muted),
                ),
                const SizedBox(height: 10),
                ProposalDiff(
                  label: '目录与标签',
                  before: location(m.before),
                  after: location(m.after),
                  currentLabel: '整理前',
                  highlightAfter:
                      applied ||
                      report.legacyReview &&
                          report.outcome ==
                              WorkspaceOrganizationOutcome.proposed,
                  afterLabel: applied
                      ? '已应用'
                      : report.legacyReview &&
                            report.outcome ==
                                WorkspaceOrganizationOutcome.proposed
                      ? '待确认建议'
                      : '原建议',
                ),
                if (!m.exists)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      '当前对象已删除或不可用，保留原身份与分类记录，不改连同名对象。',
                      style: libraryText(
                        context,
                        13,
                        color: c.muted,
                        height: 1.8,
                      ),
                    ),
                  ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: DesktopButton(
                    key: ValueKey('organization-current-${m.record.key}'),
                    kind: DesktopButtonKind.quiet,
                    onPressed: !m.exists || onRecord == null
                        ? null
                        : () => onRecord!(m.record),
                    child: const Text('查看当前资料'),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
