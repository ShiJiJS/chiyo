import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart';
import 'ui.dart';

class AuthorizationHistory extends StatefulWidget {
  const AuthorizationHistory({super.key, required this.owner});
  final OwnerAccess owner;
  @override
  State<AuthorizationHistory> createState() => _AuthorizationHistoryState();
}

class _AuthorizationHistoryState extends State<AuthorizationHistory> {
  late Future<AuditHistory> _history;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    _history = widget.owner.history();
  }

  void _reload() => setState(() => _history = widget.owner.history());
  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
      if (mounted) _reload();
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('操作未完成。记录保存异常时会暂停信息读取；请修复存储后重试。')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _retention(int days) async {
    if (days < widget.owner.auditRetentionDays) {
      final preview = await widget.owner.previewAuditRetention(days);
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => DesktopDialog(
          title: const Text('缩短记录保留时间'),
          content: Text(
            '将改为保留 $days 天，并清理更早的 ${preview.grants} 条授权历史和 ${preview.accesses} 条访问记录。之后延长期限也无法找回已清理记录。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认清理'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
      await widget.owner.setAuditRetention(days, confirmation: preview);
    } else {
      await widget.owner.setAuditRetention(days);
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(26, 25, 26, 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PageHeading('授权与访问记录', subtitle: '查看批准范围、有效期，以及之后的实际访问。'),
        Expanded(
          child: ListView(
            children: [
              Wrap(
                spacing: 14,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text('记录保留时间'),
                  DesktopSelect<int>(
                    key: const ValueKey('audit-retention'),
                    value: widget.owner.auditRetentionDays,
                    items: [30, 90, 180, 365]
                        .map(
                          (days) => DropdownMenuItem(
                            value: days,
                            child: Text('$days 天'),
                          ),
                        )
                        .toList(),
                    onChanged: _busy
                        ? null
                        : (days) {
                            if (days != null) _run(() => _retention(days));
                          },
                  ),
                  TextButton.icon(
                    onPressed: _busy ? null : _reload,
                    icon: const Icon(Icons.refresh, size: 17),
                    label: const Text('刷新记录'),
                  ),
                ],
              ),
              const QuietNotice('记录不含字段值、访问凭据或密钥。撤销只阻止后续读取，无法收回已提供的内容。'),
              const SizedBox(height: 14),
              FutureBuilder<AuditHistory>(
                future: _history,
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const QuietNotice(
                          '授权历史暂不可用。记录保存异常时，信息读取已暂停；修复存储后可重试保存。',
                          warning: true,
                        ),
                        FilledButton(
                          onPressed: _busy
                              ? null
                              : () => _run(widget.owner.retryAuditStorage),
                          child: const Text('重试保存记录'),
                        ),
                      ],
                    );
                  }
                  final history = snapshot.data;
                  if (history == null) return const LinearProgressIndicator();
                  final ids = history.grants.map((g) => g.id).toSet();
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (history.grants.isEmpty)
                        const SizedBox(
                          height: 270,
                          child: EmptyWorkspace(
                            icon: Icons.history,
                            title: '暂无授权历史。',
                            description: '批准申请后，可以在这里查看实际提供的范围，并撤销仍然有效的授权。',
                          ),
                        ),
                      for (final grant in history.grants.reversed)
                        _grant(grant, history),
                      if (history.accesses.any(
                        (r) => !ids.contains(r.grantId),
                      )) ...[
                        const SizedBox(height: 24),
                        Text(
                          '未关联保留中授权的读取尝试',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const QuietNotice('包含无法识别凭据的请求，或原授权已按期限清理的读取。'),
                        for (final record in history.accesses.where(
                          (r) => !ids.contains(r.grantId),
                        ))
                          _record(record),
                      ],
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _grant(GrantHistory grant, AuditHistory history) {
    final accesses = history.accesses
        .where((r) => r.grantId == grant.id)
        .toList();
    final events = grant.events
        .where((event) => event.kind != GrantEventKind.approved)
        .toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(21),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    '聊天：${grant.chatLabel}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                const SizedBox(width: 12),
                StatusLabel(
                  grant.restoredAt != null
                      ? '历史事实'
                      : grant.active
                      ? '授权有效'
                      : '已结束',
                  active: grant.active,
                ),
              ],
            ),
            if (grant.restoredAt != null)
              const QuietNotice('从备份恢复的历史事实，不代表当前有效授权。'),
            const SizedBox(height: 12),
            Wrap(
              spacing: 28,
              runSpacing: 8,
              children: [
                Text(
                  '批准于 ${uiTime(grant.approvedAt)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Text(
                  '到期于 ${uiTime(grant.expiresAt)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
            const SizedBox(height: 18),
            for (final field in grant.fields)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  children: [
                    const Icon(Icons.check, size: 16, color: UiColors.green),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text('${field.itemName} · ${field.fieldName}'),
                    ),
                  ],
                ),
              ),
            if (events.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 18,
                runSpacing: 6,
                children: [
                  for (final event in events)
                    Text(
                      '${_event(event.kind)} · ${uiTime(event.at)}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                ],
              ),
            ],
            if (grant.active)
              Padding(
                padding: const EdgeInsets.only(top: 14),
                child: OutlinedButton(
                  onPressed: _busy
                      ? null
                      : () => _run(
                          () => widget.owner.revokeFromHistory(grant.id),
                        ),
                  child: const Text('撤销授权'),
                ),
              ),
            const SizedBox(height: 18),
            const Divider(),
            const SizedBox(height: 15),
            Text('实际读取记录', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 5),
            for (final record in accesses) _record(record, grant: grant),
            if (accesses.isEmpty)
              Text('尚无读取记录。', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              dense: true,
              title: Text(
                '会话与字段标识',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              childrenPadding: const EdgeInsets.only(bottom: 12),
              children: [
                const QuietNotice('聊天名称由 agent 自述；下面的会话标识由本机服务生成。'),
                Align(
                  alignment: Alignment.centerLeft,
                  child: SelectableText('会话：${grant.sessionId}'),
                ),
                for (final field in grant.fields)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: SelectableText(
                        '${field.itemName} · ${field.fieldName}\n${field.itemId} / ${field.fieldId}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _record(AccessRecord record, {GrantHistory? grant}) {
    final field = grant?.fields
        .where((f) => f.itemId == record.itemId && f.fieldId == record.fieldId)
        .firstOrNull;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 14,
            runSpacing: 4,
            children: [
              Text(
                uiTime(record.at),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              Text(switch (record.outcome) {
                AccessOutcome.allowed => '读取获准',
                AccessOutcome.unauthorized => '读取被拒绝',
                AccessOutcome.auditUnavailable => '记录保存异常，未提供内容',
              }),
              Text(
                field == null
                    ? record.itemId == null
                          ? '未知目标'
                          : grant == null
                          ? '原授权历史已清理'
                          : '未匹配授权字段'
                    : '${field.itemName} · ${field.fieldName}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
          if (grant == null && record.itemId != null)
            SelectableText(
              '${record.itemId} / ${record.fieldId}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
        ],
      ),
    );
  }

  String _event(GrantEventKind kind) => switch (kind) {
    GrantEventKind.approved => '已批准',
    GrantEventKind.revoked => '已撤销',
    GrantEventKind.expired => '已过期',
    GrantEventKind.ended => '会话已结束',
    GrantEventKind.applicationClosed => '上次运行已结束',
  };
}
