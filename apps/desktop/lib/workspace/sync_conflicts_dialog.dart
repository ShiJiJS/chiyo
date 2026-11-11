import 'dart:math';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_workspace/workspace_information_codec.dart';
import '../desktop_controls.dart';
import '../ui_palette.dart';
import 'workspace_source.dart';
import 'workspace_sync.dart';
import 'library_widgets.dart';
import 'library_document.dart';
import 'template_record_content.dart';

Future<void> showSyncConflicts(
  BuildContext context,
  WorkspaceSyncReview sync,
  WorkspaceSource source,
) => showDialog<void>(
  context: context,
  builder: (_) => _SyncConflicts(sync: sync, source: source),
);

class _SyncConflicts extends StatefulWidget {
  const _SyncConflicts({required this.sync, required this.source});
  final WorkspaceSyncReview sync;
  final WorkspaceSource source;
  @override
  State<_SyncConflicts> createState() => _SyncConflictsState();
}

class _SyncConflictsState extends State<_SyncConflicts> {
  late Future<List<Map<String, Object?>>> _load;
  int _item = 0;
  bool _saving = false;
  String? _operation;
  bool? _choice;
  String? _error;
  final _reading = <String, DocumentReadingController>{};
  @override
  void initState() {
    super.initState();
    _load = widget.sync.reviewConflicts();
  }

  @override
  void dispose() {
    for (final c in _reading.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _reload() {
    setState(() {
      _item = 0;
      _error = null;
      _operation = null;
      _choice = null;
      _load = widget.sync.reviewConflicts();
    });
  }

  Future<void> _save(Map<String, Object?> conflict, bool choice) async {
    _operation ??= base64Url
        .encode(List.generate(24, (_) => Random.secure().nextInt(256)))
        .replaceAll('=', '');
    _choice ??= choice;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.sync.resolveConflict(conflict, _choice!, _operation!);
      if (mounted) _reload();
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = '未能确认处理结果。请重试原选择，或关闭后重新同步查看。';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
        });
      }
    }
  }

  Widget _candidate(Map raw, String label, String identity) {
    final candidate = Map<String, dynamic>.from(raw);
    final info = candidate['information'];
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(
          color: UiPalette.of(context).rail,
          border: Border.all(color: UiPalette.of(context).line),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              label,
              style: libraryText(context, 16, weight: FontWeight.w700),
            ),
            const SizedBox(height: 16),
            if (candidate['deleted'] == true)
              const Text('已删除')
            else if (info is Map) ...[
              Builder(
                builder: (context) {
                  final detail = WorkspaceInformationCodec().decode(
                    core.informationFromJson(Map<String, dynamic>.from(info)),
                  );
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        detail.record.name,
                        style: libraryText(
                          context,
                          22,
                          weight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        detail.record.type.name,
                        style: libraryText(
                          context,
                          13,
                          color: UiPalette.of(context).muted,
                        ),
                      ),
                      if (detail.record.description.isNotEmpty)
                        Text(detail.record.description),
                      TemplateRecordContent(
                        detail: detail,
                        relations: widget.source,
                        onOpen: null,
                        fileBuilder: (key) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          child: Text(
                            workspaceFields(detail)
                                        .where((f) => f['key'] == key)
                                        .firstOrNull?['label']
                                    as String? ??
                                '文件',
                          ),
                        ),
                        credentialBuilder: (_) => const SizedBox.shrink(),
                        documentController: _reading.putIfAbsent(
                          identity,
                          DocumentReadingController.new,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ] else if (candidate['credential'] case final Map credential) ...[
              Text(
                credential['name'] as String,
                style: libraryText(context, 22, weight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              Text('账号：${credential['account'] ?? '未填写'}'),
              Text('用途：${credential['publicPurpose'] ?? ''}'),
              Text('修改时间：${credential['modifiedAt'] ?? ''}'),
              const SizedBox(height: 12),
              const Text('凭据内容已加密保留。选择后使用对应的密码或凭据文件。'),
            ] else ...[
              for (final row in candidate['summary'] as List? ?? const [])
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text((row as Map)['name'] as String? ?? '相关记录'),
                ),
            ],
          ],
        ),
      ),
    );
  }

  String _name(Map row) {
    for (final side in ['incoming', 'local']) {
      final c = row[side] as Map;
      if (c['information'] is Map) {
        return (c['information'] as Map)['name'] as String;
      }
      if (c['credential'] is Map) {
        return (c['credential'] as Map)['name'] as String;
      }
    }
    return switch ((row['key'] as Map)['kind']) {
      'directory' => '目录',
      'tag' => '标签',
      'plugin' => '模板插件',
      'template' => '资料模板',
      'order' => '排列顺序',
      'recycle' => '回收站',
      'history' => '历史记录',
      _ => '关联内容',
    };
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: Dialog(
      child: SizedBox(
        width: 1120,
        height: 760,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: FutureBuilder<List<Map<String, Object?>>>(
            future: _load,
            builder: (context, result) {
              if (result.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (result.hasError) {
                return Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text('暂时无法读取需要处理的内容。'),
                    DesktopButton(
                      onPressed: _reload,
                      child: const Text('重新读取'),
                    ),
                    DesktopButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('关闭'),
                    ),
                  ],
                );
              }
              final all = result.data!;
              if (all.isEmpty) {
                return Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text('没有需要处理的同步冲突。'),
                    const SizedBox(height: 16),
                    DesktopButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('完成'),
                    ),
                  ],
                );
              }
              final conflict = all.first;
              final items = conflict['items'] as List;
              final remote = conflict['remote'] == true;
              final left = remote ? '服务器内容' : '本机内容';
              final right = remote ? '本机内容' : '服务器内容';
              final row = items[_item.clamp(0, items.length - 1)] as Map;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '选择要保留的内容',
                          style: libraryText(
                            context,
                            24,
                            weight: FontWeight.w700,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: _saving
                            ? null
                            : () => Navigator.pop(context),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '这组内容在两端分别有修改。选择后整组保存，原来的内容保留在历史中。',
                    style: libraryText(
                      context,
                      14,
                      color: UiPalette.of(context).muted,
                    ),
                  ),
                  const SizedBox(height: 20),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (var i = 0; i < items.length; i++)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ChoiceChip(
                              label: Text(_name(items[i] as Map)),
                              selected: i == _item,
                              onSelected: _saving
                                  ? null
                                  : (_) => setState(() => _item = i),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Expanded(
                    child: SingleChildScrollView(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _candidate(
                            row['local'] as Map,
                            left,
                            '${conflict['cursor']}:$_item:left',
                          ),
                          const SizedBox(width: 16),
                          _candidate(
                            row['incoming'] as Map,
                            right,
                            '${conflict['cursor']}:$_item:right',
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Text(_error!),
                    ),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Text('共 ${all.length} 组'),
                      const Spacer(),
                      if (_saving)
                        const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      const SizedBox(width: 12),
                      DesktopButton(
                        onPressed: _saving || _choice == true
                            ? null
                            : () => _save(conflict, false),
                        child: Text(_choice == false ? '重试原选择' : '使用$left'),
                      ),
                      const SizedBox(width: 12),
                      DesktopButton(
                        onPressed: _saving || _choice == false
                            ? null
                            : () => _save(conflict, true),
                        child: Text(_choice == true ? '重试原选择' : '使用$right'),
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      ),
    ),
  );
}
