import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import '../desktop_controls.dart';
import '../desktop_feedback.dart';
import '../desktop_motion.dart';
import '../ui_palette.dart';
import '../prototype_icons.dart';
import 'sample_workspace_source.dart';
import 'sample_workspace_fixture.dart';
import 'sample_workspace_stress_fixture.dart';
import 'workspace_controller.dart';
import 'workspace_source.dart';
import 'zhiyu_app.dart';
import 'mac_preview_desktop.dart';
import 'workspace_records_controller.dart';
import 'library_controller.dart';
import 'library_page.dart';
import 'library_file_dialogs.dart';
import 'library_credential_choices.dart';
import 'plugins_controller.dart';
import 'plugins_page.dart';
import 'plugin_dialogs.dart';
import 'library_edit_dialog.dart';
import 'legacy_templates_controller.dart';
import 'approvals_controller.dart';
import 'approvals_page.dart';
import 'grant_history_controller.dart';
import 'grant_history_page.dart';

/// Only the isolated composition root knows which provider is a sample.
/// U02–U07 register their production widgets through pageBuilder.
class PreviewWorkspace extends StatefulWidget {
  const PreviewWorkspace({super.key, this.pageBuilder, this.desktop});
  final WorkspacePageBuilder? pageBuilder;
  final MacPreviewDesktop? desktop;
  @override
  State<PreviewWorkspace> createState() => _PreviewWorkspaceState();
}

class _PreviewWorkspaceState extends State<PreviewWorkspace> {
  late final SampleWorkspaceSource _source;
  late final WorkspaceController _controller;
  late final LibraryController _library;
  late final PluginsController _plugins;
  late final LegacyTemplatesController _legacy;
  late final ApprovalsController _approvals;
  late final GrantHistoryController _history;
  bool _historyFrozen = false;
  StreamSubscription<WorkspaceRecordRef?>? _summaryChanges;
  final _guideFocus = FocusNode();
  bool _stress = false;
  int _modalDepth = 0;
  bool? _nativeNavigationEnabled;
  VoidCallback? _pendingUiNavigation;
  @override
  void initState() {
    super.initState();
    _source = SampleWorkspaceSource(
      readAsset: (asset) async {
        final data = await rootBundle.load(asset);
        return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      },
    );
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
    _library = LibraryController(_source);
    _plugins = PluginsController(_source.plugins, _source.changes);
    _legacy = LegacyTemplatesController(
      _source.legacyTemplates,
      _source.changes,
    );
    unawaited(_legacy.load());
    unawaited(_plugins.load());
    _summaryChanges = _source.changes.listen(
      (_) => unawaited(_controller.refresh()),
    );
    widget.desktop?.onNavigate = (page) {
      if (_controller.navigationLocked) return;
      _controller.navigate(page);
      if (page == WorkspacePage.library) _library.focusSearch();
    };
    unawaited(_controller.refresh());
    unawaited(
      _library.load(
        _library.query,
        keepSelection: const WorkspaceRecordRef(
          WorkspaceRecordKind.information,
          'azure',
        ),
      ),
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

  bool _deferNavigation(VoidCallback action) {
    if (!mounted || _approvals.frozen || _historyFrozen) return true;
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
    final enabled = _modalDepth == 0 && !_approvals.frozen && !_historyFrozen;
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
    _guideFocus.dispose();
    _approvals.dispose();
    _history.dispose();
    _controller.dispose();
    _library.dispose();
    _plugins.dispose();
    _legacy.dispose();
    unawaited(_summaryChanges?.cancel());
    _source.dispose();
    widget.desktop?.dispose();
    super.dispose();
  }

  void _scenario(SampleWorkspaceScenario value) {
    _source.setScenario(value);
    unawaited(_controller.refresh());
    unawaited(_library.load(_library.query));
    unawaited(_plugins.load());
    unawaited(_legacy.load());
    unawaited(_approvals.load());
    unawaited(_history.load());
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
        filePicker: () =>
            showWorkspaceFileChoices(context, _source.fileChoices),
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
    if (page == WorkspacePage.settings) {
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

  Future<void> _dataset(bool stress) async {
    await _source.replaceFixture(
      stress ? buildWorkspaceStressFixture() : sampleWorkspaceJson,
    );
    _stress = stress;
    await _controller.refresh();
    _approvals.resetView();
    _history.resetView();
    await _library.resetView();
    if (stress) await _library.showAll();
  }

  void _guide(BuildContext context) {
    _modalChanged(true);
    unawaited(
      showDesktopDialog<void>(
        context,
        returnFocus: _guideFocus,
        builder: (dialogContext) => DesktopDialog(
          title: const Text('设计说明与界面检查'),
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('按已确认的知予工作台布局制作。当前窗口使用独立示例数据，重启或重置后恢复初始内容。'),
              const SizedBox(height: 22),
              const Text('阅读外观', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 10),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final value in Brightness.values)
                    DesktopButton(
                      key: ValueKey('preview-theme-${value.name}'),
                      onPressed: () {
                        _controller.setBrightness(value);
                        Navigator.pop(dialogContext);
                      },
                      child: Text(value == Brightness.light ? '明亮' : '黑暗'),
                    ),
                ],
              ),
              const SizedBox(height: 22),
              const Text('资料规模', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 10),
              const Text(
                '压力场景含200条普通信息、8条凭据、50个目录和100个标签，全部为虚构内容。切换规模会重置预览修改与返回位置。',
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final stress in [false, true])
                    DesktopButton(
                      key: ValueKey(
                        'preview-dataset-${stress ? 'stress' : 'reference'}',
                      ),
                      selected: _stress == stress,
                      onPressed: () async {
                        Navigator.pop(dialogContext);
                        await _dataset(stress);
                      },
                      child: Text(stress ? '压力资料' : '基准资料'),
                    ),
                ],
              ),
              const SizedBox(height: 22),
              const Text('审批状态', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 10),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  DesktopButton(
                    key: const ValueKey('preview-approval-executions'),
                    onPressed:
                        _approvals.detail?.credentialExpiresAt != null &&
                            _approvals.detail!.scopes.any(
                              (x) =>
                                  x.kind ==
                                      WorkspaceApprovalScopeKind.credential &&
                                  x.available,
                            )
                        ? () {
                            _source.demonstrateApprovalExecutions(
                              _approvals.selection!,
                            );
                            Navigator.pop(dialogContext);
                          }
                        : null,
                    child: const Text('显示三次凭据使用结果'),
                  ),
                  DesktopButton(
                    key: const ValueKey('preview-approval-execution-observe'),
                    onPressed:
                        _approvals.detail?.executions.any(
                              (e) => e.state == WorkspaceExecutionState.unknown,
                            ) ==
                            true
                        ? () {
                            _source.publishApprovalExecutionObservation(
                              _approvals.selection!,
                            );
                            Navigator.pop(dialogContext);
                          }
                        : null,
                    child: const Text('更新未知操作的清理状态'),
                  ),
                  DesktopButton(
                    key: const ValueKey('preview-approval-execution-failure'),
                    onPressed: () {
                      _source.nextApprovalExecutionReadFailure =
                          const WorkspaceFailure(
                            'offline',
                            '原操作暂时无法查询，原状态已保留。不要重跑。',
                          );
                      Navigator.pop(dialogContext);
                    },
                    child: const Text('下一次使用结果查询失败'),
                  ),
                  DesktopButton(
                    key: const ValueKey('preview-approval-expire'),
                    onPressed: () {
                      _source.advanceApprovalClock(const Duration(hours: 9));
                      Navigator.pop(dialogContext);
                    },
                    child: const Text('推进请求与授权到期'),
                  ),
                  DesktopButton(
                    key: const ValueKey('preview-approval-session-end'),
                    onPressed: () {
                      _source.endApprovalSession('session-maintenance');
                      Navigator.pop(dialogContext);
                    },
                    child: const Text('结束维护会话'),
                  ),
                  DesktopButton(
                    key: const ValueKey('preview-approval-unknown'),
                    onPressed: () {
                      _source.loseNextApprovalReply = true;
                      Navigator.pop(dialogContext);
                    },
                    child: const Text('下一次审批回包丢失'),
                  ),
                ],
              ),
              const SizedBox(height: 22),
              const Text('读取状态', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 10),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final value in SampleWorkspaceScenario.values)
                    DesktopButton(
                      key: ValueKey('preview-scenario-${value.name}'),
                      onPressed: () {
                        _scenario(value);
                        Navigator.pop(dialogContext);
                      },
                      child: Text(switch (value) {
                        SampleWorkspaceScenario.ready => '正常资料',
                        SampleWorkspaceScenario.empty => '空资料',
                        SampleWorkspaceScenario.waiting => '持续等待',
                        SampleWorkspaceScenario.failure => '读取失败',
                      }),
                    ),
                ],
              ),
              const SizedBox(height: 22),
              const Text(
                '主机身份状态',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final scenario in SampleHostScenario.values)
                    DesktopButton(
                      key: ValueKey('preview-host-${scenario.name}'),
                      onPressed: () async {
                        Navigator.pop(dialogContext);
                        _scenario(SampleWorkspaceScenario.ready);
                        await _source.demonstrateHost(scenario);
                        if (!mounted) return;
                        _plugins.showHostSettings(null);
                        _controller.navigate(WorkspacePage.settings);
                      },
                      child: Text(
                        scenario == SampleHostScenario.fingerprintChanged
                            ? '东京主机指纹变化'
                            : '东京主机缺少指纹',
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 22),
              const Text(
                '按钮和表单',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 10),
              _ControlSample(
                source: _source,
                failNextSave: () =>
                    _source.nextSaveFailure = const WorkspaceFailure(
                      'sample_save_failed',
                      '保存失败，输入已保留，请重试。',
                    ),
              ),
              const SizedBox(height: 18),
              DesktopButton(
                key: const ValueKey('preview-file-error'),
                onPressed: () {
                  _source.nextFilePreviewFailure = const WorkspaceFailure(
                    'preview_unavailable',
                    '文件预览失败，文件信息仍可查看。',
                  );
                  Navigator.pop(dialogContext);
                },
                child: const Text('下一次文件预览失败（刷新预览后生效）'),
              ),
              const SizedBox(height: 12),
              DesktopButton(
                key: const ValueKey('preview-credential-error'),
                onPressed: () {
                  _source.nextCredentialReadFailure = const WorkspaceFailure(
                    'unavailable',
                    '凭据资料读取失败，请重试。',
                  );
                  Navigator.pop(dialogContext);
                },
                child: const Text('下一次凭据读取失败（刷新凭据资料后生效）'),
              ),
            ],
          ),
          actions: [
            DesktopButton(
              onPressed: () {
                _source.reset();
                _approvals.resetView();
                _history.resetView();
                unawaited(_library.resetView());
                unawaited(_controller.refresh());
                Navigator.pop(dialogContext);
                DesktopFeedback.show(context, '已重置预览资料');
              },
              child: const Text('重置预览资料'),
            ),
            DesktopButton(
              kind: DesktopButtonKind.primary,
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('完成'),
            ),
          ],
        ),
      ).whenComplete(() {
        _modalChanged(false);
        // The guide trigger is disabled while a modal holds navigation. Restore
        // focus after the enabled widget has rebuilt, not before gate release.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_controller.navigationLocked) {
            _guideFocus.requestFocus();
          }
        });
      }),
    );
  }

  @override
  Widget build(BuildContext context) => ZhiyuApp(
    controller: _controller,
    windowTitle: MacPreviewDesktop.windowTitle,
    trailingBuilder: (context) => DesktopButton(
      key: const ValueKey('preview-guide'),
      focusNode: _guideFocus,
      kind: DesktopButtonKind.quiet,
      fontSize: 12,
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
      onPressed: _controller.navigationLocked ? null : () => _guide(context),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('设计说明'),
          const SizedBox(width: 7),
          SizedBox(
            width: 19,
            height: 24.1875,
            child: Align(
              alignment: Alignment.topCenter,
              child: PrototypeIcon(
                PrototypeIconGlyph.arrow,
                size: 19,
                color: UiPalette.of(context).ink,
              ),
            ),
          ),
        ],
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
                filePicker: () =>
                    showWorkspaceFileChoices(context, _source.fileChoices),
                credentialPicker: (form) => showWorkspaceCredentialChoices(
                  context,
                  _source.credentials.candidates,
                  form: form,
                ),
                onRetry: () => _scenario(SampleWorkspaceScenario.ready),
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
                  _source.setScenario(SampleWorkspaceScenario.ready);
                  unawaited(_approvals.load());
                },
              )
            : location.page == WorkspacePage.history
            ? GrantHistoryPage(
                controller: _history,
                onRecord: (ref) => unawaited(_hostRecord(ref)),
                onRequest: (id) => _navigate(WorkspacePage.approvals, id),
                onModalChanged: _modalChanged,
                onRetry: () {
                  _source.setScenario(SampleWorkspaceScenario.ready);
                  unawaited(_history.load(review: true));
                },
              )
            : location.page == WorkspacePage.settings
            ? PluginsPage(
                controller: _plugins,
                legacy: _legacy,
                onLegacyCreate: (t) => unawaited(_createWithLegacy(context, t)),
                hosts: _source.hosts,
                hostChanges: _source.changes,
                onRecord: (ref) => unawaited(_hostRecord(ref)),
                picker: () => showPluginChoices(
                  context,
                  _source.pluginChoices,
                  _source.plugins.releaseCandidate,
                ),
                onRetry: () => _scenario(SampleWorkspaceScenario.ready),
                onCreate: (type) =>
                    unawaited(_createWithTemplate(context, type)),
                onRecords: (type) => unawaited(_templateRecords(type)),
                onModalChanged: _modalChanged,
              )
            : _FoundationPage(
                controller: _controller,
                onRetry: () => _scenario(SampleWorkspaceScenario.ready),
              ),
  );
}

class _ControlSample extends StatefulWidget {
  const _ControlSample({required this.source, required this.failNextSave});
  final WorkspaceSource source;
  final VoidCallback failNextSave;
  @override
  State<_ControlSample> createState() => _ControlSampleState();
}

class _ControlSampleState extends State<_ControlSample> {
  String _selection = '文本';
  late final WorkspaceRecordsController _records;
  final _name = TextEditingController();
  WorkspaceDetail? _draft;
  bool _dirty = false;
  static int _nextOperationId = 0;
  @override
  void initState() {
    super.initState();
    _records = WorkspaceRecordsController(widget.source)..addListener(_changed);
    unawaited(_records.load(const WorkspaceQuery(typeId: 'server')));
  }

  void _changed() {
    if (!mounted) return;
    final detail = _records.detail;
    if (!_dirty && !_name.value.composing.isValid && detail != null) {
      _draft = detail;
      if (_name.text != detail.record.name) _name.text = detail.record.name;
    }
    setState(() {});
  }

  Future<void> _save() async {
    final draft = _draft;
    if (draft == null) return;
    final submittedName = _name.text;
    final result = await _records.save(
      WorkspaceEdit(
        operationId: 'preview-control-${_nextOperationId++}',
        expectedVersion: draft.version,
        record: draft.record.copyWith(name: submittedName),
        values: const {},
      ),
    );
    if (!mounted) return;
    if (result case WorkspaceSaved(:final detail)) {
      _draft = detail;
      if (_name.text == submittedName) {
        _dirty = false;
        _name.text = detail.record.name;
      }
      DesktopFeedback.show(context, '已保存到预览资料');
    }
  }

  @override
  void dispose() {
    _records.removeListener(_changed);
    _records.dispose();
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          DesktopButton(
            key: const ValueKey('preview-action'),
            onPressed: _draft == null ? null : _save,
            busy: _records.saveState == WorkspaceSaveState.saving,
            child: const Text('保存'),
          ),
          const DesktopButton(onPressed: null, child: Text('不可用')),
          DesktopButton(
            tooltip: '字段的展示形式；普通文件与凭据分别管理。',
            kind: DesktopButtonKind.quiet,
            onPressed: () {},
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('字段形式'),
                SizedBox(width: 5),
                Icon(Icons.info_outline, size: 15),
              ],
            ),
          ),
        ],
      ),
      const SizedBox(height: 12),
      TextField(
        key: const ValueKey('preview-text-input'),
        controller: _name,
        enabled: _records.saveState != WorkspaceSaveState.saving,
        onChanged: (_) => _dirty = true,
        decoration: InputDecoration(
          labelText: '示例输入',
          errorText: _records.saveFailure?.fieldErrors['name'],
        ),
      ),
      if (_records.saveFailure != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            _records.saveFailure!.message,
            style: TextStyle(color: UiPalette.of(context).danger),
          ),
        ),
      if (_records.failure != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text('示例资料暂不可用：${_records.failure!.message}'),
        ),
      Align(
        alignment: Alignment.centerLeft,
        child: DesktopButton(
          kind: DesktopButtonKind.quiet,
          onPressed: widget.failNextSave,
          child: const Text('下次保存失败'),
        ),
      ),
      const SizedBox(height: 12),
      DesktopSelect<String>(
        isExpanded: true,
        value: _selection,
        onChanged: (value) => setState(() => _selection = value!),
        items: const [
          DropdownMenuItem(value: '文本', child: Text('文本')),
          DropdownMenuItem(value: '多行文本', child: Text('多行文本')),
          DropdownMenuItem(value: '文件', child: Text('文件')),
        ],
      ),
    ],
  );
}

/// Temporary U01 surface, replaced by the module page builders in U02–U07.
/// It exercises the public loading contract, not a copy of the HTML prototype.
class _FoundationPage extends StatelessWidget {
  const _FoundationPage({required this.controller, required this.onRetry});
  final WorkspaceController controller;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) {
    final c = UiPalette.of(context);
    return DesktopEntrance(
      key: ValueKey(controller.location.page),
      child: Center(
        child: Container(
          width: 620,
          margin: const EdgeInsets.all(28),
          padding: const EdgeInsets.all(32),
          decoration: BoxDecoration(
            color: c.paper,
            border: Border.all(color: c.line),
            borderRadius: BorderRadius.circular(10),
          ),
          child: SingleChildScrollView(
            primary: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  controller.location.page.label,
                  style: Theme.of(context).textTheme.headlineLarge,
                ),
                const SizedBox(height: 16),
                switch (controller.load) {
                  WorkspaceLoad.idle || WorkspaceLoad.loading => const Row(
                    children: [
                      SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      SizedBox(width: 10),
                      Text('正在读取…'),
                    ],
                  ),
                  WorkspaceLoad.error => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(controller.failure!.message),
                      const SizedBox(height: 16),
                      DesktopButton(
                        onPressed: onRetry,
                        child: const Text('重试'),
                      ),
                    ],
                  ),
                  WorkspaceLoad.empty => const Text('暂无资料'),
                  WorkspaceLoad.ready => Text(
                    '${controller.summary!.records} 项资料 · '
                    '${controller.summary!.pending} 条待处理请求 · ${controller.summary!.proposals} 条录入提案',
                  ),
                },
              ],
            ),
          ),
        ),
      ),
    );
  }
}
