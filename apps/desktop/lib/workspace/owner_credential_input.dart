import 'package:flutter/material.dart';
import '../credential_files.dart';
import '../desktop_controls.dart';
import '../ui_palette.dart';
import 'library_widgets.dart';
import 'dart:async';
import 'workspace_source.dart';

/// The Host owns this editor and its plaintext controller. Only staged opaque
/// metadata leaves the dialog for the generic credential form.
Future<WorkspaceCredentialCandidate?> showOwnerCredentialInput(
  BuildContext context,
  CredentialInputStaging staging,
  WorkspaceCredentialForm? requiredForm, {
  CredentialFilePicker files = const NativeCredentialFilePicker(),
}) => showDesktopDialog<WorkspaceCredentialCandidate>(
  context,
  builder: (_) =>
      _Input(staging: staging, requiredForm: requiredForm, files: files),
);

class _Input extends StatefulWidget {
  const _Input({
    required this.staging,
    required this.requiredForm,
    required this.files,
  });
  final CredentialInputStaging staging;
  final WorkspaceCredentialForm? requiredForm;
  final CredentialFilePicker files;
  @override
  State<_Input> createState() => _InputState();
}

class _InputState extends State<_Input> {
  final _secret = TextEditingController();
  late WorkspaceCredentialForm _form =
      widget.requiredForm ?? WorkspaceCredentialForm.string;
  SelectedCredentialFile? _file;
  String? _error;
  bool _picking = false;
  bool _completed = false;
  @override
  void dispose() {
    if (!_completed) {
      unawaited(
        Future<void>.sync(
          widget.staging.cancelPending,
        ).catchError((Object _) {}),
      );
    }
    _secret.clear();
    _secret.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    if (_picking) return;
    setState(() {
      _picking = true;
      _error = null;
    });
    try {
      widget.staging.check();
      final result = await widget.files.choose();
      if (!mounted) return;
      widget.staging.check();
      if (result != null) setState(() => _file = result);
    } catch (_) {
      if (mounted) setState(() => _error = '文件未能读取，请重新选择；尚未保存凭据。');
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _complete() async {
    if (_picking) return;
    setState(() {
      _picking = true;
      _error = null;
    });
    try {
      final result = _form == WorkspaceCredentialForm.string
          ? await widget.staging.string(_secret.text)
          : _file == null
          ? throw const WorkspaceFailure('validation', '请先选择凭据文件。')
          : await widget.staging.file(_file!);
      if (!mounted) {
        await widget.staging.release(result.id);
        return;
      }
      _completed = true;
      Navigator.pop(context, result);
    } catch (error) {
      if (!mounted) return;
      setState(
        () =>
            _error = error is WorkspaceFailure ? error.message : '输入未能保留，请重试。',
      );
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  @override
  Widget build(BuildContext context) => DesktopDialog(
    title: const Text('输入凭据材料'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.requiredForm == null) ...[
          Wrap(
            spacing: 8,
            children: [
              for (final form in WorkspaceCredentialForm.values)
                DesktopButton(
                  selected: _form == form,
                  onPressed: _picking
                      ? null
                      : () => setState(() {
                          _form = form;
                          _secret.clear();
                          _file = null;
                          _error = null;
                        }),
                  child: Text(
                    form == WorkspaceCredentialForm.string ? '字符串' : '文件',
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
        ],
        if (_form == WorkspaceCredentialForm.string)
          DesktopTextField(
            key: const ValueKey('owner-credential-secret'),
            controller: _secret,
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            maxLength: 65536,
            decoration: const InputDecoration(labelText: '密码或凭据内容'),
          )
        else ...[
          DesktopButton(
            key: const ValueKey('owner-credential-pick-file'),
            busy: _picking,
            onPressed: _picking ? null : _pick,
            child: const Text('选择凭据文件'),
          ),
          if (_file != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('${_file!.name} · ${_file!.bytes.length}字节'),
            ),
        ],
        const SizedBox(height: 12),
        Text(
          '完成输入后返回凭据表单；点击保存后才会入库。',
          style: libraryText(context, 13, color: UiPalette.of(context).muted),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              _error!,
              style: libraryText(
                context,
                13,
                color: UiPalette.of(context).danger,
              ),
            ),
          ),
      ],
    ),
    actions: [
      DesktopButton(
        key: const ValueKey('owner-credential-input-cancel'),
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      DesktopButton(
        key: const ValueKey('owner-credential-input-complete'),
        kind: DesktopButtonKind.primary,
        onPressed: _picking ? null : _complete,
        child: const Text('完成输入'),
      ),
    ],
  );
}
