import 'dart:async';
import 'package:flutter/material.dart';
import '../desktop_controls.dart';
import 'library_credential_editor.dart';
import 'library_history_dialog.dart';
import 'library_widgets.dart';
import 'recycled_attachment_preview.dart';
import 'workspace_source.dart';

/// A batch member can be inspected, but only the parent batch can be restored.
Future<void> showLibraryRecycledMember(
  BuildContext context,
  WorkspaceSource source,
  WorkspaceLibraryRecycleRecord member,
  WorkspaceCatalog catalog,
) => showDesktopDialog<void>(
  context,
  builder: (_) => _Member(source, member, catalog),
);

class _Member extends StatefulWidget {
  const _Member(this.source, this.member, this.catalog);
  final WorkspaceSource source;
  final WorkspaceLibraryRecycleRecord member;
  final WorkspaceCatalog catalog;
  @override
  State<_Member> createState() => _MemberState();
}

class _MemberState extends State<_Member> {
  StreamSubscription<WorkspaceRecordRef?>? _changes;
  WorkspaceArchive? _archive;
  WorkspaceCredentialRecycled? _credential;
  Map<WorkspaceRecordRef, String> _names = {};
  String? _failure;
  bool _loading = true;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    _changes = widget.source.changes.listen((_) => unawaited(_load()));
    unawaited(_load());
  }

  @override
  void dispose() {
    ++_generation;
    _changes?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _failure = null;
    });
    try {
      final member = widget.member, id = member.recycleEntryId!;
      WorkspaceArchive? archive;
      WorkspaceCredentialRecycled? credential;
      Map<WorkspaceRecordRef, String> names = {};
      if (member.ref.kind == WorkspaceRecordKind.credential) {
        credential = await widget.source.credentials.readRecycled(id);
        if (credential.detail.record.ref != member.ref) {
          throw const WorkspaceFailure('invalid_response', '回收资料不匹配。');
        }
        final targets = await widget.source.readSummaries(
          credential.detail.allLinks,
        );
        names = {for (final target in targets) target.ref: target.name};
      } else {
        archive = await widget.source.readRecycled(id);
        if (archive.detail.record.ref != member.ref) {
          throw const WorkspaceFailure('invalid_response', '回收资料不匹配。');
        }
      }
      if (!mounted || generation != _generation) return;
      setState(() {
        _archive = archive;
        _credential = credential;
        _names = names;
      });
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _archive = null;
          _credential = null;
          _names = {};
          _failure = error is WorkspaceFailure
              ? error.message
              : '回收内容暂不可用，请重试。';
        });
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => DesktopDialog(
    title: const Text('回收内容预览'),
    content: SizedBox(
      width: 680,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_loading) const LinearProgressIndicator(),
          if (_failure != null) Text(_failure!),
          if (_archive case final archive?)
            LibrarySnapshotView(
              archive: archive,
              fileBuilder: widget.source is WorkspaceRecycledFiles
                  ? (key) => RecycledAttachmentPreview(
                      source: widget.source,
                      entryId: widget.member.recycleEntryId!,
                      fieldKey: key,
                    )
                  : null,
            ),
          if (_credential case final credential?) ...[
            Text(
              credential.detail.record.name,
              style: libraryHeading(context, 20),
            ),
            const SizedBox(height: 12),
            CredentialCurrentMetadata(
              detail: credential.detail,
              catalog: widget.catalog,
              linkNames: _names,
              directoryLabel:
                  credential.entry.directoryName ??
                  (credential.detail.record.directoryId == null
                      ? '未分类'
                      : '原目录已移除'),
            ),
          ],
          if (_archive != null || _credential != null) ...[
            const SizedBox(height: 16),
            Text(
              '恢复后位置：${widget.member.path.isEmpty ? '未分类' : widget.member.path.join(' / ')}',
            ),
            const SizedBox(height: 8),
            const Text('此处只预览内容，返回后可整批恢复。'),
          ],
        ],
      ),
    ),
    actions: [
      if (_failure != null)
        DesktopButton(
          onPressed: _loading ? null : _load,
          child: const Text('重试'),
        ),
      DesktopButton(
        key: const ValueKey('batch-member-close'),
        onPressed: () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
    ],
  );
}
