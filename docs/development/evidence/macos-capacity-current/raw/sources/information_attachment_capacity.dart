import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart';
import 'information_files.dart';
import 'prototype_ui.dart';
import 'settings_controls.dart';

class InformationAttachmentCapacity extends StatefulWidget {
  const InformationAttachmentCapacity({super.key, required this.owner});
  final OwnerAccess owner;
  @override
  State<InformationAttachmentCapacity> createState() =>
      _InformationAttachmentCapacityState();
}

class _InformationAttachmentCapacityState
    extends State<InformationAttachmentCapacity> {
  InformationAttachmentUsage? _usage;
  bool _loading = true, _failed = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final usage = await widget.owner.informationAttachmentUsage();
      if (mounted) setState(() => _usage = usage);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.owner.serviceAvailable) {
      return const SettingsNotice(
        '附件用量未能读取',
        '本机服务暂不可用，请恢复服务后刷新。',
        error: true,
      );
    }
    final usage = _usage;
    final copies = widget.owner.informationFileDeliveries
        .where((r) => r.holdsCopy)
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsRow(
          '普通附件容量',
          usage == null
              ? _failed
                    ? '附件用量未能读取。'
                    : '正在读取附件用量…'
              : '原件与草稿 ${informationFileSize(usage.originalAndStagedBytes)} / ${informationFileSize(informationFileStagingByteLimit)}。\n可用原文版本 ${usage.availableVersions} 份（含当前及保留版本），未保存草稿 ${usage.stagedFiles} 份；版本记录 ${usage.versionRecords} 条。',
          control: settingsAction(
            context,
            _loading ? '正在刷新…' : '刷新用量',
            _loading ? null : _load,
            key: const ValueKey('refresh-attachment-usage'),
          ),
        ),
        if (_failed)
          SettingsNotice(
            '用量未更新',
            usage == null ? '读取失败，尚无可用的用量结果，请重试。' : '读取失败；已显示的用量为上次结果，请重试。',
            error: true,
          ),
        SettingsRow(
          '受管文件副本',
          '${copies.length} / $informationDeliveryLimit 份 · ${informationFileSize(copies.fold<int>(0, (sum, r) => sum + r.byteLength))} / ${informationFileSize(informationDeliveryByteLimit)}。\n包含准备中和待回收副本；历史归档不占活副本额度。',
          control: const SizedBox.shrink(),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 27),
          child: Text(
            '单文件最多 ${informationFileSize(informationFileByteLimit)}。历史版本和回收内容至少保留30天；删除不会立即释放原件容量。',
            style: prototypeText(context, 13, height: 1.8),
          ),
        ),
      ],
    );
  }
}
