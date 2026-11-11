import 'dart:async';
import 'package:flutter/material.dart';
import '../desktop_controls.dart';
import '../ui_palette.dart';
import 'credential_mutation.dart';
import 'library_widgets.dart';
import 'library_relation_picker.dart';
import 'workspace_source.dart';

Future<WorkspaceRecordRef?> showLibraryCredentialEditor(
  BuildContext context,
  WorkspaceSource source,
  WorkspaceCatalog catalog, {
  WorkspaceRecordRef? ref,
  String? initialDirectoryId,
  bool replace = false,
  WorkspaceCredentialPicker? picker,
}) => showDesktopDialog<WorkspaceRecordRef>(
  context,
  builder: (_) => _CredentialFormLoader(
    source: source,
    catalog: catalog,
    ref: ref,
    initialDirectoryId: initialDirectoryId,
    replace: replace,
    picker: picker,
  ),
);

class _CredentialFormLoader extends StatefulWidget {
  const _CredentialFormLoader({
    required this.source,
    required this.catalog,
    this.ref,
    this.initialDirectoryId,
    required this.replace,
    this.picker,
  });
  final WorkspaceSource source;
  final WorkspaceCatalog catalog;
  final WorkspaceRecordRef? ref;
  final String? initialDirectoryId;
  final bool replace;
  final WorkspaceCredentialPicker? picker;
  @override
  State<_CredentialFormLoader> createState() => _CredentialFormLoaderState();
}

class _CredentialFormLoaderState extends State<_CredentialFormLoader> {
  WorkspaceCredentialDetail? _detail;
  Object? _error;
  bool _loading = true;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final detail = widget.ref == null
          ? null
          : await widget.source.credentials.read(widget.ref!);
      if (mounted) {
        setState(() {
          _detail = detail;
          _loading = false;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error;
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => !_loading && _error == null
      ? _CredentialEditor(
          source: widget.source,
          catalog: widget.catalog,
          detail: _detail,
          initialDirectoryId: widget.initialDirectoryId,
          picker: widget.picker,
          replace: widget.replace,
        )
      : DesktopDialog(
          title: const Text('凭据资料'),
          content: Text(
            _loading
                ? '正在读取凭据资料…'
                : _error is WorkspaceFailure
                ? (_error as WorkspaceFailure).message
                : '暂时无法读取凭据，请重试。',
          ),
          actions: [
            if (!_loading)
              DesktopButton(onPressed: _load, child: const Text('重试')),
            DesktopButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
          ],
        );
}

class _CredentialEditor extends StatefulWidget {
  const _CredentialEditor({
    required this.source,
    required this.catalog,
    required this.detail,
    required this.initialDirectoryId,
    required this.picker,
    required this.replace,
  });
  final WorkspaceSource source;
  final WorkspaceCatalog catalog;
  final WorkspaceCredentialDetail? detail;
  final String? initialDirectoryId;
  final WorkspaceCredentialPicker? picker;
  final bool replace;
  @override
  State<_CredentialEditor> createState() => _CredentialEditorState();
}

class _CredentialEditorState extends State<_CredentialEditor> {
  late final _name = TextEditingController(
    text: widget.detail?.record.name ?? '',
  );
  late final _purpose = TextEditingController(
    text: widget.detail?.record.description ?? '',
  );
  late final _note = TextEditingController(
    text: widget.detail?.privateNote ?? '',
  );
  late final _binding = TextEditingController(
    text: widget.detail?.binding ?? '',
  );
  late final _mutation = CredentialMutation(
    widget.source.credentials,
    expectedRef: widget.detail?.record.ref,
  )..addListener(_changed);
  late WorkspaceCatalog _catalog = widget.catalog;
  late WorkspaceCredentialDetail? _baseline = widget.detail;
  WorkspaceCredentialDetail? _latest;
  Map<WorkspaceRecordRef, String> _latestNames = {};
  late String? _directory = widget.detail == null
      ? widget.initialDirectoryId
      : widget.detail!.record.directoryId;
  late final _tags = {...?widget.detail?.record.tags.map((t) => t.id)};
  late List<WorkspaceRecordRef> _links = List.of(
    widget.detail?.linkedInformation ?? [],
  );
  WorkspaceCredentialCandidate? _candidate;
  bool _picking = false, _bindingEdited = false, _visibilityDirty = false;
  late bool _discoverable = widget.detail?.discoverable ?? false;
  bool _dirty = false, _discard = false, _linksDirty = false, _checking = false;
  String? _checkError;
  bool get _editable =>
      !_mutation.busy && !_mutation.uncertain && !_checking && !_picking;
  bool get _needsCandidate => widget.detail == null || widget.replace;
  @override
  void dispose() {
    if (_candidate != null) unawaited(_release(_candidate!.id));
    _mutation.dispose();
    _name.dispose();
    _purpose.dispose();
    _note.dispose();
    _binding.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _release(String id) async {
    try {
      await widget.source.credentials.releaseCandidate(id);
    } catch (_) {
      /* The service owns recovery/expiry of staging leases. */
    }
  }

  Future<void> _pick() async {
    if (!_editable) return;
    final picker = widget.picker;
    if (picker == null) {
      setState(() => _checkError = '凭据输入服务不可用，请稍后重试。');
      return;
    }
    setState(() => _picking = true);
    try {
      final candidate = await picker(widget.detail?.form);
      if (candidate == null) return;
      if (!mounted) {
        await _release(candidate.id);
        return;
      }
      if (widget.detail != null && candidate.form != widget.detail!.form) {
        unawaited(_release(candidate.id));
        setState(() => _checkError = '更换材料必须保持原有形态。');
        return;
      }
      final previous = _candidate;
      setState(() {
        _candidate = candidate;
        // Suggestions belong to a new, untouched field. Choosing replacement
        // material must not overwrite an existing or explicitly edited value.
        if (widget.detail == null && !_bindingEdited) {
          _binding.text = candidate.binding;
        }
        _checkError = null;
        _edit();
      });
      if (previous != null && previous.id != candidate.id) {
        unawaited(_release(previous.id));
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _checkError = error is WorkspaceFailure
              ? error.message
              : '凭据输入或选择暂不可用，请重试。',
        );
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  void _edit([String? _]) {
    _dirty = true;
    _mutation.edited();
  }

  void _close(WorkspaceRecordRef ref) {
    setState(() => _dirty = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.pop(context, ref);
    });
  }

  Future<void> _save() async {
    if (!_editable) return;
    if (_needsCandidate && _candidate == null) {
      setState(() => _checkError = '请选择凭据资料。');
      return;
    }
    final receipt = await _mutation.submitCommand(
      (id) => WorkspaceCredentialWrite(
        operationId: id,
        ref: _baseline?.record.ref,
        expectedRecordVersion: _baseline?.recordVersion,
        expectedMaterialVersion: _baseline?.materialVersion,
        candidateId: _candidate?.id,
        discoverable: _visibilityDirty || _baseline == null
            ? _discoverable
            : null,
        name: _name.text,
        purpose: _purpose.text,
        privateNote: _note.text,
        binding: _binding.text,
        directoryId: _directory,
        tagIds: _tags,
        linkedInformation: _linksDirty || _baseline == null ? _links : null,
      ),
      widget.source.credentials.save,
    );
    if (mounted && receipt != null) _close(receipt.ref);
  }

  Future<void> _lookup() async {
    final receipt = await _mutation.reconcile();
    if (mounted && receipt != null) _close(receipt.ref);
  }

  Future<void> _readCurrent() async {
    if (_baseline == null || _checking) return;
    setState(() {
      _checking = true;
      _checkError = null;
    });
    try {
      final latest = await widget.source.credentials.read(
        _baseline!.record.ref,
      );
      final catalog = await widget.source.loadCatalog();
      final links = await widget.source.readSummaries(latest.linkedInformation);
      if (mounted) {
        setState(() {
          _latest = latest;
          _catalog = catalog;
          _latestNames = {
            for (final r in links) r.ref: '${r.name}（${r.type.name}）',
          };
          _checking = false;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _checking = false;
          _checkError = error is WorkspaceFailure
              ? error.message
              : '当前资料暂不可读取。';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = UiPalette.of(context), failure = _mutation.failure;
    return PopScope(
      canPop: !_dirty && !_mutation.busy && !_checking && !_picking,
      onPopInvokedWithResult: (popped, _) {
        if (!popped && !_mutation.busy && !_checking && !_picking) {
          setState(() => _discard = true);
        }
      },
      child: DesktopDialog(
        title: Text(
          widget.detail == null
              ? '添加凭据'
              : widget.replace
              ? '更换凭据材料'
              : '编辑凭据',
        ),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_needsCandidate) ...[
              DesktopButton(
                key: const ValueKey('credential-edit-candidate'),
                onPressed: _editable ? _pick : null,
                child: Text(
                  _picking
                      ? '等待材料输入或选择'
                      : _candidate == null
                      ? '输入或选择凭据内容'
                      : _candidate!.label,
                ),
              ),
              if (_candidate case final selected?) ...[
                const SizedBox(height: 8),
                Text(
                  '${selected.format} · ${selected.delivery.label}',
                  style: libraryText(context, 13, color: c.muted),
                ),
                if (selected.filename != null)
                  Text(selected.filename!, style: libraryText(context, 13)),
              ],
              if (failure?.fieldErrors['candidate'] case final error?)
                Text(error, style: libraryText(context, 13, color: c.danger)),
              const SizedBox(height: 16),
              Text(
                widget.replace
                    ? '材料更换后生成新版本，旧使用能力不会恢复；停用状态保持。'
                    : '凭据内容由专用入口保管，不作为普通信息字段提供。',
                style: libraryText(context, 13, color: c.muted),
              ),
              const SizedBox(height: 18),
            ] else ...[
              Text(
                '${widget.detail!.format} · 材料v${widget.detail!.materialVersion} · ${widget.detail!.mask}',
                style: libraryText(context, 13, color: c.muted),
              ),
              const SizedBox(height: 18),
            ],
            DesktopTextField(
              key: const ValueKey('credential-edit-name'),
              controller: _name,
              enabled: _editable,
              onChanged: _edit,
              decoration: InputDecoration(
                labelText: '凭据名称',
                errorText: failure?.fieldErrors['name'],
              ),
            ),
            DesktopTextField(
              key: const ValueKey('credential-edit-purpose'),
              controller: _purpose,
              enabled: _editable,
              onChanged: _edit,
              minLines: 2,
              maxLines: 4,
              decoration: InputDecoration(
                labelText: '公开用途',
                errorText: failure?.fieldErrors['purpose'],
              ),
            ),
            Row(
              children: [
                Checkbox(
                  key: const ValueKey('credential-edit-discoverable'),
                  value: _discoverable,
                  onChanged: !_editable
                      ? null
                      : (value) => setState(() {
                          _discoverable = value!;
                          _visibilityDirty = true;
                          _edit();
                        }),
                ),
                Expanded(
                  child: Text(
                    '允许AI发现凭据名称和公开用途',
                    style: libraryText(context, 13),
                  ),
                ),
              ],
            ),
            Text(
              '允许发现不等于允许使用；秘密内容仍须单独申请和审批，私有备注不公开。',
              style: libraryText(context, 13, color: c.muted),
            ),
            const SizedBox(height: 18),
            DesktopTextField(
              key: const ValueKey('credential-edit-note'),
              controller: _note,
              enabled: _editable,
              onChanged: _edit,
              minLines: 2,
              maxLines: 4,
              decoration: InputDecoration(
                labelText: '私有备注',
                errorText: failure?.fieldErrors['privateNote'],
              ),
            ),
            DesktopTextField(
              key: const ValueKey('credential-edit-binding'),
              controller: _binding,
              enabled: _editable,
              onChanged: (value) {
                _bindingEdited = true;
                _edit(value);
              },
              decoration: InputDecoration(
                labelText: '建议引用名',
                errorText: failure?.fieldErrors['binding'],
              ),
            ),
            LibraryDirectorySelect(
              catalog: _catalog,
              value: _directory,
              errorText: failure?.fieldErrors['directory'],
              onChanged: !_editable
                  ? null
                  : (value) => setState(() {
                      _directory = value;
                      _edit();
                    }),
            ),
            Text('标签', style: libraryText(context, 13, color: c.muted)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 7,
              runSpacing: 7,
              children: [
                for (final tag in _catalog.tags)
                  LibraryTag(
                    tag.name,
                    selected: _tags.contains(tag.id),
                    onPressed: !_editable
                        ? null
                        : () => setState(() {
                            if (!_tags.add(tag.id)) _tags.remove(tag.id);
                            _edit();
                          }),
                  ),
              ],
            ),
            if (failure?.fieldErrors['tags'] case final error?)
              Text(error, style: libraryText(context, 13, color: c.danger)),
            const SizedBox(height: 18),
            LibraryRelationPicker(
              source: widget.source,
              typeId: 'credential',
              relationKey: 'related',
              label: '关联资料',
              record: _baseline?.record.ref,
              enabled: _editable,
              selected: _links,
              errorText: failure?.fieldErrors['related'],
              onChanged: (refs) => setState(() {
                _links = refs;
                _linksDirty = true;
                _edit();
              }),
            ),
            if (_baseline?.referencingInformation.isNotEmpty ?? false) ...[
              const SizedBox(height: 8),
              Text(
                '另有 ${_baseline!.referencingInformation.length} 项来自对方资料的关联，可在详情页查看并打开对方资料修改。',
                style: libraryText(context, 13, color: c.muted),
              ),
            ],
            if (_latest case final latest?) ...[
              const SizedBox(height: 22),
              Text(
                '当前版本核对',
                style: libraryText(context, 17, weight: FontWeight.w600),
              ),
              CredentialCurrentMetadata(
                detail: latest,
                catalog: _catalog,
                linkNames: _latestNames,
              ),
              const SizedBox(height: 12),
              DesktopButton(
                key: const ValueKey('credential-edit-accept-current'),
                onPressed: !_editable
                    ? null
                    : () => setState(() {
                        _baseline = latest;
                        if (!_visibilityDirty) {
                          _discoverable = latest.discoverable;
                        }
                        if (!_linksDirty) {
                          _links = List.of(latest.linkedInformation);
                        }
                        _latest = null;
                        _mutation.acceptCurrentVersion();
                      }),
                child: const Text('已核对，按当前版本保留此草稿'),
              ),
            ],
          ],
        ),
        actions: [
          if (failure != null)
            SizedBox(
              width: double.infinity,
              child: Text(
                failure.message,
                style: libraryText(context, 13, color: c.danger),
              ),
            ),
          if (_checkError != null)
            SizedBox(
              width: double.infinity,
              child: Text(
                _checkError!,
                style: libraryText(context, 13, color: c.danger),
              ),
            ),
          if (_mutation.uncertain)
            DesktopButton(
              onPressed: _mutation.busy ? null : _lookup,
              child: const Text('核对此次保存'),
            ),
          if (failure?.code == 'conflict')
            DesktopButton(
              onPressed: _checking ? null : _readCurrent,
              child: const Text('读取当前资料'),
            ),
          if (_discard) ...[
            SizedBox(
              width: double.infinity,
              child: Text(
                '尚有未保存的修改。',
                style: libraryText(context, 13, color: c.warning),
              ),
            ),
            DesktopButton(
              onPressed: () => setState(() {
                _dirty = false;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) Navigator.pop(context);
                });
              }),
              child: const Text('放弃修改'),
            ),
          ],
          DesktopButton(
            onPressed: _mutation.busy || _checking || _picking
                ? null
                : () => _dirty
                      ? setState(() => _discard = true)
                      : Navigator.pop(context),
            child: const Text('取消'),
          ),
          DesktopButton(
            key: const ValueKey('credential-edit-save'),
            kind: DesktopButtonKind.primary,
            busy: _mutation.busy,
            onPressed: _mutation.canSubmit && !_checking && !_picking
                ? _save
                : null,
            child: Text(widget.replace ? '更换材料' : '保存'),
          ),
        ],
      ),
    );
  }
}

/// Every versioned metadata field is visible before rebasing a retained draft.
class CredentialCurrentMetadata extends StatelessWidget {
  const CredentialCurrentMetadata({
    super.key,
    required this.detail,
    required this.catalog,
    this.linkNames = const {},
    this.directoryLabel,
  });
  final WorkspaceCredentialDetail detail;
  final WorkspaceCatalog catalog;
  final Map<WorkspaceRecordRef, String> linkNames;
  final String? directoryLabel;
  @override
  Widget build(BuildContext context) => SelectableText(
    [
      '名称：${detail.record.name}',
      '用途：${detail.record.description}',
      if (detail.account.isNotEmpty) '账号：${detail.account}',
      '私有备注：${detail.privateNote}',
      '引用名：${detail.binding}',
      '材料：${detail.format} · v${detail.materialVersion} · ${detail.filename ?? '字符串'}',
      '状态：${detail.enabled ? '已启用' : '已停用'}',
      '目录：${directoryLabel ?? catalog.directories.where((d) => d.id == detail.record.directoryId).firstOrNull?.name ?? '未分类'}',
      '标签：${detail.record.tags.map((t) => t.name).join('、')}',
      '关联资料：${detail.linkedInformation.map((r) => linkNames[r] ?? '已不可用的关联资料').join('、')}',
    ].join('\n'),
    style: libraryText(context, 13, height: 1.8),
  );
}
