import 'dart:async';
import 'package:flutter/material.dart';
import '../desktop_scroll.dart';
import '../desktop_controls.dart';
import 'workspace_controller.dart';
import 'workspace_source.dart';
import 'workspace_inputs.dart';
import 'zhiyu_app.dart';
import 'workspace_desktop.dart';
import 'library_controller.dart';
import 'library_page.dart';
import 'plugins_controller.dart';
import 'plugins_page.dart';
import 'library_edit_dialog.dart';
import 'legacy_templates_controller.dart';
import 'approvals_controller.dart';
import 'approvals_page.dart';
import 'grant_history_controller.dart';
import 'grant_history_page.dart';
import 'settings_controller.dart';
import 'settings_page.dart';
import 'classification_controller.dart';
import 'backup_controller.dart';
import 'runtime_controller.dart';
import 'agents_controller.dart';
import 'proposals_controller.dart';
import 'proposals_page.dart';

/// Shared owner UI. Its composition root supplies data and owns service lifetime;
/// this widget never creates a sample provider or opens a database.
class WorkspaceApp extends StatelessWidget {
  const WorkspaceApp({
    super.key,
    required this.source,
    required this.windowTitle,
    this.initialSelection,
    this.initialQuery = const WorkspaceQuery(),
    this.pageBuilder,
    this.desktop,
    this.inputsBuilder,
  });
  final WorkspaceSource source;
  final String windowTitle;
  final WorkspaceRecordRef? initialSelection;
  final WorkspaceQuery initialQuery;
  final WorkspacePageBuilder? pageBuilder;
  final WorkspaceDesktop? desktop;
  final WorkspaceInputs Function(BuildContext)? inputsBuilder;
  @override
  Widget build(BuildContext context) => _WorkspaceSession(
    key: ValueKey((source, desktop)),
    source: source,
    windowTitle: windowTitle,
    initialSelection: initialSelection,
    initialQuery: initialQuery,
    pageBuilder: pageBuilder,
    desktop: desktop,
    inputsBuilder: inputsBuilder,
  );
}

// A different service/source starts a fresh projection and releases all old
// subscriptions, even if the outer application widget retains its key.
class _WorkspaceSession extends StatefulWidget {
  const _WorkspaceSession({
    super.key,
    required this.source,
    required this.windowTitle,
    this.initialSelection,
    this.initialQuery = const WorkspaceQuery(),
    this.pageBuilder,
    this.desktop,
    this.inputsBuilder,
  });
  final WorkspaceSource source;
  final String windowTitle;
  final WorkspaceRecordRef? initialSelection;
  final WorkspaceQuery initialQuery;
  final WorkspacePageBuilder? pageBuilder;
  final WorkspaceDesktop? desktop;
  final WorkspaceInputs Function(BuildContext)? inputsBuilder;
  @override
  State<_WorkspaceSession> createState() => _WorkspaceAppState();
}

class _WorkspaceAppState extends State<_WorkspaceSession> {
  late final WorkspaceSource _source;
  late final WorkspaceController _controller;
  late final LibraryController _library;
  late final PluginsController _plugins;
  late final LegacyTemplatesController _legacy;
  late final ApprovalsController _approvals;
  late final GrantHistoryController _history;
  bool _historyFrozen = false;
  late final ProposalsController _proposals;
  bool _proposalFrozen = false;
  late final WorkspaceSettingsController _settings;
  late final ClassificationController _classifications;
  bool _settingsFrozen = false;
  late final BackupController _backups;
  bool _backupFrozen = false;
  late final WorkspaceRuntimeController _runtime;
  late final WorkspaceAgentsController _agents;
  bool _runtimeFrozen = false, _runtimeGate = false;
  bool _quitRequested = false;
  late final void Function(WorkspacePage) _desktopNavigation;
  late final void Function(String) _desktopRequestNavigation;
  StreamSubscription<WorkspaceRecordRef?>? _summaryChanges;
  int _modalDepth = 0;
  bool? _nativeNavigationEnabled;
  VoidCallback? _pendingUiNavigation;
  @override
  void initState() {
    super.initState();
    _source = widget.source;
    _controller = WorkspaceController(_source);
    _approvals = ApprovalsController(_source.approvals, _source.changes)
      ..addListener(_approvalChanged);
    unawaited(_approvals.load());
    _history = GrantHistoryController(
      _source.grantHistory,
      _source.approvals,
      _source.changes,
    )..addListener(_historyChanged);
    unawaited(_history.load());
    _proposals = ProposalsController(_source.proposals, _source.changes)
      ..addListener(_proposalChanged);
    unawaited(_proposals.load());
    _library = LibraryController(
      _source,
      initialQuery: widget.initialQuery,
      initialSelection: widget.initialSelection,
    );
    _classifications = ClassificationController(_source);
    _backups = BackupController(_source.backups, _source.changes)
      ..addListener(_backupChanged);
    unawaited(_backups.load());
    _runtime = WorkspaceRuntimeController(_source.runtime, _source.changes)
      ..addListener(_runtimeChanged);
    unawaited(_runtime.load());
    _agents = WorkspaceAgentsController(_source.agents, _source.changes);
    unawaited(_agents.load());
    _plugins = PluginsController(_source.plugins, _source.changes);
    _legacy = LegacyTemplatesController(
      _source.legacyTemplates,
      _source.changes,
    );
    _settings = WorkspaceSettingsController(
      _source.settings,
      _source.changes,
      onTheme: (theme) => _controller.setBrightness(
        theme == WorkspaceTheme.dark ? Brightness.dark : Brightness.light,
      ),
    )..addListener(_settingsChanged);
    unawaited(_settings.load());
    unawaited(_legacy.load());
    unawaited(_plugins.load());
    _summaryChanges = _source.changes.listen(
      (_) => unawaited(_controller.refresh()),
    );
    _desktopNavigation = (page) {
      if (_controller.navigationLocked) return;
      _controller.navigate(page);
      if (page == WorkspacePage.library) _library.focusSearch();
    };
    _desktopRequestNavigation = (id) {
      if (_controller.navigationLocked) return;
      _navigate(WorkspacePage.approvals, id);
    };
    if (widget.desktop case final WorkspaceRequestNavigation desktop) {
      desktop.onOpenRequest = _desktopRequestNavigation;
    }
    widget.desktop?.onNavigate = _desktopNavigation;
    unawaited(_controller.refresh());
    unawaited(
      _library.load(_library.query, keepSelection: widget.initialSelection),
    );
  }

  void _approvalChanged() {
    if (_approvals.frozen) _pendingUiNavigation = null;
    _syncNavigation();
  }

  void _historyChanged() {
    _historyFrozen = _history.frozen;
    if (_historyFrozen) _pendingUiNavigation = null;
    _syncNavigation();
  }

  void _proposalChanged() {
    _proposalFrozen = _proposals.frozen;
    if (_proposalFrozen) _pendingUiNavigation = null;
    _syncNavigation();
  }

  void _settingsChanged() {
    _settingsFrozen = _settings.frozen;
    if (_settingsFrozen) _pendingUiNavigation = null;
    _syncNavigation();
  }

  void _backupChanged() {
    _backupFrozen = _backups.frozen;
    if (_backupFrozen) _pendingUiNavigation = null;
    _syncNavigation();
  }

  void _runtimeChanged() {
    _runtimeFrozen = _runtime.frozen;
    _runtimeGate = _runtime.shutdownGate;
    if (_runtimeFrozen || _runtimeGate) _pendingUiNavigation = null;
    if (!_quitRequested &&
        _runtime.value?.phase == WorkspaceRuntimePhase.stopped) {
      _quitRequested = true;
      unawaited(widget.desktop?.quit());
    }
    _syncNavigation();
  }

  bool _deferNavigation(VoidCallback action) {
    if (!mounted ||
        _approvals.frozen ||
        _historyFrozen ||
        _proposalFrozen ||
        _settingsFrozen ||
        _backupFrozen ||
        _runtimeFrozen ||
        _runtimeGate) {
      return true;
    }
    if (_modalDepth > 0) {
      // Only explicit UI destinations wait for modal completion. Native events
      // are rejected, so an old system event never becomes a later navigation.
      _pendingUiNavigation = action;
      return true;
    }
    return false;
  }

  void _modalChanged(bool open) {
    if (!mounted) return;
    if (open) {
      _modalDepth++;
    } else if (_modalDepth > 0) {
      _modalDepth--;
    }
    _syncNavigation();
  }

  void _syncNavigation() {
    if (!mounted) return;
    final enabled =
        _modalDepth == 0 &&
        !_approvals.frozen &&
        !_historyFrozen &&
        !_proposalFrozen &&
        !_settingsFrozen &&
        !_backupFrozen &&
        !_runtimeFrozen &&
        !_runtimeGate;
    _controller.setNavigationLocked(!enabled);
    if (_nativeNavigationEnabled != enabled) {
      _nativeNavigationEnabled = enabled;
      unawaited(widget.desktop?.setNavigationEnabled(enabled));
    }
    if (enabled && _pendingUiNavigation != null) {
      final navigate = _pendingUiNavigation!;
      _pendingUiNavigation = null;
      scheduleMicrotask(() {
        if (mounted && !_controller.navigationLocked) navigate();
      });
    }
  }

  @override
  void dispose() {
    _approvals.dispose();
    _history.dispose();
    _proposals.dispose();
    _settings.dispose();
    _backups.dispose();
    _runtime.dispose();
    _agents.dispose();
    _classifications.dispose();
    _controller.dispose();
    _library.dispose();
    _plugins.dispose();
    _legacy.dispose();
    unawaited(_summaryChanges?.cancel());
    if (identical(widget.desktop?.onNavigate, _desktopNavigation)) {
      widget.desktop?.onNavigate = null;
    }
    if (widget.desktop case final WorkspaceRequestNavigation desktop) {
      if (identical(desktop.onOpenRequest, _desktopRequestNavigation)) {
        desktop.onOpenRequest = null;
      }
    }
    super.dispose();
  }

  Future<void> _createWithTemplate(
    BuildContext context,
    WorkspaceType type,
  ) async {
    _modalChanged(true);
    try {
      await _library.load(_library.query);
      if (!context.mounted) return;
      final ref = await showLibraryEditor(
        context,
        _library,
        selectedType: type,
      );
      if (!context.mounted || ref == null) return;
      await _library.openRelated(ref);
    } finally {
      _modalChanged(false);
    }
    if (mounted) _controller.navigate(WorkspacePage.library);
  }

  Future<void> _templateRecords(WorkspaceType type) async {
    await _library.apply(WorkspaceQuery(typeId: type.id));
    _controller.navigate(WorkspacePage.library);
  }

  Future<void> _createWithLegacy(
    BuildContext context,
    WorkspaceLegacyTemplate template,
  ) async {
    _modalChanged(true);
    try {
      await _library.load(_library.query);
      if (!context.mounted) return;
      final ref = await showLibraryEditor(
        context,
        _library,
        legacyTemplate: template,
        filePicker: widget.inputsBuilder?.call(context).file,
      );
      if (!context.mounted || ref == null) return;
      await _library.openRelated(ref);
    } finally {
      _modalChanged(false);
    }
    if (mounted) _controller.navigate(WorkspacePage.library);
  }

  void _navigate(WorkspacePage page, String id) {
    if (_deferNavigation(() => _navigate(page, id))) return;
    if (page == WorkspacePage.approvals) unawaited(_approvals.open(id));
    if (page == WorkspacePage.history) unawaited(_history.open(id));
    if (page == WorkspacePage.proposals) unawaited(_proposals.open(id));
    if (page == WorkspacePage.settings) {
      _settings.select(
        id == 'agents'
            ? WorkspaceSettingsSection.agents
            : id == 'runtime'
            ? WorkspaceSettingsSection.runtime
            : id == 'backups'
            ? WorkspaceSettingsSection.backups
            : WorkspaceSettingsSection.plugins,
      );
      const prefix = 'plugin:builtin.server/host:';
      if (id.startsWith(prefix)) {
        _plugins.showHostSettings(
          WorkspaceHostTarget.record(
            WorkspaceRecordRef(
              WorkspaceRecordKind.information,
              id.substring(prefix.length),
            ),
          ),
        );
      } else if (id == 'ssh-hosts') {
        _plugins.showHostSettings(null);
      }
    }
    _controller.navigate(page, objectId: id, remember: true);
  }

  Future<void> _hostRecord(WorkspaceRecordRef ref) async {
    if (_deferNavigation(() => unawaited(_hostRecord(ref)))) return;
    await _library.openRelated(ref);
    if (mounted) _controller.navigate(WorkspacePage.library, remember: true);
  }

  @override
  Widget build(BuildContext context) {
    final app = _buildApp();
    final desktop = widget.desktop;
    if (desktop == null) return app;
    return ValueListenableBuilder<DesktopScrollbarStyle>(
      valueListenable: desktop.scrollbarStyle,
      child: app,
      builder: (_, style, child) =>
          DesktopScrollbarScope(style: style, child: child!),
    );
  }

  Widget _buildApp() => ZhiyuApp(
    controller: _controller,
    windowTitle: widget.windowTitle,
    // A resumed unknown operation may arrive while the initial page is the
    // library. Keep reconciliation reachable even while navigation is locked.
    trailingBuilder: (_) => ListenableBuilder(
      listenable: _backups,
      builder: (context, _) => !_backups.uncertain
          ? const SizedBox.shrink()
          : Tooltip(
              message: '上次备份操作结果未确认。只核对原操作，不重新导出或恢复。',
              child: DesktopButton(
                key: const ValueKey('backup-root-reconcile'),
                onPressed: _backups.busy
                    ? null
                    : (_backups.needsAccess
                          ? _backups.recoverAccess
                          : _backups.reconcile),
                child: Text(
                  _backups.busy
                      ? '正在核对备份…'
                      : (_backups.needsAccess ? '重新选择原文件并核对' : '核对上次备份操作'),
                ),
              ),
            ),
    ),
    pageBuilder:
        widget.pageBuilder ??
        (context, location) => location.page == WorkspacePage.library
            ? LibraryPage(
                controller: _library,
                onWorkspaceBack: _controller.canGoBack
                    ? _controller.goBack
                    : null,
                workspaceBackLabel:
                    '返回${_controller.previousPage?.label ?? ''}',
                workspaceNavigationEnabled: !_controller.navigationLocked,
                filePicker: widget.inputsBuilder?.call(context).file,
                credentialPicker: widget.inputsBuilder
                    ?.call(context)
                    .credential,
                onRetry: () => unawaited(_library.load(_library.query)),
                onNavigate: _navigate,
                onModalChanged: _modalChanged,
              )
            : location.page == WorkspacePage.approvals
            ? ApprovalsPage(
                controller: _approvals,
                onHistory: (id) =>
                    _navigate(WorkspacePage.history, 'request:$id'),
                onRecord: (ref) => unawaited(_hostRecord(ref)),
                onRetry: () {
                  unawaited(_approvals.load());
                },
              )
            : location.page == WorkspacePage.proposals
            ? ProposalsPage(
                controller: _proposals,
                onWorkspaceBack: _controller.canGoBack
                    ? _controller.goBack
                    : null,
                workspaceBackLabel:
                    '返回${_controller.previousPage?.label ?? ''}',
                onHistory: (id) => _navigate(WorkspacePage.history, id),
                onRecord: (ref) => unawaited(_hostRecord(ref)),
                onModalChanged: _modalChanged,
                onRetry: () {
                  unawaited(_proposals.load());
                },
              )
            : location.page == WorkspacePage.history
            ? GrantHistoryPage(
                controller: _history,
                onWorkspaceBack: _controller.canGoBack
                    ? _controller.goBack
                    : null,
                workspaceBackLabel:
                    '返回${_controller.previousPage?.label ?? ''}',
                onProposal: (id) => _navigate(WorkspacePage.proposals, id),
                onRecord: (ref) => unawaited(_hostRecord(ref)),
                onRequest: (id) => _navigate(WorkspacePage.approvals, id),
                onModalChanged: _modalChanged,
                onRetry: () {
                  unawaited(_history.load(review: true));
                },
              )
            : WorkspaceSettingsPage(
                controller: _settings,
                plugins: _plugins,
                classifications: _classifications,
                backups: _backups,
                runtime: _runtime,
                agents: _agents,
                backupPicker:
                    widget.inputsBuilder?.call(context).backup ??
                    unavailableBackupInput,
                onLibrary: () => _navigate(WorkspacePage.library, ''),
                onRequest: (id) => _navigate(WorkspacePage.approvals, id),
                onModalChanged: _modalChanged,
                pluginBuilder: (context) => PluginsPage(
                  embedded: true,
                  controller: _plugins,
                  legacy: _legacy,
                  onLegacyCreate: (t) =>
                      unawaited(_createWithLegacy(context, t)),
                  hosts: _source.hosts,
                  hostChanges: _source.changes,
                  hostFilePicker:
                      widget.inputsBuilder?.call(context).hostFile ??
                      unavailableHostFileInput,
                  onRecord: (ref) => unawaited(_hostRecord(ref)),
                  picker:
                      widget.inputsBuilder?.call(context).plugin ??
                      unavailablePluginInput,
                  onRetry: () => unawaited(_plugins.load()),
                  onCreate: (type) =>
                      unawaited(_createWithTemplate(context, type)),
                  onRecords: (type) => unawaited(_templateRecords(type)),
                  onModalChanged: _modalChanged,
                ),
              ),
  );
}
