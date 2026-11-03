import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart' as core;
import '../desktop_controls.dart';
import 'proposal_passwords.dart';
import 'workspace_source.dart';

/// Controllers and strings belong to the trusted Host, scoped to one library
/// and proposal revision. The workspace receives widgets and readiness only.
class OwnerProposalPasswords extends ProposalPasswords {
  OwnerProposalPasswords(this.owner) : _scope = owner.captureLibraryScope();
  final core.OwnerAccess owner;
  final core.OwnerLibraryScope _scope;
  final _inputs = <(String, int, String), TextEditingController>{};

  TextEditingController _controller(String id, int version, String item) =>
      _inputs.putIfAbsent((id, version, item), () {
        final proposal = owner.importProposals
            .where((p) => p.id == id && p.version == version)
            .firstOrNull;
        final credential = proposal?.items
            .where((i) => 'proposal:$id:${i.key}' == item)
            .firstOrNull
            ?.credential;
        return TextEditingController(
          text: credential?.source == 'owner' && credential?.material != null
              ? utf8.decode(credential!.material!)
              : '',
        );
      });

  @override
  bool ready(String proposalId, int version, String itemId) =>
      _inputs[(proposalId, version, itemId)]?.text.isNotEmpty ?? false;

  @override
  Widget input(
    String proposalId,
    int version,
    String itemId, {
    required bool enabled,
  }) => _InlinePassword(
    key: ValueKey((proposalId, version, itemId)),
    controller: _controller(proposalId, version, itemId),
    itemId: itemId,
    enabled: enabled,
    changed: notifyListeners,
  );

  @override
  Future<Set<String>> store(String proposalId, int version) async {
    final entries = _inputs.entries
        .where(
          (e) =>
              e.key.$1 == proposalId &&
              e.key.$2 == version &&
              e.value.text.isNotEmpty,
        )
        .toList();
    if (entries.isEmpty) return {};
    try {
      await owner.inLibraryScope(_scope, () async {
        final proposal = owner.importProposals
            .where((p) => p.id == proposalId)
            .firstOrNull;
        if (proposal == null || proposal.version != version) {
          throw const core.AccessFailure('proposal_changed');
        }
        final values = <String, String>{};
        for (final entry in entries) {
          final candidate = proposal.items
              .where((i) => 'proposal:${proposal.id}:${i.key}' == entry.key.$3)
              .firstOrNull;
          if (candidate?.credential?.source != 'owner') {
            throw const core.AccessFailure('proposal_changed');
          }
          values[candidate!.key] = entry.value.text;
        }
        await owner.fillImportCredentials(proposalId, version, values);
      });
      // A failed admission must preserve both input and readiness. Move the
      // private controllers to the revision this exact batch just produced.
      for (final entry in entries) {
        _inputs.remove(entry.key);
        _inputs[(proposalId, version + 1, entry.key.$3)] = entry.value;
      }
      return entries.map((e) => e.key.$3).toSet();
    } on core.AccessFailure catch (error) {
      throw WorkspaceFailure(
        error.status == 'proposal_changed' ? 'conflict' : error.status,
        error.status == 'invalid_credential_content'
            ? '密码不能为空，不能超过65536字节或包含空字符。输入仍保留。'
            : '提案已变化或密码暂时无法保存，输入仍保留，请重新核对。',
      );
    } catch (_) {
      throw const WorkspaceFailure('unavailable', '密码暂时无法保存，输入仍保留，请重试。');
    }
  }

  @override
  void clear(String proposalId) {
    final keys = _inputs.keys.where((k) => k.$1 == proposalId).toList();
    for (final key in keys) {
      final controller = _inputs.remove(key)!;
      controller.clear();
      // Widgets may still be mounted until the controller reloads the result.
      WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
    }
  }

  @override
  void dispose() {
    for (final controller in _inputs.values) {
      controller.clear();
      controller.dispose();
    }
    _inputs.clear();
    super.dispose();
  }
}

class _InlinePassword extends StatefulWidget {
  const _InlinePassword({
    super.key,
    required this.controller,
    required this.itemId,
    required this.enabled,
    required this.changed,
  });
  final TextEditingController controller;
  final String itemId;
  final bool enabled;
  final VoidCallback changed;
  @override
  State<_InlinePassword> createState() => _InlinePasswordState();
}

class _InlinePasswordState extends State<_InlinePassword> {
  bool _visible = false;
  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        child: DesktopTextField(
          key: ValueKey('proposal-owner-password-${widget.itemId}'),
          controller: widget.controller,
          enabled: widget.enabled,
          obscureText: !_visible,
          inlineSecret: true,
          enableSuggestions: false,
          autocorrect: false,
          maxLength: 65536,
          onChanged: (_) => widget.changed(),
          decoration: const InputDecoration(labelText: '密码'),
        ),
      ),
      const SizedBox(width: 10),
      DesktopButton(
        key: ValueKey('proposal-password-visible-${widget.itemId}'),
        kind: DesktopButtonKind.quiet,
        onPressed: widget.enabled
            ? () => setState(() => _visible = !_visible)
            : null,
        child: Text(_visible ? '隐藏密码' : '显示密码'),
      ),
    ],
  );
}
