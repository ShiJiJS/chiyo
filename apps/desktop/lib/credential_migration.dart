import 'desktop_controls.dart';
import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart';
import 'credential_dialogs.dart';
import 'prototype_dialog.dart';
import 'prototype_ui.dart';
import 'ui_palette.dart';

/// Explicit owner selection. Field names and impact are shown, never guessed
/// from content, and the value is not copied into the dialog or its messages.
class CredentialMigrationDialog extends StatefulWidget {
  const CredentialMigrationDialog({
    super.key,
    required this.owner,
    required this.item,
  });
  final OwnerAccess owner;
  final InformationItem item;
  @override
  State<CredentialMigrationDialog> createState() =>
      _CredentialMigrationDialogState();
}

class _CredentialMigrationDialogState extends State<CredentialMigrationDialog> {
  CredentialMigrationPreview? _preview;
  String? _fieldId, _error;
  bool _busy = false;
  void _select(String? id) {
    setState(() {
      _fieldId = id;
      _error = null;
      _preview = null;
      if (id == null) return;
      try {
        _preview = widget.owner.previewCredentialMigration(
          FieldRef(widget.item.id, id),
          widget.item.version,
        );
      } on Object {
        _error = '信息已变化或凭据服务不可用，请关闭后重新打开。原信息未改变。';
      }
    });
  }

  Future<void> _confirm() async {
    if (_busy || _preview == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final c = await widget.owner.migrateFieldToCredential(
        FieldRef(widget.item.id, _fieldId!),
        widget.item.version,
      );
      if (mounted) Navigator.pop(context, c);
    } on AccessFailure catch (e) {
      if (mounted) {
        setState(
          () => _error = e.status == 'invalid_credential_content'
              ? '所选字段为空、过长或含不支持的字符，无法转换为字符串凭据。原信息未改变。'
              : '信息已变化，请关闭后重新选择。原信息未改变。',
        );
      }
    } on Object {
      if (mounted) {
        setState(() => _error = '转换失败，整批已回滚。原信息、凭据和读取授权保持原状，可修复存储后重试。');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = UiPalette.of(context);
    Widget paragraph(String value) =>
        Text(value, style: prototypeText(context, 13, height: 1.9));
    Widget fact(String label, String value) => Container(
      padding: const EdgeInsets.symmetric(vertical: 13),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: p.line)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: (MediaQuery.textScalerOf(context).scale(13) * 6).clamp(
              120.0,
              240.0,
            ),
            child: Text(
              label,
              style: prototypeText(context, 13, color: p.muted),
            ),
          ),
          Expanded(child: paragraph(value)),
        ],
      ),
    );
    return PopScope(
      canPop: !_busy,
      child: PrototypeDialog(
        title: '将旧字段转为托管凭据',
        flow: true,
        simpleFlow: true,
        actionDivider: false,
        onClose: _busy ? null : () => Navigator.pop(context),
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            paragraph('只转换你明确选中的普通字段。不会扫描或自动猜测秘密。'),
            const SizedBox(height: 18),
            Text('选择要转换的字段', style: prototypeText(context, 13)),
            const SizedBox(height: 7),
            DesktopSelect<String>(
              key: const ValueKey('migration-field'),
              initialValue: _fieldId,
              isExpanded: true,
              hint: Text(
                '请选择字段',
                style: prototypeText(context, 13, color: p.muted),
              ),
              decoration: InputDecoration(
                isDense: true,
                contentPadding: const EdgeInsets.all(9),
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: p.line),
                ),
                focusedBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: p.accent),
                ),
              ),
              items: [
                for (final f in widget.item.fields.where(
                  (f) => f.kind != FieldKind.file,
                ))
                  DropdownMenuItem(
                    value: f.id,
                    child: Text(f.name, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: _busy ? null : _select,
            ),
            if (widget.item.fields.any((f) => f.kind == FieldKind.file))
              paragraph('普通文件不能转换为字符串凭据。密钥文件请在凭据管理中单独导入。'),
            if (_preview case final preview?) ...[
              const SizedBox(height: 18),
              Column(
                children: [
                  fact('旧字段', '${preview.item.name} / ${preview.field.name}'),
                  fact(
                    '会受到影响',
                    '${preview.activeGrantCount} 项读取授权、${preview.revisionCount} 个历史版本、${preview.recycleCopyCount} 份回收副本',
                  ),
                  fact(
                    '转换后',
                    '${preview.credentialName} · 独立字符串凭据，默认不允许发现，并关联原信息',
                  ),
                ],
              ),
            ],
            const SizedBox(height: 18),
            paragraph('确认后原普通读取路径关闭，旧字段授权永久失效。其他字段的授权不受影响。'),
            const SizedBox(height: 10),
            paragraph(
              '保留历史与回收副本供你查看，离线备份不会同步擦除。恢复旧内容会取得新字段身份，旧授权不会恢复。整个转换失败时整批回滚。',
            ),
            if (_error != null) credentialFlowError(context, _error!),
          ],
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            style: prototypeSecondary(context),
            child: const Text('取消'),
          ),
          TextButton(
            key: const ValueKey('migration-confirm'),
            onPressed: _busy || _preview == null ? null : _confirm,
            style: prototypePrimary(context),
            child: Text(_busy ? '正在转换…' : '确认转换所选字段'),
          ),
        ],
      ),
    );
  }
}
