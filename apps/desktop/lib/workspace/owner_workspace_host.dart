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
import 'package:info_storage/info_storage.dart';
import '../backups.dart';
import '../information_files.dart';
import 'owner_workspace_file_selections.dart';
import 'owner_workspace_backup_files.dart';
import 'owner_workspace_backups.dart';
import 'unavailable_workspace_sources.dart';
import 'workspace_inputs.dart';

/// Production composition for the library/service already opened by bootstrap.
/// No database, key, server, hook or fictional source is created here.
class OwnerWorkspaceHost extends StatefulWidget {
  const OwnerWorkspaceHost({
    super.key,
    required this.runtime,
    this.backups,
    this.fileOutputs,
    this.backupPicker = const NativeBackupFilePicker(),
    this.filePicker = const NativeInformationFilePicker(),
  });
  final DesktopRuntime runtime;
  final InformationBackups? backups;
  final InformationFileOutputs? fileOutputs;
  final BackupFilePicker backupPicker;
  final InformationFilePicker filePicker;
  @override
  State<OwnerWorkspaceHost> createState() => _OwnerWorkspaceHostState();
}

class _OwnerWorkspaceHostState extends State<OwnerWorkspaceHost> {
  late OwnerWorkspaceSource _source;
  final _bundle = MacAgentBundle();
  late final RuntimeWorkspaceDesktop _desktop;
  StreamSubscription<WorkspaceRecordRef?>? _changes;
  OwnerWorkspaceBackups? _backups;
  OwnerWorkspaceBackupFiles? _backupFiles;
  @override
  void initState() {
    super.initState();
    _desktop = RuntimeWorkspaceDesktop(widget.runtime);
    _bind();
  }

  void _bind() {
    if (widget.backups != null) {
      _backupFiles = OwnerWorkspaceBackupFiles(
        owner: widget.runtime.service.owner,
        picker: widget.backupPicker,
      );
      _backups = OwnerWorkspaceBackups(
        owner: widget.runtime.service.owner,
        backups: widget.backups!,
        files: _backupFiles!,
        picker: widget.backupPicker,
        onRestored: () => _source.refreshFromOwner(),
      );
    }
    _source = OwnerWorkspaceSource(
      owner: widget.runtime.service.owner,
      fileOutputs: widget.fileOutputs,
      outputPicker: widget.backupPicker,
      fileSelections: OwnerWorkspaceFileSelections(
        widget.runtime.service.owner,
        picker: widget.filePicker,
      ),
      backups: _backups ?? const UnavailableWorkspaceBackup(),
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
      final oldBackups = _backups;
      unawaited(_changes?.cancel());
      setState(_bind);
      unawaited(old.dispose());
      oldBackups?.dispose();
    });
  }

  @override
  void dispose() {
    unawaited(_changes?.cancel());
    unawaited(_source.dispose());
    _backups?.dispose();
    _desktop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => WorkspaceApp(
    source: _source,
    desktop: _desktop,
    windowTitle: '知予',
    inputsBuilder: (_) => WorkspaceInputs(
      backup: _backupFiles?.pick,
      file: _source.selections.pick,
    ),
  );
}
