import 'dart:async';

import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart';

class Approvals extends StatefulWidget {
  const Approvals({super.key, required this.service, required this.port});
  final InformationService service;
  final int port;
  @override
  State<Approvals> createState() => ApprovalsState();
}

class ApprovalsState extends State<Approvals> {
  Timer? _refresh;
  final _selection = <String, Set<FieldRef>>{};
  @override
  void initState() {
    super.initState();
    _refresh = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _refresh?.cancel();
    super.dispose();
  }

  void _manage(VoidCallback action) {
    try {
      action();
      setState(() {});
    } on AccessFailure {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请求状态已变化，请重新检查。')));
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final requests = widget.service.owner.requests;
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const Text(
                '决定本次聊天可以读取什么',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              const Text('当前为开发版本；恢复链路尚未验收，请只录入虚构资料。关闭应用会使当前授权失效。'),
              const SizedBox(height: 8),
              Text(
                '本机 CLI 服务已启动 · 127.0.0.1:${widget.port}',
                style: const TextStyle(color: Color(0xff245c51)),
              ),
              const Divider(height: 32),
              const Text('待审批有效期（仅影响新申请）'),
              DropdownButton<int>(
                key: const ValueKey('request-lifetime'),
                value: widget.service.owner.requestLifetime.inMinutes,
                items:
                    {
                          5,
                          15,
                          30,
                          60,
                          120,
                          widget.service.owner.requestLifetime.inMinutes,
                        }
                        .map(
                          (minutes) => DropdownMenuItem(
                            value: minutes,
                            child: Text('$minutes 分钟'),
                          ),
                        )
                        .toList(),
                onChanged: (minutes) async {
                  if (minutes == null) return;
                  try {
                    await Future<void>.sync(
                      () => widget.service.owner.setRequestLifetime(
                        Duration(minutes: minutes),
                      ),
                    );
                    if (mounted) setState(() {});
                  } on Object {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('设置未保存，请重试。')),
                      );
                    }
                  }
                },
              ),
              if (requests.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 48),
                  child: Text('暂无访问请求。使用 CLI 查询目录并提交申请。'),
                ),
              for (final request in requests) _requestView(request),
              const SizedBox(height: 24),
              const Text('授权仅包含选中的信息字段，新增信息需要重新申请。撤销可以阻止后续读取，无法收回已经提供的内容。'),
            ],
          ),
        ),
      ),
    );
  }

  Widget _requestView(OwnerRequestSnapshot request) {
    final id = request.id;
    final fields = request.fields;
    final selected = _selection.putIfAbsent(id, () => fields.toSet());
    final state = request.state;
    return Card(
      margin: const EdgeInsets.only(bottom: 20),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '聊天：${request.chatLabel}',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(request.purpose),
            const Text(
              '聊天名称与用途由 agent 自述，仅供判断。',
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 12),
            if (state == AccessRequestState.pending) ...[
              Text(
                '待审批剩余：${request.remainingSeconds ~/ 60} 分 ${request.remainingSeconds % 60} 秒',
              ),
              for (final field in fields)
                CheckboxListTile(
                  key: ValueKey('field-${field.fieldId}'),
                  contentPadding: EdgeInsets.zero,
                  title: Text(_fieldLabel(field)),
                  subtitle: Text('${field.itemId} / ${field.fieldId}'),
                  value: selected.contains(field),
                  onChanged: (value) => setState(() {
                    if (value == true) {
                      selected.add(field);
                    } else {
                      selected.remove(field);
                    }
                  }),
                ),
              const Text('有效期：批准后 8 小时，读取不会延长有效期。'),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: selected.isEmpty
                    ? null
                    : () => _manage(
                        () =>
                            widget.service.owner.approve(id, selected.toList()),
                      ),
                child: const Text('批准所选字段'),
              ),
              TextButton(
                onPressed: () => _manage(() => widget.service.owner.deny(id)),
                child: const Text('拒绝申请'),
              ),
            ] else ...[
              Text(switch (state) {
                AccessRequestState.pending => '待审批',
                AccessRequestState.approved => '已批准',
                AccessRequestState.revoked => '已撤销',
                AccessRequestState.denied => '已拒绝',
                AccessRequestState.cancelled => '已取消',
                AccessRequestState.expired => '已过期',
              }),
              if (request.approvedFields != null) ...[
                Text(
                  '已批准字段：${request.approvedFields!.map((f) => f.fieldId).join(', ')}',
                ),
                Text(
                  '到期时间：${request.grantExpiresAt?.toUtc().toIso8601String()}',
                ),
              ],
              if (state == AccessRequestState.approved)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: OutlinedButton(
                    onPressed: () =>
                        _manage(() => widget.service.owner.revoke(id)),
                    child: const Text('撤销授权'),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  String _fieldLabel(FieldRef ref) {
    for (final item in widget.service.agent.catalog()) {
      if (item['id'] != ref.itemId) continue;
      for (final field in item['fields'] as List) {
        if (field['id'] == ref.fieldId) {
          return '${item['name']} · ${field['name']}';
        }
      }
    }
    return '${ref.itemId} / ${ref.fieldId}';
  }
}
