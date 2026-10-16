import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:info_storage/info_storage.dart';

/// The OS file-dialog boundary. Widget tests supply paths, never open dialogs.
abstract interface class BackupFilePicker {
  Future<String?> recoveryKeyOutput();
  Future<String?> backupOutput();
  Future<String?> backupInput();
}

class NativeBackupFilePicker implements BackupFilePicker {
  const NativeBackupFilePicker();
  static const _channel = MethodChannel('agent_info_manage/backup_files');
  @override
  Future<String?> recoveryKeyOutput() =>
      _channel.invokeMethod<String>('recoveryKeyOutput');
  @override
  Future<String?> backupOutput() =>
      _channel.invokeMethod<String>('backupOutput');
  @override
  Future<String?> backupInput() => _channel.invokeMethod<String>('backupInput');
}

class BackupLibrary extends StatefulWidget {
  const BackupLibrary({
    super.key,
    required this.backups,
    this.files = const NativeBackupFilePicker(),
  });
  final InformationBackups backups;
  final BackupFilePicker files;
  @override
  State<BackupLibrary> createState() => _BackupLibraryState();
}

class _BackupLibraryState extends State<BackupLibrary> {
  bool _enabled = false, _busy = true;
  String? _message;
  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      final key = await widget.backups.recoveryKey();
      if (mounted) setState(() => _enabled = key != null);
    } catch (_) {
      if (mounted) setState(() => _message = '备份设置无法读取，请保留现有资料。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _failure(Object error) => switch (error) {
    StorageFailure(code: 'output_exists') => '所选文件已存在，请选择新的文件名，原文件未覆盖。',
    StorageFailure(code: 'recipient_not_empty') =>
      '当前资料库不为空，无法恢复。请在新设备的空资料库中恢复，现有资料保持不变。',
    StorageFailure(code: 'unsupported_backup') => '该备份格式或版本不受支持，资料未恢复。',
    StorageFailure(code: 'invalid_recovery_key') => '恢复密钥格式不正确，请检查另存的完整密钥。',
    StorageFailure(code: 'invalid_backup') => '密钥不匹配、文件损坏或备份内容无效，资料未恢复。',
    _ => '操作未完成，请检查文件位置、恢复密钥及资料库状态。',
  };
  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _message = _failure(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showKey({bool enable = false}) async {
    final key = enable
        ? await widget.backups.enable()
        : await widget.backups.recoveryKey();
    if (!mounted || key == null) return;
    setState(() => _enabled = true);
    await showDialog<void>(
      context: context,
      builder: (context) => _RecoveryKeyDialog(
        recoveryKey: key,
        save: () async {
          final path = await widget.files.recoveryKeyOutput();
          if (path == null) return false;
          await widget.backups.saveRecoveryKeyTo(path);
          return true;
        },
      ),
    );
  }

  Future<void> _export() async {
    final path = await widget.files.backupOutput();
    if (path == null) return;
    await widget.backups.exportTo(path);
    if (mounted) setState(() => _message = '加密备份已导出。');
  }

  Future<void> _restore() async {
    final path = await widget.files.backupInput();
    if (!mounted || path == null) return;
    final key = await showDialog<String>(
      context: context,
      builder: (_) => const _RestoreKeyDialog(),
    );
    if (!mounted || key == null) return;
    final snapshot = await widget.backups.inspect(path, key);
    if (!mounted) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认恢复当前资料'),
        content: Text(
          '备份时间：${snapshot.createdAt.toLocal()}\n信息 ${snapshot.informationCount} 项，目录 ${snapshot.directoryCount} 个，标签 ${snapshot.tagCount} 个，模板 ${snapshot.templateCount} 个。\n\n仅能恢复到空资料库，不会覆盖或合并现有资料。备份仅含当前资料及设置，不含待处理提案、审批、有效授权、历史版本、回收站或访问历史。恢复后 Agent 需要重新申请。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('恢复到空资料库'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await widget.backups.restore(snapshot);
    if (mounted) setState(() => _message = '资料已恢复，请到“我的信息”查看。Agent 需要重新申请访问。');
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      Text('手动加密备份', style: Theme.of(context).textTheme.headlineSmall),
      const SizedBox(height: 12),
      const Text('当前为开发版本，请仅使用虚构资料。跨平台及真实桌面恢复仍待验收。'),
      const SizedBox(height: 12),
      const Text(
        '备份包含当前信息、目录、标签、字段模板及设置。历史版本、回收站、访问历史、待处理提案及审批不在此版备份范围内。备份不会保存有效授权或本机数据库密钥。',
      ),
      const SizedBox(height: 20),
      const Text(
        '恢复密钥与本机数据库密钥独立，日常打开应用无需输入。请把恢复密钥另存到安全位置，与备份分开保管；任何同时拿到备份和恢复密钥的人都能读取其中的资料。',
      ),
      const SizedBox(height: 20),
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          if (!_enabled)
            FilledButton(
              onPressed: _busy
                  ? null
                  : () => _run(() => _showKey(enable: true)),
              child: const Text('启用手动备份'),
            ),
          if (_enabled)
            OutlinedButton(
              onPressed: _busy ? null : () => _run(_showKey),
              child: const Text('查看并保存恢复密钥'),
            ),
          FilledButton(
            onPressed: _busy || !_enabled ? null : () => _run(_export),
            child: const Text('导出加密备份'),
          ),
        ],
      ),
      const SizedBox(height: 32),
      const Text('恢复仅支持新设备或空资料库，已有资料时会拒绝恢复，不会自动覆盖或合并。请保留原设备及原备份，确认恢复成功后再处理它们。'),
      const SizedBox(height: 12),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton(
          onPressed: _busy ? null : () => _run(_restore),
          child: const Text('从备份恢复'),
        ),
      ),
      if (_busy)
        const Padding(
          padding: EdgeInsets.all(16),
          child: LinearProgressIndicator(),
        ),
      if (_message != null)
        Padding(
          padding: const EdgeInsets.only(top: 20),
          child: Text(_message!, key: const ValueKey('backup-result')),
        ),
    ],
  );
}

class _RecoveryKeyDialog extends StatefulWidget {
  const _RecoveryKeyDialog({required this.recoveryKey, required this.save});
  final String recoveryKey;
  final Future<bool> Function() save;
  @override
  State<_RecoveryKeyDialog> createState() => _RecoveryKeyDialogState();
}

class _RecoveryKeyDialogState extends State<_RecoveryKeyDialog> {
  bool _saving = false;
  String? _message;
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('请另行保存恢复密钥'),
    content: SizedBox(
      width: 540,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '此密钥能解开你的备份。请勿发给 Agent 或写入日志，也不要与备份放在同一个文件里。保存的是可独立使用的明文密钥，请选择安全位置。',
          ),
          const SizedBox(height: 16),
          SelectableText(
            widget.recoveryKey,
            style: const TextStyle(fontFamily: 'monospace'),
          ),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(_message!),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => Navigator.pop(context),
        child: const Text('完成'),
      ),
      FilledButton(
        onPressed: _saving
            ? null
            : () async {
                setState(() => _saving = true);
                try {
                  final saved = await widget.save();
                  if (mounted && saved) {
                    setState(() => _message = '恢复密钥已另存，请与备份分开保管。');
                  }
                } on StorageFailure catch (error) {
                  if (mounted) {
                    setState(
                      () => _message = error.code == 'output_exists'
                          ? '所选文件已存在，请换一个文件名。'
                          : '密钥保存失败，请检查文件位置。',
                    );
                  }
                } catch (_) {
                  if (mounted) setState(() => _message = '密钥保存失败，请检查文件位置。');
                } finally {
                  if (mounted) setState(() => _saving = false);
                }
              },
        child: const Text('保存恢复密钥文件'),
      ),
    ],
  );
}

class _RestoreKeyDialog extends StatefulWidget {
  const _RestoreKeyDialog();
  @override
  State<_RestoreKeyDialog> createState() => _RestoreKeyDialogState();
}

class _RestoreKeyDialogState extends State<_RestoreKeyDialog> {
  final _key = TextEditingController();
  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('输入恢复密钥'),
    content: SizedBox(
      width: 540,
      child: TextField(
        controller: _key,
        obscureText: true,
        enableSuggestions: false,
        autocorrect: false,
        maxLength: 128,
        decoration: const InputDecoration(labelText: '另存的完整恢复密钥'),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _key.text.trim()),
        child: const Text('检查备份'),
      ),
    ],
  );
}
