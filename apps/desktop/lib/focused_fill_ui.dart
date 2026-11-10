import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart';
import 'credential_dialogs.dart' show credentialFlowError;
import 'credential_use_draft.dart';
import 'prototype_dialog.dart';
import 'prototype_ui.dart';
import 'ui.dart';

String focusedFillStateLabel(FocusedFillState state) => switch (state) {
  FocusedFillState.checking => '正在核验',
  FocusedFillState.sent => '输入已发送',
  FocusedFillState.refused => '未输入',
  FocusedFillState.partial => '部分发送',
  FocusedFillState.unknown => '结果未知',
};

FocusedFillState _visibleState(OwnerAccess owner, FocusedFillOperation op) =>
    owner.focusedFillOperationState(op.id);

String _time(DateTime? value) =>
    value == null ? '未记录' : value.toLocal().toString().split('.').first;
String _application(FocusedFillApplication value) =>
    value.executable.split(RegExp(r'[/\\]')).last;

String _outcome(FocusedFillState state) => switch (state) {
  FocusedFillState.checking => '等待本次操作完成，先查询原操作。',
  FocusedFillState.sent => '按键已提交给 Windows；未读取密码框确认，也未提交登录。',
  FocusedFillState.refused => '本次未发送按键。修正原因后，可明确发起新操作。',
  FocusedFillState.partial => '可能已留下部分内容。停止自动填充，由用户检查并清空后决定是否重新操作。',
  FocusedFillState.unknown => '无法确认是否已输入。只查询原操作；不要自动更换操作 ID 重填。',
};

String _reason(String? code) => switch (code) {
  null => '前台应用及密码控件核验后提交输入。',
  'desktop_locked' => '当前桌面已锁定或不是可用的交互桌面。',
  'unsupported_target' => '无法可靠识别可输入的前台密码框。',
  'focus_changed' => '输入目标发生变化，后续输入已停止。',
  'modifier_active' => '修饰键仍处于按下状态。',
  'application_changed' => '应用身份与批准的程序不一致。',
  'access_denied' => '目标程序的用户、会话或权限条件不允许输入。',
  'audit_unavailable' => '操作记录未能完整保存，需先核查原操作。',
  'busy' => '已有输入操作占用当前桌面。',
  'input_rejected' => 'Windows 未接受本次输入。',
  'native_unavailable' => '原生输入程序不可用。',
  'grant_expired' => '使用授权已到期。',
  'grant_revoked' => '使用授权已撤销。',
  _ => '本次操作无法继续（$code）。',
};

Widget _text(
  BuildContext context,
  String text,
  double size, {
  Color? color,
  FontWeight weight = FontWeight.w400,
  String? family,
  double height = 1.5,
}) => Text(
  text,
  style: prototypeText(
    context,
    size,
    color: color,
    weight: weight,
    family: family,
    height: height,
  ),
);

Widget _fact(
  BuildContext context,
  String label,
  String value, {
  bool code = false,
  bool compact = false,
}) => Container(
  padding: EdgeInsets.symmetric(vertical: compact ? 7 : 13),
  decoration: compact
      ? null
      : BoxDecoration(
          border: Border(bottom: BorderSide(color: UiPalette.of(context).line)),
        ),
  child: Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(
        width: compact ? 88 : 100,
        child: _text(context, label, 13, color: UiPalette.of(context).muted),
      ),
      SizedBox(width: compact ? 16 : 12),
      Expanded(
        child: SelectableText(
          value,
          style: prototypeText(
            context,
            13,
            family: code ? 'Consolas' : null,
            height: compact ? 1.5 : 1.8,
          ),
        ),
      ),
    ],
  ),
);

Widget _boundary(BuildContext context, String text) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 12),
  child: _text(
    context,
    text,
    13,
    color: UiPalette.of(context).muted,
    height: 1.9,
  ),
);

/// Shared Round05 application facts. Website text is expressly self-reported.
class FocusedFillTargetFacts extends StatefulWidget {
  const FocusedFillTargetFacts({super.key, required this.plan});
  final FocusedFillPlan plan;
  @override
  State<FocusedFillTargetFacts> createState() => _FocusedFillTargetFactsState();
}

class _FocusedFillTargetFactsState extends State<FocusedFillTargetFacts> {
  bool _expanded = false;
  FocusedFillPlan get plan => widget.plan;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SizedBox(height: 12),
      _fact(context, '允许的应用', _application(plan.application), compact: true),
      _fact(context, '输入目标', '该应用当前前台的密码框', compact: true),
      _fact(
        context,
        '申报页面',
        plan.targetHint.isEmpty ? '未申报' : plan.targetHint,
        code: true,
        compact: true,
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton(
          key: const ValueKey('fill-application-details'),
          style: prototypeButton(
            context,
            size: 13,
            padding: const EdgeInsets.symmetric(vertical: 10),
          ),
          onPressed: () => setState(() => _expanded = !_expanded),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox.square(
                dimension: 8,
                child: CustomPaint(
                  painter: _DisclosureTriangle(
                    _expanded,
                    UiPalette.of(context).muted,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              const Text('应用位置与固定摘要'),
            ],
          ),
        ),
      ),
      AnimatedSize(
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : UiMotion.entrance,
        child: !_expanded
            ? const SizedBox.shrink()
            : Column(
                children: [
                  _fact(
                    context,
                    '应用位置',
                    plan.application.executable,
                    code: true,
                  ),
                  _fact(
                    context,
                    'SHA-256',
                    plan.application.sha256,
                    code: true,
                  ),
                  _boundary(
                    context,
                    '程序更新后摘要变化，需要重新申请。应用身份不等于网站来源；网址由 Agent 自述，未核验。',
                  ),
                ],
              ),
      ),
    ],
  );
}

class _DisclosureTriangle extends CustomPainter {
  _DisclosureTriangle(this.expanded, this.color);
  final bool expanded;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final path = expanded
        ? (Path()
            ..moveTo(0, 1)
            ..lineTo(8, 1)
            ..lineTo(4, 7)
            ..close())
        : (Path()
            ..moveTo(1, 0)
            ..lineTo(7, 4)
            ..lineTo(1, 8)
            ..close());
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_DisclosureTriangle old) =>
      old.expanded != expanded || old.color != color;
}

Widget _identity(BuildContext context, String caption) {
  final c = UiPalette.of(context);
  return Row(
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
        child: _text(context, 'A', 16, family: 'Georgia'),
      ),
      const SizedBox(width: 8),
      _text(context, 'Agent', 14, weight: FontWeight.w700),
      const SizedBox(width: 8),
      Flexible(child: _text(context, caption, 12, color: c.muted)),
    ],
  );
}

Widget _summary(BuildContext context, List<(String, String)> items) {
  final c = UiPalette.of(context);
  final scaled = MediaQuery.textScalerOf(context).scale(14) > 20;
  Widget cell((String, String) item) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _text(context, item.$1, 12, color: c.muted),
      const SizedBox(height: 8),
      _text(context, item.$2, 14, weight: FontWeight.w500),
    ],
  );
  return Container(
    margin: const EdgeInsets.only(top: 28),
    padding: const EdgeInsets.symmetric(vertical: 20),
    decoration: BoxDecoration(
      border: Border(
        top: BorderSide(color: c.line),
        bottom: BorderSide(color: c.line),
      ),
    ),
    child: scaled
        ? Wrap(spacing: 32, runSpacing: 18, children: items.map(cell).toList())
        : IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < items.length; i++)
                  Expanded(
                    child: Container(
                      padding: EdgeInsets.only(
                        left: i == 0 ? 0 : 24,
                        right: 12,
                      ),
                      decoration: i == 0
                          ? null
                          : BoxDecoration(
                              border: Border(left: BorderSide(color: c.line)),
                            ),
                      child: cell(items[i]),
                    ),
                  ),
              ],
            ),
          ),
  );
}

class _FillEntrance extends StatelessWidget {
  const _FillEntrance({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: 1),
    duration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : UiMotion.entrance,
    builder: (context, opacity, child) =>
        Opacity(opacity: opacity, child: child),
    child: child,
  );
}

class FocusedFillApprovalPanel extends StatefulWidget {
  const FocusedFillApprovalPanel({
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
  State<FocusedFillApprovalPanel> createState() =>
      _FocusedFillApprovalPanelState();
}

class _FocusedFillApprovalPanelState extends State<FocusedFillApprovalPanel> {
  final _document = ScrollController(), _decision = ScrollController();
  bool _busy = false;
  CredentialUseRequest get r =>
      widget.owner.credentialUseRequests
          .where((r) => r.id == widget.request.id)
          .firstOrNull ??
      widget.request;
  CredentialUseApprovalDraft get draft => widget.draft;
  bool get pending => widget.owner.credentialUseState(r) == 'pending';
  bool get eligible {
    try {
      widget.owner.checkCredentialUseEligibility(r);
      return true;
    } on Object {
      return false;
    }
  }

  String get name => r.credentialName ?? '名称未记录';
  bool get allowed =>
      pending ? draft.allowCredential && eligible : r.credentialApproved;
  @override
  void dispose() {
    _document.dispose();
    _decision.dispose();
    super.dispose();
  }

  Future<void> _decide(bool approve) async {
    if (_busy || !pending) return;
    String? error;
    var saving = false;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierColor: const Color(0x4f241b27),
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) => PopScope(
          canPop: !saving,
          child: PrototypeDialog(
            width: 650,
            actionDivider: false,
            actionPaddingTop: 22,
            title: approve ? '批准本机焦点填充' : '拒绝这次申请',
            onClose: saving ? null : () => Navigator.pop(context),
            body: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _text(
                  context,
                  approve
                      ? '允许当前会话在 ${approvalDurationLabel(draft.minutes!)}内，使用「$name」版本 ${r.version}，向「${_application(r.focusedFill!.application)}」的前台密码框填充。'
                      : '本次申请将被拒绝，不提供凭据，也不发送按键。',
                  14,
                ),
                if (approve)
                  _boundary(
                    context,
                    '批准本身不输入。Agent 随后重新点击密码框并后台调用 CLI；不会自动提交登录。网址仅为自述，不能保证目标网站来源。',
                  ),
                if (error != null) credentialFlowError(context, error!),
              ],
            ),
            actions: [
              TextButton(
                style: prototypeSecondary(context),
                onPressed: saving ? null : () => Navigator.pop(context),
                child: Text(approve ? '返回调整' : '返回'),
              ),
              TextButton(
                key: const ValueKey('fill-confirm-decision'),
                style: prototypePrimary(context),
                onPressed:
                    saving ||
                        !widget.owner.serviceAvailable ||
                        approve && (!allowed || !pending)
                    ? null
                    : () async {
                        update(() {
                          saving = true;
                          error = null;
                        });
                        setState(() => _busy = true);
                        try {
                          await widget.owner.decideCredentialUse(
                            r.id,
                            approveCredential: approve && allowed,
                            fields: const [],
                            lifetime: Duration(minutes: draft.minutes!),
                          );
                          if (dialogContext.mounted) {
                            Navigator.pop(dialogContext);
                          }
                          if (mounted) widget.onChanged();
                        } on Object {
                          if (dialogContext.mounted) {
                            update(() {
                              saving = false;
                              error = '审批未保存，请核对请求、凭据版本和存储后重试。当前选择已保留。';
                            });
                          }
                        } finally {
                          if (mounted) setState(() => _busy = false);
                        }
                      },
                child: Text(
                  saving
                      ? '保存中…'
                      : approve
                      ? '确认批准授权'
                      : '确认拒绝',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _section(String step, String title, String tip, Widget body) {
    final c = UiPalette.of(context);
    return Container(
      margin: const EdgeInsets.only(top: 18),
      padding: const EdgeInsets.only(top: 18),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: c.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _text(context, step, 14, color: c.accent, family: 'Georgia'),
              const SizedBox(width: 10),
              Flexible(
                child: _text(context, title, 16, weight: FontWeight.w700),
              ),
              const SizedBox(width: 10),
              TextButton(
                key: ValueKey('fill-tip-$step'),
                style: prototypeButton(
                  context,
                  radius: 13,
                  size: 14,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 2,
                  ),
                  side: BorderSide(color: c.line),
                  foreground: c.accent,
                ),
                onPressed: () =>
                    setState(() => draft.tip = draft.tip == step ? null : step),
                child: Semantics(label: '查看$title说明', child: const Text('?')),
              ),
            ],
          ),
          AnimatedSize(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 150),
            alignment: Alignment.topCenter,
            child: draft.tip == step
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
                    child: _text(context, tip, 13, color: c.muted, height: 1.9),
                  )
                : const SizedBox.shrink(),
          ),
          body,
        ],
      ),
    );
  }

  Widget _body() {
    final c = UiPalette.of(context);
    return Scrollbar(
      controller: _document,
      child: SingleChildScrollView(
        primary: false,
        controller: _document,
        padding: const EdgeInsets.all(26),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                _text(
                  context,
                  pending
                      ? '待处理'
                      : r.credentialApproved
                      ? '已批准'
                      : '未批准',
                  12,
                  color: pending ? c.statusAttention : c.muted,
                ),
                _text(context, '凭据使用 · 本机焦点填充', 12, color: c.muted),
              ],
            ),
            const SizedBox(height: 12),
            _text(
              context,
              r.chatLabel,
              27,
              family: 'SimSun',
              weight: FontWeight.w500,
              height: 1.3,
            ),
            const SizedBox(height: 12),
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
                  child: _text(context, 'A', 16, family: 'Georgia'),
                ),
                const SizedBox(width: 8),
                _text(context, 'Agent', 14, weight: FontWeight.w700),
                const SizedBox(width: 8),
                _text(context, '当前聊天', 12, color: c.muted),
                const SizedBox(width: 12),
                Expanded(
                  child: Tooltip(
                    message: r.id,
                    child: Text(
                      r.id.length > 20 ? '${r.id.substring(0, 16)}…' : r.id,
                      maxLines: 1,
                      textAlign: TextAlign.right,
                      overflow: TextOverflow.ellipsis,
                      style: prototypeText(
                        context,
                        11,
                        color: c.muted,
                        family: 'Consolas',
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _text(context, r.purpose, 14, height: 1.8),
            _section(
              '01',
              '使用哪个凭据',
              '申请只引用凭据身份和版本。密码由本机宿主取得并输入，CLI 不返回原文；文件凭据不用于密码框填充。',
              Container(
                margin: const EdgeInsets.only(top: 14),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: c.rail,
                  border: Border.all(color: c.line),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Row(
                  children: [
                    PrototypeCheck(
                      value: allowed,
                      onChanged: pending && eligible && !_busy
                          ? (value) => setState(
                              () => draft.allowCredential = value ?? false,
                            )
                          : null,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _text(context, name, 14, weight: FontWeight.w700),
                          _text(
                            context,
                            '${widget.owner.credentials.where((c) => c.id == r.credentialId).firstOrNull?.publicPurpose ?? '字符串凭据'} · 版本 ${r.version}',
                            12,
                            color: c.muted,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: c.paper,
                        border: Border.all(color: c.line),
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: _text(context, '字符串', 11, color: c.muted),
                    ),
                  ],
                ),
              ),
            ),
            if (pending && !eligible)
              _boundary(context, '凭据或应用条件已变化，当前不能批准。请重新申请。'),
            _section(
              '02',
              '填充到哪里',
              '每次核验前台窗口、进程创建身份和密码控件。锁屏、目标变化或无法识别时拒绝。相同应用中的其他页面仍须谨慎确认。仅在网页内聚焦不够；若工具不能切换系统前台，请先切回目标应用，再调用 CLI。',
              FocusedFillTargetFacts(plan: r.focusedFill!),
            ),
            _section(
              '03',
              '批准后如何使用',
              '此方式没有待启动的业务命令，也不创建临时密钥文件。按键已提交不代表登录成功。保持密码遮挡；显示明文后的截图仍可能进入模型上下文。',
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final step in [
                    ('1', 'Agent 点击密码框', '审批后重新点击目标，保持本机前台焦点。'),
                    ('2', '后台调用 CLI', '只提交本申请引用与独立操作 ID；本机宿主核验后输入。'),
                    ('3', '查看输入状态', '不自动提交登录；异常时查询原操作，不自动重填。'),
                  ])
                    Padding(
                      padding: const EdgeInsets.only(top: 14),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 30,
                            child: _text(
                              context,
                              step.$1,
                              18,
                              color: c.accent,
                              family: 'Georgia',
                            ),
                          ),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _text(
                                  context,
                                  step.$2,
                                  14,
                                  weight: FontWeight.w500,
                                ),
                                _text(context, step.$3, 13, color: c.muted),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _decisionBody() {
    final c = UiPalette.of(context);
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
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _text(context, '本次决定', 12, color: c.muted),
              const SizedBox(height: 10),
              _text(
                context,
                '允许密码框填充',
                22,
                family: 'SimSun',
                weight: FontWeight.w500,
              ),
              const SizedBox(height: 18),
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 10,
                children: [
                  _text(
                    context,
                    allowed ? '1' : '0',
                    44,
                    family: 'Georgia',
                    color: c.strong,
                  ),
                  _text(context, '项凭据', 13, color: c.muted),
                ],
              ),
              _text(context, '不提供密码原文或其他字段', 12, color: c.muted),
              const SizedBox(height: 22),
              Divider(color: c.line),
              const SizedBox(height: 16),
              _text(
                context,
                '批准 → 点击密码框 → CLI 填充',
                13,
                weight: FontWeight.w700,
              ),
              _boundary(context, '固定凭据版本、应用和使用方式。期限内可重复使用，每次独立记录。'),
              _text(context, '使用授权期限', 12),
              const SizedBox(height: 9),
              if (pending)
                DesktopSelect<int>(
                  key: const ValueKey('focused-fill-lifetime'),
                  value: draft.minutes,
                  isExpanded: true,
                  items: [
                    for (final n in AccessTiming.grantMinutes)
                      DropdownMenuItem(value: n, child: Text('${n ~/ 60} 小时')),
                  ],
                  onChanged: _busy
                      ? null
                      : (v) => setState(
                          () =>
                              draft.minutes = v ?? AccessTiming.defaultMinutes,
                        ),
                )
              else
                _text(context, '截止 ${_time(r.credentialExpiresAt)}', 12),
              const SizedBox(height: 20),
              if (pending) ...[
                TextButton(
                  key: const ValueKey('focused-fill-approve'),
                  style: prototypePrimary(context),
                  onPressed: !_busy && allowed && widget.owner.serviceAvailable
                      ? () => _decide(true)
                      : null,
                  child: const Text('批准填充授权 →'),
                ),
                TextButton(
                  style: prototypeButton(
                    context,
                    padding: const EdgeInsets.symmetric(vertical: 15),
                  ),
                  onPressed: _busy || !widget.owner.serviceAvailable
                      ? null
                      : () => _decide(false),
                  child: const Text('拒绝请求'),
                ),
              ] else ...[
                _text(
                  context,
                  switch (grant) {
                    'available' => '已批准，等待 Agent 点击密码框',
                    'revoked' => '使用授权已撤销',
                    'expired' => '使用授权已到期',
                    'version_invalidated' => '凭据或应用条件已变化',
                    _ => '使用授权已结束',
                  },
                  13,
                  weight: FontWeight.w700,
                ),
                _boundary(context, '批准不会发送按键。'),
                TextButton(
                  style: prototypeButton(context),
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (context) => PrototypeDialog(
                      width: 780,
                      title: '逐次填充记录',
                      onClose: () => Navigator.pop(context),
                      body: FocusedFillOperations(
                        owner: widget.owner,
                        request: r,
                        onChanged: widget.onChanged,
                      ),
                    ),
                  ),
                  child: const Text('查看使用记录 →'),
                ),
              ],
              _boundary(context, '撤销或到期阻止后续输入，不能清除已经填入的内容。'),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => _FillEntrance(
    child: LayoutBuilder(
      builder: (context, bounds) =>
          bounds.maxWidth >= 780 &&
              MediaQuery.textScalerOf(context).scale(14) <= 20
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: _body()),
                SizedBox(width: 244, child: _decisionBody()),
              ],
            )
          : Column(
              children: [
                Expanded(child: _body()),
                SizedBox(height: bounds.maxHeight * .4, child: _decisionBody()),
              ],
            ),
    ),
  );
}

/// Typed per-operation facts; never uses launch plans, process output or secrets.
class FocusedFillOperations extends StatefulWidget {
  const FocusedFillOperations({
    super.key,
    required this.owner,
    required this.request,
    required this.onChanged,
  });
  final OwnerAccess owner;
  final CredentialUseRequest request;
  final VoidCallback onChanged;
  @override
  State<FocusedFillOperations> createState() => _FocusedFillOperationsState();
}

class _FocusedFillOperationsState extends State<FocusedFillOperations> {
  String? _selected;
  int _page = 0;
  bool _busy = false;
  Future<void> _acknowledge(FocusedFillOperation op) async {
    if (_busy) return;
    var saving = false;
    String? error;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) => PopScope(
          canPop: !saving,
          child: PrototypeDialog(
            width: 650,
            title: '确认已检查输入框',
            actionDivider: false,
            onClose: saving ? null : () => Navigator.pop(context),
            body: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _text(context, '请先亲自检查目标输入框，并清空或处理可能留下的内容。', 14),
                _boundary(context, '确认只解除后续操作的暂停；不发送按键，不改变原输入结果，也不恢复或延长授权。'),
                _fact(context, '原操作', op.operationId, code: true),
                if (error != null) credentialFlowError(context, error!),
              ],
            ),
            actions: [
              TextButton(
                style: prototypeSecondary(context),
                onPressed: saving ? null : () => Navigator.pop(context),
                child: const Text('继续暂停'),
              ),
              TextButton(
                key: const ValueKey('fill-confirm-attention'),
                style: prototypePrimary(context),
                onPressed: saving || !widget.owner.serviceAvailable
                    ? null
                    : () async {
                        update(() {
                          saving = true;
                          error = null;
                        });
                        setState(() => _busy = true);
                        try {
                          await widget.owner.acknowledgeFocusedFillAttention(
                            op.id,
                          );
                          if (dialogContext.mounted) {
                            Navigator.pop(dialogContext);
                          }
                          if (mounted) {
                            setState(() {});
                            widget.onChanged();
                          }
                        } on Object {
                          if (dialogContext.mounted) {
                            update(() {
                              saving = false;
                              error = '确认未保存，操作可能仍在进行或存储不可用。原结果保持不变，请稍后重试。';
                            });
                          }
                        } finally {
                          if (mounted) setState(() => _busy = false);
                        }
                      },
                child: Text(saving ? '保存中…' : '确认已检查'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = UiPalette.of(context);
    final all = widget.owner.focusedFillOperations
        .where((op) => op.requestId == widget.request.id)
        .toList()
        .reversed
        .toList();
    final pages = (all.length / 8).ceil().clamp(1, 2147483647);
    _page = _page.clamp(0, pages - 1);
    final records = all.skip(_page * 8).take(8).toList();
    final selected =
        records.where((op) => op.id == _selected).firstOrNull ??
        records.firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 20),
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          spacing: 12,
          children: [
            _text(context, '逐次填充记录', 16, weight: FontWeight.w700),
            _text(context, '${all.length} 次操作', 12, color: c.muted),
          ],
        ),
        if (records.isEmpty)
          _boundary(context, '尚未填充。Agent 需先点击获批应用中的密码框，再后台调用 CLI。'),
        for (final op in records)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: TextButton(
              key: ValueKey('fill-operation-${op.operationId}'),
              style: prototypeButton(
                context,
                padding: const EdgeInsets.all(14),
                background: selected?.id == op.id ? c.selected : c.paper,
                side: BorderSide(
                  color: selected?.id == op.id ? c.accent : c.line,
                ),
              ),
              onPressed: () => setState(() => _selected = op.id),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _text(context, op.operationId, 13, family: 'Consolas'),
                        _text(context, _time(op.createdAt), 12, color: c.muted),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  _text(
                    context,
                    focusedFillStateLabel(_visibleState(widget.owner, op)),
                    13,
                  ),
                ],
              ),
            ),
          ),
        if (all.length > 8)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Row(
              children: [
                Expanded(
                  child: _text(
                    context,
                    '显示 ${records.length} / ${all.length} 次',
                    12,
                    color: c.muted,
                  ),
                ),
                TextButton(
                  key: const ValueKey('fill-operations-previous'),
                  style: prototypeButton(context, size: 20, iconOnly: true),
                  onPressed: _page == 0
                      ? null
                      : () => setState(() {
                          _page--;
                          _selected = null;
                        }),
                  child: const Text('‹', textScaler: TextScaler.noScaling),
                ),
                _text(context, '${_page + 1} / $pages', 12, color: c.muted),
                TextButton(
                  key: const ValueKey('fill-operations-next'),
                  style: prototypeButton(context, size: 20, iconOnly: true),
                  onPressed: _page + 1 >= pages
                      ? null
                      : () => setState(() {
                          _page++;
                          _selected = null;
                        }),
                  child: const Text('›', textScaler: TextScaler.noScaling),
                ),
              ],
            ),
          ),
        if (selected != null)
          AnimatedSize(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 150),
            child: Column(
              key: ValueKey('fill-operation-detail-${selected.id}'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 22),
                _text(
                  context,
                  focusedFillStateLabel(_visibleState(widget.owner, selected)),
                  16,
                  weight: FontWeight.w700,
                ),
                _boundary(
                  context,
                  _outcome(_visibleState(widget.owner, selected)),
                ),
                _fact(
                  context,
                  '处理时间',
                  _time(selected.finishedAt ?? selected.createdAt),
                ),
                _fact(context, '本次应用', _application(selected.application)),
                _fact(
                  context,
                  '原因',
                  _reason(
                    selected.state == FocusedFillState.checking &&
                            _visibleState(widget.owner, selected) ==
                                FocusedFillState.unknown
                        ? 'audit_unavailable'
                        : selected.errorCode,
                  ),
                ),
                if (selected.attentionAcknowledgedAt != null)
                  _boundary(
                    context,
                    '已由用户确认目标（${_time(selected.attentionAcknowledgedAt)}）。原输入结果保留，未重填，也未延长授权。',
                  )
                else if (widget.request.restoredAt == null &&
                    widget.owner.canAcknowledgeFocusedFillAttention(
                      selected.id,
                    )) ...[
                  _boundary(context, '不要自动重填。此状态不能当作“未输入”，也不能当作登录成功。'),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      key: const ValueKey('fill-acknowledge-attention'),
                      style: prototypeSecondary(context),
                      onPressed: _busy || !widget.owner.serviceAvailable
                          ? null
                          : () => _acknowledge(selected),
                      child: const Text('我已检查并处理输入框'),
                    ),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

class FocusedFillHistoryDocument extends StatefulWidget {
  const FocusedFillHistoryDocument({
    super.key,
    required this.owner,
    required this.request,
    required this.stateLabel,
    required this.onChanged,
    this.onOpenCredential,
  });
  final OwnerAccess owner;
  final CredentialUseRequest request;
  final String stateLabel;
  final VoidCallback onChanged;
  final ValueChanged<String>? onOpenCredential;
  @override
  State<FocusedFillHistoryDocument> createState() =>
      _FocusedFillHistoryDocumentState();
}

class _FocusedFillHistoryDocumentState
    extends State<FocusedFillHistoryDocument> {
  final _scroll = ScrollController();
  String? _error;
  bool _busy = false;
  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _revoke() async {
    final confirmed = await prototypeConfirm(
      context,
      title: '撤销填充授权？',
      message: '阻止后续输入，已经填入的内容仍由目标应用持有。此操作不会清空输入框。',
      action: '确认撤销',
    );
    if (!confirmed || !mounted || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.owner.revokeCredentialUse(widget.request.id);
      if (mounted) widget.onChanged();
    } on Object {
      if (mounted) setState(() => _error = '撤销未保存，请检查本机服务或存储后重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r =
        widget.owner.credentialUseRequests
            .where((r) => r.id == widget.request.id)
            .firstOrNull ??
        widget.request;
    final c = UiPalette.of(context);
    final records = widget.owner.focusedFillOperations.where(
      (op) => op.requestId == r.id,
    );
    return Container(
      key: ValueKey('history-document-${r.id}'),
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
                primary: false,
                controller: _scroll,
                padding: const EdgeInsets.fromLTRB(34, 28, 42, 28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      children: [
                        _text(
                          context,
                          widget.stateLabel,
                          12,
                          color:
                              widget.owner.credentialGrantState(r) ==
                                  'available'
                              ? c.statusLive
                              : c.muted,
                        ),
                        _text(context, '凭据使用 · 本机焦点填充', 12, color: c.muted),
                      ],
                    ),
                    const SizedBox(height: 13),
                    _text(
                      context,
                      r.chatLabel,
                      29,
                      family: 'SimSun',
                      weight: FontWeight.w500,
                    ),
                    const SizedBox(height: 16),
                    _identity(context, '申请时的会话'),
                    _summary(context, [
                      ('使用凭据', r.credentialName ?? '名称未记录'),
                      ('固定版本', '版本 ${r.version}'),
                      ('使用操作', '${records.length} 次'),
                    ]),
                    const SizedBox(height: 20),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 480),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _fact(
                              context,
                              '允许的应用',
                              _application(r.focusedFill!.application),
                              compact: true,
                            ),
                            _fact(context, '输入目标', '本机前台密码框', compact: true),
                            _fact(
                              context,
                              '授权到期',
                              _time(r.credentialExpiresAt),
                              compact: true,
                            ),
                          ],
                        ),
                      ),
                    ),
                    _boundary(
                      context,
                      r.restoredAt == null
                          ? '同一范围内可重复使用，操作不会续期。记录输入事实，不保存密码或输入框内容。'
                          : '从备份恢复的历史事实；未恢复授权、输入能力或目标进程。',
                    ),
                    FocusedFillOperations(
                      owner: widget.owner,
                      request: r,
                      onChanged: widget.onChanged,
                    ),
                    if (_error != null) credentialFlowError(context, _error!),
                  ],
                ),
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: c.line)),
            ),
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              spacing: 16,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _text(context, '撤销阻止后续填充，已填内容仍由目标应用持有。', 12, color: c.muted),
                if (widget.onOpenCredential != null)
                  TextButton(
                    style: prototypeButton(context),
                    onPressed: () => widget.onOpenCredential!(r.credentialId),
                    child: const Text('查看凭据 →'),
                  ),
                if (widget.owner.credentialGrantState(r) == 'available')
                  TextButton(
                    key: const ValueKey('fill-revoke'),
                    style: prototypeSecondary(context),
                    onPressed: _busy || !widget.owner.serviceAvailable
                        ? null
                        : _revoke,
                    child: const Text('撤销填充授权'),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
