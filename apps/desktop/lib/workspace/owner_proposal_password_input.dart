import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart' as core;
import '../desktop_controls.dart';
import 'proposal_passwords.dart';
import 'workspace_source.dart';
import 'package:info_remote/owner_client.dart';
import 'remote_proposal_password_store.dart';

/// Controllers and strings belong to the trusted Host, scoped to one library
/// and proposal revision. The workspace receives widgets and readiness only.
class OwnerProposalPasswords extends ProposalPasswords {
  OwnerProposalPasswords(core.OwnerAccess owner)
    : _owner = owner,
      _scope = owner.captureLibraryScope(),
      _remote = null;
  OwnerProposalPasswords.remote(OwnerClient client)
    : _owner = null,
      _scope = null,
      _remote = RemoteProposalPasswordStore(client);
  final core.OwnerAccess? _owner;
  core.OwnerAccess get owner => _owner!;
  final core.OwnerLibraryScope? _scope;
  final RemoteProposalPasswordStore? _remote;
  final _inputs = <(String, int, String), TextEditingController>{};
  final _loads = <(String, int, String), Future<void>>{};
  final _loading = <(String, int, String)>{};
  final _errors = <(String, int, String), WorkspaceFailure>{};
  bool _closed = false;

  String _itemKey(String proposal, String item) {
    final prefix = 'proposal:$proposal:';
    if (!item.startsWith(prefix)) {
      throw const WorkspaceFailure('conflict', '密码填写目标已变化，请重新核对。');
    }
    return item.substring(prefix.length);
  }

  void _load((String, int, String) key, TextEditingController controller) {
    _loading.add(key);
    _errors.remove(key);
    _loads[key] = (() async {
      try {
        final value = await _remote!.read(
          key.$1,
          key.$2,
          _itemKey(key.$1, key.$3),
        );
        if (!_closed && identical(_inputs[key], controller)) {
          controller.text = value;
        }
      } catch (error) {
        if (!_closed && identical(_inputs[key], controller)) {
          _errors[key] = error is WorkspaceFailure
              ? error
              : const WorkspaceFailure('unavailable', '密码暂时无法读取，请重试。');
        }
      } finally {
        if (!_closed && identical(_inputs[key], controller)) {
          _loading.remove(key);
          notifyListeners();
        }
      }
    })();
  }

  TextEditingController _controller(String id, int version, String item) =>
      _inputs.putIfAbsent((id, version, item), () {
        if (_remote != null) {
          final controller = TextEditingController();
          // Defer until putIfAbsent has installed its ownership identity.
          scheduleMicrotask(() {
            if (!_closed &&
                identical(_inputs[(id, version, item)], controller)) {
              _load((id, version, item), controller);
            }
          });
          _loading.add((id, version, item));
          return controller;
        }
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
      !_loading.contains((proposalId, version, itemId)) &&
      !_errors.containsKey((proposalId, version, itemId)) &&
      (_inputs[(proposalId, version, itemId)]?.text.isNotEmpty ?? false);

  @override
  Widget input(
    String proposalId,
    int version,
    String itemId, {
    required bool enabled,
  }) {
    final key = (proposalId, version, itemId);
    final controller = _controller(proposalId, version, itemId);
    final input = _InlinePassword(
      key: ValueKey((proposalId, version, itemId)),
      controller: controller,
      itemId: itemId,
      enabled: enabled && !_loading.contains(key) && !_errors.containsKey(key),
      changed: notifyListeners,
    );
    if (_remote == null) return input;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        input,
        if (_errors[key] case final failure?) ...[
          Text(failure.message),
          DesktopButton(
            onPressed: enabled
                ? () {
                    _load(key, controller);
                    notifyListeners();
                  }
                : null,
            child: const Text('重新读取密码'),
          ),
        ],
      ],
    );
  }

  @override
  Future<Set<String>> store(String proposalId, int version) async {
    if (_remote != null) {
      await Future.wait([
        for (final e in _loads.entries)
          if (e.key.$1 == proposalId && e.key.$2 == version) e.value,
      ]);
      final failure = _errors.entries
          .where((e) => e.key.$1 == proposalId && e.key.$2 == version)
          .firstOrNull;
      if (failure != null) throw failure.value;
    }
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
      if (_remote != null) {
        final receipt = await _remote.fill(proposalId, version, {
          for (final entry in entries)
            _itemKey(proposalId, entry.key.$3): entry.value.text,
        });
        return _moveInputs(
          proposalId,
          version,
          receipt.keys.map((k) => 'proposal:$proposalId:$k').toSet(),
        );
      }
      await owner.inLibraryScope(_scope!, () async {
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
      return _moveInputs(
        proposalId,
        version,
        entries.map((e) => e.key.$3).toSet(),
      );
    } on core.AccessFailure catch (error) {
      throw WorkspaceFailure(
        error.status == 'proposal_changed' ? 'conflict' : error.status,
        error.status == 'invalid_credential_content'
            ? '密码不能为空，不能超过65536字节或包含空字符。输入仍保留。'
            : '提案已变化或密码暂时无法保存，输入仍保留，请重新核对。',
      );
    } on WorkspaceFailure {
      rethrow;
    } catch (_) {
      throw const WorkspaceFailure('unavailable', '密码暂时无法保存，输入仍保留，请重试。');
    }
  }

  Set<String> _moveInputs(String proposalId, int version, Set<String> filled) {
    for (final item in filled) {
      final controller = _inputs.remove((proposalId, version, item));
      if (controller != null) {
        _inputs[(proposalId, version + 1, item)] = controller;
      }
    }
    return filled;
  }

  @override
  Future<Set<String>?> reconcile(String proposalId, int version) async {
    if (_remote == null) return super.reconcile(proposalId, version);
    final receipt = await _remote.reconcile(proposalId, version);
    return receipt == null
        ? null
        : _moveInputs(
            proposalId,
            version,
            receipt.keys.map((key) => 'proposal:$proposalId:$key').toSet(),
          );
  }

  @override
  void clear(String proposalId) {
    _remote?.clear(proposalId);
    _loads.removeWhere((key, _) => key.$1 == proposalId);
    _loading.removeWhere((key) => key.$1 == proposalId);
    _errors.removeWhere((key, _) => key.$1 == proposalId);
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
    _closed = true;
    _remote?.dispose();
    _loads.clear();
    _loading.clear();
    _errors.clear();
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
  Widget build(BuildContext context) => DesktopTextField(
    key: ValueKey('proposal-owner-password-${widget.itemId}'),
    controller: widget.controller,
    enabled: widget.enabled,
    obscureText: !_visible,
    inlineSecret: true,
    enableSuggestions: false,
    autocorrect: false,
    maxLength: 65536,
    onChanged: (_) => widget.changed(),
    decoration: InputDecoration(
      labelText: '密码',
      suffixIcon: IconButton(
        key: ValueKey('proposal-password-visible-${widget.itemId}'),
        tooltip: _visible ? '隐藏密码' : '显示密码',
        onPressed: widget.enabled
            ? () => setState(() => _visible = !_visible)
            : null,
        icon: Icon(
          _visible ? Icons.visibility_off_outlined : Icons.visibility_outlined,
          size: 18,
        ),
      ),
    ),
  );
}
