import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart';
import 'credential_files.dart';
import 'prototype_dialog.dart';
import 'prototype_ui.dart';
import 'ui_palette.dart';

Widget credentialInput(
  BuildContext context,
  String label,
  TextEditingController controller, {
  Key? key,
  bool secret = false,
  String? hint,
  int? maxLength,
  int lines = 1,
  bool flow = false,
}) {
  final p = UiPalette.of(context);
  return Padding(
    padding: EdgeInsets.only(top: flow ? 10 : 18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: prototypeText(context, 13)),
        SizedBox(height: flow ? 7 : 8),
        TextField(
          key: key,
          controller: controller,
          obscureText: secret,
          enableSuggestions: !secret,
          autocorrect: !secret,
          maxLines: lines,
          maxLength: maxLength,
          buildCounter:
              (
                _, {
                required currentLength,
                required isFocused,
                required maxLength,
              }) => null,
          style: prototypeText(context, flow ? 13 : 14),
          decoration: InputDecoration(
            isDense: true,
            hintText: hint,
            hintStyle: prototypeText(context, 13, color: p.muted),
            contentPadding: flow
                ? const EdgeInsets.all(9)
                : const EdgeInsets.symmetric(horizontal: 12, vertical: 11.5),
            filled: true,
            fillColor: flow ? p.paper : p.rail,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(4),
              borderSide: BorderSide(color: p.line),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(4),
              borderSide: BorderSide(color: p.line),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(4),
              borderSide: BorderSide(color: p.accent),
            ),
          ),
        ),
      ],
    ),
  );
}

Widget credentialHelp(BuildContext context, String text) => Padding(
  padding: const EdgeInsets.only(top: 8),
  child: Text(
    text,
    style: prototypeText(
      context,
      13,
      color: UiPalette.of(context).muted,
      height: 1.8,
    ),
  ),
);
Widget credentialFlowError(BuildContext context, String text) => Semantics(
  liveRegion: true,
  child: Container(
    margin: const EdgeInsets.symmetric(vertical: 16),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: UiPalette.of(context).rail,
      border: Border.all(color: UiPalette.of(context).line),
    ),
    child: Text(
      text,
      style: prototypeText(
        context,
        13,
        color: const Color(0xff8b3c37),
        height: 1.8,
      ),
    ),
  ),
);

class CredentialEditor extends StatefulWidget {
  const CredentialEditor({
    super.key,
    required this.owner,
    this.files = const NativeCredentialFilePicker(),
  });
  final OwnerAccess owner;
  final CredentialFilePicker files;
  @override
  State<CredentialEditor> createState() => _CredentialEditorState();
}

class _CredentialEditorState extends State<CredentialEditor> {
  final _name = TextEditingController(),
      _secret = TextEditingController(),
      _binding = TextEditingController(text: 'SERVICE_TOKEN');
  CredentialForm _form = CredentialForm.string;
  SelectedCredentialFile? _file;
  bool _busy = false, _importing = false;
  bool get _dirty =>
      _name.text.isNotEmpty ||
      _secret.text.isNotEmpty ||
      _file != null ||
      _binding.text !=
          (_form == CredentialForm.file ? 'CREDENTIAL_FILE' : 'SERVICE_TOKEN');
  String? _error;
  @override
  void dispose() {
    _name.dispose();
    _secret.dispose();
    _binding.dispose();
    super.dispose();
  }

  Future<void> _close() async {
    if (_busy) return;
    if (_dirty &&
        !await prototypeConfirm(
          context,
          title: '放弃未保存的凭据？',
          message: '凭据尚未保存。取消会保留当前输入；放弃后清除草稿。',
          action: '放弃更改',
        )) {
      return;
    }
    if (mounted) Navigator.pop(context);
  }

  Future<void> _choose() async {
    setState(() {
      _busy = true;
      _importing = true;
      _error = null;
    });
    try {
      final file = await widget.files.choose();
      if (mounted && file != null) {
        setState(() {
          _file = file;
        });
      }
    } on Object {
      if (mounted) setState(() => _error = '文件未导入。请选择 1 字节至 1 MiB 的本机普通文件。');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _importing = false;
        });
      }
    }
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final c = _form == CredentialForm.string
          ? await widget.owner.createStringCredential(
              name: _name.text,
              publicPurpose: 'API Token',
              secret: _secret.text,
              suggestedBinding: _binding.text,
            )
          : await widget.owner.createFileCredential(
              name: _name.text,
              publicPurpose: '凭据文件',
              fileName: _file!.name,
              bytes: _file!.bytes,
              suggestedBinding: _binding.text,
            );
      _secret.clear();
      _file = null;
      if (mounted) Navigator.pop(context, c);
    } on Object {
      if (mounted) setState(() => _error = '凭据未保存。原有内容未改变，请检查名称、内容和别名后重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = UiPalette.of(context);
    final ready =
        _name.text.trim().isNotEmpty &&
        (_form == CredentialForm.string
            ? _secret.text.isNotEmpty
            : _file != null) &&
        RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,63}$').hasMatch(_binding.text);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: PrototypeDialog(
        width: 650,
        actionDivider: false,
        actionPaddingTop: 22,
        title: '添加凭据',
        onClose: _busy ? null : _close,
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                for (final form in CredentialForm.values) ...[
                  if (form == CredentialForm.file) const SizedBox(width: 12),
                  Expanded(
                    child: TextButton(
                      key: ValueKey('credential-form-${form.name}'),
                      onPressed: _busy
                          ? null
                          : () => setState(() {
                              _form = form;
                              _binding.text = form == CredentialForm.file
                                  ? 'CREDENTIAL_FILE'
                                  : 'SERVICE_TOKEN';
                            }),
                      style: prototypeButton(
                        context,
                        background: _form == form ? p.selected : p.paper,
                        side: BorderSide(
                          color: _form == form ? p.accent : p.line,
                        ),
                        radius: 5,
                        padding: const EdgeInsets.all(16),
                      ),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              form == CredentialForm.string ? '字符串' : '文件',
                              style: prototypeText(
                                context,
                                14,
                                weight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              form == CredentialForm.string
                                  ? 'Token、密码等秘密文本'
                                  : 'SSH 私钥、证书、Cookie 文件',
                              style: prototypeText(context, 12, color: p.muted),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
            credentialInput(
              context,
              '凭据名称',
              _name,
              key: const ValueKey('credential-name'),
              hint: '例如：测试服务器部署密钥',
              maxLength: 60,
            ),
            if (_form == CredentialForm.string)
              credentialInput(
                context,
                '凭据内容',
                _secret,
                key: const ValueKey('credential-secret'),
                secret: true,
                hint: '输入 Token 或秘密值',
              )
            else
              Padding(
                padding: const EdgeInsets.only(top: 18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('凭据文件', style: prototypeText(context, 13)),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 11,
                      ),
                      decoration: BoxDecoration(
                        color: p.rail,
                        border: Border.all(color: p.line),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Row(
                        children: [
                          TextButton(
                            key: const ValueKey('choose-credential-file'),
                            onPressed: _busy ? null : _choose,
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
              ),
            credentialHelp(
              context,
              _form == CredentialForm.file
                  ? '保存文件内容的独立副本。更改原文件不会自动更新凭据，也不会自动删除原文件。'
                  : '使用时注入进程环境变量，不通过聊天或普通读取接口交出原文。',
            ),
            credentialInput(
              context,
              _form == CredentialForm.file ? '文件引用别名' : '建议环境变量名',
              _binding,
              key: const ValueKey('credential-binding'),
              maxLength: 64,
            ),
            credentialHelp(
              context,
              '别名可用字母、数字和下划线；环境变量建议用大写字母。这里只保存建议；每次申请另行声明参数位置或目标程序认识的环境变量名。',
            ),
            if (_error != null) credentialFlowError(context, _error!),
          ],
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : _close,
            style: prototypeSecondary(context),
            child: const Text('取消'),
          ),
          TextButton(
            key: const ValueKey('save-credential'),
            onPressed: !_busy && ready ? _save : null,
            style: prototypePrimary(context).copyWith(
              foregroundColor: WidgetStatePropertyAll(p.paper),
              backgroundColor: WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.disabled)
                    ? Color.lerp(p.paper, p.accent, .45)
                    : p.accent,
              ),
            ),
            child: Text(_busy ? (_importing ? '导入中…' : '保存中…') : '保存凭据'),
          ),
        ],
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    for (final c in [_name, _secret, _binding]) {
      c.addListener(() {
        if (mounted) setState(() {});
      });
    }
  }
}

Future<void> manageCredentialLinks(
  BuildContext context,
  OwnerAccess owner,
  InformationItem item,
) async {
  final selected = owner
      .credentialsForInformation(item.id)
      .map((c) => c.id)
      .toSet();
  final revisions = {for (final c in owner.credentials) c.id: c.revision};
  String? error;
  bool busy = false;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    barrierColor: const Color(0x4f241b27),
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, change) => PrototypeDialog(
        width: 650,
        title: '关联凭据',
        onClose: busy ? null : () => Navigator.pop(dialogContext),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '为「${item.name}」选择可引用的凭据。关联后，使用仍需单独授权。',
              style: prototypeText(context, 14, height: 1.8),
            ),
            for (final c in owner.credentials)
              Container(
                margin: const EdgeInsets.only(top: 10),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  border: Border.all(color: UiPalette.of(context).line),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: 17,
                      height: 17,
                      child: Theme(
                        data:
                            owner.credentialAvailability(c) !=
                                    CredentialAvailability.available &&
                                !selected.contains(c.id)
                            ? Theme.of(context).copyWith(
                                extensions: [
                                  UiPalette.of(
                                    context,
                                  ).copyWith(muted: const Color(0xffb8b8b8)),
                                ],
                                checkboxTheme: Theme.of(context).checkboxTheme
                                    .copyWith(
                                      fillColor:
                                          WidgetStateProperty.resolveWith(
                                            (states) =>
                                                states.contains(
                                                  WidgetState.selected,
                                                )
                                                ? null
                                                : const Color(0xffefefef),
                                          ),
                                    ),
                              )
                            : Theme.of(context),
                        child: PrototypeCheck(
                          size: 17,
                          key: ValueKey('credential-link-${c.id}'),
                          value: selected.contains(c.id),
                          onChanged: busy
                              ? null
                              : (v) => change(
                                  () => v == true
                                      ? selected.add(c.id)
                                      : selected.remove(c.id),
                                ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            c.name,
                            style: prototypeText(
                              context,
                              14,
                              weight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            '${c.publicPurpose} · ${c.form == CredentialForm.file ? '文件' : '字符串'}',
                            style: prototypeText(context, 12),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        vertical: 2,
                        horizontal: 8,
                      ),
                      decoration: BoxDecoration(
                        color: UiPalette.of(context).paper,
                        border: Border.all(color: UiPalette.of(context).line),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        credentialStatus(owner, c),
                        style: prototypeText(
                          context,
                          11,
                          color: UiPalette.of(context).muted,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            if (owner.credentials.isEmpty)
              credentialHelp(context, '尚无凭据，请先在凭据库添加。'),
            if (error != null) credentialFlowError(context, error!),
            const SizedBox(height: 22),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  style: prototypeSecondary(context),
                  onPressed: busy ? null : () => Navigator.pop(dialogContext),
                  child: const Text('取消'),
                ),
                const SizedBox(width: 12),
                TextButton(
                  key: const ValueKey('credential-save-links'),
                  style: prototypePrimary(context),
                  onPressed: busy
                      ? null
                      : () async {
                          change(() {
                            busy = true;
                            error = null;
                          });
                          try {
                            await owner.setInformationCredentialLinks(
                              item.id,
                              selected.toList(),
                              expectedRevisions: revisions,
                            );
                            if (dialogContext.mounted) {
                              Navigator.pop(dialogContext);
                            }
                          } on Object {
                            change(() {
                              busy = false;
                              error = '关联未保存，请重新核对后重试。';
                            });
                          }
                        },
                  child: const Text('保存关联'),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

String credentialStatus(OwnerAccess owner, ManagedCredential c) =>
    switch (owner.credentialAvailability(c)) {
      CredentialAvailability.available => '可用',
      CredentialAvailability.disabled => '已停用',
      CredentialAvailability.expired => '已过期',
      CredentialAvailability.deleted => '回收站',
    };
