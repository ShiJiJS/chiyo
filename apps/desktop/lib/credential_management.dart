import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart';
import 'credential_dialogs.dart';
import 'credential_files.dart';
import 'prototype_dialog.dart';
import 'prototype_ui.dart';
import 'ui_palette.dart';

class CredentialManagement extends StatefulWidget {
  const CredentialManagement({
    super.key,
    required this.owner,
    required this.credential,
    required this.action,
    this.files = const NativeCredentialFilePicker(),
  });
  final OwnerAccess owner;
  final ManagedCredential credential;
  final String action;
  final CredentialFilePicker files;
  @override
  State<CredentialManagement> createState() => _CredentialManagementState();
}

class _CredentialManagementState extends State<CredentialManagement> {
  late final _name = TextEditingController(text: widget.credential.name),
      _purpose = TextEditingController(text: widget.credential.publicPurpose),
      _note = TextEditingController(text: widget.credential.privateNote),
      _binding = TextEditingController(
        text: widget.credential.suggestedBinding,
      ),
      _expiry = TextEditingController(
        text: widget.credential.expiresAt?.toUtc().toIso8601String() ?? '',
      ),
      _secret = TextEditingController();
  late bool _public = widget.credential.discoverable;
  SelectedCredentialFile? _file;
  bool _busy = false, _details = false;
  String? _error;
  ManagedCredential get c => widget.credential;
  String get action => widget.action;
  static const titles = {
    'metadata': 'Agent 可见信息与有效期',
    'rotate': '更换凭据版本',
    'disable': '停用凭据',
    'enable': '启用凭据',
    'delete': '删除凭据',
    'restore': '恢复凭据',
  };
  static const saveLabels = {
    'metadata': '保存可见性与有效期',
    'rotate': '保存新版本',
    'disable': '停用凭据',
    'enable': '启用凭据',
    'delete': '移入凭据回收站',
    'restore': '恢复为停用凭据',
  };
  @override
  void dispose() {
    for (final controller in [
      _name,
      _purpose,
      _note,
      _binding,
      _expiry,
      _secret,
    ]) {
      if (controller == _secret) controller.clear();
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      switch (action) {
        case 'metadata':
          final expiry = _expiry.text.trim().isEmpty
              ? null
              : DateTime.tryParse(_expiry.text.trim());
          if (_expiry.text.trim().isNotEmpty && expiry == null) {
            throw const FormatException();
          }
          await widget.owner.updateCredentialMetadata(
            c.id,
            c.revision,
            name: _name.text,
            publicPurpose: _purpose.text,
            privateNote: _note.text,
            suggestedBinding: _binding.text,
            discoverable: _public,
            expiresAt: expiry,
          );
        case 'rotate':
          if (c.form == CredentialForm.string) {
            await widget.owner.rotateStringCredential(
              c.id,
              c.revision,
              _secret.text,
            );
          } else {
            if (_file == null) throw const FormatException();
            await widget.owner.rotateFileCredential(
              c.id,
              c.revision,
              bytes: _file!.bytes,
              fileName: _file!.name,
            );
          }
        case 'disable':
          await widget.owner.setCredentialEnabled(c.id, c.revision, false);
        case 'enable':
          await widget.owner.setCredentialEnabled(c.id, c.revision, true);
        case 'delete':
          await widget.owner.deleteCredential(c.id, c.revision);
        case 'restore':
          await widget.owner.restoreCredential(c.id);
      }
      _secret.clear();
      _file = null;
      if (mounted) Navigator.pop(context);
    } on Object {
      if (mounted) setState(() => _error = '凭据变更未保存，原版本仍保留。请核对内容与当前版本后重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _close() {
    if (!_busy) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => Actions(
    actions: {
      DismissIntent: CallbackAction<DismissIntent>(
        onInvoke: (_) {
          _close();
          return null;
        },
      ),
    },
    child: Focus(autofocus: true, skipTraversal: true, child: _dialog(context)),
  );

  Widget _dialog(BuildContext context) {
    final p = UiPalette.of(context), owner = widget.owner;
    Widget paragraph(String text, {String? leadingStrong}) => Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: prototypeCh(context, 14, 48)),
          child: Text.rich(
            TextSpan(
              children: [
                if (leadingStrong != null)
                  TextSpan(
                    text: leadingStrong,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                TextSpan(text: text),
              ],
            ),
            style: prototypeText(context, 14, height: 1.85),
          ),
        ),
      ),
    );
    Widget fact(
      String title,
      String value, {
      bool code = false,
      bool strong = false,
    }) => Container(
      padding: const EdgeInsets.symmetric(vertical: 13),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: p.line)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: prototypeText(context, 13, color: p.muted)),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: prototypeText(
                context,
                13,
                family: code ? 'Consolas' : null,
                weight: strong ? FontWeight.w700 : FontWeight.w400,
              ),
            ),
          ),
        ],
      ),
    );
    return PrototypeDialog(
      flow: true,
      scrollGutter: 0,
      simpleFlow: true,
      title: titles[action]!,
      onClose: _busy ? null : _close,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          paragraph(
            ' · 当前版本 ${c.version} · ${credentialStatus(owner, c)}',
            leadingStrong: c.name,
          ),
          if (action == 'rotate') ...[
            if (c.form == CredentialForm.string)
              credentialInput(
                context,
                '新凭据内容',
                _secret,
                secret: true,
                flow: true,
                key: const ValueKey('credential-new-secret'),
              )
            else
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('新凭据文件', style: prototypeText(context, 13)),
                  const SizedBox(height: 7),
                  Container(
                    padding: const EdgeInsets.all(9),
                    decoration: BoxDecoration(
                      color: p.paper,
                      border: Border.all(color: p.line),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(
                      children: [
                        TextButton(
                          key: const ValueKey('credential-new-file'),
                          style: prototypeButton(
                            context,
                            size: 12,
                            background: p.canvas,
                            side: BorderSide(color: p.muted),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 2,
                            ),
                            radius: 1,
                          ),
                          onPressed: _busy
                              ? null
                              : () async {
                                  try {
                                    final file = await widget.files.choose();
                                    if (mounted && file != null) {
                                      setState(() => _file = file);
                                    }
                                  } on Object {
                                    if (mounted) {
                                      setState(
                                        () => _error =
                                            '文件未导入。请选择 1 字节至 1 MiB 的本机普通文件。',
                                      );
                                    }
                                  }
                                },
                          child: const Text('选择文件'),
                        ),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            _file?.name ?? '未选择任何文件',
                            style: prototypeText(context, 12),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            const SizedBox(height: 14),
            paragraph('新版本会使旧版待启动许可失效。旧秘密加密保留 30 天供用户恢复，不能申请使用。'),
          ],
          if (action == 'metadata') ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: PrototypeCheck(
                      size: 16,
                      key: const ValueKey('credential-discoverable'),
                      value: _public,
                      onChanged: _busy
                          ? null
                          : (v) => setState(() => _public = v!),
                    ),
                  ),
                  Text('允许 Agent 发现此凭据', style: prototypeText(context, 13)),
                ],
              ),
            ),
            fact('公开引用', '${c.id} · v${c.version}', code: true),
            fact('公开名称与用途', '${c.name} · ${c.publicPurpose}', strong: true),
            fact('公开形式与状态', '${c.form.name} · ${credentialStatus(owner, c)}'),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Align(
                alignment: Alignment.centerLeft,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: prototypeCh(context, 13, 48),
                  ),
                  child: Text(
                    '默认关闭；不披露原文、导入源路径和私有备注。关联某信息不自动公开。',
                    style: prototypeText(
                      context,
                      13,
                      color: p.muted,
                      height: 1.85,
                    ),
                  ),
                ),
              ),
            ),
            credentialInput(
              context,
              '到期时间',
              _expiry,
              flow: true,
              key: const ValueKey('credential-expiry'),
              hint: '未设置',
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                style: prototypeButton(context, size: 13, foreground: p.accent),
                onPressed: () => setState(() => _details = !_details),
                child: Text(_details ? '收起名称、用途与私有备注' : '编辑名称、用途与私有备注'),
              ),
            ),
            if (_details) ...[
              credentialInput(context, '名称', _name, maxLength: 60),
              credentialInput(context, '公开用途', _purpose, maxLength: 2000),
              credentialInput(
                context,
                '私有备注',
                _note,
                maxLength: 4000,
                lines: 3,
              ),
              credentialInput(context, '建议绑定名称（可选）', _binding, maxLength: 64),
            ],
          ],
          if (action == 'disable') paragraph('停用保留资料，使待启动许可失效。正在运行的程序不会停止。'),
          if (action == 'enable') paragraph('启用后可重新申请使用；已过期凭据仍需先修改有效期。'),
          if (action == 'delete') ...[
            paragraph('移入凭据回收站 30 天，待启动许可立即失效。关联信息不会删除；离线备份中的副本仍可能保留。'),
            fact('关联信息', '${owner.informationForCredential(c.id).length} 条'),
          ],
          if (action == 'restore')
            paragraph('恢复为停用状态并建立新版本；重新启用并重新申请后才可使用。旧许可不会恢复。'),
          if (_error != null) credentialFlowError(context, _error!),
        ],
      ),
      actions: [
        TextButton(
          style: prototypeSecondary(context),
          onPressed: _busy ? null : _close,
          child: const Text('取消'),
        ),
        TextButton(
          key: const ValueKey('save-credential-management'),
          style: prototypePrimary(context),
          onPressed: _busy ? null : _save,
          child: Text(_busy ? '保存中…' : saveLabels[action]!),
        ),
      ],
    );
  }
}

Future<void> showCredentialRecycle(
  BuildContext context,
  OwnerAccess owner,
) async {
  String? error;
  await showDialog<void>(
    context: context,
    barrierColor: const Color(0x4f241b27),
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, change) => PrototypeDialog(
        flow: true,
        title: '凭据回收站',
        onClose: () => Navigator.pop(dialogContext),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '删除后加密保留 30 天；恢复建立新版本并保持停用。关联信息和历史事实不会因此删除。',
              style: prototypeText(context, 14, height: 1.85),
            ),
            for (final c in owner.recycledCredentials)
              Container(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${c.name} · 版本 ${c.version}',
                        style: prototypeText(context, 14),
                      ),
                    ),
                    TextButton(
                      style: prototypeSecondary(context),
                      onPressed: () async {
                        await showDialog<void>(
                          context: context,
                          barrierColor: const Color(0x4f241b27),
                          builder: (_) => CredentialManagement(
                            owner: owner,
                            credential: c,
                            action: 'restore',
                          ),
                        );
                        change(() => error = null);
                      },
                      child: const Text('恢复'),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      style: prototypeButton(
                        context,
                        size: 13,
                        foreground: UiPalette.of(context).danger,
                      ),
                      onPressed: () async {
                        if (!await prototypeConfirm(
                          context,
                          title: '永久删除凭据？',
                          message:
                              '将清除「${c.name}」的全部托管秘密版本。关联 ${owner.informationForCredential(c.id).length} 条信息；旧许可不会恢复，历史事实保留，离线备份中的副本可能仍存在。',
                          action: '永久删除',
                        )) {
                          return;
                        }
                        try {
                          await owner.permanentlyDeleteCredential(
                            c.id,
                            c.revision,
                          );
                          change(() => error = null);
                        } on Object {
                          change(() => error = '清除失败，秘密材料仍保留，请重试。');
                        }
                      },
                      child: const Text('永久删除'),
                    ),
                  ],
                ),
              ),
            if (owner.recycledCredentials.isEmpty)
              credentialHelp(context, '暂无可恢复的凭据。'),
            if (error != null) credentialHelp(context, error!),
          ],
        ),
      ),
    ),
  );
}

Future<void> showCredentialVersions(
  BuildContext context,
  OwnerAccess owner,
  ManagedCredential credential,
) async {
  String? error;
  await showDialog<void>(
    context: context,
    barrierColor: const Color(0x4f241b27),
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, change) => PrototypeDialog(
        flow: true,
        title: '凭据版本与恢复',
        onClose: () => Navigator.pop(dialogContext),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '旧版本只供用户恢复，加密保留 30 天，不能申请使用。恢复建立停用的新版本。',
              style: prototypeText(context, 14, height: 1.85),
            ),
            for (final v in owner.credentialVersions(credential.id))
              Container(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '版本 ${v.version} · ${v.retiredAt == null ? '当前版本' : '已退休'}',
                        style: prototypeText(context, 14),
                      ),
                    ),
                    if (v.retiredAt != null)
                      TextButton(
                        style: prototypeSecondary(context),
                        onPressed: () async {
                          if (!await prototypeConfirm(
                            context,
                            title: '恢复此凭据版本？',
                            message:
                                '以版本 ${v.version} 的内容建立新版本并保持停用；旧使用许可不会恢复。',
                            action: '恢复为新版本',
                          )) {
                            return;
                          }
                          try {
                            await owner.restoreCredentialVersion(
                              credential.id,
                              owner.credential(credential.id).revision,
                              v.version,
                            );
                            if (dialogContext.mounted) {
                              Navigator.pop(dialogContext);
                            }
                          } on Object {
                            change(() => error = '版本未恢复，请重新核对保留期和当前版本。');
                          }
                        },
                        child: const Text('恢复为新版本'),
                      ),
                  ],
                ),
              ),
            if (error != null) credentialHelp(context, error!),
          ],
        ),
      ),
    ),
  );
}
