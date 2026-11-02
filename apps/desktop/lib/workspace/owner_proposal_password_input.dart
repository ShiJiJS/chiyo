import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart' as core;
import '../desktop_controls.dart';
import '../ui_palette.dart';

/// Only the trusted Host owns the password controller. The workspace receives
/// a completion flag, never a secret or a reusable material handle.
Future<bool> showOwnerProposalPasswordInput(
  BuildContext context,
  core.OwnerAccess owner,
  String proposalId,
  int version,
  String itemId,
) async =>
    await showDesktopDialog<bool>(
      context,
      builder: (_) => _Password(owner, proposalId, version, itemId),
    ) ??
    false;

class _Password extends StatefulWidget {
  const _Password(this.owner, this.proposalId, this.version, this.itemId);
  final core.OwnerAccess owner;
  final String proposalId, itemId;
  final int version;
  @override
  State<_Password> createState() => _PasswordState();
}

class _PasswordState extends State<_Password> {
  final _password = TextEditingController();
  late final _scope = widget.owner.captureLibraryScope();
  bool _saving = false;
  String? _error;
  @override
  void dispose() {
    _password.clear();
    _password.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.owner.inLibraryScope(_scope, () async {
        final p = widget.owner.importProposals
            .where((p) => p.id == widget.proposalId)
            .firstOrNull;
        final candidate = p?.items
            .where((i) => 'proposal:${p.id}:${i.key}' == widget.itemId)
            .firstOrNull;
        if (p == null ||
            p.version != widget.version ||
            candidate?.credential?.source != 'owner') {
          throw const core.AccessFailure('proposal_changed');
        }
        await widget.owner.fillImportCredential(
          p.id,
          p.version,
          candidate!.key,
          _password.text,
        );
      });
      _password.clear();
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) {
        setState(
          () => _error =
              error is core.AccessFailure &&
                  error.status == 'invalid_credential_content'
              ? '请填写有效密码，不能超过65536字节或包含空字符。'
              : '提案已变化或暂时无法保存，请关闭后重新核对；尚未批准入库。',
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => DesktopDialog(
    title: const Text('为这份提案填写密码'),
    closeEnabled: !_saving,
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('密码只进入加密提案，不会返回给 AI。保存后请核对提案并批准，才会正式入库。'),
        const SizedBox(height: 16),
        DesktopTextField(
          key: const ValueKey('proposal-owner-password'),
          controller: _password,
          obscureText: true,
          enableSuggestions: false,
          autocorrect: false,
          maxLength: 65536,
          decoration: const InputDecoration(labelText: '账号密码'),
        ),
        if (_error != null)
          Text(_error!, style: TextStyle(color: UiPalette.of(context).danger)),
      ],
    ),
    actions: [
      DesktopButton(
        onPressed: _saving ? null : () => Navigator.pop(context, false),
        child: const Text('取消'),
      ),
      DesktopButton(
        key: const ValueKey('proposal-owner-password-save'),
        busy: _saving,
        kind: DesktopButtonKind.primary,
        onPressed: _saving ? null : _save,
        child: const Text('保存密码到提案'),
      ),
    ],
  );
}
