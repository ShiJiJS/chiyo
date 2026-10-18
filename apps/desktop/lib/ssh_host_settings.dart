import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart';
import 'credential_files.dart';
import 'prototype_dialog.dart';
import 'prototype_ui.dart';
import 'settings_controls.dart';
import 'ui.dart';

class SshHostSettings extends StatefulWidget {
  const SshHostSettings({super.key, required this.owner, required this.files});
  final OwnerAccess owner;
  final CredentialFilePicker files;
  @override
  State<SshHostSettings> createState() => _SshHostSettingsState();
}

class _SshHostSettingsState extends State<SshHostSettings> {
  bool _busy = false;
  String? _error, _message;
  Future<void> _import() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _message = null;
    });
    try {
      final file = await widget.files.choose();
      if (file == null || !mounted) return;
      validateSshKnownHosts(file.name, file.bytes);
      final snapshot = SshHostTrustSnapshot(
        id: 'preview',
        name: file.name,
        bytes: file.bytes,
        confirmedAt: DateTime.now(),
      );
      final hosts = const LineSplitter()
          .convert(utf8.decode(file.bytes))
          .map((v) => v.trim())
          .where((v) => v.isNotEmpty && !v.startsWith('#'))
          .map((line) {
            final parts = line.split(RegExp(r'\s+'));
            return parts[parts.first.startsWith('@') ? 1 : 0];
          })
          .toSet()
          .toList();
      final confirmed = await showDialog<bool>(
        context: context,
        barrierColor: const Color(0x4f241b27),
        builder: (context) => PrototypeDialog(
          width: 650,
          title: '确认 SSH 主机记录',
          onClose: () => Navigator.pop(context, false),
          body: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '请先通过可信来源核对这些主机及文件指纹。导入不会连接服务器或自动信任扫描结果。',
                style: prototypeText(context, 14, height: 1.9),
              ),
              const SizedBox(height: 18),
              Text(
                file.name,
                style: prototypeText(context, 14, weight: FontWeight.w600),
              ),
              const SizedBox(height: 10),
              SelectableText(
                '${hosts.take(12).join('\n')}${hosts.length > 12 ? '\n另有 ${hosts.length - 12} 个主机条目，请核对完整源文件。' : ''}',
                style: prototypeText(
                  context,
                  13,
                  family: 'Consolas',
                  height: 1.9,
                ),
              ),
              const SizedBox(height: 14),
              SelectableText(
                '文件 SHA256\n${snapshot.sha256}',
                style: prototypeText(
                  context,
                  12,
                  family: 'Consolas',
                  height: 1.9,
                ),
              ),
              const SizedBox(height: 18),
              const SettingsNotice(
                '旧的未启动 SSH 申请将失效',
                '替换主机记录后需要重新申请。已经运行的任务继续使用原快照，不会自动终止。',
                marginTop: 0,
                warning: true,
              ),
            ],
          ),
          actions: [
            TextButton(
              style: prototypeSecondary(context),
              onPressed: () => Navigator.pop(context, false),
              child: const Text('返回核对'),
            ),
            TextButton(
              style: prototypePrimary(context),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认并启用'),
            ),
          ],
        ),
      );
      if (confirmed == true) {
        await widget.owner.configureSshKnownHosts(file.name, file.bytes);
        if (mounted) setState(() => _message = '主机记录已确认，新的 SSH 申请将绑定这份快照。');
      }
    } on Object {
      if (mounted) setState(() => _error = '未能导入主机记录。请检查文件内容和本机存储，原有确认记录保持不变。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clear() async {
    final yes = await showDialog<bool>(
      context: context,
      barrierColor: const Color(0x4f241b27),
      builder: (context) => PrototypeDialog(
        width: 550,
        title: '清除 SSH 主机记录',
        onClose: () => Navigator.pop(context, false),
        body: const QuietNotice(
          '清除后暂停接受新的 SSH 使用申请，旧的未启动申请失效。已启动任务不受影响。',
          warning: true,
        ),
        actions: [
          TextButton(
            style: prototypeSecondary(context),
            onPressed: () => Navigator.pop(context, false),
            child: const Text('返回'),
          ),
          TextButton(
            style: prototypePrimary(context),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认清除'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
      _message = null;
    });
    try {
      await widget.owner.clearSshKnownHosts();
      if (mounted) setState(() => _message = '已清除，重新确认主机记录后可提交新的 SSH 申请。');
    } on Object {
      if (mounted) setState(() => _error = '未能清除，请检查本机存储后重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final trust = widget.owner.sshKnownHosts;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsRow(
          '已确认的主机记录',
          trust == null
              ? '尚未确认。SSH 使用申请会被拒绝，其他凭据接收方式不受影响。'
              : '${trust.name}\n确认于 ${trust.confirmedAt.toLocal().toString().split('.').first}',
          first: true,
          control: settingsAction(
            context,
            trust == null ? '导入主机记录' : '替换主机记录',
            _busy ? null : _import,
            primary: true,
          ),
        ),
        if (trust != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 18),
            child: SelectableText(
              '${trust.sha256}\n快照 ${trust.id}',
              style: prototypeText(
                context,
                12,
                family: 'Consolas',
                height: 1.9,
                color: UiPalette.of(context).muted,
              ),
            ),
          ),
        const SettingsNotice(
          '每次审批固定一份快照',
          'SSH 使用严格主机校验、所选私钥和独立空配置，不会自动读取个人 known_hosts、配置或 ssh-agent。未知主机或主机密钥变化时直接失败；请通过可信来源核对后再替换记录。',
          icon: PrototypeIconGlyph.shield,
        ),
        if (trust != null)
          Padding(
            padding: const EdgeInsets.only(top: 18),
            child: Align(
              alignment: Alignment.centerLeft,
              child: settingsAction(context, '清除主机记录', _busy ? null : _clear),
            ),
          ),
        if (_error != null) SettingsNotice('主机记录未保存', _error!, error: true),
        if (_message != null)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text(
              _message!,
              style: prototypeText(context, 13, height: 1.9),
            ),
          ),
      ],
    );
  }
}
