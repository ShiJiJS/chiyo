import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart';
import 'credential_delivery.dart';
import 'credential_execution_receipt.dart';
import 'credential_operations.dart';
import 'prototype_ui.dart';
import 'settings_controls.dart';
import 'ui.dart';
import 'focused_fill_ui.dart';

String credentialHistoryState(OwnerAccess owner, CredentialUseRequest r) {
  if (r.protocolVersion == 2) {
    if (r.restoredAt != null) return '历史事实';
    return switch (owner.credentialGrantState(r)) {
      'available' => '有效',
      'expired' => '已到期',
      'revoked' => '已撤销',
      'version_invalidated' => '使用条件已变化',
      _ =>
        owner.credentialUseState(r) == 'denied'
            ? '已拒绝'
            : r.credentialApproved
            ? '已结束'
            : '未批准凭据',
    };
  }
  final execution = owner.credentialExecutions
      .where((e) => e.id == r.executionId)
      .firstOrNull;
  if (execution != null) return credentialExecutionLabel(execution);
  return switch (owner.credentialGrantState(r)) {
    'available' => '等待启动',
    'expired' => '已到期',
    'revoked' => '已撤销',
    'version_invalidated' => '使用条件已变化',
    _ =>
      owner.credentialUseState(r) == 'denied'
          ? '已拒绝'
          : r.credentialApproved
          ? '许可不可用'
          : '未批准凭据',
  };
}

/// The Round05 credential history card. It projects durable facts, never output
/// buffers, private process identities, paths to managed material or authority.
class CredentialHistoryDocument extends StatefulWidget {
  const CredentialHistoryDocument({
    super.key,
    required this.owner,
    required this.request,
    required this.onChanged,
    this.fieldGrant,
    this.accesses = const [],
    this.onOpenCredential,
  });
  final OwnerAccess owner;
  final CredentialUseRequest request;
  final GrantHistory? fieldGrant;
  final List<AccessRecord> accesses;
  final VoidCallback onChanged;
  final ValueChanged<String>? onOpenCredential;
  @override
  State<CredentialHistoryDocument> createState() =>
      _CredentialHistoryDocumentState();
}

class _CredentialHistoryDocumentState extends State<CredentialHistoryDocument> {
  final _scroll = ScrollController();
  bool _busy = false, _tip = false, _details = false;
  String? _error;
  CredentialUseRequest get r =>
      widget.owner.credentialUseRequests
          .where((r) => r.id == widget.request.id)
          .firstOrNull ??
      widget.request;
  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      if (mounted) widget.onChanged();
    } on CredentialUseFailure catch (e) {
      if (mounted) {
        setState(
          () => _error = switch (e.code) {
            'cleanup_busy' => '仍有活动进程，或无法确认进程组已结束。材料已保留，请稍后核查。',
            'cleanup_identity_mismatch' => '受管材料身份已变化，未删除可疑文件。请先人工核查。',
            'cleanup_failed' => '文件仍被占用或无法删除。解除占用后可只重试清理。',
            _ => '未能保存决定或完成清理，请检查本机服务后重试。',
          },
        );
      }
    } on Object {
      if (mounted) setState(() => _error = '未能保存决定，请修复存储后重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _revoke({bool fields = false}) async {
    final confirmed = await showSettingsDialog<bool>(
      context: context,
      builder: (context) => SettingsDialog(
        title: fields ? '撤销字段授权' : '撤销使用授权',
        actions: [
          settingsAction(context, '保留授权', () => Navigator.pop(context, false)),
          settingsAction(
            context,
            '确认撤销',
            () => Navigator.pop(context, true),
            primary: true,
          ),
        ],
        child: Text(
          fields
              ? '停止这份授权的后续字段读取。凭据使用许可保持独立；已经提供的内容无法收回。'
              : '阻止本次使用许可的后续启动，不会终止已启动程序；同时批准的字段读取保持独立。',
          style: prototypeText(context, 14, height: 1.9),
        ),
      ),
    );
    if (confirmed == true) {
      await _run(
        () => fields
            ? widget.owner.revokeFromHistory(widget.fieldGrant!.id)
            : widget.owner.revokeCredentialUse(r.id),
      );
    }
  }

  Widget t(
    String text,
    double size, {
    Color? color,
    FontWeight weight = FontWeight.w400,
    String? family,
  }) => Text(
    text,
    style: prototypeText(
      context,
      size,
      color: color,
      weight: weight,
      family: family,
    ),
  );
  String time(DateTime? value) =>
      value == null ? '未记录' : value.toLocal().toString().split('.').first;
  Widget _actions(CredentialExecution? record, bool available, bool cleanup) =>
      Wrap(
        alignment: WrapAlignment.end,
        spacing: 12,
        runSpacing: 10,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (available)
            settingsAction(context, '撤销使用授权', _busy ? null : () => _revoke()),
          if (r.protocolVersion == 1 &&
              widget.fieldGrant != null &&
              widget.owner.credentialFieldGrantState(r) == 'available')
            settingsAction(
              context,
              '撤销字段授权',
              _busy ? null : () => _revoke(fields: true),
            ),
          if (cleanup)
            settingsAction(
              context,
              '重试文件清理',
              _busy
                  ? null
                  : () => _run(() async {
                      await widget.owner.cleanupCredentialExecution(record!.id);
                    }),
            ),
          if (widget.onOpenCredential != null)
            TextButton(
              onPressed: () => widget.onOpenCredential!(r.credentialId),
              style: prototypeButton(context),
              child: const Text('查看凭据 →'),
            ),
        ],
      );
  Widget fact(
    String label,
    String value, {
    bool code = false,
    bool divider = false,
    bool injectionTip = false,
  }) => Container(
    padding: const EdgeInsets.symmetric(vertical: 10),
    decoration: divider
        ? BoxDecoration(
            border: Border(
              bottom: BorderSide(color: UiPalette.of(context).line),
            ),
          )
        : null,
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 90,
          child: injectionTip
              ? Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    t(label, 13, color: UiPalette.of(context).muted),
                    SizedBox.square(
                      dimension:
                          26 * MediaQuery.textScalerOf(context).scale(14) / 14,
                      child: TextButton(
                        key: const ValueKey('history-injection-tip'),
                        onPressed: () => setState(() => _tip = !_tip),
                        style: prototypeButton(
                          context,
                          radius: 13,
                          side: BorderSide(color: UiPalette.of(context).line),
                          background: _tip
                              ? UiPalette.of(context).selected
                              : null,
                        ),
                        child: t(
                          '?',
                          14,
                          color: UiPalette.of(context).accent,
                          family: 'Georgia',
                        ),
                      ),
                    ),
                  ],
                )
              : t(label, 13, color: UiPalette.of(context).muted),
        ),
        const SizedBox(width: 15),
        Expanded(
          child: SelectableText(
            value,
            textAlign: divider ? TextAlign.end : TextAlign.start,
            style: prototypeText(
              context,
              code ? 12 : 13,
              family: code ? 'Consolas' : null,
            ),
          ),
        ),
      ],
    ),
  );
  @override
  Widget build(BuildContext context) {
    if (r.isFocusedFill) {
      return FocusedFillHistoryDocument(
        key: ValueKey('focused-history-${r.id}'),
        owner: widget.owner,
        request: r,
        stateLabel: credentialHistoryState(widget.owner, r),
        onChanged: widget.onChanged,
        onOpenCredential: widget.onOpenCredential,
      );
    }
    final avatarSize = MediaQuery.textScalerOf(context).scale(16) * 1.75;
    final c = UiPalette.of(context),
        record = widget.owner.credentialExecutions
            .where((e) => e.id == r.executionId)
            .firstOrNull;
    final permit = widget.owner.credentialGrantState(r),
        available = permit == 'available';
    final fieldState = widget.owner.credentialFieldGrantState(r);
    final plan = r.requestedPlan ?? r.plan;
    final command = [
      plan.path,
      ...plan.argv.map(launchValueLabel),
    ].map((s) => s.contains(RegExp(r'\s')) ? jsonEncode(s) : s).join(' ');
    final fields = widget.fieldGrant?.fields ?? const <RecordedField>[];
    final cleanup =
        record != null &&
        record.materialLease != null &&
        record.cleanupState != 'complete' &&
        !{'preparing', 'running'}.contains(record.state);
    final reusable = r.protocolVersion == 2;
    final operationCount = widget.owner.credentialExecutions
        .where((e) => e.requestId == r.id)
        .length;
    final summaries = [
      ('使用凭据', r.credentialName ?? '名称未记录'),
      (
        r.credentialApproved
            ? reusable
                  ? '固定版本'
                  : '批准版本'
            : '申请版本',
        '版本 ${r.version}',
      ),
      (
        reusable ? '使用操作' : '启动尝试',
        reusable ? '$operationCount 次' : '${r.attemptConsumed ? 1 : 0} / 1 次',
      ),
    ];
    return Container(
      key: ValueKey('history-document-${r.id}'),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: c.paper,
        border: Border.all(color: c.line),
        borderRadius: BorderRadius.circular(7),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0632202d),
            offset: Offset(0, 3),
            blurRadius: 8,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Scrollbar(
              controller: _scroll,
              child: SingleChildScrollView(
                controller: _scroll,
                padding: const EdgeInsets.fromLTRB(34, 28, 42, 28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Wrap(
                            spacing: 12,
                            runSpacing: 8,
                            children: [
                              t(
                                credentialHistoryState(widget.owner, r),
                                12,
                                color: available ? c.statusLive : c.muted,
                              ),
                              t(
                                reusable ? '凭据使用 · 有效期内复用' : '凭据使用 · 运行时注入',
                                12,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        t(
                          r.id.length > 20 ? '${r.id.substring(0, 16)}…' : r.id,
                          12,
                          color: c.muted,
                          family: 'Consolas',
                        ),
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 13, bottom: 16),
                      child: t(
                        r.chatLabel,
                        29,
                        family: 'SimSun',
                        weight: FontWeight.w500,
                      ),
                    ),
                    if (!reusable &&
                        (record?.state == 'prepare_failed' ||
                            record?.state == 'start_failed'))
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 20),
                        child: t('本次启动尝试已消耗，程序未启动。修正原因后，需要重新申请一次使用许可。', 13),
                      ),
                    if (r.restoredAt != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 20),
                        child: t(
                          '从备份恢复的历史事实，不表示本机仍在运行。许可、运行材料和输出没有恢复；原设备的任务和材料需在原设备核查。',
                          13,
                        ),
                      ),
                    if (!reusable &&
                        record?.state == 'unknown' &&
                        r.restoredAt == null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 20),
                        child: t('结果尚无法确认。先核查原执行与残留文件，避免重复运行。', 13),
                      ),
                    Row(
                      children: [
                        Container(
                          width: avatarSize,
                          height: avatarSize,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: c.selected,
                            border: Border.all(color: c.line),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: t(
                            r.chatLabel.isEmpty
                                ? 'A'
                                : r.chatLabel.substring(0, 1),
                            16,
                            family: 'Georgia',
                          ),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: t(r.chatLabel, 14, weight: FontWeight.w700),
                        ),
                        const SizedBox(width: 8),
                        t('申请时的会话', 12, color: c.muted),
                      ],
                    ),
                    Container(
                      margin: const EdgeInsets.only(top: 28),
                      padding: const EdgeInsets.only(top: 20, bottom: 18),
                      decoration: BoxDecoration(
                        border: Border(
                          top: BorderSide(color: c.line),
                          bottom: BorderSide(color: c.line),
                        ),
                      ),
                      child: IntrinsicHeight(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (var i = 0; i < 3; i++)
                              Expanded(
                                child: Container(
                                  padding: EdgeInsets.only(
                                    left: i == 0 ? 0 : 24,
                                    right: 12,
                                  ),
                                  decoration: i == 0
                                      ? null
                                      : BoxDecoration(
                                          border: Border(
                                            left: BorderSide(color: c.line),
                                          ),
                                        ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      t(summaries[i].$1, 12, color: c.muted),
                                      const SizedBox(height: 8),
                                      if (i == 2)
                                        Row(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.baseline,
                                          textBaseline: TextBaseline.alphabetic,
                                          children: [
                                            Text(
                                              '${reusable
                                                  ? operationCount
                                                  : r.attemptConsumed
                                                  ? 1
                                                  : 0}',
                                              style: prototypeText(
                                                context,
                                                28,
                                                family: 'Georgia',
                                                height: 1.2,
                                                color: c.strong,
                                              ),
                                            ),
                                            const SizedBox(width: 5),
                                            t(reusable ? '次' : '/ 1 次', 15),
                                          ],
                                        )
                                      else
                                        t(
                                          summaries[i].$2,
                                          16,
                                          weight: FontWeight.w500,
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    if (reusable) ...[
                      CredentialUseOperations(
                        key: ValueKey('operations-${r.id}'),
                        owner: widget.owner,
                        request: r,
                      ),
                      if (_error != null)
                        SettingsNotice('操作未完成', _error!, error: true),
                    ] else ...[
                      const SizedBox(height: 18),
                      fact(
                        '注入方式',
                        r.plan.receiver == 'gh_token'
                            ? '秘密值 → 环境变量'
                            : r.plan.receiver == 'ssh_identity'
                            ? '临时文件路径 → 命令参数'
                            : '临时文件路径 → 环境变量',
                        injectionTip: true,
                      ),
                      fact(
                        r.plan.receiver == 'ssh_identity' ? '文件引用' : '环境变量',
                        r.plan.receiver == 'ssh_identity'
                            ? '{{file:${r.alias}}}'
                            : credentialInjectionTarget(r),
                        code: true,
                      ),
                      fact('申报目标', credentialCommandTarget(r)),
                      AnimatedSize(
                        duration: MediaQuery.disableAnimationsOf(context)
                            ? Duration.zero
                            : const Duration(milliseconds: 150),
                        alignment: Alignment.topCenter,
                        child: _tip
                            ? SettingsNotice(
                                '由 CLI 设置接收位置',
                                credentialInjectionTip(r),
                              )
                            : const SizedBox(),
                      ),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: t('由 CLI 启动的命令', 12, color: c.muted)),
                          const SizedBox(width: 12),
                          TextButton(
                            onPressed: () =>
                                setState(() => _details = !_details),
                            style: prototypeButton(
                              context,
                              padding: EdgeInsets.zero,
                            ),
                            child: t(
                              '程序位置与固定计划 ${_details ? '−' : '＋'}',
                              12,
                              color: c.accent,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.all(15),
                        decoration: BoxDecoration(
                          color: c.rail,
                          border: Border.all(color: c.line),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: SelectableText(
                          command,
                          style: prototypeText(
                            context,
                            13,
                            family: 'Consolas',
                            height: 1.8,
                          ),
                        ),
                      ),
                      if (_details) ...[
                        fact('申报用途', r.purpose),
                        fact('工作目录', r.plan.cwd, code: true),
                        fact(
                          '固定参数',
                          jsonEncode(
                            r.plan.argv.map((a) => a.toJson()).toList(),
                          ),
                          code: true,
                        ),
                        fact(
                          '固定环境',
                          jsonEncode(
                            r.plan.env.map((k, v) => MapEntry(k, v.toJson())),
                          ),
                          code: true,
                        ),
                        fact('计划 hash', r.plan.planHash, code: true),
                        fact('接收配置', credentialIsolationFacts(r)),
                      ],
                      Container(
                        margin: const EdgeInsets.only(top: 12),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        decoration: BoxDecoration(
                          border: Border(top: BorderSide(color: c.line)),
                        ),
                        child: Wrap(
                          spacing: 28,
                          runSpacing: 8,
                          children: [
                            t(
                              '${r.decidedAt == null
                                  ? '申请时间'
                                  : r.credentialApproved
                                  ? '授权时间'
                                  : '审批时间'}  ${time(r.decidedAt ?? r.createdAt)}',
                              13,
                            ),
                            if (r.credentialExpiresAt != null)
                              t('允许启动至  ${time(r.credentialExpiresAt)}', 13),
                            if (r.revokedAt != null)
                              t('撤销使用于  ${time(r.revokedAt)}', 13),
                          ],
                        ),
                      ),
                      if (fields.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        t('同时批准读取的连接字段', 13, weight: FontWeight.w600),
                        const SizedBox(height: 8),
                        t(
                          fields
                              .map((f) => '${f.itemName}：${f.fieldName}')
                              .join('；'),
                          13,
                          color: c.muted,
                        ),
                        const SizedBox(height: 10),
                        t(
                          '字段授权：${fieldState == 'available'
                              ? '有效'
                              : fieldState == 'expired'
                              ? '已到期'
                              : '已结束'} · ${widget.accesses.length} 次实际读取',
                          12,
                          color: c.muted,
                        ),
                      ],
                      const SizedBox(height: 14),
                      fact('申请', switch (widget.owner.credentialUseState(r)) {
                        'approved' => '已批准',
                        'partially_approved' => '部分批准',
                        'denied' => '已拒绝',
                        'expired' => '已到期',
                        _ => '已结束',
                      }, divider: true),
                      fact(
                        '使用许可',
                        available
                            ? '有效 · 尚未消耗'
                            : r.attemptConsumed
                            ? '已消耗 · 不可重新启动'
                            : credentialHistoryState(widget.owner, r),
                        divider: true,
                      ),
                      fact(
                        '执行',
                        record == null
                            ? '尚未启动'
                            : credentialExecutionLabel(record),
                        divider: true,
                      ),
                      fact(
                        '清理',
                        record == null
                            ? '尚未生成材料'
                            : record.restoredAt != null
                            ? '本机不恢复运行材料'
                            : credentialCleanupLabel(record.cleanupState),
                        divider: true,
                      ),
                      if (record != null)
                        TextButton(
                          onPressed: () => showCredentialExecutionReceipt(
                            context,
                            widget.owner,
                            r,
                          ),
                          style: prototypeButton(
                            context,
                            padding: const EdgeInsets.symmetric(vertical: 10),
                          ),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: t('查看执行记录 →', 13, color: c.accent),
                          ),
                        ),
                      if (available)
                        const SettingsNotice(
                          '等待 CLI 启动任务',
                          '仅生成了使用许可，尚未向进程注入凭据或生成临时文件。',
                        ),
                      if (_error != null)
                        SettingsNotice('操作未完成', _error!, error: true),
                      if (widget.accesses.isNotEmpty) ...[
                        const SizedBox(height: 18),
                        t('字段实际访问', 14, weight: FontWeight.w600),
                        for (final access in widget.accesses)
                          fact(
                            time(access.at),
                            '${access.itemName ?? '信息名称未记录'}：${access.fieldName ?? '字段名称未记录'} · ${access.outcome == AccessOutcome.allowed ? '访问允许' : '读取被拒绝'}',
                            divider: true,
                          ),
                      ],
                      const SizedBox(height: 17),
                      t(
                        '准备失败或启动失败也消耗一次尝试。撤销不会终止已运行进程；结果未知时不自动重试。文件清理不能收回已复制的内容。',
                        13,
                        color: c.muted,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 18),
            decoration: BoxDecoration(
              color: c.rail,
              border: Border(top: BorderSide(color: c.line)),
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final message = t(
                  reusable
                      ? '撤销阻止新使用；已经运行的进程继续，材料按各自进程组清理。'
                      : available
                      ? '授权到期或被撤销后，CLI 将拒绝新的使用。'
                      : '记录保留使用对象、注入方式、运行与清理结果。',
                  12,
                  color: c.muted,
                );
                final actions = _actions(
                  record,
                  available,
                  !reusable && cleanup,
                );
                return constraints.maxWidth < 850 ||
                        MediaQuery.textScalerOf(context).scale(12) > 18
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          message,
                          const SizedBox(height: 12),
                          actions,
                        ],
                      )
                    : Row(
                        children: [
                          Expanded(child: message),
                          const SizedBox(width: 16),
                          actions,
                        ],
                      );
              },
            ),
          ),
        ],
      ),
    );
  }
}
