import 'package:flutter/material.dart';
import 'desktop_controls.dart';
import 'ui_palette.dart';
import 'workspace/library_widgets.dart';

/// Shared presentation for connection, recovery and loading. Network and
/// profile decisions stay in the launcher; no preview values are supplied here.
class ConnectionSurface extends StatelessWidget {
  const ConnectionSurface({
    super.key,
    required this.title,
    required this.description,
    required this.children,
    this.icon = Icons.dns_outlined,
    this.loading = false,
    this.embedded = false,
  });
  final String title, description;
  final List<Widget> children;
  final IconData icon;
  final bool loading, embedded;
  @override
  Widget build(BuildContext context) {
    final c = UiPalette.of(context);
    return ColoredBox(
      color: c.rail,
      child: SafeArea(
        child: Align(
          alignment: embedded ? Alignment.topLeft : Alignment.center,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: SizedBox(
              width: 480,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: c.selected,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: loading
                          ? SizedBox(
                              width: 30,
                              height: 30,
                              child: CircularProgressIndicator(
                                color: c.accent,
                                strokeWidth: 2,
                              ),
                            )
                          : Icon(icon, color: c.accent, size: 30),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(title, style: libraryHeading(context, 28)),
                  const SizedBox(height: 10),
                  Text(
                    description,
                    style: libraryText(
                      context,
                      14,
                      color: c.muted,
                      height: 1.6,
                    ),
                  ),
                  const SizedBox(height: 28),
                  ...children,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum ConnectionCertificateStatus { unconfigured, unverified, verified, error }

class ConnectionForm extends StatefulWidget {
  const ConnectionForm({
    super.key,
    required this.address,
    required this.token,
    required this.certificate,
    required this.busy,
    required this.onConnect,
    this.error,
    this.onConfirmServer,
    this.onCancel,
    this.embedded = false,
    this.certificateStatus = ConnectionCertificateStatus.unconfigured,
  });
  final TextEditingController address, token, certificate;
  final bool busy;
  final String? error;
  final VoidCallback onConnect;
  final VoidCallback? onConfirmServer, onCancel;
  final bool embedded;
  final ConnectionCertificateStatus certificateStatus;
  @override
  State<ConnectionForm> createState() => _ConnectionFormState();
}

class _ConnectionFormState extends State<ConnectionForm> {
  bool _visible = false;
  @override
  Widget build(BuildContext context) {
    final c = UiPalette.of(context), w = widget;
    return ConnectionSurface(
      title: w.embedded ? '存储与同步' : '连接服务器',
      embedded: w.embedded,
      description: w.embedded ? '查看或修改服务器连接。保存成功后切换。' : '连接后查看和管理你的资料。',
      loading: w.busy,
      children: [
        DesktopTextField(
          controller: w.address,
          enabled: !w.busy,
          decoration: const InputDecoration(
            labelText: '服务器地址',
            hintText: 'https://server.example:47126',
          ),
        ),
        const SizedBox(height: 18),
        DesktopTextField(
          controller: w.token,
          enabled: !w.busy,
          obscureText: !_visible,
          decoration: InputDecoration(
            labelText: 'Token',
            suffixIcon: IconButton(
              tooltip: _visible ? '隐藏 Token' : '显示 Token',
              onPressed: w.busy
                  ? null
                  : () => setState(() => _visible = !_visible),
              icon: Icon(
                _visible
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
                size: 18,
              ),
            ),
          ),
        ),
        const SizedBox(height: 18),
        Container(
          decoration: BoxDecoration(
            border: Border.all(color: c.line),
            borderRadius: BorderRadius.circular(8),
          ),
          clipBehavior: Clip.antiAlias,
          child: ExpansionTile(
            backgroundColor: Colors.transparent,
            collapsedBackgroundColor: Colors.transparent,
            tilePadding: const EdgeInsets.symmetric(horizontal: 14),
            childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
            shape: const Border(),
            collapsedShape: const Border(),
            leading: Icon(
              Icons.verified_user_outlined,
              size: 18,
              color: w.certificateStatus == ConnectionCertificateStatus.error
                  ? c.danger
                  : w.certificateStatus == ConnectionCertificateStatus.verified
                  ? c.success
                  : c.muted,
            ),
            title: Row(
              children: [
                Expanded(child: Text('服务器证书', style: libraryText(context, 13))),
                Text(
                  switch (w.certificateStatus) {
                    ConnectionCertificateStatus.unconfigured => '未配置',
                    ConnectionCertificateStatus.unverified => '待核验',
                    ConnectionCertificateStatus.verified => '已核验',
                    ConnectionCertificateStatus.error => '核验失败',
                  },
                  style: libraryText(
                    context,
                    13,
                    color:
                        w.certificateStatus == ConnectionCertificateStatus.error
                        ? c.danger
                        : w.certificateStatus ==
                              ConnectionCertificateStatus.verified
                        ? c.success
                        : c.muted,
                  ),
                ),
              ],
            ),
            children: [
              DesktopTextField(
                controller: w.certificate,
                enabled: !w.busy,
                minLines: 3,
                maxLines: 6,
                decoration: const InputDecoration(
                  labelText: '服务器 CA 证书',
                  helperText: '使用私人证书时填写，不会修改系统信任设置。',
                ),
              ),
            ],
          ),
        ),
        if (w.error != null)
          Padding(
            padding: const EdgeInsets.only(top: 18),
            child: Text(
              w.error!,
              key: const ValueKey('connection-error'),
              style: libraryText(context, 14, color: c.danger),
            ),
          ),
        const SizedBox(height: 24),
        if (w.onConfirmServer != null) ...[
          DesktopButton(
            onPressed: w.busy ? null : w.onConfirmServer,
            child: const Text('确认连接新服务器'),
          ),
          const SizedBox(height: 12),
        ],
        DesktopButton(
          kind: DesktopButtonKind.primary,
          key: const ValueKey('connection-save'),
          busy: w.busy,
          onPressed: w.busy ? null : w.onConnect,
          child: Text(
            w.busy
                ? '正在连接…'
                : w.embedded
                ? '保存并连接'
                : '连接',
          ),
        ),
        if (w.onCancel != null) ...[
          const SizedBox(height: 12),
          DesktopButton(
            key: const ValueKey('connection-cancel'),
            kind: DesktopButtonKind.quiet,
            onPressed: w.busy ? null : w.onCancel,
            child: const Text('返回工作区'),
          ),
        ],
      ],
    );
  }
}
