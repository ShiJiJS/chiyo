import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:info_remote/agent_connection.dart';
import 'package:info_remote/owner_client.dart';
import 'desktop_controls.dart';

/// Owner setup creates a restricted device profile. No management Token is
/// written to it, and this dialog neither installs nor trusts Codex hooks.
class OnlineAgentConnectionDialog extends StatefulWidget {
  const OnlineAgentConnectionDialog({
    super.key,
    required this.client,
    required this.directory,
    required this.certificate,
  });
  final OwnerClient client;
  final Directory directory;
  final String certificate;
  @override
  State<OnlineAgentConnectionDialog> createState() =>
      _OnlineAgentConnectionDialogState();
}

class _OnlineAgentConnectionDialogState
    extends State<OnlineAgentConnectionDialog> {
  final _name = TextEditingController(text: Platform.localHostname);
  late final String _operation =
      'device-${List.generate(16, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
  String? _submittedName, _path, _error;
  bool _busy = true;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final file = File('${widget.directory.path}/agent-connection.json');
      if (await FileSystemEntity.type(file.path, followLinks: false) ==
          FileSystemEntityType.notFound) {
        return;
      }
      final profile = await AgentConnectionProfile.read(file);
      if (profile.address != widget.client.address ||
          profile.serverId != widget.client.serverId) {
        throw const FormatException();
      }
      final connection = AgentConnection(profile);
      try {
        if ((await connection.call('/capabilities', {}))['status'] != 'ok') {
          throw const FormatException();
        }
      } finally {
        connection.close();
      }
      if (mounted) setState(() => _path = file.path);
    } on Object {
      if (mounted) setState(() => _error = '原连接配置不可用，可以重新生成。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _generate() async {
    final name = _submittedName ?? _name.text.trim();
    if (name.isEmpty || name.length > 200) {
      setState(() => _error = '请填写设备名称。');
      return;
    }
    _submittedName = name;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final device = await widget.client.request('POST', '/v1/owner/devices', {
        'operationId': _operation,
        'name': name,
      });
      final profile = AgentConnectionProfile(
        address: widget.client.address,
        serverId: widget.client.serverId,
        deviceToken: device['deviceToken'] as String,
        certificate: widget.certificate,
      );
      final file = await profile.saveIn(widget.directory);
      if (mounted) setState(() => _path = file.path);
    } on Object {
      if (mounted) setState(() => _error = '生成未完成，请检查连接后重试。重试会核对原请求。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: DesktopDialog(
      width: 560,
      title: const Text('AI 接入'),
      closeEnabled: !_busy,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('CLI 使用单独的设备连接配置。资料申请仍由你审批。'),
          const SizedBox(height: 16),
          if (_path == null)
            DesktopTextField(
              key: const ValueKey('agent-connection-name'),
              controller: _name,
              enabled: !_busy && _submittedName == null,
              decoration: const InputDecoration(labelText: '设备名称'),
            ),
          if (_busy) const LinearProgressIndicator(),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_error!),
            ),
          if (_path != null) ...[
            const Text('连接配置已保存。按配套说明让 CLI 使用此文件：'),
            const SizedBox(height: 10),
            SelectableText(
              _path!,
              key: const ValueKey('agent-connection-path'),
            ),
          ],
        ],
      ),
      actions: [
        if (_path == null)
          DesktopButton(
            key: const ValueKey('agent-connection-generate'),
            onPressed: _busy ? null : _generate,
            child: const Text('生成配置'),
          ),
        DesktopButton(
          key: const ValueKey('agent-connection-close'),
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('完成'),
        ),
      ],
    ),
  );
}
