import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart';
import 'credential_delivery.dart';
import 'credential_execution_receipt.dart';
import 'prototype_dialog.dart';
import 'prototype_ui.dart';
import 'settings_controls.dart';
import 'ui.dart';

/// An authorization's operations, rather than its latest execution pointer.
/// Selection is by immutable execution identity and remains stable on reports.
class CredentialUseOperations extends StatefulWidget {
  const CredentialUseOperations({
    super.key,
    required this.owner,
    required this.request,
    this.refresh = false,
  });
  final OwnerAccess owner;
  final CredentialUseRequest request;
  final bool refresh;
  @override
  State<CredentialUseOperations> createState() =>
      _CredentialUseOperationsState();
}

class _CredentialUseOperationsState extends State<CredentialUseOperations> {
  static const _pageSize = 5;
  String? _selected;
  int? _page;
  Timer? _timer;
  bool _tip = false;

  @override
  void initState() {
    super.initState();
    if (widget.refresh) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted &&
            TickerMode.valuesOf(context).enabled &&
            (ModalRoute.of(context)?.isCurrent ?? true)) {
          setState(() {});
        }
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String _time(DateTime? value) =>
      value == null ? '时间未记录' : value.toLocal().toString().split('.').first;
  Widget _text(
    String value, {
    double size = 13,
    Color? color,
    String? family,
    FontWeight weight = FontWeight.w400,
  }) => Text(
    value,
    style: prototypeText(
      context,
      size,
      color: color,
      family: family,
      weight: weight,
      height: 1.8,
    ),
  );
  Widget _fact(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 9),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 102,
          child: _text(label, color: UiPalette.of(context).muted),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: SelectableText(
            value,
            style: prototypeText(context, 12, family: 'Consolas', height: 1.8),
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final c = UiPalette.of(context), r = widget.request;
    final records =
        widget.owner.credentialExecutions
            .where((e) => e.requestId == r.id)
            .toList()
          ..sort((a, b) {
            final at = a.createdAt, bt = b.createdAt;
            if (at != null && bt != null) {
              final order = at.compareTo(bt);
              if (order != 0) return order;
            }
            if (at == null && bt != null) return -1;
            if (at != null && bt == null) return 1;
            return a.id.compareTo(b.id);
          });
    final selected =
        records.where((e) => e.id == _selected).firstOrNull ??
        records.where((e) => e.id == r.executionId).firstOrNull ??
        records.lastOrNull;
    _selected = selected?.id;
    final pages = (records.length / _pageSize).ceil().clamp(1, 1 << 30);
    final page =
        (_page ??
                (selected == null ? 0 : records.indexOf(selected) ~/ _pageSize))
            .clamp(0, pages - 1);
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 150);
    final plan = selected?.operationPlan;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 20),
        LayoutBuilder(
          builder: (context, bounds) {
            final facts = [
              _fact(
                '授权期限',
                r.credentialValidity == CredentialUseValidity.session
                    ? '不限时（限本聊天）'
                    : _time(r.credentialExpiresAt),
              ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _fact('允许方式', switch (r.plan.receiver) {
                      'ssh_identity' => 'SSH · 临时文件参数',
                      'aws_shared_credentials' => '临时文件 · 环境变量',
                      'program_stdin' => '程序标准输入',
                      'program_file' => '临时凭据文件',
                      _ => '凭据值 · 环境变量',
                    }),
                  ),
                  TextButton(
                    key: const ValueKey('reuse-injection-tip'),
                    onPressed: () => setState(() => _tip = !_tip),
                    style: prototypeButton(context, padding: EdgeInsets.zero),
                    child: _text('?', size: 12, color: c.accent),
                  ),
                ],
              ),
            ];
            return bounds.maxWidth < 480 ||
                    MediaQuery.textScalerOf(context).scale(12) > 18
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [facts[0], const SizedBox(height: 12), facts[1]],
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: facts[0]),
                      const SizedBox(width: 24),
                      Expanded(child: facts[1]),
                    ],
                  );
          },
        ),
        AnimatedSize(
          duration: duration,
          alignment: Alignment.topCenter,
          child: _tip
              ? SettingsNotice(
                  '由 CLI 设置接收位置',
                  '${credentialInjectionTip(r)}同一批准范围内的新命令不重新审批；每次操作冻结自己的计划和操作 ID。增加未批准的凭据或使用方式需要新申请。',
                )
              : const SizedBox(),
        ),
        const SizedBox(height: 22),
        _text(
          '此授权只在当前会话及固定期限内有效。逐次使用不会延长截止时间；连接字段按独立授权处理。',
          size: 12,
          color: c.muted,
        ),
        const SizedBox(height: 8),
        _text('逐次使用记录', size: 15, weight: FontWeight.w600),
        const SizedBox(height: 12),
        if (records.isEmpty)
          const SettingsNotice(
            '尚无使用操作',
            '批准不会自动执行。Agent 提交操作 ID 和本次完整命令后，由 CLI 校验并启动。',
          ),
        for (final e in records.skip(page * _pageSize).take(_pageSize))
          AnimatedContainer(
            duration: duration,
            decoration: BoxDecoration(
              color: e.id == selected?.id ? c.rail : c.paper,
              border: Border(bottom: BorderSide(color: c.line)),
            ),
            child: TextButton(
              key: ValueKey('use-operation-${e.id}'),
              onPressed: () => setState(() => _selected = e.id),
              style: prototypeButton(
                context,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 13,
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Tooltip(
                          message: e.operationId ?? e.id,
                          child: Text(
                            e.operationId ?? e.id,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: prototypeText(
                              context,
                              13,
                              weight: FontWeight.w600,
                              color: c.ink,
                            ),
                          ),
                        ),
                        _text(_time(e.createdAt), size: 12, color: c.muted),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Flexible(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: _text(
                        credentialExecutionLabel(e),
                        size: 12,
                        color: c.muted,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (pages > 1)
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              IconButton(
                tooltip: '上一页操作',
                onPressed: page == 0
                    ? null
                    : () => setState(() => _page = page - 1),
                icon: const Icon(Icons.chevron_left, size: 18),
              ),
              _text('${page + 1} / $pages', size: 12),
              IconButton(
                tooltip: '下一页操作',
                onPressed: page + 1 >= pages
                    ? null
                    : () => setState(() => _page = page + 1),
                icon: const Icon(Icons.chevron_right, size: 18),
              ),
            ],
          ),
        AnimatedSize(
          duration: duration,
          alignment: Alignment.topCenter,
          child: selected == null
              ? const SizedBox()
              : Column(
                  key: ValueKey(selected.id),
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 4),
                    _text('本次 CLI 启动计划', size: 14, weight: FontWeight.w600),
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.all(15),
                      decoration: BoxDecoration(
                        color: c.rail,
                        border: Border.all(color: c.line),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: SelectableText(
                        plan == null
                            ? '计划未记录；不使用申请首条命令代替本次事实。'
                            : [
                                    plan.path
                                        .split(RegExp(r'[/\\]'))
                                        .last
                                        .replaceFirst(
                                          RegExp(
                                            r'\.exe$',
                                            caseSensitive: false,
                                          ),
                                          '',
                                        ),
                                    ...plan.argv.map(launchValueLabel),
                                  ]
                                  .map(
                                    (s) => s.contains(RegExp(r'\s'))
                                        ? jsonEncode(s)
                                        : s,
                                  )
                                  .join(' '),
                        style: prototypeText(
                          context,
                          13,
                          family: 'Consolas',
                          height: 1.8,
                        ),
                      ),
                    ),
                    _fact('操作 ID', selected.operationId ?? '未记录'),
                    _fact('授权批准', _time(r.decidedAt)),
                    if (plan != null) ...[
                      _fact('程序位置', plan.path),
                      _fact('工作目录', plan.cwd),
                      _fact('计划 hash', plan.planHash),
                    ],
                    _fact(
                      '文件清理',
                      credentialCleanupLabel(selected.cleanupState),
                    ),
                    if (selected.state == 'unknown')
                      const SettingsNotice(
                        '先核查原操作',
                        '结果未知不等于未执行。只查询原操作，不自动换 ID 重做。',
                        error: true,
                      ),
                    if ({
                          'prepare_failed',
                          'start_failed',
                        }.contains(selected.state) ||
                        selected.state == 'exited' && selected.exitCode != 0)
                      const SettingsNotice(
                        '本次操作未成功',
                        '此结果不消耗整个授权。修正并核查原因后，可在有效范围内明确提交新的操作 ID。',
                      ),
                    TextButton(
                      onPressed: () => showCredentialExecutionReceipt(
                        context,
                        widget.owner,
                        r,
                        executionId: selected.id,
                      ),
                      style: prototypeButton(
                        context,
                        padding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: _text('查看本次执行记录与清理 →', color: c.accent),
                      ),
                    ),
                  ],
                ),
        ),
      ],
    );
  }
}

Future<void> showCredentialUseOperations(
  BuildContext context,
  OwnerAccess owner,
  CredentialUseRequest request,
) => showDialog<void>(
  context: context,
  barrierColor: const Color(0x4f241b27),
  builder: (context) => PrototypeDialog(
    width: 700,
    title: '逐次使用记录',
    onClose: () => Navigator.pop(context),
    body: CredentialUseOperations(
      owner: owner,
      request: request,
      refresh: true,
    ),
    actions: [
      TextButton(
        style: prototypeSecondary(context),
        onPressed: () => Navigator.pop(context),
        child: const Text('返回'),
      ),
    ],
  ),
);
