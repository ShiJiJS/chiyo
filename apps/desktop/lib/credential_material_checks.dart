import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart';
import 'credential_execution_receipt.dart';
import 'settings_controls.dart';
import 'prototype_ui.dart';
import 'ui.dart';

class CredentialMaterialChecks extends StatefulWidget {
  const CredentialMaterialChecks({
    super.key,
    required this.owner,
    this.reconcile,
  });
  final OwnerAccess owner;
  final Future<void> Function()? reconcile;
  @override
  State<CredentialMaterialChecks> createState() =>
      _CredentialMaterialChecksState();
}

class _CredentialMaterialChecksState extends State<CredentialMaterialChecks> {
  int _page = 0;
  bool _busy = false;
  String? _error;
  Future<void> _check() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (widget.reconcile != null) {
        await widget.reconcile!();
      } else {
        await widget.owner.reconcileCredentialMaterialCleanup();
      }
    } on Object {
      if (mounted) setState(() => _error = '核查暂时失败，材料已保留，请检查本机存储。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final records = widget.owner.credentialMaterialChecks;
    final pages = (records.length / 5).ceil().clamp(1, 1 << 30);
    final page = _page.clamp(0, pages - 1);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsRow(
          '临时凭据材料',
          records.isEmpty
              ? '暂无待核查的已结束执行。活动任务的文件会保留至进程组结束。'
              : '${records.length} 项待核查。仅处理已登记的材料，核查失败时保留文件；不会重跑命令或终止进程。',
          control: settingsAction(
            context,
            _busy ? '正在核查…' : '重新核查',
            _busy ? null : _check,
          ),
        ),
        for (final record in records.skip(page * 5).take(5))
          Builder(
            builder: (context) {
              final request = widget.owner.credentialUseRequests
                  .where((r) => r.id == record.requestId)
                  .firstOrNull;
              return SettingsRow(
                request?.chatLabel ?? '执行 ${record.id}',
                '${credentialExecutionLabel(record)} · ${credentialCleanupLabel(record.cleanupState)}',
                control: settingsAction(
                  context,
                  '查看执行记录',
                  request == null
                      ? null
                      : () async {
                          await showCredentialExecutionReceipt(
                            context,
                            widget.owner,
                            request,
                          );
                          if (mounted) setState(() {});
                        },
                ),
              );
            },
          ),
        if (pages > 1)
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                style: prototypeButton(context),
                onPressed: page > 0
                    ? () => setState(() => _page = page - 1)
                    : null,
                child: const Text('上一页'),
              ),
              Text(
                '${page + 1} / $pages',
                style: prototypeText(
                  context,
                  12,
                  color: UiPalette.of(context).muted,
                ),
              ),
              TextButton(
                style: prototypeButton(context),
                onPressed: page + 1 < pages
                    ? () => setState(() => _page = page + 1)
                    : null,
                child: const Text('下一页'),
              ),
            ],
          ),
        if (_error != null) SettingsNotice('核查未完成', _error!, error: true),
      ],
    );
  }
}
