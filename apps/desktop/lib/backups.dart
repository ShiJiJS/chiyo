import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_core/info_core.dart';
import 'ui.dart';
import 'prototype_ui.dart';
import 'settings_controls.dart';
import 'information_attachment_capacity.dart';
import 'information_files.dart';

/// The OS file-dialog boundary. Widget tests supply paths, never open dialogs.
abstract class BackupFilePicker {
  const BackupFilePicker();
  Future<String?> recoveryKeyOutput();
  Future<String?> backupOutput();
  Future<String?> backupInput();
  Future<String?> recoveryKeyInput() async => null;
  Future<BackupStaging?> prepareStaging(String output) async => null;
  Future<void> releaseStaging(BackupStaging staging) async {}
  Future<void> releaseRecordedStaging(Map<String, Object?> directory) async =>
      throw const StorageFailure('backup_staging_failed');
  Future<String> outputBookmark(BackupStaging staging) async =>
      throw const StorageFailure('backup_access_required');
  Future<String> acquireAccess(
    Map<String, String> access, {
    required bool needsOutput,
  }) async => throw const StorageFailure('backup_access_required');
  Future<void> releaseAccess(String token) async {}
  Future<String?> reselectOutput(String expectedPath) async =>
      throw const StorageFailure('backup_access_required');
}

class BackupStaging {
  const BackupStaging(this.directory, this.token, {this.stagingBookmark});
  final String directory, token;
  final String? stagingBookmark;
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
  Future<String?> recoveryKeyInput() =>
      _channel.invokeMethod<String>('recoveryKeyInput');
  @override
  Future<BackupStaging?> prepareStaging(String output) async {
    if (defaultTargetPlatform != TargetPlatform.macOS) return null;
    final value = await _channel.invokeMapMethod<String, String>(
      'prepareBackupStaging',
      output,
    );
    if (value == null ||
        value['directory'] == null ||
        value['token'] == null ||
        value['stagingBookmark'] == null) {
      throw const StorageFailure('backup_staging_failed');
    }
    return BackupStaging(
      value['directory']!,
      value['token']!,
      stagingBookmark: value['stagingBookmark'],
    );
  }

  @override
  Future<void> releaseStaging(BackupStaging staging) =>
      _channel.invokeMethod<void>('releaseBackupStaging', staging.token);

  @override
  Future<void> releaseRecordedStaging(Map<String, Object?> directory) =>
      _channel.invokeMethod<void>('releaseRegisteredBackupStaging', directory);

  Future<String?> _access(String method, Object arguments) async {
    try {
      return await _channel.invokeMethod<String>(method, arguments);
    } on PlatformException {
      throw const StorageFailure('backup_access_required');
    }
  }

  @override
  Future<String> outputBookmark(BackupStaging staging) async =>
      await _access('captureBackupOutputBookmark', staging.token) ??
      (throw const StorageFailure('backup_access_required'));
  @override
  Future<String> acquireAccess(
    Map<String, String> access, {
    required bool needsOutput,
  }) async =>
      await _access('acquireBackupAccess', {
        'access': access,
        'needsOutput': needsOutput,
      }) ??
      (throw const StorageFailure('backup_access_required'));
  @override
  Future<void> releaseAccess(String token) =>
      _channel.invokeMethod<void>('releaseBackupAccess', token);
  @override
  Future<String?> reselectOutput(String expectedPath) =>
      _access('reselectBackupOutput', expectedPath);
}

String _backupFailure(Object error) => switch (error) {
  StorageFailure(code: 'output_exists') => '所选文件已存在，请选择新的文件名，原文件未覆盖。',
  StorageFailure(code: 'recipient_not_empty') =>
    '当前信息库已有信息、凭据、回收对象、提案或历史记录，不能覆盖或合并恢复。请在独立空库操作。',
  StorageFailure(code: 'invalid_recovery_key') => '恢复密钥文件格式不正确，请选择独立另存的完整密钥。',
  StorageFailure(code: 'invalid_backup') => '恢复密钥不匹配、文件损坏或备份内容无效。当前信息库未改变。',
  StorageFailure(code: 'unsupported_backup') => '此备份格式或版本不受支持，当前信息库未改变。',
  StorageFailure(code: 'backup_changed') => '备份在检查后发生变化，请重新选择并检查。当前信息库未改变。',
  StorageFailure(code: 'attachment_missing' || 'attachment_integrity_failed') =>
    '附件原文缺失或校验失败，操作未完成。请检查原库或其他完整备份后重试。',
  StorageFailure(code: 'backup_too_large') =>
    '备份超过当前容量或记录上限，导出未完成。请检查附件与保留记录用量。',
  StorageFailure(code: 'recovery_key_not_saved') => '请先独立保存恢复密钥文件，保存成功后才能导出。',
  _ => '操作未完成，请检查文件位置、恢复密钥及存储状态后重试。',
};

class BackupLibrary extends StatefulWidget {
  const BackupLibrary({
    super.key,
    required this.backups,
    required this.owner,
    this.onRestored,
    this.embedded = false,
    this.files = const NativeBackupFilePicker(),
  });
  final InformationBackups backups;
  final OwnerAccess owner;
  final VoidCallback? onRestored;
  final bool embedded;
  final BackupFilePicker files;
  @override
  State<BackupLibrary> createState() => _BackupLibraryState();
}

class _BackupLibraryState extends State<BackupLibrary> {
  bool _busy = true, _empty = false;
  int _capacityRevision = 0;
  String? _error;
  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      final empty = await widget.backups.recipientEmpty();
      if (mounted) {
        setState(() {
          _empty = empty;
          _capacityRevision++;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = '备份服务暂不可用，请检查信息库后重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open() async {
    await showSettingsDialog<void>(
      context: context,
      builder: (_) => BackupFlowDialog(
        backups: widget.backups,
        owner: widget.owner,
        files: widget.files,
        onRestored: widget.onRestored,
      ),
    );
    if (mounted) await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final c = UiPalette.of(context);
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!widget.embedded)
          const PageHeading('备份与恢复', subtitle: '使用独立恢复密钥，保存与恢复你的信息库。'),
        Container(
          padding: const EdgeInsets.fromLTRB(26, 26, 26, 25),
          margin: const EdgeInsets.only(bottom: 27),
          decoration: BoxDecoration(
            color: c.paper,
            border: Border.all(color: c.line),
            borderRadius: BorderRadius.circular(7),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 48,
                height: 51,
                decoration: BoxDecoration(
                  color: c.selected,
                  border: Border.all(color: c.line),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Center(
                  child: PrototypeIcon(
                    PrototypeIconGlyph.shield,
                    size: 26,
                    color: c.accent,
                  ),
                ),
              ),
              const SizedBox(width: 19),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '手动加密备份',
                      style: prototypeText(
                        context,
                        18,
                        weight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 9),
                    Text(
                      '备份文件需要恢复密钥才能打开。恢复密钥独立于本机数据库密钥，请与备份文件分开保管。',
                      style: prototypeText(
                        context,
                        13,
                        color: c.muted,
                        height: 1.9,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        settingsAction(
                          context,
                          '导出加密备份',
                          _busy ? null : _open,
                          primary: true,
                          trailing: const Text('↗'),
                        ),
                        settingsAction(context, '恢复密钥说明', _busy ? null : _open),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Text(
          '从备份恢复',
          style: prototypeText(context, 16, weight: FontWeight.w700),
        ),
        const SizedBox(height: 15),
        SettingsRow(
          '恢复到空的信息库',
          _empty
              ? '当前信息库为空，可以选择备份和恢复密钥，核对预览后恢复。'
              : '当前信息库非空，暂时不能恢复。\n信息、独立凭据、回收对象、提案或历史记录均不能覆盖或合并恢复。',
          control: settingsAction(context, '查看恢复步骤', _busy ? null : _open),
          bottomPadding: 23,
        ),
        const SettingsNotice(
          '历史授权不会重新生效',
          '恢复后保留原记录的时间与事实。Agent 需要重新发起访问申请。',
          icon: PrototypeIconGlyph.clock,
          verticalPadding: 15.5,
        ),
        if (_error != null) SettingsNotice('备份服务不可用', _error!, error: true),
        if (_busy) const LinearProgressIndicator(),
        InformationAttachmentCapacity(
          key: ValueKey(_capacityRevision),
          owner: widget.owner,
        ),
      ],
    );
    return widget.embedded
        ? body
        : SingleChildScrollView(padding: UiSpace.page, child: body);
  }
}

/// Production flow used by settings and isolated native acceptance alike.
class BackupFlowDialog extends StatefulWidget {
  const BackupFlowDialog({
    super.key,
    required this.backups,
    required this.owner,
    required this.files,
    this.onRestored,
  });
  final InformationBackups backups;
  final OwnerAccess owner;
  final BackupFilePicker files;
  final VoidCallback? onRestored;
  @override
  State<BackupFlowDialog> createState() => _BackupFlowDialogState();
}

class _BackupFlowDialogState extends State<BackupFlowDialog> {
  bool _busy = true, _saved = false, _empty = false, _completed = false;
  String? _localKey, _backupPath, _keyPath, _error, _result;
  BackupContents? _preview;
  BackupExportSummary? _exportSummary;
  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    await _run(() async {
      final key = await widget.backups.recoveryKey();
      final saved = await widget.backups.recoveryKeySaved();
      final empty = await widget.backups.recipientEmpty();
      if (mounted) {
        setState(() {
          _localKey = key;
          _saved = saved;
          _empty = empty;
        });
      }
    }, initial: true);
  }

  Future<void> _run(
    Future<void> Function() action, {
    bool initial = false,
  }) async {
    if (_busy && !initial) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = _backupFailure(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _createKey() => _run(() async {
    final key = await widget.backups.enable();
    if (mounted) setState(() => _localKey = key);
  });
  Future<void> _saveKey() => _run(() async {
    final path = await widget.files.recoveryKeyOutput();
    if (path == null) return;
    await widget.backups.saveRecoveryKeyTo(path);
    final saved = await widget.backups.recoveryKeySaved();
    if (mounted) {
      setState(() {
        _saved = saved;
        _result = '恢复密钥已另存，请与备份分开保管。';
      });
    }
  });
  Future<void> _export() => _run(() async {
    final path = await widget.files.backupOutput();
    if (path == null) return;
    if (mounted) {
      setState(() {
        _exportSummary = null;
        _result = null;
      });
    }
    final staging = await widget.files.prepareStaging(path);
    late BackupExportSummary summary;
    try {
      summary = await widget.owner.exportLibrary(
        () => widget.backups.exportTo(path, stagingParent: staging?.directory),
      );
    } finally {
      if (staging != null) {
        try {
          await widget.files.releaseStaging(staging);
        } catch (_) {
          /* Encrypted staging stays isolated if cleanup fails. */
        }
      }
    }
    if (mounted) {
      setState(() {
        _result = '加密备份已导出。';
        _exportSummary = summary;
      });
    }
  });
  Future<void> _select(bool recovery) => _run(() async {
    final path = await (recovery
        ? widget.files.recoveryKeyInput()
        : widget.files.backupInput());
    if (path == null) return;
    if (mounted) {
      setState(() {
        if (recovery) {
          _keyPath = path;
        } else {
          _backupPath = path;
        }
        _preview = null;
        _completed = false;
      });
    }
  });
  Future<void> _inspect() => _run(() async {
    if (_backupPath == null || _keyPath == null) {
      setState(() => _error = '请选择备份文件和恢复密钥文件。');
      return;
    }
    final empty = await widget.backups.recipientEmpty();
    if (!empty) {
      setState(() {
        _empty = false;
        _preview = null;
        _error = '目标信息库非空，不能覆盖或合并恢复。请在独立空库操作。';
      });
      return;
    }
    final key = await widget.backups.readRecoveryKeyFrom(_keyPath!);
    final preview = await widget.backups.inspect(_backupPath!, key);
    if (mounted) {
      setState(() {
        _empty = true;
        _preview = preview;
        _completed = false;
      });
    }
  });
  Future<void> _restore() => _run(() async {
    if (_preview == null || _completed) return;
    await widget.owner.restoreLibrary(() => widget.backups.restore(_preview!));
    widget.onRestored?.call();
    if (mounted) {
      setState(() {
        _completed = true;
        _empty = false;
        _result = '资料已恢复，请到“信息库”查看。Agent 需要重新申请访问。';
      });
    }
  });
  Widget _paragraph(String text) => Align(
    alignment: Alignment.centerLeft,
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: 400 * MediaQuery.textScalerOf(context).scale(14) / 14,
      ),
      child: Text(
        text,
        style: prototypeText(
          context,
          14,
          color: UiPalette.of(context).muted,
          height: 1.85,
        ),
      ),
    ),
  );
  Widget _heading(String text) => Padding(
    padding: const EdgeInsets.only(top: 18, bottom: 12),
    child: Text(
      text,
      style: prototypeText(context, 16, weight: FontWeight.w700),
    ),
  );
  Widget _fileControl(bool recovery) {
    final c = UiPalette.of(context), path = recovery ? _keyPath : _backupPath;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 19 * MediaQuery.textScalerOf(context).scale(1),
          child: Text(
            recovery ? '恢复密钥文件' : '备份文件',
            style: prototypeText(context, 13),
          ),
        ),
        const SizedBox(height: 7),
        Container(
          padding: const EdgeInsets.all(9),
          decoration: BoxDecoration(
            color: c.paper,
            border: Border.all(color: c.line),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            children: [
              TextButton(
                key: ValueKey(
                  recovery ? 'backup-select-key' : 'backup-select-file',
                ),
                onPressed: _busy ? null : () => _select(recovery),
                style: prototypeButton(
                  context,
                  size: 13,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 2.5,
                  ),
                  background: const Color(0xffefefef),
                  side: const BorderSide(color: Color(0xff767676)),
                  radius: 2,
                ),
                child: const Text('选择文件'),
              ),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  path == null
                      ? '未选择任何文件'
                      : path.replaceAll('\\', '/').split('/').last,
                  overflow: TextOverflow.ellipsis,
                  style: prototypeText(context, 13),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => SettingsDialog(
    title: '备份与恢复',
    flow: true,
    busy: _busy,
    actions: const [],
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _paragraph(
          '使用独立恢复密钥加密备份。包含信息、设置、托管凭据及保留期内秘密版本和回收对象、关联、SSH 主机信任与历史事实；临时授权、待处理请求、运行材料和输出不入备份。',
        ),
        const SizedBox(height: 10),
        _paragraph('备份中含秘密原文，请与恢复密钥分开保管。删除或转换当前内容，不会擦除已经导出的离线备份。'),
        if (_saved)
          Padding(
            // The saved-key result is a 14px status block, not a section h3.
            padding: const EdgeInsets.only(top: 29, bottom: 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '恢复密钥已另存',
                  style: prototypeText(context, 14, weight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                _paragraph('每次导出前检查目标位置。不要把恢复密钥交给 Agent。'),
              ],
            ),
          )
        else ...[
          _heading(_localKey == null ? '首次启用备份' : '恢复密钥待另存'),
          _paragraph('创建并另存恢复密钥后才能导出。请与备份文件分开保存。'),
          const SizedBox(height: 15),
        ],
        if (_localKey == null)
          Align(
            alignment: Alignment.centerLeft,
            child: settingsAction(context, '创建恢复密钥', _busy ? null : _createKey),
          ),
        if (_localKey != null && !_saved) ...[
          SelectableText(
            _localKey!,
            style: prototypeText(context, 12, family: 'Consolas'),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: settingsAction(context, '保存恢复密钥文件', _busy ? null : _saveKey),
          ),
        ],
        if (_saved)
          settingsAction(
            context,
            '导出加密备份',
            _busy ? null : _export,
            primary: true,
            verticalPadding: 13,
          ),
        if (_result != null)
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: Text(
              _result!,
              key: const ValueKey('backup-result'),
              style: prototypeText(
                context,
                13,
                color: UiPalette.of(context).statusLive,
              ),
            ),
          ),
        if (_exportSummary case final summary?)
          _paragraph(
            '普通附件：当前文件字段 ${summary.currentAttachmentCount} 个，可恢复原文版本 ${summary.attachmentCount} 份（含保留版本）· ${informationFileSize(summary.attachmentBytes)}。文件交付事实 ${summary.fileDeliveryCount} 条，不含活副本。',
          ),
        _heading('恢复到空的信息库'),
        _paragraph(_empty ? '当前目标库为空，可以检查备份。' : '目标库非空，不能覆盖或合并恢复。'),
        const SizedBox(height: 25),
        LayoutBuilder(
          builder: (context, box) =>
              MediaQuery.textScalerOf(context).scale(14) > 20 ||
                  box.maxWidth < 480
              ? Column(
                  children: [
                    _fileControl(false),
                    const SizedBox(height: 15),
                    _fileControl(true),
                  ],
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: _fileControl(false)),
                    const SizedBox(width: 15),
                    Expanded(child: _fileControl(true)),
                  ],
                ),
        ),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerLeft,
          child: settingsAction(context, '检查备份与恢复密钥', _busy ? null : _inspect),
        ),
        if (_error != null) SettingsNotice('操作未完成', _error!, error: true),
        if (_preview case final p?) ...[
          _heading('恢复预览'),
          _paragraph(
            '${p.informationCount} 条信息、${p.directoryCount} 个目录、${p.tagCount} 个标签、${p.templateCount} 个模板。修改版本 ${p.revisionCount} 条，可恢复回收站 ${p.recycleCount} 条，授权历史 ${p.grantHistoryCount} 条，访问记录 ${p.accessRecordCount} 条，请求记录 ${p.requestHistoryCount} 条。',
          ),
          const SizedBox(height: 12),
          _paragraph(
            p.formatVersion < 5
                ? '旧格式不含托管凭据及其使用历史。'
                : '凭据对象 ${p.credentialCount} 项（含回收对象或删除后的非秘密记录），秘密版本 ${p.credentialVersionCount} 份，SSH 主机信任 ${p.sshTrustCount} 份，凭据使用历史 ${p.credentialUseHistoryCount} 条，启动事实 ${p.credentialExecutionCount} 条。',
          ),
          const SizedBox(height: 12),
          _paragraph(
            p.formatVersion < 8
                ? '旧格式不含普通附件原文。'
                : '普通附件：当前文件字段 ${p.currentAttachmentCount} 个，可恢复原文版本 ${p.attachmentCount} 份（含保留版本）· ${informationFileSize(p.attachmentBytes)}。文件交付事实 ${p.fileDeliveryCount} 条；恢复后需重新申请读取，不重建活副本。',
          ),
          const SizedBox(height: 12),
          _paragraph(
            '备份格式 ${p.formatVersion}；保留对象状态，到期按当前时间判断。历史只表示过去事实，不会恢复有效使用许可、活动会话、待审批、授权凭证、运行文件、输出、整理任务或整理结果。',
          ),
          const SizedBox(height: 15),
          settingsAction(
            context,
            '确认恢复到空库',
            _busy || _completed ? null : _restore,
            primary: true,
            verticalPadding: 13,
          ),
        ],
        if (_busy)
          const Padding(
            padding: EdgeInsets.only(top: 14),
            child: LinearProgressIndicator(),
          ),
        const SizedBox(height: 36),
      ],
    ),
  );
}
