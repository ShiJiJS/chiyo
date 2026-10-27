import 'dart:async';
import 'package:flutter/material.dart';
import '../desktop_controls.dart';
import '../ui_palette.dart';
import 'credential_mutation.dart';
import 'library_widgets.dart';
import 'workspace_source.dart';

class CredentialUseDialog extends StatefulWidget {
  const CredentialUseDialog({
    super.key,
    required this.source,
    required this.ref,
    this.onApproval,
  });
  final WorkspaceCredentialSource source;
  final WorkspaceRecordRef ref;
  final ValueChanged<String>? onApproval;
  @override
  State<CredentialUseDialog> createState() => _CredentialUseDialogState();
}

class _CredentialUseDialogState extends State<CredentialUseDialog> {
  final _purpose = TextEditingController();
  late final _mutation = CredentialMutation(
    widget.source,
    expectedRef: widget.ref,
  )..addListener(_changed);
  WorkspaceCredentialDetail? _detail;
  List<WorkspaceCredentialSession> _sessions = [];
  List<WorkspaceCredentialReceiver> _receivers = [];
  String? _sessionId, _receiverId, _readError;
  int _minutes = 15;
  bool _loading = true,
      _dirty = false,
      _discard = false,
      _needsRecheck = false,
      _resultLoading = false;
  WorkspaceCredentialReceipt? _receipt;
  WorkspaceCredentialUseRequest? _request;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _mutation.dispose();
    _purpose.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final conflict = _mutation.failure?.code == 'conflict';
    setState(() {
      _loading = true;
      _readError = null;
    });
    try {
      final detail = await widget.source.read(widget.ref);
      final sessions = await widget.source.sessions();
      final receivers = await widget.source.receivers(widget.ref);
      if (mounted) {
        setState(() {
          _detail = detail;
          _sessions = sessions;
          _receivers = receivers;
          _loading = false;
          _sessionId = sessions.any((s) => s.id == _sessionId)
              ? _sessionId
              : sessions.firstOrNull?.id;
          _receiverId = conflict ? null : receivers.firstOrNull?.id;
          _needsRecheck = conflict;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _readError = error is WorkspaceFailure ? error.message : '使用配置暂不可读取。';
        });
      }
    }
  }

  void _edit() {
    _dirty = true;
    _mutation.edited();
  }

  Future<void> _acceptReceipt(WorkspaceCredentialReceipt receipt) async {
    if (receipt.requestId == null) {
      _mutation.markUncertain('申请回执暂不可核对，请先查询原操作。');
      return;
    }
    setState(() {
      _receipt = receipt;
      _dirty = false;
    });
    await _loadResult();
  }

  Future<void> _loadResult() async {
    setState(() {
      _resultLoading = true;
      _readError = null;
    });
    try {
      final requests = await widget.source.requests(ref: widget.ref);
      final request = requests
          .where((r) => r.id == _receipt!.requestId)
          .firstOrNull;
      if (mounted) {
        setState(() {
          _request = request;
          _resultLoading = false;
          if (request == null) _readError = '申请当前状态暂不可用，请按申请编号核对。';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _resultLoading = false;
          _readError = '申请已提交，当前状态暂不可读取。';
        });
      }
    }
  }

  Future<void> _submit() async {
    final detail = _detail;
    if (detail == null ||
        _sessionId == null ||
        _receiverId == null ||
        !detail.canRequestUse) {
      return;
    }
    final receipt = await _mutation.submit(
      (id) => widget.source.requestUse(
        WorkspaceCredentialUseDraft(
          operationId: id,
          ref: widget.ref,
          expectedRecordVersion: detail.recordVersion,
          expectedMaterialVersion: detail.materialVersion,
          useGeneration: detail.useGeneration,
          purpose: _purpose.text,
          receiverId: _receiverId!,
          sessionId: _sessionId!,
          minutes: _minutes,
        ),
      ),
    );
    if (mounted && receipt != null) await _acceptReceipt(receipt);
  }

  Future<void> _lookup() async {
    final result = await _mutation.reconcile();
    if (mounted && result != null) await _acceptReceipt(result);
  }

  @override
  Widget build(BuildContext context) {
    final c = UiPalette.of(context),
        detail = _detail,
        failure = _mutation.failure;
    if (_receipt case final receipt?) {
      return DesktopDialog(
        title: const Text('使用申请已提交'),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _request == null ? '已收到提交回执。' : _request!.state.label,
              style: libraryText(context, 17, weight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            SelectableText(
              '申请编号：${receipt.requestId}',
              style: libraryText(context, 13),
            ),
            if (_request case final request?) ...[
              const SizedBox(height: 12),
              Text('${request.credentialName} · 材料v${request.materialVersion}'),
              Text('${request.session.label} · ${request.session.agentClaim}'),
              Text(request.purpose),
              Text('申请期限：${request.minutes}分钟，实际以审批为准。'),
            ],
            const SizedBox(height: 12),
            const Text('提交申请不等于批准，也不会启动程序或填充内容。'),
            if (_resultLoading) const Text('正在读取申请状态…'),
            if (_readError != null)
              Text(
                _readError!,
                style: libraryText(context, 13, color: c.warning),
              ),
          ],
        ),
        actions: [
          if (_readError != null)
            DesktopButton(
              onPressed: _resultLoading ? null : _loadResult,
              child: const Text('重新读取状态'),
            ),
          if (widget.onApproval != null && receipt.requestId != null)
            DesktopButton(
              key: const ValueKey('credential-request-open-approval'),
              onPressed: () {
                Navigator.pop(context, true);
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  widget.onApproval!(
                    _request?.approvalId ?? 'credential:${receipt.requestId!}',
                  );
                });
              },
              child: const Text('前往审批'),
            ),
          DesktopButton(
            key: const ValueKey('credential-request-done'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('返回凭据'),
          ),
        ],
      );
    }
    final editable = !_loading && !_mutation.busy && !_mutation.uncertain;
    final receiver = _receivers.where((r) => r.id == _receiverId).firstOrNull;
    return PopScope(
      canPop: !_dirty && !_mutation.busy,
      onPopInvokedWithResult: (popped, _) {
        if (!popped && !_mutation.busy) setState(() => _discard = true);
      },
      child: DesktopDialog(
        title: const Text('申请使用凭据'),
        content: _loading
            ? const Text('正在读取使用配置…')
            : detail == null
            ? Text(_readError ?? '凭据暂不可用。')
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${detail.record.name} · 材料v${detail.materialVersion}',
                    style: libraryText(context, 16, weight: FontWeight.w600),
                  ),
                  Text(detail.delivery.label),
                  const SizedBox(height: 18),
                  DesktopSelect<String>(
                    key: const ValueKey('credential-request-session'),
                    value: _sessionId,
                    items: [
                      for (final session in _sessions)
                        DropdownMenuItem(
                          value: session.id,
                          child: Text(session.label),
                        ),
                    ],
                    decoration: const InputDecoration(labelText: '授权会话'),
                    onChanged: !editable
                        ? null
                        : (value) => setState(() {
                            _sessionId = value;
                            _edit();
                          }),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _sessions
                            .where((s) => s.id == _sessionId)
                            .firstOrNull
                            ?.agentClaim ??
                        '尚未选择申请者自述。',
                    style: libraryText(context, 13, color: c.muted),
                  ),
                  const SizedBox(height: 18),
                  DesktopTextField(
                    key: const ValueKey('credential-request-purpose'),
                    controller: _purpose,
                    enabled: editable,
                    minLines: 2,
                    maxLines: 4,
                    decoration: const InputDecoration(labelText: '本次用途'),
                    onChanged: (_) => _edit(),
                  ),
                  const SizedBox(height: 18),
                  DesktopSelect<String>(
                    key: const ValueKey('credential-request-receiver'),
                    value: _receiverId,
                    hint: const Text('选择接收器并核对'),
                    items: [
                      for (final receiver in _receivers)
                        DropdownMenuItem(
                          value: receiver.id,
                          child: Text(receiver.label),
                        ),
                    ],
                    decoration: const InputDecoration(labelText: '接收器与启动计划'),
                    onChanged: !editable
                        ? null
                        : (value) => setState(() {
                            _receiverId = value;
                            _edit();
                            if (_needsRecheck) {
                              _needsRecheck = false;
                              _mutation.acceptCurrentVersion();
                            }
                          }),
                  ),
                  if (_needsRecheck)
                    Text(
                      '已读取当前配置，请重新选择接收器并核对。',
                      style: libraryText(context, 13, color: c.warning),
                    ),
                  if (receiver != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      '可执行程序',
                      style: libraryText(context, 13, color: c.muted),
                    ),
                    SelectableText(
                      receiver.executable,
                      style: libraryText(
                        context,
                        13,
                      ).copyWith(fontFamily: 'Menlo'),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '工作目录',
                      style: libraryText(context, 13, color: c.muted),
                    ),
                    SelectableText(
                      receiver.workingDirectory,
                      style: libraryText(
                        context,
                        13,
                      ).copyWith(fontFamily: 'Menlo'),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '独立参数',
                      style: libraryText(context, 13, color: c.muted),
                    ),
                    for (final (index, arg) in receiver.arguments.indexed)
                      SelectableText(
                        '${index + 1}. $arg',
                        style: libraryText(
                          context,
                          13,
                        ).copyWith(fontFamily: 'Menlo'),
                      ),
                    const SizedBox(height: 8),
                    Text(
                      '${detail.delivery == WorkspaceCredentialDelivery.file ? '临时文件路径引用' : '环境变量'}：${receiver.binding}（不显示内容）',
                      style: libraryText(context, 13),
                    ),
                  ],
                  const SizedBox(height: 18),
                  DesktopSelect<int>(
                    key: const ValueKey('credential-request-minutes'),
                    value: _minutes,
                    items: const [
                      DropdownMenuItem(value: 15, child: Text('15分钟')),
                      DropdownMenuItem(value: 30, child: Text('30分钟')),
                    ],
                    decoration: const InputDecoration(labelText: '申请期限'),
                    onChanged: !editable
                        ? null
                        : (value) => setState(() {
                            _minutes = value!;
                            _edit();
                          }),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    detail.unavailableReason ??
                        '授权期内可按获批方式多次操作，每次操作独立记录；提交申请不会执行。',
                    style: libraryText(
                      context,
                      13,
                      color: detail.canRequestUse ? c.muted : c.warning,
                      height: 1.8,
                    ),
                  ),
                ],
              ),
        actions: [
          if (_readError != null)
            SizedBox(
              width: double.infinity,
              child: Text(
                _readError!,
                style: libraryText(context, 13, color: c.danger),
              ),
            ),
          if (failure != null)
            SizedBox(
              width: double.infinity,
              child: Text(
                failure.message,
                style: libraryText(context, 13, color: c.danger),
              ),
            ),
          if (_mutation.uncertain)
            DesktopButton(
              onPressed: _mutation.busy ? null : _lookup,
              child: const Text('核对此次申请'),
            ),
          if (failure?.code == 'conflict' || _readError != null)
            DesktopButton(
              onPressed: _loading ? null : _load,
              child: const Text('重新读取配置'),
            ),
          if (_discard) ...[
            SizedBox(
              width: double.infinity,
              child: Text(
                '尚有未提交的申请。',
                style: libraryText(context, 13, color: c.warning),
              ),
            ),
            DesktopButton(
              onPressed: () => setState(() {
                _dirty = false;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) Navigator.pop(context);
                });
              }),
              child: const Text('放弃申请'),
            ),
          ],
          DesktopButton(
            onPressed: _mutation.busy
                ? null
                : () => _dirty
                      ? setState(() => _discard = true)
                      : Navigator.pop(context),
            child: const Text('取消'),
          ),
          DesktopButton(
            key: const ValueKey('credential-request-submit'),
            kind: DesktopButtonKind.primary,
            busy: _mutation.busy,
            onPressed:
                _mutation.canSubmit &&
                    editable &&
                    detail?.canRequestUse == true &&
                    _receiverId != null &&
                    _sessionId != null
                ? _submit
                : null,
            child: const Text('提交使用申请'),
          ),
        ],
      ),
    );
  }
}
