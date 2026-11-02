import 'owner_workspace_hosts.dart';
import 'dart:async';
import 'package:info_cli/macos_agent_bundle.dart';
import 'owner_workspace_agents.dart';
import 'owner_workspace_settings.dart';
import 'owner_workspace_runtime.dart';
import 'owner_workspace_proposals.dart';
import 'owner_workspace_plugins.dart';
import 'owner_workspace_legacy_templates.dart';
import 'owner_plugin_picker.dart';
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
import '../credential_files.dart';
import 'owner_credential_input.dart';
import 'owner_proposal_password_input.dart';
import 'owner_workspace_credentials.dart';
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
    this.fileOpens,
    this.backupPicker = const NativeBackupFilePicker(),
    this.filePicker = const NativeInformationFilePicker(),
    this.credentialFiles = const NativeCredentialFilePicker(),
    this.pluginPicker = const NativeTemplatePackagePicker(),
  });
  final DesktopRuntime runtime;
  final InformationBackups? backups;
  final InformationFileOutputs? fileOutputs;
  final InformationFileOpens? fileOpens;
  final BackupFilePicker backupPicker;
  final InformationFilePicker filePicker;
  final CredentialFilePicker credentialFiles;
  final InformationFilePicker pluginPicker;
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
  late OwnerWorkspacePlugins _plugins;
  late OwnerWorkspaceHosts _hosts;
  @override
  void initState() {
    super.initState();
    _desktop = RuntimeWorkspaceDesktop(widget.runtime);
    _bind();
    widget.runtime.addListener(_runtimeChanged);
  }

  void _runtimeChanged() => _source.notifyExternalChange();

  void _bind() {
    _plugins = OwnerWorkspacePlugins(
      owner: widget.runtime.service.owner,
      picker: widget.pluginPicker,
      changed: () => _source.notifyExternalChange(),
    );
    _hosts = OwnerWorkspaceHosts(
      owner: widget.runtime.service.owner,
      changed: () => _source.notifyExternalChange(),
      picker: widget.filePicker,
    );
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
      plugins: _plugins,
      hosts: _hosts,
      legacyTemplates: OwnerWorkspaceLegacyTemplates(
        widget.runtime.service.owner,
        _plugins,
      ),
      definitionsReader: () => _plugins.templates,
      templateState: _plugins.stateFor,
      fileOutputs: widget.fileOutputs,
      fileOpens: widget.fileOpens,
      outputPicker: widget.backupPicker,
      fileSelections: OwnerWorkspaceFileSelections(
        widget.runtime.service.owner,
        picker: widget.filePicker,
      ),
      backups: _backups ?? const UnavailableWorkspaceBackup(),
      proposals: OwnerWorkspaceProposals(
        owner: widget.runtime.service.owner,
        library: () => _source,
        changed: () => _source.notifyExternalChange(),
      ),
      runtime: OwnerWorkspaceRuntime(
        runtime: widget.runtime,
        changed: () => _source.notifyExternalChange(),
      ),
      settings: OwnerWorkspaceSettings(
        owner: widget.runtime.service.owner,
        runtime: widget.runtime,
        changed: () => _source.refreshFromOwner(),
      ),
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
      final oldPlugins = _plugins;
      final oldHosts = _hosts;
      final oldBackups = _backups;
      unawaited(_changes?.cancel());
      setState(_bind);
      unawaited(old.dispose());
      oldPlugins.dispose();
      oldHosts.dispose();
      oldBackups?.dispose();
    });
  }

  @override
  void dispose() {
    unawaited(_changes?.cancel());
    widget.runtime.removeListener(_runtimeChanged);
    unawaited(_source.dispose());
    _backups?.dispose();
    _plugins.dispose();
    _hosts.dispose();
    _desktop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => WorkspaceApp(
    source: _source,
    desktop: _desktop,
    windowTitle: '知予',
    inputsBuilder: (context) {
      final source = _source;
      return WorkspaceInputs(
        proposalPassword: (id, version, item) => showOwnerProposalPasswordInput(
          context,
          widget.runtime.service.owner,
          id,
          version,
          item,
        ),
        backup: _backupFiles?.pick,
        plugin: _plugins.pick,
        hostFile: _hosts.pick,
        file: source.selections.pick,
        credential: (form) => showOwnerCredentialInput(
          context,
          (source.credentials as OwnerWorkspaceCredentials).staging,
          form,
          files: widget.credentialFiles,
        ),
      );
    },
  );
}
