import 'dart:async';
import 'package:flutter/material.dart';
import '../desktop_controls.dart';
import '../desktop_feedback.dart';
import '../ui_palette.dart';
import 'credential_mutation.dart';
import 'library_credential_editor.dart';
import 'library_widgets.dart';
import 'workspace_source.dart';

Future<bool?> showCredentialMaterials(
  BuildContext context,
  WorkspaceSource source,
  WorkspaceRecordRef ref,
) {
  DesktopFeedback.dismiss(context);
  return showDesktopDialog<bool>(
    context,
    builder: (_) => _Materials(source: source.credentials, ref: ref),
  );
}

Future<WorkspaceRecordReceipt?> showCredentialRecycle(
  BuildContext context,
  WorkspaceSource source, {
  WorkspaceRecordRef? ref,
  WorkspaceRecycleEntry? entry,
}) {
  DesktopFeedback.dismiss(context);
  return showDesktopDialog<WorkspaceRecordReceipt>(
    context,
    builder: (_) =>
        _Recycle(source: source, ref: ref ?? entry!.record.ref, entry: entry),
  );
}

class _Materials extends StatefulWidget {
  const _Materials({required this.source, required this.ref});
  final WorkspaceCredentialSource source;
  final WorkspaceRecordRef ref;
  @override
  State<_Materials> createState() => _MaterialsState();
}

class _MaterialsState extends State<_Materials> {
  late final mutation = CredentialMutation(
    widget.source,
    expectedRef: widget.ref,
  )..addListener(_changed);
  WorkspaceCredentialMaterialHistory? history;
  String? readError, outcome;
  bool loading = true, confirm = false;
  int? selected;
  final _restoreFocus = FocusNode();
  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _restoreFocus.dispose();
    mutation.dispose();
    super.dispose();
  }

  Future<void> load() async {
    if (mutation.busy || mutation.uncertain) return;
    setState(() {
      loading = true;
      readError = null;
      confirm = false;
      selected = null;
    });
    try {
      final next = await widget.source.materials(widget.ref);
      if (!mounted) return;
      mutation.acceptCurrentVersion();
      setState(() => history = next);
    } catch (e) {
      if (mounted) {
        setState(
          () => readError = e is WorkspaceFailure ? e.message : '材料版本暂不可用，请重试。',
        );
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> submit() async {
    final d = history!.current;
    setState(() => outcome = null);
    final receipt = await mutation.submitCommand(
      (id) => WorkspaceCredentialChange(
        operationId: id,
        ref: widget.ref,
        expectedRecordVersion: d.recordVersion,
        expectedMaterialVersion: d.materialVersion,
        action: WorkspaceCredentialAction.restoreMaterial,
        materialVersion: selected,
      ),
      widget.source.change,
    );
    if (mounted && receipt != null) Navigator.pop(context, true);
  }

  Future<void> lookup() async {
    final receipt = await mutation.reconcile();
    if (!mounted) return;
    if (receipt != null) {
      Navigator.pop(context, true);
    } else if (!mutation.uncertain) {
      setState(() => outcome = '已确认未提交，可以明确重试。');
    }
  }

  Widget _versions(WorkspaceCredentialMaterialHistory h, bool writable) =>
      Column(
        key: const ValueKey('credential-material-list'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final material in h.materials)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _MaterialVersionRow(
                material: material,
                current: material.version == h.current.materialVersion,
                selected: selected == material.version,
                onSelected:
                    !writable || material.version == h.current.materialVersion
                    ? null
                    : () => setState(() {
                        selected = material.version;
                        mutation.edited();
                      }),
              ),
            ),
          if (!h.materials.any((m) => m.version != h.current.materialVersion))
            const Text('没有保留的历史材料。'),
        ],
      );

  Widget _confirmation(
    BuildContext context,
    WorkspaceCredentialMaterialHistory h,
    WorkspaceCredentialMaterial chosen,
  ) {
    final c = UiPalette.of(context);
    final current = h.materials
        .where((m) => m.version == h.current.materialVersion)
        .firstOrNull;
    return Column(
      key: const ValueKey('credential-material-confirm'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '恢复材料 v${chosen.version} → 新材料 v${h.current.materialVersion + 1}',
          style: libraryText(context, 16, weight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        const Text('恢复后凭据将停用，旧授权不会恢复。'),
        const SizedBox(height: 16),
        Text(
          '恢复来源',
          style: libraryText(
            context,
            13,
            color: c.muted,
            weight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 8),
        _MaterialVersionRow(material: chosen, current: false, selected: true),
        const SizedBox(height: 16),
        Text(
          '当前材料',
          style: libraryText(
            context,
            13,
            color: c.muted,
            weight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 8),
        if (current != null)
          _MaterialVersionRow(material: current, current: true, selected: false)
        else
          Text(
            '${h.current.format} · ${h.current.filename ?? '字符串'} · ${h.current.mask}',
          ),
        const SizedBox(height: 16),
        const Text('仅恢复材料，保留当前名称、用途、私有备注、分类、关联和使用配置。'),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = UiPalette.of(context), h = history;
    final writable =
        !loading && readError == null && !mutation.busy && !mutation.uncertain;
    final chosen = h?.materials.where((m) => m.version == selected).firstOrNull;
    return PopScope<bool>(
      canPop: !mutation.busy,
      child: DesktopDialog(
        title: Text(confirm ? '恢复凭据材料' : '凭据材料版本'),
        contentKey: PageStorageKey('credential-material-view-$confirm'),
        content: SizedBox(
          width: 680,
          child: loading
              ? const Text('正在读取材料版本…')
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (readError != null)
                      Text(
                        readError!,
                        style: libraryText(context, 14, color: c.danger),
                      ),
                    if (h != null) ...[
                      Text(
                        h.current.record.name,
                        style: libraryText(
                          context,
                          19,
                          weight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '当前材料 v${h.current.materialVersion} · ${h.current.enabled ? '已启用' : '已停用'}',
                        style: libraryText(context, 14, color: c.muted),
                      ),
                      const SizedBox(height: 16),
                      if (confirm && chosen != null)
                        _confirmation(context, h, chosen)
                      else
                        _versions(h, writable),
                    ],
                  ],
                ),
        ),
        actions: [
          if (outcome != null)
            SizedBox(
              width: double.infinity,
              child: Text(
                outcome!,
                style: libraryText(context, 13, color: c.muted),
              ),
            ),
          if (mutation.failure != null)
            SizedBox(
              width: double.infinity,
              child: Text(
                mutation.failure!.message,
                style: libraryText(context, 13, color: c.danger),
              ),
            ),
          if (mutation.uncertain)
            DesktopButton(
              key: const ValueKey('credential-material-lookup'),
              onPressed: mutation.busy ? null : lookup,
              child: const Text('核对此次恢复'),
            ),
          if (readError != null || mutation.failure?.code == 'conflict')
            DesktopButton(
              onPressed: mutation.busy ? null : load,
              child: const Text('重新读取并核对'),
            ),
          if (confirm && !mutation.uncertain)
            DesktopButton(
              key: const ValueKey('credential-material-back'),
              onPressed: mutation.busy
                  ? null
                  : () {
                      setState(() => confirm = false);
                      _restoreFocus.requestFocus();
                    },
              child: const Text('返回版本列表'),
            ),
          DesktopButton(
            key: const ValueKey('credential-material-close'),
            onPressed: mutation.busy ? null : () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
          DesktopButton(
            key: const ValueKey('credential-material-restore'),
            focusNode: _restoreFocus,
            kind: DesktopButtonKind.primary,
            busy: mutation.busy,
            onPressed: !writable || !mutation.canSubmit || chosen == null
                ? null
                : confirm
                ? submit
                : () => setState(() => confirm = true),
            child: Text(confirm ? '确认恢复为新材料版本' : '恢复此材料…'),
          ),
        ],
      ),
    );
  }
}

/// The current/confirmed version is reading content, not a dimmed disabled
/// command. Retain the same shared button surface for selectable old versions.
class _MaterialVersionRow extends StatelessWidget {
  const _MaterialVersionRow({
    required this.material,
    required this.current,
    required this.selected,
    this.onSelected,
  });
  final WorkspaceCredentialMaterial material;
  final bool current, selected;
  final VoidCallback? onSelected;
  @override
  Widget build(BuildContext context) {
    final c = UiPalette.of(context);
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '材料 v${material.version}${current ? ' · 当前' : ''} · ${material.filename ?? '字符串'}',
          style: libraryText(
            context,
            14,
            color: selected ? c.accent : c.ink,
            weight: FontWeight.w600,
          ),
        ),
        Text(
          '${material.format} · ${material.mask}',
          style: libraryText(context, 13, color: c.muted),
        ),
        Text(
          '创建于 ${libraryLocalDateTime(material.createdAt)}',
          style: libraryText(context, 13, color: c.muted),
        ),
        if (material.retiredAt != null)
          Text(
            '保留至 ${libraryLocalDateTime(material.retiredAt!.add(const Duration(days: 30)))}',
            style: libraryText(context, 13, color: c.muted),
          ),
      ],
    );
    final key = ValueKey('credential-material-${material.version}');
    if (onSelected != null) {
      return DesktopButton(
        key: key,
        selected: selected,
        alignment: Alignment.centerLeft,
        onPressed: onSelected,
        child: content,
      );
    }
    return Semantics(
      selected: selected,
      child: Container(
        key: key,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? c.selected : c.paper,
          border: Border.all(color: c.line),
          borderRadius: BorderRadius.circular(7),
        ),
        child: content,
      ),
    );
  }
}

class _Recycle extends StatefulWidget {
  const _Recycle({required this.source, required this.ref, this.entry});
  final WorkspaceSource source;
  final WorkspaceRecordRef ref;
  final WorkspaceRecycleEntry? entry;
  @override
  State<_Recycle> createState() => _RecycleState();
}

class _RecycleState extends State<_Recycle> {
  late final mutation = CredentialMutation(
    widget.source.credentials,
    expectedRef: widget.ref,
  )..addListener(_changed);
  WorkspaceCredentialDetail? detail;
  WorkspaceCredentialRecycled? recycled;
  WorkspaceCatalog? catalog;
  Map<WorkspaceRecordRef, String> names = {};
  String? readError, outcome;
  bool loading = true, purge = false;
  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    mutation.dispose();
    super.dispose();
  }

  Future<void> load() async {
    if (mutation.busy || mutation.uncertain) return;
    setState(() {
      loading = true;
      readError = null;
      purge = false;
    });
    try {
      final r = widget.entry == null
          ? null
          : await widget.source.credentials.readRecycled(widget.entry!.id);
      final d = r?.detail ?? await widget.source.credentials.read(widget.ref);
      final c = await widget.source.loadCatalog();
      if (r != null && r.catalogVersion != c.version) {
        throw const WorkspaceFailure('conflict', '分类已变化，请重新读取恢复范围。');
      }
      final targets = await widget.source.readSummaries(d.allLinks);
      if (!mounted) return;
      mutation.acceptCurrentVersion();
      setState(() {
        recycled = r;
        detail = d;
        catalog = c;
        names = {for (final target in targets) target.ref: target.name};
      });
    } catch (e) {
      if (mounted) {
        setState(
          () => readError = e is WorkspaceFailure ? e.message : '凭据暂时无法读取，请重试。',
        );
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  void complete(WorkspaceCredentialReceipt receipt) {
    Navigator.pop(
      context,
      WorkspaceRecordReceipt(
        ref: receipt.ref,
        version: receipt.recordVersion,
        entryId: receipt.entryId,
        notices: receipt.notices,
      ),
    );
  }

  Future<void> submit() async {
    final d = detail!;
    setState(() => outcome = null);
    final receipt = await mutation.submitCommand(
      (id) => WorkspaceCredentialChange(
        operationId: id,
        ref: widget.ref,
        expectedRecordVersion: d.recordVersion,
        expectedMaterialVersion: d.materialVersion,
        action: widget.entry == null
            ? WorkspaceCredentialAction.recycle
            : purge
            ? WorkspaceCredentialAction.purge
            : WorkspaceCredentialAction.restoreRecycled,
        entryId: widget.entry?.id,
        expectedCatalogVersion: recycled?.catalogVersion,
      ),
      widget.source.credentials.change,
    );
    if (mounted && receipt != null) complete(receipt);
  }

  Future<void> lookup() async {
    final receipt = await mutation.reconcile();
    if (!mounted) return;
    if (receipt != null) {
      complete(receipt);
    } else if (!mutation.uncertain) {
      setState(() => outcome = '已确认未提交，可以明确重试。');
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = UiPalette.of(context), d = detail, r = recycled;
    final deleting = widget.entry == null;
    final writable =
        !loading && readError == null && !mutation.busy && !mutation.uncertain;
    return PopScope<WorkspaceRecordReceipt>(
      canPop: !mutation.busy,
      child: DesktopDialog(
        title: Text(
          deleting
              ? '回收凭据'
              : purge
              ? '永久清理凭据'
              : '回收凭据资料',
        ),
        content: SizedBox(
          width: 680,
          child: loading
              ? const Text('正在读取凭据…')
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (readError != null)
                      Text(
                        readError!,
                        style: libraryText(context, 14, color: c.danger),
                      ),
                    if (d != null) ...[
                      Text(
                        d.record.name,
                        style: libraryText(
                          context,
                          19,
                          weight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${d.format} · 材料 v${d.materialVersion} · ${d.mask}',
                        style: libraryText(context, 14),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        deleting
                            ? '回收后凭据将停用，从信息库和当前关联中移除；30天内可恢复。旧授权不会恢复，也不会自动结束已启动的操作。'
                            : purge
                            ? '永久清理后，凭据及保留材料无法再从回收站或材料版本恢复。历史使用事实仍保留；已启动的操作不会因此自动结束。'
                            : '恢复会创建新材料版本，并保持停用。旧授权不会恢复；已移除的目录、标签和关联不会复活。',
                        style: libraryText(
                          context,
                          14,
                          color: purge ? c.danger : c.muted,
                          height: 1.8,
                        ),
                      ),
                      if (!deleting && r != null)
                        Text(
                          '保留至 ${libraryLocalDateTime(r.entry.expiresAt)}',
                          style: libraryText(context, 13, color: c.muted),
                        ),
                      if (catalog != null) ...[
                        const SizedBox(height: 16),
                        CredentialCurrentMetadata(
                          detail: d,
                          catalog: catalog!,
                          linkNames: names,
                        ),
                      ],
                      if (!deleting && !purge && r != null) ...[
                        const SizedBox(height: 18),
                        Text(
                          '恢复后：材料 v${r.restored.materialVersion} · 已停用',
                          style: libraryText(
                            context,
                            16,
                            weight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          '目录：${catalog!.directories.where((x) => x.id == r.restored.record.directoryId).firstOrNull?.name ?? '未分类'}',
                        ),
                        Text(
                          '保留标签：${r.restored.record.tags.map((t) => t.name).join('、')}',
                        ),
                        Text(
                          '保留关联：${r.restored.allLinks.map((ref) => names[ref] ?? '不可用资料').join('、')}',
                        ),
                        for (final notice in r.notices)
                          Text(
                            notice,
                            style: libraryText(context, 13, color: c.warning),
                          ),
                      ],
                    ],
                  ],
                ),
        ),
        actions: [
          if (outcome != null)
            SizedBox(
              width: double.infinity,
              child: Text(
                outcome!,
                style: libraryText(context, 13, color: c.muted),
              ),
            ),
          if (mutation.failure != null)
            SizedBox(
              width: double.infinity,
              child: Text(
                mutation.failure!.message,
                style: libraryText(context, 13, color: c.danger),
              ),
            ),
          if (mutation.uncertain)
            DesktopButton(
              key: const ValueKey('credential-recycle-lookup'),
              onPressed: mutation.busy ? null : lookup,
              child: const Text('核对此次操作'),
            ),
          if (readError != null || mutation.failure?.code == 'conflict')
            DesktopButton(
              key: const ValueKey('credential-recycle-reload'),
              onPressed: mutation.busy ? null : load,
              child: const Text('重新读取并核对'),
            ),
          if (!deleting && !purge)
            DesktopButton(
              key: const ValueKey('credential-recycle-purge'),
              kind: DesktopButtonKind.danger,
              onPressed: !writable
                  ? null
                  : () => setState(() {
                      purge = true;
                      mutation.edited();
                    }),
              child: const Text('永久清理…'),
            ),
          DesktopButton(
            onPressed: mutation.busy
                ? null
                : () => purge && !mutation.uncertain
                      ? setState(() => purge = false)
                      : Navigator.pop(context),
            child: Text(purge ? '返回查看' : '取消'),
          ),
          DesktopButton(
            key: const ValueKey('credential-recycle-submit'),
            kind: deleting || purge
                ? DesktopButtonKind.danger
                : DesktopButtonKind.primary,
            busy: mutation.busy,
            onPressed: !writable || !mutation.canSubmit || d == null
                ? null
                : submit,
            child: Text(
              deleting
                  ? '移到回收站'
                  : purge
                  ? '确认永久清理'
                  : '恢复凭据',
            ),
          ),
        ],
      ),
    );
  }
}
