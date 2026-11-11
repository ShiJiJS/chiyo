import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart';
import 'ui.dart';
import 'prototype_ui.dart';
import 'prototype_dialog.dart';
import 'credential_execution_receipt.dart';
import 'credential_operations.dart';
import 'credential_delivery.dart';
import 'credential_use_draft.dart';
import 'focused_fill_ui.dart';
import 'information_file_summary.dart';
export 'credential_use_draft.dart';

String credentialUseStateLabel(String state) => switch (state) {
  'pending' => '待处理',
  'approved' => '已批准',
  'partially_approved' => '部分批准',
  'denied' => '已拒绝',
  'expired' => '已到期',
  _ => '已结束',
};

class CredentialUseApprovalPanel extends StatefulWidget {
  const CredentialUseApprovalPanel({
    super.key,
    required this.owner,
    required this.request,
    required this.draft,
    required this.onChanged,
  });
  final OwnerAccess owner;
  final CredentialUseRequest request;
  final CredentialUseApprovalDraft draft;
  final VoidCallback onChanged;
  @override
  State<CredentialUseApprovalPanel> createState() =>
      _CredentialUseApprovalPanelState();
}

class _CredentialUseApprovalPanelState
    extends State<CredentialUseApprovalPanel> {
  final _document = ScrollController(), _decision = ScrollController();
  bool _busy = false;
  String? _error;
  CredentialUseRequest get r =>
      widget.owner.credentialUseRequests
          .where((r) => r.id == widget.request.id)
          .firstOrNull ??
      widget.request;
  bool get reusable => r.protocolVersion == 2;
  List<CredentialExecution> get operations => widget.owner.credentialExecutions
      .where((e) => e.requestId == r.id)
      .toList();
  CredentialUseApprovalDraft get draft => widget.draft;
  bool get pending => widget.owner.credentialUseState(r) == 'pending';
  bool get allowCredential =>
      pending ? draft.allowCredential && eligible : r.credentialApproved;
  int get selectedFieldCount =>
      pending ? draft.fields.length : r.approvedFields.length;
  CredentialExecution? get execution {
    try {
      return widget.owner.credentialExecutions
          .where((e) => e.id == r.executionId)
          .firstOrNull;
    } on Object {
      return null;
    }
  }

  @override
  void dispose() {
    _document.dispose();
    _decision.dispose();
    super.dispose();
  }

  String get credentialName {
    try {
      return widget.owner.credential(r.credentialId).name;
    } on Object {
      return '已删除凭据';
    }
  }

  bool get eligible {
    try {
      widget.owner.checkCredentialUseEligibility(r);
      return true;
    } on Object {
      return false;
    }
  }

  String get command => _command(r.plan);
  String _command(CredentialLaunchPlan plan) => [
    plan.path
        .split(RegExp(r'[/\\]'))
        .last
        .replaceFirst(RegExp(r'\.exe$', caseSensitive: false), ''),
    ...plan.argv.map(launchValueLabel),
  ].map((s) => s.contains(' ') ? '"$s"' : s).join(' ');
  String _time(DateTime? d) => d == null ? '未批准' : d.toLocal().toString();

  Future<void> _revoke() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.owner.revokeCredentialUse(r.id);
      if (mounted) widget.onChanged();
    } on Object {
      if (mounted) setState(() => _error = '未能保存撤销决定，请检查本机服务后重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _dialog(String kind) async {
    final approve = kind == 'approve';
    final detail = kind == 'request';
    final selected = approve ? draft.fields.toList() : <FieldRef>[];
    final reviewed = <FieldRef, InformationField>{
      for (final ref in selected)
        for (final item in widget.owner.information.where(
          (i) => i.id == ref.itemId,
        ))
          for (final field in item.fields.where((f) => f.id == ref.fieldId))
            ref: field,
    };
    final fileFields = reviewed.values
        .where((f) => f.kind == FieldKind.file)
        .toList();
    final loaded = <InformationAttachmentRef>{};
    Widget fact(String label, String value) =>
        _fact(label, value, brief: detail);
    await showDialog<void>(
      context: context,
      barrierColor: const Color(0x4f241b27),
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, update) {
          Future<void> decide() async {
            update(() => _busy = true);
            try {
              await widget.owner.decideCredentialUse(
                r.id,
                approveCredential: approve && allowCredential,
                fields: selected,
                reviewedVersions: {
                  for (final entry in reviewed.entries)
                    entry.key: entry.value.version,
                },
                lifetime: draft.minutes == null
                    ? null
                    : Duration(minutes: draft.minutes!),
                fieldLifetime: reusable
                    ? Duration(minutes: draft.fieldMinutes)
                    : null,
              );
              if (mounted) setState(() => _error = null);
              if (dialogContext.mounted) Navigator.pop(dialogContext);
              widget.onChanged();
            } on Object catch (error) {
              if (mounted) {
                setState(
                  () => _error =
                      error is CredentialUseFailure &&
                          error.code == 'scope_changed'
                      ? '连接字段或文件版本已变化。请返回核对后重新批准，当前决定未保存。'
                      : '未能保存决定，请检查凭据、请求状态或存储后重试。输入已保留。',
                );
              }
              if (dialogContext.mounted) update(() => _busy = false);
              return;
            }
            if (mounted) setState(() => _busy = false);
          }

          return PrototypeDialog(
            width: 650,
            title: detail
                ? '申请明细'
                : approve
                ? '批准凭据使用'
                : '拒绝使用申请',
            onClose: _busy ? null : () => Navigator.pop(dialogContext),
            actionDivider: false,
            actionPaddingTop: 22,
            body: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  detail
                      ? 'Agent 提交的申请；用途与目标是自述内容。原文不随申请提交。'
                      : approve
                      ? (allowCredential
                            ? reusable
                                  ? '允许本次会话在有效期内重复使用「$credentialName」版本 ${r.version}，使用方式固定。'
                                  : '允许本次会话启动一次任务，使用「$credentialName」版本 ${r.version}。'
                            : '本次仅批准所选连接字段，不提供凭据使用许可。')
                      : '本次申请不会获得凭据使用许可，也不会提供同时申请的连接字段。',
                  style: prototypeText(context, 14, height: 1.85),
                ),
                if (detail || approve) ...[
                  const SizedBox(height: 14),
                  if (detail) fact('使用凭据', '$credentialName · 版本 ${r.version}'),
                  fact(
                    '凭据许可',
                    allowCredential
                        ? pending
                              ? reusable
                                    ? draft.minutes == null
                                          ? '不限时（限本聊天）'
                                          : '${approvalDurationLabel(draft.minutes!)}内可重复使用，不续期'
                                    : '${approvalDurationLabel(draft.minutes!)}内允许启动一次'
                              : r.credentialValidity ==
                                    CredentialUseValidity.session
                              ? '不限时（限本聊天）'
                              : '截止 ${_time(r.credentialExpiresAt)}'
                        : '不批准',
                  ),
                  if (r.fields.isNotEmpty)
                    fact(
                      '字段许可',
                      pending
                          ? '$selectedFieldCount 个字段 · ${approvalDurationLabel(reusable ? draft.fieldMinutes : draft.minutes!)}（独立许可）'
                          : '$selectedFieldCount 个字段 · 截止 ${_time(r.fieldExpiresAt)}（独立许可）',
                    ),
                  for (final field in fileFields) ...[
                    const SizedBox(height: 12),
                    Text(
                      '${field.name} · 领取原文件',
                      style: prototypeText(
                        context,
                        13,
                        weight: FontWeight.w600,
                      ),
                    ),
                    InformationFileSummary(
                      owner: widget.owner,
                      reference: field.attachment!,
                      onLoaded: (version) {
                        if (version.available && dialogContext.mounted) {
                          update(() => loaded.add(version.reference));
                        }
                      },
                    ),
                  ],
                  if (fileFields.isNotEmpty)
                    Text(
                      '文件字段允许 Agent 领取并读取原文件，使用独立的普通信息期限；不是凭据注入。',
                      style: prototypeText(context, 12, height: 1.9),
                    ),
                  fact('注入位置', credentialInjectionFact(r)),
                  fact(
                    r.plan.receiver == 'ssh_identity' ? '主机快照与隔离' : '接收配置',
                    credentialIsolationFacts(r),
                  ),
                  _code(command),
                  fact('程序位置', r.plan.path),
                  fact(
                    '参数（按项）',
                    jsonEncode(r.plan.argv.map((a) => a.toJson()).toList()),
                  ),
                  fact('工作目录', r.plan.cwd),
                  fact('凭据标识 / 版本', '${r.credentialId} / ${r.version}'),
                  fact('计划 hash', r.plan.planHash),
                  const SizedBox(height: 12),
                  Text(
                    reusable
                        ? '首条命令用于理解用途，批准不会立即运行。同一批准范围内的新命令不重新审批；每次操作冻结自己的完整计划和操作 ID。增加未批准的凭据或使用方式需要新申请。'
                        : '由知予 CLI 启动。批准不会立即运行；程序、参数和注入位置按本次申请固定。',
                    style: prototypeText(
                      context,
                      12,
                      color: UiPalette.of(context).muted,
                      height: 1.9,
                    ),
                  ),
                  const SizedBox(height: 14),
                  const QuietNotice(
                    '程序可接触原文。撤销只会阻止新的启动，不能收回已注入的内容，也不会终止已运行进程。',
                    panel: true,
                  ),
                  if (detail) ...[
                    const SizedBox(height: 12),
                    _code(
                      const JsonEncoder.withIndent(
                        '  ',
                      ).convert(r.toRequestInputJson()),
                    ),
                    fact('待审批截止', _time(r.requestExpiresAt)),
                    fact('程序校验', r.plan.executable.sha256),
                    const SizedBox(height: 12),
                    Text(
                      '批准后的启动调用',
                      style: prototypeText(
                        context,
                        13,
                        weight: FontWeight.w500,
                      ),
                    ),
                    _code(
                      jsonEncode({
                        'command': 'run-use',
                        'requestId': r.id,
                        if (reusable) ...{
                          'protocolVersion': 2,
                          'operationId': '由 Agent 为本次操作生成唯一 ID',
                          'launch': r.toRequestInputJson()['launch'],
                        },
                      }),
                    ),
                  ],
                ],
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  QuietNotice(_error!, warning: true),
                ],
              ],
            ),
            actions: [
              if (!detail)
                TextButton(
                  style: prototypeSecondary(context),
                  onPressed: _busy ? null : () => Navigator.pop(dialogContext),
                  child: const Text('返回核对'),
                ),
              TextButton(
                style: prototypePrimary(context),
                onPressed:
                    _busy ||
                        fileFields.any((f) => !loaded.contains(f.attachment))
                    ? null
                    : detail
                    ? () => Navigator.pop(dialogContext)
                    : decide,
                child: Text(
                  _busy
                      ? '正在保存…'
                      : detail
                      ? '返回审批'
                      : approve
                      ? '确认批准'
                      : '确认拒绝',
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _code(String value) => Container(
    margin: const EdgeInsets.only(top: 12),
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    decoration: BoxDecoration(
      color: UiPalette.of(context).canvas,
      border: Border.all(color: UiPalette.of(context).line),
      borderRadius: BorderRadius.circular(4),
    ),
    child: SelectableText(
      value,
      style: prototypeText(context, 13, family: 'Consolas', height: 1.9),
    ),
  );
  Widget _fact(String label, String value, {bool brief = false}) => Container(
    padding: EdgeInsets.symmetric(vertical: brief ? 13 : 15),
    decoration: BoxDecoration(
      border: Border(bottom: BorderSide(color: UiPalette.of(context).line)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: brief ? 100 : 122,
          child: Text(
            label,
            style: prototypeText(
              context,
              brief ? 14 : 13,
              color: UiPalette.of(context).muted,
            ),
          ),
        ),
        SizedBox(width: brief ? 12 : 18),
        Expanded(
          child: SelectableText(
            value,
            style: prototypeText(context, 13, family: 'Consolas'),
          ),
        ),
      ],
    ),
  );
  Widget _section(
    String step,
    String title,
    String tip,
    String text,
    Widget child,
  ) {
    final c = UiPalette.of(context);
    final short = MediaQuery.sizeOf(context).height < 850;
    return Container(
      margin: EdgeInsets.only(top: short ? 12 : 18),
      padding: EdgeInsets.only(top: short ? 12 : 18),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: c.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                step,
                style: prototypeText(
                  context,
                  14,
                  family: 'Georgia',
                  color: c.accent,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                title,
                style: prototypeText(context, 16, weight: FontWeight.w700),
              ),
              const SizedBox(width: 10),
              SizedBox.square(
                dimension: 26,
                child: TextButton(
                  key: ValueKey('use-tip-$tip'),
                  style: prototypeButton(
                    context,
                    size: 14,
                    iconOnly: true,
                    foreground: c.accent,
                    background: draft.tip == tip ? c.selected : null,
                    side: BorderSide(color: c.line),
                    radius: 13,
                  ),
                  onPressed: () =>
                      setState(() => draft.tip = draft.tip == tip ? null : tip),
                  child: Text(
                    '?',
                    textScaler: TextScaler.noScaling,
                    style: prototypeText(
                      context,
                      14,
                      family: 'Georgia',
                      color: c.accent,
                      height: 1,
                    ),
                  ),
                ),
              ),
              if (tip == 'injection') ...[
                const Spacer(),
                Text(
                  r.plan.receiver == 'gh_token'
                      ? '秘密值 → 环境变量'
                      : r.plan.receiver == 'ssh_identity'
                      ? '临时文件路径 → 命令参数'
                      : '临时文件路径 → 环境变量',
                  textAlign: TextAlign.right,
                  style: prototypeText(context, 12, color: c.muted),
                ),
              ],
            ],
          ),
          AnimatedSize(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 150),
            alignment: Alignment.topCenter,
            child: draft.tip == tip
                ? Container(
                    margin: const EdgeInsets.only(top: 10),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 15,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: c.rail,
                      border: Border.all(color: c.line),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          text.substring(0, text.indexOf('。') + 1),
                          style: prototypeText(
                            context,
                            13,
                            height: 1.9,
                            weight: FontWeight.w500,
                          ),
                        ),
                        Text(
                          text.substring(text.indexOf('。') + 1),
                          style: prototypeText(
                            context,
                            13,
                            height: 1.9,
                            color: c.muted,
                          ),
                        ),
                      ],
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          child,
        ],
      ),
    );
  }

  Widget _documentBody() {
    final c = UiPalette.of(context);
    final short = MediaQuery.sizeOf(context).height < 850;
    final credential = widget.owner.credentials
        .where((c) => c.id == r.credentialId)
        .firstOrNull;
    final allow = allowCredential;
    return Scrollbar(
      controller: _document,
      child: SingleChildScrollView(
        primary: false,
        controller: _document,
        key: PageStorageKey('credential-use-document-${r.id}'),
        padding: const EdgeInsets.fromLTRB(26, 24, 26, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: pending ? c.statusAttention : c.muted,
                      width: 1.5,
                    ),
                  ),
                ),
                const SizedBox(width: 7),
                Text(
                  credentialUseStateLabel(widget.owner.credentialUseState(r)),
                  style: prototypeText(
                    context,
                    12,
                    color: pending ? c.statusAttention : c.muted,
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  '凭据使用申请',
                  style: prototypeText(context, 12, color: c.muted),
                ),
                const Spacer(),
                TextButton(
                  style: prototypeButton(
                    context,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                  onPressed: () => _dialog('request'),
                  child: const Text('查看申请明细 ↗'),
                ),
              ],
            ),
            SizedBox(height: short ? 10 : 12),
            Text(
              r.chatLabel,
              style: prototypeText(
                context,
                short ? 26 : 27,
                family: 'SimSun',
                weight: FontWeight.w500,
              ).copyWith(letterSpacing: .5),
            ),
            SizedBox(height: short ? 8 : 14),
            Row(
              children: [
                Container(
                  width: 28,
                  height: 28,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: c.selected,
                    border: Border.all(color: c.line),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    'A',
                    style: prototypeText(
                      context,
                      16,
                      family: 'Georgia',
                      weight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  'Agent',
                  style: prototypeText(context, 13, weight: FontWeight.w700),
                ),
                const SizedBox(width: 8),
                Text('当前聊天', style: prototypeText(context, 12, color: c.muted)),
                const Spacer(),
                Tooltip(
                  message: r.id,
                  child: Text(
                    r.id.length > 12 ? '${r.id.substring(0, 8)}…' : r.id,
                    style: prototypeText(
                      context,
                      11,
                      family: 'Consolas',
                      color: c.muted,
                    ),
                  ),
                ),
              ],
            ),
            SizedBox(height: short ? 10 : 16),
            Text(r.purpose, style: prototypeText(context, 14, height: 1.8)),
            _section(
              '01',
              '使用哪个凭据',
              'credential',
              '申请只引用名称、标识与版本。凭据原文由本机服务保管，不放进申请。关联服务器信息不等于获得密钥使用权。',
              Container(
                margin: EdgeInsets.only(top: short ? 10 : 12),
                padding: short
                    ? const EdgeInsets.symmetric(horizontal: 12, vertical: 10)
                    : const EdgeInsets.all(13),
                decoration: BoxDecoration(
                  color: c.rail,
                  border: Border.all(color: c.line),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: PrototypeCheck(
                        key: const ValueKey('credential-use-allow'),
                        value: allow,
                        onChanged: pending && eligible
                            ? (v) => setState(
                                () => draft.allowCredential = v ?? false,
                              )
                            : null,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            credentialName,
                            style: prototypeText(
                              context,
                              14,
                              weight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '${credential?.form == CredentialForm.file ? '文件' : '字符串'} · ${credential?.publicPurpose ?? ''} · 版本 ${r.version}',
                            style: prototypeText(
                              context,
                              12,
                              height: 1.8,
                              color: c.muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: c.paper,
                        border: Border.all(color: c.line),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        eligible ? '可用' : '已失效',
                        style: prototypeText(context, 11, color: c.muted),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            _section(
              '02',
              '注入到哪里',
              'injection',
              credentialInjectionTip(r),
              Padding(
                padding: EdgeInsets.only(top: short ? 12 : 16, bottom: 3),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                r.plan.receiver == 'ssh_identity'
                                    ? '参数位置'
                                    : '环境变量名',
                                style: prototypeText(
                                  context,
                                  12,
                                  color: c.muted,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                r.plan.receiver == 'ssh_identity'
                                    ? 'ssh 的 -i 参数'
                                    : credentialInjectionTarget(r),
                                style: prototypeText(
                                  context,
                                  14,
                                  family: 'Consolas',
                                ),
                              ),
                            ],
                          ),
                        ),
                        SizedBox(
                          width: MediaQuery.sizeOf(context).width <= 1300
                              ? 9
                              : 15,
                        ),
                        SizedBox(
                          width: 24,
                          child: Text(
                            '←',
                            style: prototypeText(context, 14, color: c.accent),
                          ),
                        ),
                        SizedBox(
                          width: MediaQuery.sizeOf(context).width <= 1300
                              ? 9
                              : 15,
                        ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '程序收到',
                                style: prototypeText(
                                  context,
                                  12,
                                  color: c.muted,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                credentialInjectionValue(r),
                                style: prototypeText(
                                  context,
                                  14,
                                  weight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    if (r.plan.receiver != 'gh_token')
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Wrap(
                          spacing: 12,
                          runSpacing: 6,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              '文件引用',
                              style: prototypeText(context, 12, color: c.muted),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: c.selected,
                                borderRadius: BorderRadius.circular(3),
                              ),
                              child: Text(
                                '{{file:${r.alias}}}',
                                style: prototypeText(
                                  context,
                                  12,
                                  family: 'Consolas',
                                  color: c.strong,
                                ),
                              ),
                            ),
                            Text(
                              '运行前由 CLI 替换',
                              style: prototypeText(context, 12, color: c.muted),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
            _section(
              '03',
              reusable ? '首条 CLI 命令参考' : '由 CLI 启动什么命令',
              'launch',
              reusable
                  ? '批准不会自动运行。Agent 为每次操作提供唯一操作 ID 和完整命令，由知予 CLI 校验后注入并启动。同一批准范围内的新命令不重新审批；每次操作冻结自己的计划。增加未批准的凭据或使用方式需要新申请。'
                  : 'Agent 让知予 CLI 执行这份申请。批准不会自动运行。CLI 校验当前会话和使用授权后，准备凭据并启动下面的程序；程序、参数、工作目录或注入位置改变都需要重新申请。',
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _code(_command(r.requestedPlan ?? r.plan)),
                  const SizedBox(height: 8),
                  Text(
                    credentialIsolationFacts(r),
                    style: prototypeText(
                      context,
                      11,
                      color: c.muted,
                      height: 1.8,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 24,
                    runSpacing: 6,
                    children: [
                      Text(
                        '执行机器  本机',
                        style: prototypeText(context, 12, color: c.muted),
                      ),
                      Text(
                        '工作目录  ${r.plan.cwd}',
                        style: prototypeText(
                          context,
                          12,
                          family: 'Consolas',
                          color: c.muted,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    style: prototypeButton(context, size: 13),
                    onPressed: () => setState(
                      () => draft.planExpanded = !draft.planExpanded,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          draft.planExpanded
                              ? Icons.arrow_drop_down
                              : Icons.arrow_right,
                          size: 13,
                        ),
                        const SizedBox(width: 1),
                        const Text('程序位置与固定计划'),
                      ],
                    ),
                  ),
                  if (draft.planExpanded) ...[
                    const SizedBox(height: 8),
                    _code(command),
                    SelectableText(
                      r.plan.path,
                      style: prototypeText(
                        context,
                        13,
                        family: 'Consolas',
                        color: c.muted,
                      ),
                    ),
                    for (final e in r.plan.env.entries)
                      Text(
                        '${e.key} = ${launchValueLabel(e.value)}',
                        style: prototypeText(
                          context,
                          12,
                          family: 'Consolas',
                          color: c.muted,
                        ),
                      ),
                    const SizedBox(height: 8),
                    SelectableText(
                      credentialIsolationFacts(r),
                      style: prototypeText(
                        context,
                        12,
                        color: c.muted,
                        height: 1.8,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (r.fields.isNotEmpty) ...[
              const SizedBox(height: 15),
              TextButton(
                style: prototypeButton(
                  context,
                  size: 13,
                  padding: const EdgeInsets.symmetric(vertical: 9),
                ),
                onPressed: () => setState(
                  () => draft.fieldsExpanded = !draft.fieldsExpanded,
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '${draft.fieldsExpanded ? '▾' : '▸'} 另外申请读取连接字段 ${pending ? draft.fields.length : r.approvedFields.length} / ${r.fields.length}',
                  ),
                ),
              ),
              if (draft.fieldsExpanded)
                for (final field in r.fields) _fieldRow(field),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              QuietNotice(_error!, warning: true),
            ],
          ],
        ),
      ),
    );
  }

  Widget _fieldRow(FieldRef field) {
    final c = UiPalette.of(context);
    final item = widget.owner.information
        .where((i) => i.id == field.itemId)
        .firstOrNull;
    final f = item?.fields.where((f) => f.id == field.fieldId).firstOrNull;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 9),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.line)),
      ),
      child: Row(
        children: [
          PrototypeCheck(
            size: 16,
            value: pending
                ? draft.fields.contains(field)
                : r.approvedFields.contains(field),
            onChanged: pending && (f != null || draft.fields.contains(field))
                ? (v) => setState(() {
                    if (v == true) {
                      draft.fields.add(field);
                    } else {
                      draft.fields.remove(field);
                    }
                  })
                : null,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(f?.name ?? '已删除字段', style: prototypeText(context, 12)),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: f?.kind == FieldKind.file
                ? InformationFileSummary(
                    owner: widget.owner,
                    reference: f!.attachment!,
                    compact: true,
                  )
                : SelectableText(
                    f?.value ?? '',
                    style: prototypeText(context, 12, family: 'Consolas'),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _decisionBody() {
    final c = UiPalette.of(context);
    final allow = allowCredential;
    final grant = widget.owner.credentialGrantState(r);
    return Container(
      decoration: BoxDecoration(
        color: c.rail,
        border: Border(left: BorderSide(color: c.line)),
      ),
      child: Scrollbar(
        controller: _decision,
        child: SingleChildScrollView(
          primary: false,
          controller: _decision,
          padding: const EdgeInsets.fromLTRB(21, 25, 21, 25),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '本次决定',
                style: prototypeText(
                  context,
                  11,
                  color: c.muted,
                  height: 21 / 11,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                reusable ? '批准期限内使用' : '允许这次启动',
                style: prototypeText(
                  context,
                  23,
                  family: 'SimSun',
                  weight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 20),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    allow ? '1' : '0',
                    style: prototypeText(
                      context,
                      42,
                      family: 'Georgia',
                      height: 1.2,
                      color: c.strong,
                    ),
                  ),
                  const SizedBox(width: 11),
                  Text(
                    '项凭据',
                    style: prototypeText(context, 12, color: c.strong),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                r.fields.isEmpty
                    ? '不提供其他信息字段'
                    : '另提供 ${pending ? draft.fields.length : r.approvedFields.length} 个连接字段',
                style: prototypeText(context, 11, color: c.muted),
              ),
              Container(
                margin: const EdgeInsets.only(top: 20),
                padding: const EdgeInsets.only(top: 21),
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: c.line)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '批准 → Agent 调用 → CLI 启动',
                      style: prototypeText(
                        context,
                        13,
                        weight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      reusable
                          ? '期限内可重复使用，绑定当前会话。\n固定凭据版本和使用方式；逐次命令独立记录。'
                          : '仅一次，绑定当前会话。\n按本页的凭据与启动内容执行。',
                      style: prototypeText(
                        context,
                        12,
                        height: 1.8,
                        color: c.muted,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Text(
                reusable ? '使用授权期限' : '允许启动的期限',
                style: prototypeText(context, 12),
              ),
              const SizedBox(height: 9),
              if (pending || !reusable)
                SizedBox(
                  height:
                      MediaQuery.textScalerOf(context).scale(13) * 1.5 + 21.5,
                  child: DesktopSelect<String>(
                    value: draft.minutes?.toString() ?? 'session',
                    isExpanded: true,
                    items: [
                      if (r.supportsSessionValidity)
                        const DropdownMenuItem(
                          value: 'session',
                          child: Text('不限时（限本聊天）'),
                        ),
                      for (final n in AccessTiming.grantMinutes)
                        DropdownMenuItem(
                          value: n.toString(),
                          child: Text('${n ~/ 60} 小时'),
                        ),
                    ],
                    onChanged: pending
                        ? (v) => setState(
                            () => draft.minutes = v == 'session'
                                ? null
                                : int.parse(
                                    v ?? AccessTiming.defaultMinutes.toString(),
                                  ),
                          )
                        : null,
                  ),
                ),
              if (!pending && reusable)
                Text(
                  r.credentialValidity == CredentialUseValidity.session
                      ? '不限时（限本聊天）'
                      : _time(r.credentialExpiresAt),
                  style: prototypeText(context, 12),
                ),
              if (reusable && r.fields.isNotEmpty) ...[
                const SizedBox(height: 18),
                Text('连接字段读取期限（独立）', style: prototypeText(context, 12)),
                const SizedBox(height: 9),
                if (pending)
                  DesktopSelect<int>(
                    key: const ValueKey('credential-field-lifetime'),
                    value: draft.fieldMinutes,
                    isExpanded: true,
                    items: [
                      for (final n in AccessTiming.grantMinutes)
                        DropdownMenuItem(
                          value: n,
                          child: Text('${n ~/ 60} 小时'),
                        ),
                    ],
                    onChanged: draft.fields.isEmpty
                        ? null
                        : (v) => setState(
                            () => draft.fieldMinutes =
                                v ?? AccessTiming.defaultMinutes,
                          ),
                  )
                else
                  Text(
                    _time(r.fieldExpiresAt),
                    style: prototypeText(context, 12),
                  ),
              ],
              const SizedBox(height: 18),
              Text(
                '程序会接触原文。\n运行时注入不构成强隔离。',
                style: prototypeText(
                  context,
                  13,
                  height: 1.85,
                  color: c.strong,
                ),
              ),
              const SizedBox(height: 20),
              if (pending) ...[
                TextButton(
                  key: const ValueKey('credential-use-approve'),
                  style: prototypePrimary(context).copyWith(
                    padding: const WidgetStatePropertyAll(
                      EdgeInsets.symmetric(horizontal: 10, vertical: 13),
                    ),
                  ),
                  onPressed:
                      _busy ||
                          !widget.owner.serviceAvailable ||
                          (!draft.allowCredential || !eligible) &&
                              draft.fields.isEmpty
                      ? null
                      : () => _dialog('approve'),
                  child: Text(reusable ? '批准期限内使用 →' : '批准本次选择 →'),
                ),
                TextButton(
                  style: prototypeButton(
                    context,
                    padding: const EdgeInsets.symmetric(vertical: 15),
                  ),
                  onPressed: _busy ? null : () => _dialog('reject'),
                  child: const Text('拒绝请求'),
                ),
              ] else ...[
                Text(
                  switch (grant) {
                    'consumed' => '已占用一次启动尝试',
                    'available' =>
                      reusable ? '使用授权有效 · 可重复使用' : '已批准，等待 Agent 调用',
                    'expired' => '使用许可已到期',
                    'version_invalidated' => '凭据已变化，旧许可失效',
                    _ => r.credentialApproved ? '使用许可已结束' : '未批准凭据使用',
                  },
                  style: prototypeText(
                    context,
                    13,
                    weight: FontWeight.w700,
                    color: c.strong,
                    height: 1.9,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '凭据${r.credentialValidity == CredentialUseValidity.session ? '不限时（限本聊天）' : '截止 ${_time(r.credentialExpiresAt)}'}\n字段截止 ${_time(r.fieldExpiresAt)}',
                  style: prototypeText(
                    context,
                    12,
                    height: 1.9,
                    color: c.muted,
                  ),
                ),
                if (grant == 'available')
                  TextButton(
                    style: prototypeButton(context),
                    onPressed: _busy ? null : _revoke,
                    child: const Text('撤销使用授权'),
                  ),
              ],
              if (reusable && operations.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  '逐次使用记录',
                  style: prototypeText(context, 11, color: c.muted),
                ),
                Text(
                  '${operations.length} 次操作 · ${operations.where((e) => {'preparing', 'running'}.contains(e.state)).length} 个进行中',
                  style: prototypeText(context, 13, height: 1.9),
                ),
                TextButton(
                  style: prototypeButton(context),
                  onPressed: () =>
                      showCredentialUseOperations(context, widget.owner, r),
                  child: const Text('查看全部操作 →'),
                ),
              ],
              if (!reusable && r.executionId != null) ...[
                const SizedBox(height: 12),
                Text('执行结果', style: prototypeText(context, 11, color: c.muted)),
                const SizedBox(height: 5),
                Text(
                  credentialExecutionLabel(execution),
                  style: prototypeText(
                    context,
                    13,
                    color: c.strong,
                    height: 1.9,
                  ),
                ),
                Text(
                  credentialCleanupLabel(execution?.cleanupState),
                  style: prototypeText(context, 11, color: c.muted),
                ),
                TextButton(
                  style: prototypeButton(
                    context,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                  ),
                  onPressed: () =>
                      showCredentialExecutionReceipt(context, widget.owner, r),
                  child: const Text('查看执行记录 →'),
                ),
              ],
              const SizedBox(height: 16),
              Text(
                '到期或撤销只阻止新启动，不能收回已读内容，也不会终止进程。',
                style: prototypeText(context, 11, height: 1.9, color: c.muted),
              ),
              if (r.plan.receiver != 'gh_token') ...[
                const SizedBox(height: 12),
                Text(
                  '进程组结束后核对身份并尝试清理临时文件。',
                  style: prototypeText(
                    context,
                    11,
                    height: 1.9,
                    color: c.muted,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => r.isFocusedFill
      ? FocusedFillApprovalPanel(
          key: ValueKey('focused-fill-${r.id}'),
          owner: widget.owner,
          request: r,
          draft: draft,
          onChanged: widget.onChanged,
        )
      : LayoutBuilder(
          builder: (context, bounds) {
            final wide =
                bounds.maxWidth >= 780 &&
                MediaQuery.textScalerOf(context).scale(14) <= 20;
            return wide
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: _documentBody()),
                      SizedBox(width: 244, child: _decisionBody()),
                    ],
                  )
                : Column(
                    children: [
                      Expanded(child: _documentBody()),
                      SizedBox(
                        height: bounds.maxHeight * .4,
                        child: _decisionBody(),
                      ),
                    ],
                  );
          },
        );
}
