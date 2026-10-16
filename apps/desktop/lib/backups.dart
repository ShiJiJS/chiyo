import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_core/info_core.dart';
import 'ui.dart';

/// The OS file-dialog boundary. Widget tests supply paths, never open dialogs.
abstract class BackupFilePicker {
  const BackupFilePicker();
  Future<String?> recoveryKeyOutput();
  Future<String?> backupOutput();
  Future<String?> backupInput();
  Future<BackupStaging?> prepareStaging(String output) async => null;
  Future<void> releaseStaging(BackupStaging staging) async {}
}

class BackupStaging {
  const BackupStaging(this.directory, this.token);
  final String directory, token;
}

class NativeBackupFilePicker extends BackupFilePicker {
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
  @override
  Future<BackupStaging?> prepareStaging(String output) async {
    if (defaultTargetPlatform != TargetPlatform.macOS) return null;
    final value = await _channel.invokeMapMethod<String, String>(
      'prepareBackupStaging',
      output,
    );
    if (value == null || value['directory'] == null || value['token'] == null) {
      throw const StorageFailure('backup_staging_failed');
    }
    return BackupStaging(value['directory']!, value['token']!);
  }

  @override
  Future<void> releaseStaging(BackupStaging staging) =>
      _channel.invokeMethod<void>('releaseBackupStaging', staging.token);
}

class BackupLibrary extends StatefulWidget {
  const BackupLibrary({
    super.key,
    required this.backups,
    required this.owner,
    this.onRestored,
    this.files = const NativeBackupFilePicker(),
  });
  final InformationBackups backups;
  final OwnerAccess owner;
  final VoidCallback? onRestored;
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
      '当前资料库已有资料、提案或历史记录，无法恢复。请在新设备的空资料库中恢复，现有资料保持不变。',
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
    final staging = await widget.files.prepareStaging(path);
    try {
      await widget.owner.exportLibrary(
        () => widget.backups.exportTo(path, stagingParent: staging?.directory),
      );
    } finally {
      if (staging != null) {
        try {
          await widget.files.releaseStaging(staging);
        } catch (_) {
          /* Keep encrypted leftovers without changing the export outcome. */
        }
      }
    }
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
      builder: (context) => DesktopDialog(
        title: const Text('确认恢复资料库'),
        content: Text(
          '备份时间：${snapshot.createdAt.toLocal()}\n信息 ${snapshot.informationCount} 项，目录 ${snapshot.directoryCount} 个，标签 ${snapshot.tagCount} 个，模板 ${snapshot.templateCount} 个。\n'
          '修改版本 ${snapshot.revisionCount} 条，可恢复回收站 ${snapshot.recycleCount} 条，授权历史 ${snapshot.grantHistoryCount} 条，访问记录 ${snapshot.accessRecordCount} 条。\n\n'
          '${snapshot.formatVersion == 1 ? '这是早期格式，仅含当前资料及设置，不含历史或回收站。' : '历史按各自原保留时间恢复，到期内容不会重新获得保留期。'}'
          '\n仅能恢复到空资料库，不会覆盖或合并现有资料。不含提案、待审批或有效凭据；本机已有会话凭据也会失效。授权历史仅作为过去事实恢复，Agent 需要重新申请。',
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
    await widget.owner.restoreLibrary(() => widget.backups.restore(snapshot));
    widget.onRestored?.call();
    if (mounted) setState(() => _message = '资料已恢复，请到“资料库”查看。Agent 需要重新申请访问。');
  }

  @override
  Widget build(BuildContext context) => ReadingWorkspace(
    width: 1160,
    child: ListView(
      padding: UiSpace.page,
      children: [
        const PageHeading('备份与恢复', subtitle: '使用独立恢复密钥，将资料带到另一台设备。'),
        const QuietNotice('跨平台与真实桌面恢复尚未验收，请只使用虚构资料。'),
        const SizedBox(height: 20),
        LayoutBuilder(
          builder: (context, bounds) {
            final export = FormSection(
              title: '手动加密备份',
              detail: _enabled ? '已启用' : '尚未启用',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    '包含当前信息、目录、标签、模板、设置，以及保留期内的修改版本、回收站、授权历史和访问记录。为维持数据关系，另保留不含内容的删除与版本标识。',
                  ),
                  const SizedBox(height: 12),
                  const QuietNotice('不含提案、待审批、有效凭据、本机数据库密钥或恢复密钥。'),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      if (!_enabled)
                        FilledButton(
                          onPressed: _busy
                              ? null
                              : () => _run(() => _showKey(enable: true)),
                          child: const Text('启用手动备份'),
                        ),
                      if (_enabled)
                        FilledButton(
                          onPressed: _busy ? null : () => _run(_export),
                          child: const Text('导出加密备份'),
                        ),
                      if (!_enabled)
                        OutlinedButton(
                          onPressed: null,
                          child: const Text('导出加密备份'),
                        ),
                    ],
                  ),
                ],
              ),
            );
            final key = FormSection(
              title: '恢复密钥',
              protected: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('独立于本机数据库密钥，日常打开应用无需输入。请另存，并与备份分开保管。'),
                  const SizedBox(height: 12),
                  const QuietNotice('同时持有备份和恢复密钥即可读取资料。'),
                  if (_enabled)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton(
                        onPressed: _busy ? null : () => _run(_showKey),
                        child: const Text('查看并保存恢复密钥'),
                      ),
                    ),
                ],
              ),
            );
            if (bounds.maxWidth < 1000 ||
                MediaQuery.textScalerOf(context).scale(14) > 20) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [export, key],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 3, child: export),
                const SizedBox(width: 20),
                Expanded(flex: 2, child: key),
              ],
            );
          },
        ),
        const SizedBox(height: 8),
        const SectionHeading('在新设备恢复'),
        const Text('仅支持空资料库；已有资料时拒绝恢复，不覆盖或合并。确认恢复成功前，请保留原设备和原备份。'),
        const SizedBox(height: 12),
        const Text('恢复按原时间清理到期内容，不延长保留期；期间暂缓 Agent 访问，完成后需要重新申请。'),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton(
            onPressed: _busy ? null : () => _run(_restore),
            child: const Text('从备份恢复'),
          ),
        ),
        const SizedBox(height: 24),
        const Divider(),
        const QuietNotice('离线备份需自行管理，不随应用清理旧内容。'),
        if (_busy)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: LinearProgressIndicator(),
          ),
        if (_message != null)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text(_message!, key: const ValueKey('backup-result')),
          ),
      ],
    ),
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
  Widget build(BuildContext context) => DesktopDialog(
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
            style: Theme.of(context).textTheme.bodyMedium,
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
  Widget build(BuildContext context) => DesktopDialog(
    title: const Text('输入恢复密钥'),
    content: SizedBox(
      width: 540,
      child: DesktopTextField(
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
