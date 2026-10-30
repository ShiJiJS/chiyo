import 'dart:async';
import 'package:info_cli/macos_agent_bundle.dart';
import 'owner_workspace_agents.dart';
import 'package:info_core/info_core.dart' show OwnerInbox;
import 'package:flutter/material.dart';
import '../desktop_runtime.dart';
import 'owner_workspace_source.dart';
import 'runtime_workspace_desktop.dart';
import 'workspace_app.dart';
import 'workspace_source.dart';

/// Production composition for the library/service already opened by bootstrap.
/// No database, key, server, hook or fictional source is created here.
class OwnerWorkspaceHost extends StatefulWidget {
  const OwnerWorkspaceHost({super.key, required this.runtime});
  final DesktopRuntime runtime;
  @override
  State<OwnerWorkspaceHost> createState() => _OwnerWorkspaceHostState();
}

class _OwnerWorkspaceHostState extends State<OwnerWorkspaceHost> {
  late OwnerWorkspaceSource _source;
  final _bundle = MacAgentBundle();
  late final RuntimeWorkspaceDesktop _desktop;
  StreamSubscription<WorkspaceRecordRef?>? _changes;
  @override
  void initState() {
    super.initState();
    _desktop = RuntimeWorkspaceDesktop(widget.runtime);
    _bind();
  }

  void _bind() {
    _source = OwnerWorkspaceSource(
      owner: widget.runtime.service.owner,
      agents: OwnerWorkspaceAgents(
        owner: widget.runtime.service.owner,
        readBundle: _bundle.read,
      ),
    );
    _changes = _source.changes.listen((_) {
      if (!mounted ||
          _source.isCurrentLibrary ||
          widget.runtime.stopped ||
          !widget.runtime.service.owner.serviceAvailable) {
        return;
      }
      final old = _source;
      unawaited(_changes?.cancel());
      setState(_bind);
      unawaited(old.dispose());
    });
  }

  @override
  void dispose() {
    unawaited(_changes?.cancel());
    unawaited(_source.dispose());
    _desktop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      WorkspaceApp(source: _source, desktop: _desktop, windowTitle: '知予');
}
