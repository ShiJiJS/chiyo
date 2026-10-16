import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart';

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
        builder: (context) => AlertDialog(
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
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      const Text(
        '授权历史与访问记录',
        style: TextStyle(fontSize: 28, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 12),
      const Text('记录批准时的名称、范围和访问结果，不记录字段值、访问凭据或密钥。撤销仅阻止后续读取，无法收回已提供的内容。'),
      Wrap(
        spacing: 16,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          const Text('记录保留时间'),
          DropdownButton<int>(
            key: const ValueKey('audit-retention'),
            value: widget.owner.auditRetentionDays,
            items: [30, 90, 180, 365]
                .map(
                  (days) =>
                      DropdownMenuItem(value: days, child: Text('$days 天')),
                )
                .toList(),
            onChanged: _busy
                ? null
                : (days) {
                    if (days != null) {
                      _run(() => _retention(days));
                    }
                  },
          ),
          TextButton(
            onPressed: _busy ? null : _reload,
            child: const Text('刷新记录'),
          ),
        ],
      ),
      FutureBuilder<AuditHistory>(
        future: _history,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('授权历史暂不可用。记录保存异常时，信息读取已暂停；修复存储后可重试保存。'),
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
          final grantIds = history.grants.map((g) => g.id).toSet();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (history.grants.isEmpty) const Text('暂无授权历史。'),
              for (final grant in history.grants.reversed)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '聊天：${grant.chatLabel}',
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (grant.restoredAt != null)
                          const Text('从备份恢复的历史事实，不代表当前有效授权。'),
                        const Text('聊天名称由 agent 自述；下面的会话标识由本机服务生成。'),
                        SelectableText('会话：${grant.sessionId}'),
                        Text(
                          '批准时间：${_time(grant.approvedAt)}；到期时间：${_time(grant.expiresAt)}',
                        ),
                        Text(
                          '批准时长：${grant.expiresAt.difference(grant.approvedAt).inMinutes} 分钟',
                        ),
                        for (final field in grant.fields)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                              '${field.itemName} · ${field.fieldName}',
                            ),
                            subtitle: SelectableText(
                              '${field.itemId} / ${field.fieldId}',
                            ),
                          ),
                        for (final event in grant.events)
                          Text('${_event(event.kind)} · ${_time(event.at)}'),
                        if (grant.active)
                          OutlinedButton(
                            onPressed: _busy
                                ? null
                                : () => _run(
                                    () => widget.owner.revokeFromHistory(
                                      grant.id,
                                    ),
                                  ),
                            child: const Text('撤销授权'),
                          ),
                        const Divider(),
                        const Text('实际读取记录'),
                        for (final record in history.accesses.where(
                          (r) => r.grantId == grant.id,
                        ))
                          _record(record),
                        if (!history.accesses.any((r) => r.grantId == grant.id))
                          const Text('尚无读取记录。'),
                      ],
                    ),
                  ),
                ),
              if (history.accesses.any(
                (r) => !grantIds.contains(r.grantId),
              )) ...[
                const Text(
                  '未关联保留中授权的读取尝试',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const Text('包括无法识别凭据，或原授权历史已按期限清理的读取。不保留未知调用者提供的目标文本或凭据。'),
                for (final record in history.accesses.where(
                  (r) => !grantIds.contains(r.grantId),
                ))
                  _record(record),
              ],
            ],
          );
        },
      ),
    ],
  );
  Widget _record(AccessRecord record) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Text(
      '${_time(record.at)} · ${switch (record.outcome) {
        AccessOutcome.allowed => '读取获准',
        AccessOutcome.unauthorized => '读取被拒绝',
        AccessOutcome.auditUnavailable => '记录保存异常，未提供内容',
      }} · ${record.itemId == null ? '未知目标' : '${record.itemId} / ${record.fieldId}'}',
    ),
  );
  String _time(DateTime time) => time.toLocal().toString().split('.').first;
  String _event(GrantEventKind kind) => switch (kind) {
    GrantEventKind.approved => '已批准',
    GrantEventKind.revoked => '已撤销',
    GrantEventKind.expired => '已过期',
    GrantEventKind.ended => '会话已结束',
    GrantEventKind.applicationClosed => '上次运行已结束',
  };
}
