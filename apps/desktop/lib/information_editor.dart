import 'desktop_controls.dart';
import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart';
import 'prototype_dialog.dart';
import 'organization_selectors.dart';
import 'prototype_ui.dart';
import 'ui_palette.dart';
import 'information_editor_draft.dart';
export 'information_editor_draft.dart';
import 'information_files.dart';
import 'information_file_summary.dart';

typedef SaveInformationDraft =
    Future<void> Function(InformationEditorDraft draft);

Future<InformationItem?> showOwnerInformationEditor(
  BuildContext context, {
  required OwnerAccess owner,
  required InformationEditorDraft draft,
  InformationFilePicker files = const NativeInformationFilePicker(),
  String? title,
}) async {
  final session = OwnerInformationEditorSession(owner, files);
  InformationItem? saved;
  try {
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      barrierColor: const Color(0x4f241b27),
      builder: (_) => InformationEditor(
        draft: draft,
        title: title,
        directories: owner.directories,
        tags: owner.tags,
        templates: owner.templates,
        fileSession: session,
        onSave: (d) async => saved = await session.save(d),
      ),
    );
  } finally {
    await session.close();
  }
  return saved;
}

class InformationEditor extends StatefulWidget {
  const InformationEditor({
    super.key,
    required this.draft,
    required this.onSave,
    this.directories = const [],
    this.tags = const [],
    this.templates = const [],
    this.title,
    this.saveLabel = '保存信息',
    this.fileSession,
  });
  final InformationEditorDraft draft;
  final SaveInformationDraft onSave;
  final List<InformationDirectory> directories;
  final List<InformationTag> tags;
  final List<InformationTemplate> templates;
  final String? title;
  final String saveLabel;
  final OwnerInformationEditorSession? fileSession;
  @override
  State<InformationEditor> createState() => _InformationEditorState();
}

class _InformationEditorState extends State<InformationEditor> {
  bool _dirty = false, _saving = false, _leaving = false;
  bool _fileWorking = false, _committed = false;
  bool get _busy => _saving || _leaving || _fileWorking || _committed;
  final _fileErrors = <EditableInformationField, String>{};
  String? _error;
  FocusNode? _lastEditorFocus;
  int _templateRevision = 0;
  InformationEditorDraft get d => widget.draft;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_rememberEditorFocus);
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_rememberEditorFocus);
    _lastEditorFocus = null;
    super.dispose();
  }

  bool _isEditorFocus(FocusNode? node) {
    if (node == null ||
        node is FocusScopeNode ||
        node.context?.mounted != true) {
      return false;
    }
    var inside = identical(node.context, context);
    node.context!.visitAncestorElements((element) {
      inside = identical(element, context);
      return !inside;
    });
    return inside;
  }

  void _rememberEditorFocus() {
    if (_busy || !mounted) return;
    final node = FocusManager.instance.primaryFocus;
    if (_isEditorFocus(node)) _lastEditorFocus = node;
  }

  FocusNode? _captureEditorFocus() {
    final current = FocusManager.instance.primaryFocus;
    // Native/AX activation can first move focus to the dialog scope. A scope
    // is not the originating editor control to restore after cancellation.
    return _isEditorFocus(current) ? current : _lastEditorFocus;
  }

  void _changed(VoidCallback change) => setState(() {
    change();
    _dirty = true;
  });

  void _restoreFocus(FocusNode? previous) {
    if (!mounted || previous == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          ModalRoute.of(context)?.isCurrent == true &&
          previous.context?.mounted == true &&
          previous.canRequestFocus) {
        previous.requestFocus();
      }
    });
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    required String action,
  }) async {
    final previousFocus = _captureEditorFocus();
    // Do not leave a focused editor control becoming disabled underneath a
    // newly mounted confirmation. Cancelling returns focus to that control.
    FocusScope.of(context).unfocus();
    setState(() => _leaving = true);
    final confirmed = await prototypeConfirm(
      context,
      title: title,
      message: message,
      action: action,
    );
    if (!mounted) return false;
    setState(() => _leaving = false);
    if (!confirmed) _restoreFocus(previousFocus);
    return confirmed;
  }

  Future<void> _close() async {
    if (_saving || _leaving || _fileWorking) return;
    if (_dirty && !_committed) {
      final discard = await _confirm(
        title: '放弃未保存的更改？',
        message: '更改尚未保存。取消会继续保留当前输入，放弃后返回信息库。',
        action: '放弃更改',
      );
      if (!discard) return;
    }
    if (!mounted) return;
    setState(() => _leaving = true);
    try {
      await widget.fileSession?.close();
      if (mounted) Navigator.pop(context, _committed);
    } catch (_) {
      if (mounted) {
        setState(() {
          _leaving = false;
          _error = '暂存清理未完成，请再次取消以重试。原信息不会被删除。';
        });
      }
    }
  }

  Future<void> _save() async {
    if (_saving || _leaving || _fileWorking) return;
    if (_committed) {
      await _close();
      return;
    }
    if (d.name.trim().isEmpty ||
        d.fields.isEmpty ||
        d.fields.any((f) => f.name.trim().isEmpty)) {
      setState(() => _error = '请填写信息名称，并至少保留一个有名称的字段。');
      return;
    }
    final missing = d.fields.where(
      (f) => f.kind == FieldKind.file && !f.hasFile,
    );
    if (missing.isNotEmpty) {
      setState(() {
        for (final field in missing) {
          _fileErrors[field] = '请为这个字段选择一份文件。';
        }
        _error = '仍有文件字段未选择文件。';
      });
      return;
    }
    if (d.fields.any(_fileErrors.containsKey)) {
      setState(() => _error = '请重新选择文件，或明确选择继续使用原文件。');
      return;
    }
    final destructive = d.destructiveChanges;
    // Also prevent a second click while the identity confirmation is open.
    if (destructive > 0) {
      final confirmed = await _confirm(
        title: '确认字段身份变化',
        message:
            '$destructive 个字段将删除或被新含义替换。旧字段进入回收站，新增或恢复的字段需要重新授权；现有授权不会自动扩大。',
        action: '确认保存',
      );
      if (!confirmed) return;
    }
    if (!mounted) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSave(d);
      _committed = true;
      try {
        await widget.fileSession?.close();
      } catch (_) {
        if (mounted) {
          setState(() {
            _saving = false;
            _error = '信息已保存，剩余暂存清理未完成。请重试清理并关闭。';
          });
        }
        return;
      }
      if (mounted) Navigator.pop(context, true);
    } on AccessFailure catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = informationFileError(e);
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '保存失败，信息库未改变。输入已保留，请重试。';
        });
      }
    }
  }

  Widget _input(
    String label,
    String value,
    ValueChanged<String> update, {
    Key? key,
    int lines = 1,
    int max = 200,
    bool readOnly = false,
  }) => Padding(
    padding: EdgeInsets.only(top: 10, bottom: lines == 1 ? 10 : 4.5),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 19.5 * MediaQuery.textScalerOf(context).scale(1),
          child: Text(label, style: prototypeText(context, 13)),
        ),
        const SizedBox(height: 7),
        SizedBox(
          height: 19.5 * lines * MediaQuery.textScalerOf(context).scale(1) + 20,
          child: TextFormField(
            key: key,
            initialValue: value,
            enabled: !_busy && !readOnly,
            maxLength: max,
            minLines: lines,
            maxLines: lines == 1 ? 1 : 6,
            onChanged: (v) => _changed(() => update(v)),
            style: prototypeText(context, 13),
            buildCounter:
                (_, {required currentLength, required isFocused, maxLength}) =>
                    null,
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 6,
                vertical: 10,
              ),
              filled: true,
              fillColor: UiPalette.of(context).paper,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(4),
                borderSide: BorderSide(color: UiPalette.of(context).line),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(4),
                borderSide: BorderSide(color: UiPalette.of(context).line),
              ),
            ),
          ),
        ),
      ],
    ),
  );
  Widget _select<T>(
    String label,
    T? value,
    List<DropdownMenuItem<T>> items,
    ValueChanged<T?> change, {
    Key? key,
    bool showChevron = false,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 19.5 * MediaQuery.textScalerOf(context).scale(1),
          child: Text(label, style: prototypeText(context, 13)),
        ),
        const SizedBox(height: 7),
        SizedBox(
          height: 19.5 * MediaQuery.textScalerOf(context).scale(1) + 20,
          child: DesktopSelect<T>(
            key: key,
            initialValue: value,
            items: items,
            isExpanded: true,
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 6,
                vertical: 9,
              ),
              filled: true,
              fillColor: UiPalette.of(context).paper,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(3),
                borderSide: BorderSide(color: UiPalette.of(context).line),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(3),
                borderSide: BorderSide(color: UiPalette.of(context).line),
              ),
            ),
            onChanged: _busy ? null : (v) => _changed(() => change(v)),
          ),
        ),
      ],
    ),
  );
  @override
  Widget build(BuildContext context) => Actions(
    actions: {
      // A non-dismissible modal barrier also disables Flutter's default Escape
      // action. Use the same guarded close/confirmation/cleanup as the buttons.
      DismissIntent: CallbackAction<DismissIntent>(onInvoke: (_) => _close()),
    },
    child: _dialog(context),
  );

  Widget _dialog(BuildContext context) {
    final p = UiPalette.of(context);
    return PopScope(
      canPop: widget.fileSession == null && !_dirty && !_busy,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: PrototypeDialog(
        flow: true,
        title: widget.title ?? (d.original == null ? '新建信息' : '编辑信息'),
        onClose: _saving || _leaving || _fileWorking ? null : _close,
        body: Column(
          key: ValueKey(_templateRevision),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (d.original == null && widget.templates.isNotEmpty)
              _select<String>(
                '套用模板',
                null,
                [
                  const DropdownMenuItem(value: null, child: Text('手动新建')),
                  for (final template in widget.templates)
                    DropdownMenuItem(
                      value: template.id,
                      child: Text(template.name),
                    ),
                ],
                (id) {
                  if (id != null) {
                    _applyTemplate(
                      widget.templates.firstWhere((t) => t.id == id),
                    );
                  }
                },
                key: const ValueKey('new-template'),
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _input(
                    '信息名称',
                    d.name,
                    (v) => d.name = v,
                    key: const ValueKey('item-name'),
                  ),
                ),
                const SizedBox(width: 15),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text('所在目录', style: prototypeText(context, 13)),
                        const SizedBox(height: 7),
                        DirectoryField(
                          key: const ValueKey('item-directory'),
                          directories: widget.directories,
                          value: d.directoryId,
                          enabled: !_busy,
                          onChanged: (id) => _changed(() {
                            d.directoryId = id;
                            d.suggestedDirectory = '';
                          }),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            if (d.suggestedDirectory.isNotEmpty)
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 12,
                children: [
                  Text(
                    'Agent 建议创建目录：${d.suggestedDirectory}',
                    style: prototypeText(context, 12, color: p.muted),
                  ),
                  TextButton(
                    style: prototypeButton(context, size: 12),
                    onPressed: () => _changed(() => d.suggestedDirectory = ''),
                    child: const Text('忽略目录建议'),
                  ),
                ],
              ),
            _input(
              '公开说明',
              d.description,
              (v) => d.description = v,
              key: const ValueKey('item-description'),
              lines: 2,
              max: 2000,
            ),
            Padding(
              padding: const EdgeInsets.only(top: 10, bottom: 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    height: 19.5 * MediaQuery.textScalerOf(context).scale(1),
                    child: Text('标签', style: prototypeText(context, 13)),
                  ),
                  const SizedBox(height: 7),
                  TextButton(
                    key: const ValueKey('item-tags'),
                    onPressed: _busy ? null : _chooseTags,
                    style: prototypeButton(
                      context,
                      size: 13,
                      padding: const EdgeInsets.all(9),
                      foreground: p.ink,
                      side: BorderSide(color: p.line),
                    ),
                    child: SizedBox(
                      height:
                          19.5 * MediaQuery.textScalerOf(context).scale(1) + 2,
                      width: double.infinity,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          widget.tags
                              .where((tag) => d.tagIds.contains(tag.id))
                              .map((tag) => tag.name)
                              .followedBy(
                                d.tagIds
                                    .where(
                                      (id) => !widget.tags.any(
                                        (tag) => tag.id == id,
                                      ),
                                    )
                                    .map((id) => '不可用标签（$id）'),
                              )
                              .followedBy(d.suggestedTags)
                              .join('、'),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                '信息字段',
                style: prototypeText(context, 16, weight: FontWeight.w600),
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: prototypeCh(context, 13, 48),
                ),
                child: Text(
                  '字段内容会按读取授权返回给 Agent。Token 和密钥请单独保存为凭据并建立关联。',
                  style: prototypeText(
                    context,
                    13,
                    height: 1.85,
                    color: p.muted,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10.3),
            for (var i = 0; i < d.fields.length; i++) _field(i),
            Wrap(
              spacing: 12,
              children: [
                TextButton(
                  key: const ValueKey('add-field'),
                  style: prototypeButton(
                    context,
                    size: 13,
                    foreground: p.ink,
                    background: p.paper,
                    side: BorderSide(color: p.line),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                  ),
                  onPressed: _busy
                      ? null
                      : () => _changed(
                          () => d.fields.add(EditableInformationField()),
                        ),
                  child: const Text('＋ 添加字段'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                barrierColor: const Color(0x4f241b27),
                builder: (_) => PrototypeDialog(
                  title: 'Agent 可见的公开目录',
                  onClose: () => Navigator.pop(context),
                  body: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        d.name,
                        style: prototypeText(
                          context,
                          16,
                          weight: FontWeight.w600,
                        ),
                      ),
                      Text(d.description),
                      for (final f in d.fields)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Text(
                            '${f.name}${f.kind == FieldKind.file ? ' · 文件' : ''}\n${f.description}',
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              style: prototypeButton(context, size: 12, foreground: p.accent),
              child: const Text('预览公开目录'),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _error!,
                  style: prototypeText(context, 13, color: p.danger),
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            style: prototypeSecondary(context),
            onPressed: _saving || _leaving || _fileWorking ? null : _close,
            child: const Text('取消'),
          ),
          TextButton(
            style: prototypePrimary(context),
            key: const ValueKey('save-information'),
            onPressed: _saving || _leaving || _fileWorking ? null : _save,
            child: _committed
                ? const Text('重试清理并关闭')
                : _saving
                ? const Text('正在保存…')
                : widget.saveLabel.startsWith('保存') &&
                      widget.saveLabel.length > 2
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('保存'),
                      const SizedBox(width: 18),
                      Text(widget.saveLabel.substring(2)),
                    ],
                  )
                : Text(widget.saveLabel),
          ),
        ],
      ),
    );
  }

  Future<void> _chooseTags() async {
    final selected = d.tagIds.toSet();
    final suggestions = d.suggestedTags.toSet();
    final applied = await showDialog<bool>(
      context: context,
      barrierColor: const Color(0x4f241b27),
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) => PrototypeDialog(
          title: '选择标签',
          onClose: () => Navigator.pop(dialogContext, false),
          body: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: 260,
                child: TagPicker(
                  tags: widget.tags,
                  selected: selected,
                  onChanged: (ids) => update(() {
                    selected
                      ..clear()
                      ..addAll(ids);
                  }),
                ),
              ),
              for (final id
                  in selected
                      .where((id) => !widget.tags.any((t) => t.id == id))
                      .toList())
                TextButton(
                  onPressed: () => update(() => selected.remove(id)),
                  child: Text('移除不可用标签（$id）'),
                ),
              for (final name in d.suggestedTags)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      PrototypeCheck(
                        value: suggestions.contains(name),
                        onChanged: (value) => update(
                          () => value == true
                              ? suggestions.add(name)
                              : suggestions.remove(name),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextButton(
                          style: prototypeButton(context, size: 13),
                          onPressed: () => update(
                            () => suggestions.contains(name)
                                ? suggestions.remove(name)
                                : suggestions.add(name),
                          ),
                          child: Text('Agent 建议：$name'),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          actions: [
            TextButton(
              style: prototypePrimary(context),
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('使用所选标签'),
            ),
          ],
        ),
      ),
    );
    if (applied == true && mounted) {
      _changed(() {
        d.tagIds
          ..clear()
          ..addAll(selected);
        d.suggestedTags
          ..clear()
          ..addAll(suggestions);
      });
    }
  }

  Future<void> _fileAction(
    Future<void> Function() action, {
    EditableInformationField? field,
  }) async {
    if (_busy) return;
    setState(() {
      _fileWorking = true;
      _error = null;
      if (field != null) _fileErrors.remove(field);
    });
    try {
      await action();
    } catch (error) {
      if (mounted) {
        setState(() {
          if (field != null) {
            _fileErrors[field] = informationFileError(error);
          } else {
            _error = informationFileError(error);
          }
        });
      }
    } finally {
      if (mounted) setState(() => _fileWorking = false);
    }
  }

  Future<void> _applyTemplate(InformationTemplate template) =>
      _fileAction(() async {
        await widget.fileSession?.reset();
        if (mounted) {
          _changed(() {
            d.applyTemplate(template);
            _fileErrors.clear();
            _templateRevision++;
          });
        }
      });

  Future<void> _changeKind(EditableInformationField field, FieldKind kind) =>
      _fileAction(() async {
        if (field.stage != null) await widget.fileSession?.release(field);
        if (mounted) _changed(() => field.kind = kind);
      }, field: field);

  Future<void> _removeField(EditableInformationField field) =>
      _fileAction(() async {
        if (field.stage != null) await widget.fileSession?.release(field);
        if (mounted) _changed(() => d.fields.remove(field));
      }, field: field);

  Future<void> _chooseFile(EditableInformationField field) async {
    if (_busy) return;
    final previousFocus = _captureEditorFocus();
    await _fileAction(() async {
      final changed = await widget.fileSession!.choose(field);
      if (changed && mounted) _changed(() {});
    }, field: field);
    _restoreFocus(previousFocus);
  }

  Widget _fileControl(EditableInformationField field, int index) {
    final p = UiPalette.of(context), stage = field.stage;
    return AnimatedSize(
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 140),
      alignment: Alignment.topLeft,
      child: Container(
        key: ValueKey('file-control-$index'),
        margin: const EdgeInsets.symmetric(vertical: 10),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: p.rail,
          border: Border.all(color: p.line),
          borderRadius: BorderRadius.circular(5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (stage != null) ...[
              Text(
                stage.originalName,
                style: prototypeText(context, 14, weight: FontWeight.w600),
              ),
              Text(
                '${informationFileSize(stage.byteLength)} · ${stage.mediaType} · 待保存',
                style: prototypeText(context, 13, color: p.muted, height: 1.8),
              ),
            ] else if (field.retainedFile != null && widget.fileSession != null)
              InformationFileSummary(
                owner: widget.fileSession!.owner,
                reference: field.retainedFile!,
              )
            else ...[
              Text(
                field.retainedFile == null ? '选择原文件' : '保留原文件与版本',
                style: prototypeText(context, 14, weight: FontWeight.w600),
              ),
              Text(
                '每个文件字段保存一份文件',
                style: prototypeText(context, 13, color: p.muted),
              ),
            ],
            if (widget.fileSession != null) ...[
              const SizedBox(height: 8),
              Text('选择或更换文件', style: prototypeText(context, 13)),
              Container(
                margin: const EdgeInsets.only(top: 4, bottom: 8),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: p.paper,
                  border: Border.all(color: p.line),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  children: [
                    TextButton(
                      key: ValueKey('choose-file-$index'),
                      style: prototypeButton(
                        context,
                        size: 13,
                        foreground: p.ink,
                        background: p.paper,
                        side: BorderSide(color: p.line),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                      ),
                      onPressed: _busy ? null : () => _chooseFile(field),
                      child: const Text('选择文件'),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _fileWorking
                            ? '正在处理文件…'
                            : stage?.originalName ?? '未选择新的文件',
                        style: prototypeText(context, 13),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (_fileErrors[field] case final error?) ...[
              Text(error, style: prototypeText(context, 13, color: p.danger)),
              if (field.hasFile)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    style: prototypeButton(context, size: 12),
                    onPressed: _busy
                        ? null
                        : () => setState(() => _fileErrors.remove(field)),
                    child: const Text('继续使用原文件'),
                  ),
                ),
            ],
            Text(
              widget.fileSession == null
                  ? '保留已有文件。添加或更换原文件请到信息库操作。'
                  : '原文件保留在原位置。SSH 私钥、Token 请保存为凭据。',
              style: prototypeText(context, 13, height: 1.85, color: p.muted),
            ),
            const SizedBox(height: 13),
          ],
        ),
      ),
    );
  }

  Widget _field(int index) {
    final f = d.fields[index], p = UiPalette.of(context);
    return Container(
      key: ObjectKey(f),
      padding: const EdgeInsets.only(top: 13, bottom: 13),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: p.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _input(
                  '字段名称',
                  f.name,
                  (v) => f.name = v,
                  key: ValueKey('field-name-$index'),
                  readOnly:
                      f.kind == FieldKind.file && widget.fileSession == null,
                ),
              ),
              const SizedBox(width: 15),
              Expanded(
                flex: 2,
                child: _select<FieldKind>(
                  '字段类型',
                  f.kind,
                  [
                    const DropdownMenuItem(
                      value: FieldKind.structured,
                      child: Text('结构化字段'),
                    ),
                    const DropdownMenuItem(
                      value: FieldKind.textNote,
                      child: Text('受控说明'),
                    ),
                    DropdownMenuItem(
                      value: FieldKind.file,
                      enabled:
                          widget.fileSession != null ||
                          f.kind == FieldKind.file,
                      child: const Text('文件'),
                    ),
                  ],
                  (kind) {
                    if (kind != null) _changeKind(f, kind);
                  },
                  key: ValueKey('field-kind-$index'),
                  showChevron: true,
                ),
              ),
            ],
          ),
          if (f.kind == FieldKind.file)
            _fileControl(f, index)
          else
            _input(
              f.kind == FieldKind.textNote ? '受控文本说明' : '字段内容',
              f.value,
              (v) => f.value = v,
              key: ValueKey('field-value-$index'),
              lines: f.kind == FieldKind.textNote ? 3 : 1,
              max: 1000000,
            ),
          _input(
            '字段公开说明',
            f.description,
            (v) => f.description = v,
            key: ValueKey('field-description-$index'),
            max: 2000,
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              style: prototypeButton(
                context,
                size: 13,
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 10,
                ),
                foreground: p.accent,
              ),
              onPressed: _busy ? null : () => _removeField(f),
              child: const Text('移除字段'),
            ),
          ),
          if (f.replacesIdentity)
            Text(
              '名称或种类变化将创建新字段身份，需要重新授权。',
              style: prototypeText(context, 12, color: p.accent),
            ),
        ],
      ),
    );
  }
}
