import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart';
import 'prototype_ui.dart';
import 'prototype_dialog.dart';
import 'ui_palette.dart';

/// Shows immutable delivery facts and cleanup state, never a lease or path.
class InformationDeliveryHistory extends StatefulWidget {
  const InformationDeliveryHistory({
    super.key,
    required this.records,
    this.onRetryCleanup,
  });
  final List<InformationFileDelivery> records;
  final Future<void> Function()? onRetryCleanup;
  @override
  State<InformationDeliveryHistory> createState() =>
      _InformationDeliveryHistoryState();
}

class _InformationDeliveryHistoryState
    extends State<InformationDeliveryHistory> {
  int _page = 0;
  bool _busy = false;
  String? _error;
  static const _limit = 8;
  Future<void> _retry() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onRetryCleanup!();
    } catch (_) {
      if (mounted) setState(() => _error = '回收尚未完成，请稍后重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = UiPalette.of(context);
    final records = widget.records.toList()
      ..sort((a, b) {
        final time = b.createdAt.compareTo(a.createdAt);
        return time == 0 ? a.id.compareTo(b.id) : time;
      });
    final pages = records.isEmpty ? 1 : (records.length + _limit - 1) ~/ _limit;
    final page = _page.clamp(0, pages - 1);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '文件交付记录',
          style: prototypeText(context, 16, weight: FontWeight.w600),
        ),
        const SizedBox(height: 10),
        if (records.isEmpty)
          Text(
            '尚无文件交付。批准后不会自动领取文件。',
            style: prototypeText(context, 13, color: p.muted),
          ),
        for (final record in records.skip(page * _limit).take(_limit))
          Container(
            key: ValueKey('file-delivery-${record.id}'),
            padding: const EdgeInsets.symmetric(vertical: 13),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: p.line)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        '${record.field.fieldName} · 版本 ${record.attachment.attachmentVersion}',
                        style: prototypeText(
                          context,
                          14,
                          weight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 18),
                    Flexible(
                      fit: FlexFit.tight,
                      child: Text(
                        '${record.restoredAt == null ? '' : '历史：'}${_state(record.state)}',
                        textAlign: TextAlign.right,
                        style: prototypeText(context, 13, color: p.muted),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 5),
                Text(
                  '${_time(record.createdAt)} · 操作 ${record.operationId}',
                  style: prototypeText(
                    context,
                    13,
                    color: p.muted,
                    height: 1.8,
                  ),
                ),
                if (_reason(record.reason) case final reason?
                    when record.runtime)
                  Text(
                    reason,
                    style: prototypeText(
                      context,
                      13,
                      color: p.muted,
                      height: 1.8,
                    ),
                  ),
                if (record.state == 'cleanup_pending' && record.runtime)
                  Text(
                    record.cleanupError == 'cleanup_identity_mismatch'
                        ? '本机副本身份需要核对，尚未删除。'
                        : '副本仍被占用或暂时无法回收，将保留登记并重试。',
                    style: prototypeText(
                      context,
                      12,
                      color: p.muted,
                      height: 1.8,
                    ),
                  ),
                if (record.restoredAt != null)
                  Text(
                    '恢复的交付事实，不代表当前存在副本或读取权限。',
                    style: prototypeText(
                      context,
                      12,
                      color: p.muted,
                      height: 1.8,
                    ),
                  ),
              ],
            ),
          ),
        if (records.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              children: [
                Text(
                  '${records.length} 条交付记录',
                  style: prototypeText(context, 12, color: p.muted),
                ),
                const Spacer(),
                TextButton(
                  key: const ValueKey('file-deliveries-previous'),
                  style: prototypeButton(context, size: 14),
                  onPressed: page == 0
                      ? null
                      : () => setState(() => _page = page - 1),
                  child: const Text('‹'),
                ),
                Text(
                  '${page + 1} / $pages',
                  style: prototypeText(context, 12, color: p.muted),
                ),
                TextButton(
                  key: const ValueKey('file-deliveries-next'),
                  style: prototypeButton(context, size: 14),
                  onPressed: page + 1 == pages
                      ? null
                      : () => setState(() => _page = page + 1),
                  child: const Text('›'),
                ),
              ],
            ),
          ),
        if (widget.onRetryCleanup != null &&
            records.any((r) => r.runtime && r.state == 'cleanup_pending'))
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              style: prototypeSecondary(context),
              onPressed: _busy ? null : _retry,
              child: Text(_busy ? '正在核对副本…' : '重试回收'),
            ),
          ),
        if (_error != null)
          Text(_error!, style: prototypeText(context, 13, color: p.danger)),
        if (records.isNotEmpty)
          Text(
            '每次交付保留当次版本。这里不记录正文或临时路径，也不表示网站上传完成。',
            style: prototypeText(context, 13, color: p.muted, height: 1.8),
          ),
        const SizedBox(height: 22),
      ],
    );
  }

  String _time(DateTime date) {
    final local = date.toLocal();
    return '${local.year}/${local.month.toString().padLeft(2, '0')}/${local.day.toString().padLeft(2, '0')} ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }

  String _state(String state) => switch (state) {
    'preparing' => '准备中',
    'ready' => '副本已就绪',
    'cleanup_pending' => '待回收副本',
    'released' => '已释放',
    'expired' => '已失效',
    'failed' => '交付失败',
    'unknown' => '交付结果未知',
    _ => '状态未确认',
  };
  String? _reason(String? reason) => switch (reason) {
    'released' => '本次交付已显式释放。',
    'grant_expired' => '授权已到期。',
    'not_authorized' => '该授权已不可用于领取文件。',
    'session_ended' => '授权会话已结束。',
    'field_removed' => '原字段已移除。',
    'restarted' => '应用重启后没有重放本次交付。',
    'service_closed' => '本次应用运行已结束。',
    'delivery_io_failed' => '文件准备或写入失败。',
    'attachment_integrity_failed' => '原文件完整性校验未通过。',
    'audit_failed' => '交付记录保存异常。',
    'delivery_unknown' => '交付结果未确认。',
    _ => null,
  };
}
