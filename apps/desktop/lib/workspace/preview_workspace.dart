import 'dart:async';
import 'preview_connection.dart';
import 'zhiyu_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'sample_workspace_source.dart';
import 'workspace_app.dart';
import 'workspace_source.dart';
import 'workspace_inputs.dart';
import 'zhiyu_app.dart';
import 'mac_preview_desktop.dart';

/// The isolated entry owns its sample data and native preview bridge. Production
/// composes WorkspaceApp directly and does not import this provider.
class PreviewWorkspace extends StatefulWidget {
  const PreviewWorkspace({
    super.key,
    this.pageBuilder,
    this.desktop,
    this.inputsBuilder,
  });
  final WorkspacePageBuilder? pageBuilder;
  final MacPreviewDesktop? desktop;
  final WorkspaceInputs Function(BuildContext)? inputsBuilder;
  @override
  State<PreviewWorkspace> createState() => _PreviewWorkspaceState();
}

class _PreviewWorkspaceState extends State<PreviewWorkspace> {
  late final PreviewLibrarySource _source = PreviewLibrarySource(
    readAsset: (asset) async {
      final data = await rootBundle.load(asset);
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    },
  );

  StreamSubscription<WorkspaceRecordRef?>? _changes;
  String? _connection;
  bool _syncing = false;
  String _syncedAt = '刚刚';
  int _menuRevision = 0;
  @override
  void initState() {
    super.initState();
    widget.desktop?.onPreviewState = (state) {
      if (mounted) setState(() => _connection = state);
    };
    widget.desktop?.onPreviewDecision = _decide;
    _changes = _source.changes.listen((_) => unawaited(_updateMenu()));
    unawaited(_updateMenu());
  }

  Future<void> _updateMenu() async {
    if (widget.desktop == null) return;
    final revision = ++_menuRevision;
    final rows = await _source.approvals.query(const WorkspaceApprovalQuery());
    final values = <Map<String, Object?>>[];
    for (final row in rows.items.take(4)) {
      final detail = await _source.approvals.read(row.id);
      values.add({
        'id': row.id,
        'title': row.title,
        'agent': row.agentClaim,
        'purpose': row.purpose,
        'scope': detail.scopes
            .where((s) => s.requested)
            .map(
              (s) => s.label.startsWith(s.recordName)
                  ? s.label
                  : '${s.recordName} · ${s.label}',
            )
            .join('\n'),
        'quick':
            row.kind == WorkspaceApprovalKind.information && detail.canApprove,
      });
    }
    if (mounted && revision == _menuRevision) {
      await widget.desktop!.updateApprovals(values, rows.pending);
    }
  }

  Future<void> _decide(String id, bool approve) async {
    final detail = await _source.approvals.read(id);
    if (detail.request.kind != WorkspaceApprovalKind.information ||
        !detail.canApprove) {
      return;
    }
    await _source.approvals.change(
      WorkspaceApprovalChange(
        operationId: workspaceOperationId(),
        requestId: id,
        reviewToken: detail.reviewToken,
        action: approve
            ? WorkspaceApprovalAction.approve
            : WorkspaceApprovalAction.deny,
        selected: approve
            ? detail.scopes
                  .where((s) => s.requested && s.available)
                  .map((s) => s.id)
            : const [],
      ),
    );
    await _updateMenu();
  }

  Future<void> _sync() async {
    setState(() => _syncing = true);
    await Future<void>.delayed(const Duration(milliseconds: 900));
    if (mounted) {
      setState(() {
        _syncing = false;
        _syncedAt = '刚刚';
      });
    }
  }

  @override
  void dispose() {
    _changes?.cancel();
    _source.dispose();
    widget.desktop?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    alignment: Alignment.topLeft,
    children: [
      WorkspaceApp(
        source: _source,
        onConnectionSettings: () => setState(() => _connection = 'settings'),
        statusBuilder: (context) => TextButton.icon(
          onPressed: _syncing ? null : _sync,
          icon: _syncing
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.sync, size: 17),
          label: Text(_syncing ? '同步中' : '已同步 · $_syncedAt'),
        ),
        windowTitle: MacPreviewDesktop.windowTitle,
        initialQuery: const WorkspaceQuery(directoryId: 'selfhost'),
        initialSelection: const WorkspaceRecordRef(
          WorkspaceRecordKind.information,
          'azure',
        ),
        desktop: widget.desktop,
        pageBuilder: widget.pageBuilder,
        inputsBuilder: widget.inputsBuilder,
      ),
      if (_connection != null)
        Positioned.fill(
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: zhiyuTheme(Brightness.light),
            home: PreviewConnection(
              key: ValueKey(_connection),
              disconnected: _connection == 'offline',
              onBack: () => setState(() => _connection = null),
              onConnected: () => setState(() => _connection = null),
              onDisconnect: () => setState(() => _connection = 'offline'),
              onSettings: () => setState(() => _connection = 'settings'),
            ),
          ),
        ),
    ],
  );
}
