import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart';

import 'desktop_controls.dart';
import 'workspace/library_widgets.dart';

/// Compatibility view for older owner screens. It never reads the credential;
/// the owner is deciding whether this chat may receive it through the CLI.
class CredentialRevealPanel extends StatefulWidget {
  const CredentialRevealPanel({
    super.key,
    required this.owner,
    required this.request,
    required this.onChanged,
    this.history = false,
  });
  final OwnerAccess owner;
  final CredentialUseRequest request;
  final VoidCallback onChanged;
  final bool history;

  @override
  State<CredentialRevealPanel> createState() => _CredentialRevealPanelState();
}

class _CredentialRevealPanelState extends State<CredentialRevealPanel> {
  bool _busy = false;
  String? _error;

  Future<void> _decide(bool approve, {bool revoke = false}) async {
    setState(() => _busy = true);
    try {
      if (revoke) {
        await widget.owner.revokeCredentialUse(widget.request.id);
      } else {
        await widget.owner.decideCredentialUse(
          widget.request.id,
          approveCredential: approve,
        );
      }
      widget.onChanged();
    } on Object catch (error) {
      if (mounted) {
        setState(
          () => _error = error is CredentialUseFailure
              ? '未能更新授权（${error.code}）'
              : '未能更新授权，请检查连接后重试。',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final request =
        widget.owner.credentialUseRequests
            .where((r) => r.id == widget.request.id)
            .firstOrNull ??
        widget.request;
    final pending = widget.owner.credentialUseState(request) == 'pending';
    final active = widget.owner.credentialGrantState(request) == 'available';
    return SingleChildScrollView(
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('允许 AI 读取密码原文', style: libraryHeading(context, 24)),
          const SizedBox(height: 18),
          Text(
            request.credentialName ?? '凭据',
            style: libraryHeading(context, 18),
          ),
          const SizedBox(height: 12),
          Text('${request.agentName} · ${request.chatLabel}'),
          const SizedBox(height: 12),
          Text(request.purpose),
          const SizedBox(height: 12),
          Text('无法直接填写的原因：${request.revealReason}'),
          const SizedBox(height: 18),
          const Text('批准后，密码原文会提供给这次 AI 聊天。'),
          const SizedBox(height: 18),
          if (_error != null) Text(_error!),
          if (_busy) const LinearProgressIndicator(),
          if (pending && !widget.history)
            Wrap(
              spacing: 12,
              children: [
                DesktopButton(
                  onPressed: _busy ? null : () => _decide(true),
                  child: const Text('允许读取原文'),
                ),
                DesktopButton(
                  onPressed: _busy ? null : () => _decide(false),
                  child: const Text('拒绝'),
                ),
              ],
            )
          else ...[
            Text(active ? '授权有效' : '授权已结束'),
            for (final read in request.revealReads)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text('${read.at.toLocal()} · 已向 AI 提供原文'),
              ),
            if (active)
              DesktopButton(
                onPressed: _busy ? null : () => _decide(false, revoke: true),
                child: const Text('撤销授权'),
              ),
          ],
        ],
      ),
    );
  }
}
