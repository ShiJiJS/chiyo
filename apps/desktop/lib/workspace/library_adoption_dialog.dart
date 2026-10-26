import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import '../desktop_controls.dart';
import '../ui_palette.dart';
import 'library_widgets.dart';
import 'record_mutation.dart';
import 'workspace_source.dart';

Future<WorkspaceRecordRef?> showLibraryAdoption(
  BuildContext context,
  WorkspaceSource source,
  WorkspaceRecordRef ref,
) => showDesktopDialog<WorkspaceRecordRef>(
  context,
  builder: (_) => _AdoptionDialog(source: source, ref: ref),
);

class _AdoptionDialog extends StatefulWidget {
  const _AdoptionDialog({required this.source, required this.ref});
  final WorkspaceSource source;
  final WorkspaceRecordRef ref;
  @override
  State<_AdoptionDialog> createState() => _AdoptionDialogState();
}

class _AdoptionDialogState extends State<_AdoptionDialog> {
  WorkspaceDetail? _current;
  List<WorkspacePluginTemplate> _templates = const [];
  String? _target;
  WorkspaceAdoptionPreview? _plan;
  WorkspaceFailure? _failure;
  final _mappings = <String, Map<String, WorkspaceFieldMapping>>{};
  final _values = <String, TextEditingController>{};
  late final RecordMutation _mutation;
  bool _loading = true, _showRetained = false;
  int _step = 0, _generation = 0;
  bool get _locked => _loading || _mutation.frozen;
  WorkspacePluginTemplate? get _template =>
      _templates.where((t) => t.type.id == _target).firstOrNull;
  Map<String, WorkspaceFieldMapping> get _fields =>
      _mappings.putIfAbsent(_target!, () => {});
  List<Map<String, Object?>> get _sourceFields => [
    ...workspaceFields(_current!),
    for (final key in _current!.values.keys)
      if (!workspaceFields(_current!).any((f) => f['key'] == key))
        {
          'key': key,
          'label': key,
          'type': _current!.values[key] is String ? 'multiline' : 'unknown',
        },
  ];
  @override
  void initState() {
    super.initState();
    _mutation = RecordMutation(widget.source)..addListener(_changed);
    unawaited(_load());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _release() async {
    final plan = _plan;
    _plan = null;
    if (plan != null) await widget.source.releaseAdoption(plan.planId);
  }

  Future<void> _load() async {
    if (_mutation.frozen) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _failure = null;
    });
    await _release();
    try {
      final current = await widget.source.readDetail(widget.ref);
      final catalog = await widget.source.plugins.load();
      if (!mounted || generation != _generation) return;
      _current = current;
      _templates = [
        for (final p in catalog.packages)
          if (p.enabled) ...p.templates,
      ];
      if (!_templates.any((t) => t.type.id == _target)) {
        _target = null;
        _step = 0;
      }
      _mutation.acceptCurrentVersion();
    } catch (e) {
      if (!mounted || generation != _generation) return;
      _failure = e is WorkspaceFailure
          ? e
          : const WorkspaceFailure('unavailable', '资料和模板暂时无法读取，请重试。');
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  TextEditingController _value(String key) =>
      _values.putIfAbsent('$_target/$key', () => TextEditingController());
  WorkspaceFieldMapping _mapping(String key) =>
      _fields[key] ?? const WorkspaceFieldMapping();
  void _map(String key, {String? source, bool? same}) {
    final old = _mapping(key);
    setState(() {
      _fields[key] = WorkspaceFieldMapping(
        sourceKey: source ?? old.sourceKey,
        sameMeaning: same ?? false,
      );
      _failure = null;
    });
    _mutation.edited();
  }

  Future<void> _preview() async {
    if (_locked || _template == null) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _failure = null;
    });
    await _release();
    try {
      final fields = <String, WorkspaceFieldMapping>{};
      for (final f in _template!.definition['fields'] as List? ?? []) {
        final key = f['key'] as String, m = _mapping(key);
        fields[key] = WorkspaceFieldMapping(
          sourceKey: m.sourceKey,
          sameMeaning: m.sameMeaning,
          value: _value(key).text,
        );
      }
      final plan = await widget.source.previewAdoption(
        WorkspaceAdoptionDraft(
          ref: widget.ref,
          typeId: _target!,
          fields: fields,
        ),
      );
      if (!mounted || generation != _generation) {
        await widget.source.releaseAdoption(plan.planId);
        return;
      }
      _plan = plan;
      _current = plan.current;
      _step = 2;
      _mutation.acceptCurrentVersion();
    } catch (e) {
      if (!mounted || generation != _generation) return;
      _failure = e is WorkspaceFailure
          ? e
          : const WorkspaceFailure('unavailable', '暂时无法生成采用预览，请重试。');
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _apply() async {
    final plan = _plan;
    if (_locked || plan == null || !plan.canApply) return;
    final receipt = await _mutation.submit(
      WorkspaceOperationIntent(
        kind: WorkspaceOperationKind.adoptTemplate,
        ref: widget.ref,
        typeId: plan.target.type.id,
        expectedVersion: plan.current.version,
        planId: plan.planId,
      ),
      (id) => widget.source.applyAdoption(id, plan.planId),
    );
    if (mounted && receipt != null) Navigator.pop(context, receipt.ref);
  }

  Future<void> _reconcile() async {
    final receipt = await _mutation.reconcile();
    if (!mounted) return;
    if (receipt != null) {
      Navigator.pop(context, receipt.ref);
    } else if (!_mutation.uncertain) {
      setState(
        () => _failure = const WorkspaceFailure(
          'not_committed',
          '已确认尚未提交，原映射保留。请重新预览后再决定。',
        ),
      );
    }
  }

  String _text(Object? value) =>
      value is List && value.every((v) => v is Map && v.containsKey('entryId'))
      ? value
            .map((v) => '${v['title']} · ${v['period']}\n${v['detail']}')
            .join('\n\n')
      : value is Map &&
            value.containsKey('attachmentId') &&
            value.containsKey('version')
      ? '普通附件（版本${value['version']}）'
      : value == null || value == ''
      ? '未填写'
      : value is String
      ? value
      : const JsonEncoder.withIndent('  ').convert(value);
  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(text, style: libraryText(context, 14, weight: FontWeight.w600)),
  );
  Widget _mappingFields() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        '为目标字段选择来源，或填写新值。未选中的原内容会保留。',
        style: libraryText(context, 13, color: UiPalette.of(context).muted),
      ),
      const SizedBox(height: 18),
      for (final f in _template!.definition['fields'] as List? ?? [])
        Container(
          key: ValueKey('adoption-field-${f['key']}'),
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: UiPalette.of(context).line),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _label('${f['label']}${f['required'] == true ? '（必填）' : ''}'),
              DesktopSelect<String>(
                key: ValueKey('adoption-source-${f['key']}'),
                value: _mapping(f['key'] as String).sourceKey ?? '',
                items: [
                  const DropdownMenuItem(value: '', child: Text('新字段')),
                  for (final source in _sourceFields)
                    DropdownMenuItem(
                      value: source['key'] as String,
                      child: Text(
                        '${source['label']} · ${source['type']}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: _locked
                    ? null
                    : (v) {
                        if (v == '') {
                          setState(
                            () => _fields[f['key'] as String] =
                                const WorkspaceFieldMapping(),
                          );
                          _mutation.edited();
                        } else {
                          _map(f['key'] as String, source: v);
                        }
                      },
              ),
              const SizedBox(height: 10),
              if (_mapping(f['key'] as String).sourceKey == null) ...[
                if (f['type'] == 'entries')
                  const Text('从空经历列表开始，采用后可继续添加。')
                else
                  DesktopTextField(
                    key: ValueKey('adoption-value-${f['key']}'),
                    controller: _value(f['key'] as String),
                    enabled: !_locked,
                    maxLines: f['type'] == 'multiline' ? 4 : 1,
                    onChanged: (_) => _mutation.edited(),
                    decoration: InputDecoration(hintText: '填写新值'),
                  ),
              ] else ...[
                SelectableText(
                  _text(
                    _current!.values[_mapping(f['key'] as String).sourceKey],
                  ),
                  style: libraryText(context, 13, height: 1.7),
                ),
                CheckboxListTile(
                  key: ValueKey('adoption-meaning-${f['key']}'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('含义相同，保留原字段身份'),
                  subtitle: const Text('不勾选时复制为新身份，原字段另外保留。'),
                  value: _mapping(f['key'] as String).sameMeaning,
                  onChanged: _locked
                      ? null
                      : (v) => _map(f['key'] as String, same: v!),
                ),
              ],
            ],
          ),
        ),
    ],
  );
  String _errorLabel(String key) {
    for (final row in _plan!.rows) {
      if (key == workspaceValueErrorKey(row.key) ||
          key.startsWith('${row.key}:')) {
        return row.label;
      }
    }
    for (final field in _plan!.result.retainedFields) {
      if (key == field['key'] || key.startsWith('${field['key']}:')) {
        return '${field['label']}（保留）';
      }
    }
    return key == 'budget' ? '字段数量' : '字段校验';
  }

  String _previewText(Object? value) {
    final text = _text(value);
    return text.length <= 2000
        ? text
        : '${text.substring(0, 2000)}\n…（预览前2000字，原内容完整保留）';
  }

  Widget _review() {
    final plan = _plan!, c = UiPalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _label('${plan.current.record.name} → ${plan.target.type.name}'),
        Text(
          '目录、标签、附件、关联和原修订保留；采用不会批准新的信息访问或凭据使用。',
          style: libraryText(context, 13, color: c.muted),
        ),
        const SizedBox(height: 18),
        _label('保留的原字段（${plan.retained.length}）'),
        if (plan.retained.isEmpty)
          const Text('所有原字段已明确对应。')
        else if (plan.retained.length <= 3 || _showRetained)
          for (final field in plan.result.retainedFields)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    field['label'] as String,
                    style: libraryText(context, 13, color: c.muted),
                  ),
                  const SizedBox(height: 5),
                  SelectableText(
                    _previewText(plan.result.values[field['key']]),
                    style: libraryText(context, 14, height: 1.7),
                  ),
                ],
              ),
            ),
        if (plan.retained.length > 3)
          Align(
            alignment: Alignment.centerLeft,
            child: DesktopButton(
              key: const ValueKey('adoption-retained-toggle'),
              kind: DesktopButtonKind.quiet,
              onPressed: _mutation.frozen
                  ? null
                  : () => setState(() => _showRetained = !_showRetained),
              child: Text(_showRetained ? '收起保留内容' : '查看保留内容'),
            ),
          ),
        const SizedBox(height: 18),
        _label('目标模板字段'),
        for (final row in plan.rows)
          Container(
            key: ValueKey('adoption-review-${row.key}'),
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: c.line)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _label(row.label),
                Text(
                  '${row.sourceLabel ?? '新填写'} → ${row.result}${plan.result.values[row.key] == '' ? ' · 未填写' : ''}',
                  style: libraryText(context, 13, color: c.muted),
                ),
                if (plan.result.values[row.key] != '') ...[
                  const SizedBox(height: 8),
                  SelectableText(
                    _previewText(plan.result.values[row.key]),
                    style: libraryText(context, 14, height: 1.7),
                  ),
                ],
                if ((plan.errors[workspaceValueErrorKey(row.key)] ??
                        plan.errors[row.key])
                    case final error?)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      error,
                      style: libraryText(context, 13, color: c.danger),
                    ),
                  ),
              ],
            ),
          ),
        for (final e in plan.errors.entries.where(
          (e) => !plan.rows.any(
            (r) => r.key == e.key || workspaceValueErrorKey(r.key) == e.key,
          ),
        ))
          Text(
            '${_errorLabel(e.key)}：${e.value}',
            style: libraryText(context, 13, color: c.danger),
          ),
        const SizedBox(height: 16),
        Text(
          '采用后只更新这一份资料的模板快照，其他资料保持原样。',
          style: libraryText(context, 13, color: c.muted),
        ),
      ],
    );
  }

  @override
  void dispose() {
    ++_generation;
    unawaited(_release());
    _mutation.removeListener(_changed);
    _mutation.dispose();
    for (final c in _values.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final failure =
        _mutation.failure ??
        _failure ??
        (_plan?.canApply == false
            ? WorkspaceFailure(
                'validation',
                '还有${_plan!.errors.length}处需要调整，请核对字段对应。',
              )
            : null);
    return PopScope(
      canPop: !_mutation.frozen,
      child: DesktopDialog(
        key: ValueKey('adoption-step-$_step'),
        width: 860,
        title: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(switch (_step) {
              0 => '选择目标模板',
              1 => '对应原字段',
              _ => '预览采用结果',
            }),
            if (failure != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  failure.message,
                  key: const ValueKey('adoption-error'),
                  style: libraryText(
                    context,
                    14,
                    height: 1.5,
                    color: UiPalette.of(context).danger,
                  ),
                ),
              ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_loading) const Text('正在读取资料与模板…'),
            if (_current != null && _step == 0) ...[
              Text('为“${_current!.record.name}”选择已启用模板。先核对字段对应，再确认采用。'),
              const SizedBox(height: 18),
              if (_templates.isEmpty) const Text('没有可采用的模板，请先在设置中安装或启用插件。'),
              for (final t in _templates)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: DesktopButton(
                    key: ValueKey('adoption-target-${t.type.id}'),
                    selected: _target == t.type.id,
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.all(14),
                    leading: RecordIcon(t.type),
                    onPressed: _locked
                        ? null
                        : () => setState(() {
                            _target = t.type.id;
                            _step = 1;
                          }),
                    child: Text(
                      '${t.type.name} · ${t.definition['templateVersion'] ?? ''}',
                    ),
                  ),
                ),
            ],
            if (_current != null && _step == 1 && _template != null)
              _mappingFields(),
            if (_step == 2 && _plan != null) _review(),
          ],
        ),
        actions: [
          DesktopButton(
            key: const ValueKey('adoption-cancel'),
            onPressed: _mutation.frozen ? null : () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          if (_mutation.uncertain)
            DesktopButton(
              key: const ValueKey('adoption-reconcile'),
              busy: _mutation.busy,
              onPressed: _mutation.busy ? null : _reconcile,
              child: const Text('核对结果'),
            )
          else ...[
            DesktopButton(
              key: const ValueKey('adoption-refresh'),
              onPressed: _locked
                  ? null
                  : () {
                      _step = _target == null ? 0 : 1;
                      unawaited(_load());
                    },
              child: const Text('重新读取'),
            ),
            if (_step > 0)
              DesktopButton(
                key: const ValueKey('adoption-back'),
                onPressed: _locked
                    ? null
                    : () {
                        unawaited(_release());
                        setState(() => _step--);
                      },
                child: Text(_step == 2 ? '返回调整' : '更换模板'),
              ),
            if (_step == 1)
              DesktopButton(
                key: const ValueKey('adoption-preview'),
                kind: DesktopButtonKind.primary,
                onPressed: _locked ? null : _preview,
                child: const Text('预览字段对应'),
              ),
            if (_step == 2)
              DesktopButton(
                key: const ValueKey('adoption-apply'),
                kind: DesktopButtonKind.primary,
                busy: _mutation.busy,
                onPressed:
                    _locked ||
                        !_mutation.canSubmit ||
                        _plan?.canApply != true ||
                        _failure?.code == 'not_committed'
                    ? null
                    : _apply,
                child: const Text('确认采用'),
              ),
          ],
        ],
      ),
    );
  }
}
