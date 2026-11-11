import 'owner_workspace_hosts.dart';
import 'dart:async';
import 'owner_workspace_settings.dart';
import 'owner_workspace_runtime.dart';
import 'owner_workspace_proposals.dart';
import 'owner_workspace_plugins.dart';
import 'owner_workspace_legacy_templates.dart';
import 'owner_plugin_picker.dart';
import 'package:info_core/info_core.dart' show OwnerInbox;
import 'package:flutter/material.dart';
import '../desktop_runtime.dart';
import '../connection_view.dart';
import '../local_library_sync.dart';
import '../local_sync_settings.dart';
import 'package:info_remote/local_library_configuration.dart';
import '../desktop_controls.dart';
import '../ui_palette.dart';
import 'library_widgets.dart';
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
import 'owner_proposal_file_preview.dart';
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
    this.localConfiguration,
    this.replication,
    this.backupPicker = const NativeBackupFilePicker(),
    this.filePicker = const NativeInformationFilePicker(),
    this.credentialFiles = const NativeCredentialFilePicker(),
    this.pluginPicker = const NativeTemplatePackagePicker(),
  });
  final DesktopRuntime runtime;
  final InformationBackups? backups;
  final InformationFileOutputs? fileOutputs;
  final InformationFileOpens? fileOpens;
  final LocalLibraryConfiguration? localConfiguration;
  final LibraryReplication? replication;
  final BackupFilePicker backupPicker;
  final InformationFilePicker filePicker;
  final CredentialFilePicker credentialFiles;
  final InformationFilePicker pluginPicker;
  @override
  State<OwnerWorkspaceHost> createState() => _OwnerWorkspaceHostState();
}

class _OwnerWorkspaceHostState extends State<OwnerWorkspaceHost> {
  late OwnerWorkspaceSource _source;
  late final RuntimeWorkspaceDesktop _desktop;
  StreamSubscription<WorkspaceRecordRef?>? _changes;
  OwnerWorkspaceBackups? _backups;
  OwnerWorkspaceBackupFiles? _backupFiles;
  late OwnerWorkspacePlugins _plugins;
  late OwnerWorkspaceHosts _hosts;
  late OwnerProposalPasswords _passwords;
  LocalLibrarySync? _sync;
  bool _syncBusy = false;
  String _storageDescription = '本地模式';
  @override
  void initState() {
    super.initState();
    _desktop = RuntimeWorkspaceDesktop(widget.runtime);
    if (widget.localConfiguration != null && widget.replication != null) {
      _sync = LocalLibrarySync(
        configuration: widget.localConfiguration!,
        owner: widget.runtime.service.owner,
        replication: widget.replication!,
      );
      unawaited(_restoreSyncDescription());
    }
    _bind();
    widget.runtime.addListener(_runtimeChanged);
  }

  void _runtimeChanged() => _source.notifyExternalChange();

  Future<void> _restoreSyncDescription() async {
    try {
      final stored = await _sync!.readConfiguration();
      if (mounted) _syncSaved(stored['enabled'] as bool);
    } on Object {
      /* The settings pane exposes the original configuration error. */
    }
  }

  void _syncSaved(bool enabled) {
    if (!mounted) return;
    setState(() => _storageDescription = enabled ? '本地 · 同步已开启' : '本地模式');
    _source.notifyExternalChange();
  }

  void _syncBusyChanged(bool busy) {
    if (!mounted) return;
    setState(() => _syncBusy = busy);
    unawaited(_desktop.setNavigationEnabled(!busy));
  }

  void _bind() {
    _passwords = OwnerProposalPasswords(widget.runtime.service.owner);
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
      describeStorage: () => _storageDescription,
      plugins: _plugins,
      hosts: _hosts,
      legacyTemplates: OwnerWorkspaceLegacyTemplates(
        widget.runtime.service.owner,
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
    );
    _desktop.bindSource(_source);
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
      final oldPasswords = _passwords;
      final oldBackups = _backups;
      unawaited(_changes?.cancel());
      setState(_bind);
      unawaited(old.dispose());
      oldPlugins.dispose();
      oldHosts.dispose();
      oldPasswords.dispose();
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
    _passwords.dispose();
    _desktop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ExcludeFocus(
    excluding: _syncBusy,
    child: AbsorbPointer(
      absorbing: _syncBusy,
      child: WorkspaceApp(
        source: _source,
        desktop: _desktop,
        windowTitle: '知予',
        connectionBuilder: (context, onCancel) => _sync != null
            ? LocalSyncSettings(
                sync: _sync!,
                onBack: onCancel,
                onSaved: _syncSaved,
                onBusy: _syncBusyChanged,
              )
            : ConnectionSurface(
                embedded: true,
                title: '存储与同步',
                description: '资料保存在本机。',
                icon: Icons.computer_outlined,
                children: [
                  Text('本地模式', style: libraryHeading(context, 16)),
                  const SizedBox(height: 8),
                  Text(
                    '资料、文件和凭据加密保存在这台电脑。无需连接服务器，也能接收 AI 申请和审批。',
                    style: libraryText(
                      context,
                      14,
                      color: UiPalette.of(context).muted,
                      height: 1.8,
                    ),
                  ),
                  const SizedBox(height: 24),
                  DesktopButton(
                    kind: DesktopButtonKind.quiet,
                    onPressed: onCancel,
                    child: const Text('返回工作区'),
                  ),
                ],
              ),
        inputsBuilder: (context) {
          final source = _source;
          return WorkspaceInputs(
            proposalFile: (id, version, item, attachment, fileVersion) =>
                showOwnerProposalFilePreview(
                  context,
                  widget.runtime.service.owner,
                  id,
                  version,
                  item,
                  attachment,
                  fileVersion,
                ),
            proposalPassword: _passwords,
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
      ),
    ),
  );
}
