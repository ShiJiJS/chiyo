import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart';
import 'prototype_dialog.dart';
import 'prototype_ui.dart';
import 'ui.dart';
import 'credential_delivery.dart';

String credentialExecutionLabel(CredentialExecution? execution) =>
    switch (execution?.state) {
      'preparing' => '正在准备',
      'running' => '运行中',
      'exited' =>
        execution!.exitCode == 0
            ? '已成功 · 退出码 0'
            : '已退出 · 退出码 ${execution.exitCode}',
      'prepare_failed' => '准备失败',
      'start_failed' => '启动失败',
      'unknown' => '结果未知',
      _ => '执行记录暂不可用',
    };
String credentialCleanupLabel(String? state) => switch (state) {
  'not_needed' => '无需文件清理',
  'pending' => '等待清理',
  'complete' => '已清理',
  'failed' => '清理失败',
  'needs_check' => '需要人工核查',
  _ => '清理状态暂不可用',
};

Future<void> showCredentialExecutionReceipt(
  BuildContext context,
  OwnerAccess owner,
  CredentialUseRequest request, {
  String? executionId,
}) => showDialog<void>(
  context: context,
  barrierColor: const Color(0x4f241b27),
  builder: (_) => _ExecutionReceipt(
    owner: owner,
    request: request,
    executionId: executionId,
  ),
);

class _ExecutionReceipt extends StatefulWidget {
  const _ExecutionReceipt({
    required this.owner,
    required this.request,
    this.executionId,
  });
  final OwnerAccess owner;
  final CredentialUseRequest request;
  final String? executionId;
  @override
  State<_ExecutionReceipt> createState() => _ExecutionReceiptState();
}

class _ExecutionReceiptState extends State<_ExecutionReceipt> {
  Timer? _refresh;
  bool _cleaning = false;
  String? _cleanupError;
  Future<void> _cleanup() async {
    final record = execution;
    if (record == null || _cleaning) return;
    setState(() {
      _cleaning = true;
      _cleanupError = null;
    });
    try {
      await widget.owner.cleanupCredentialExecution(record.id);
    } on CredentialUseFailure catch (e) {
      if (mounted) {
        setState(
          () => _cleanupError = switch (e.code) {
            'cleanup_busy' => '仍有活动进程，或暂时无法确认进程组已结束。材料已保留，请稍后核查。',
            'cleanup_identity_mismatch' => '材料身份或目录内容已变化，未删除可疑文件。请先人工核查。',
            'cleanup_failed' => '文件仍被占用或无法删除。材料已保留，可解除占用后只重试清理。',
            _ => '未能保存或完成清理，请检查本机服务后核查。',
          },
        );
      }
    } on Object {
      if (mounted) setState(() => _cleanupError = '未能完成清理，请检查本机服务后核查。');
    } finally {
      if (mounted) setState(() => _cleaning = false);
    }
  }

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

  CredentialExecution? get execution {
    try {
      return widget.owner.credentialExecutions
          .where(
            (e) =>
                e.id == (widget.executionId ?? widget.request.executionId) &&
                e.requestId == widget.request.id,
          )
          .firstOrNull;
    } on Object {
      return null;
    }
  }

  String time(DateTime? value) =>
      value?.toLocal().toString().split('.').first ?? '尚无记录';
  Widget fact(String label, String value) => Container(
    padding: const EdgeInsets.symmetric(vertical: 15),
    decoration: BoxDecoration(
      border: Border(bottom: BorderSide(color: UiPalette.of(context).line)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 122,
          child: Text(
            label,
            style: prototypeText(
              context,
              13,
              color: UiPalette.of(context).muted,
            ),
          ),
        ),
        const SizedBox(width: 18),
        Expanded(
          child: SelectableText(
            value,
            style: prototypeText(context, 13, family: 'Consolas'),
          ),
        ),
      ],
    ),
  );
  @override
  Widget build(BuildContext context) {
    final record = execution;
    final r = widget.request;
    final plan = record?.operationPlan ?? r.plan;
    return PrototypeDialog(
      width: 650,
      title: '执行记录',
      onClose: () => Navigator.pop(context),
      actionDivider: false,
      actionPaddingTop: 22,
      body: record == null
          ? const QuietNotice('暂时无法读取执行记录，请检查本机服务后重新核对。', warning: true)
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  credentialExecutionLabel(record),
                  style: prototypeText(context, 16, weight: FontWeight.w600),
                ),
                const SizedBox(height: 10),
                if (record.protocolVersion == 2) ...[
                  fact('操作 ID', record.operationId ?? '未记录'),
                  fact('登记时间', time(record.createdAt)),
                  fact('重试规则', '同一操作不会重复启动；本次结果不消耗整个授权。'),
                ] else
                  fact('启动尝试', '已占用 1 / 1，不会自动重试'),
                fact(
                  '进程创建',
                  record.processStarted
                      ? '已确认创建'
                      : record.state == 'unknown'
                      ? '未能确认'
                      : '尚未创建',
                ),
                fact('退出码', record.exitCode?.toString() ?? '尚无记录'),
                fact('文件清理', credentialCleanupLabel(record.cleanupState)),
                if (record.materialLease != null)
                  fact(
                    '受管材料',
                    plan.receiver == 'ssh_identity'
                        ? '私钥副本 · SSH 空配置 · 确认主机快照 · 空全局主机记录'
                        : 'AWS 凭据副本 · AWS 空配置',
                  ),
                if (_cleanupError != null)
                  QuietNotice(_cleanupError!, warning: true),
                fact('开始时间', time(record.startedAt)),
                fact('结束时间', time(record.finishedAt)),
                if (record.errorCode != null) fact('结果代码', record.errorCode!),
                if (record.restoredAt != null)
                  const QuietNotice(
                    '这是从备份恢复的历史事实。本机没有恢复运行材料、输出或使用许可；原设备的任务和材料需在原设备核查。',
                  ),
                if (record.state == 'unknown' && record.restoredAt == null)
                  const QuietNotice(
                    '无法确认本次任务的最终结果。请先核查原任务，不要重新启动同一操作。',
                    warning: true,
                  ),
                const SizedBox(height: 10),
                fact('凭据 / 版本', '${r.credentialId} / ${r.version}'),
                fact('注入位置', credentialInjectionFact(r)),
                fact(
                  plan.receiver == 'ssh_identity' ? '主机快照与隔离' : '接收配置',
                  credentialIsolationFacts(r, plan: plan),
                ),
                fact('程序位置', plan.path),
                fact(
                  '参数（按项）',
                  jsonEncode(plan.argv.map((a) => a.toJson()).toList()),
                ),
                fact('工作目录', plan.cwd),
                fact('计划 hash', plan.planHash),
                fact('执行编号', record.id),
                fact('申请编号', r.id),
                const SizedBox(height: 12),
                Text(
                  '这里只保留执行事实。完整输出不写入历史或备份；执行宿主退出、缓存淘汰或任务结束超过 30 分钟后，内存输出不再保留。',
                  style: prototypeText(
                    context,
                    12,
                    color: UiPalette.of(context).muted,
                    height: 1.9,
                  ),
                ),
              ],
            ),
      actions: [
        if (record?.materialLease != null &&
            record!.cleanupState != 'complete' &&
            !{'preparing', 'running'}.contains(record.state))
          TextButton(
            style: prototypeSecondary(context),
            onPressed: _cleaning ? null : _cleanup,
            child: Text(_cleaning ? '正在核查…' : '核查并重试清理'),
          ),
        TextButton(
          style: prototypePrimary(context),
          onPressed: () => Navigator.pop(context),
          child: Text(r.protocolVersion == 2 ? '返回' : '返回审批'),
        ),
      ],
    );
  }
}
