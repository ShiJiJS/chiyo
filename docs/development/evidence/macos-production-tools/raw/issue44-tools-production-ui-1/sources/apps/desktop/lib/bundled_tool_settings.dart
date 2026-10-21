import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:info_cli/macos_bundled_tools.dart';
import 'package:info_core/agent_server.dart';
import 'settings_controls.dart';

class BundledToolSettings extends StatefulWidget {
  const BundledToolSettings({super.key, this.read});
  final Future<List<CredentialToolLocation>> Function()? read;
  @override
  State<BundledToolSettings> createState() => _BundledToolSettingsState();
}

class _BundledToolSettingsState extends State<BundledToolSettings> {
  late Future<List<CredentialToolLocation>> _tools = _read();
  Future<List<CredentialToolLocation>> _read() =>
      (widget.read ?? MacBundledTools().read)();
  String? _message;

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: _tools,
    builder: (context, snapshot) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Mac 凭据工具'),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Text(
            'GH 和 AWS 使用应用随包版本，SSH 使用系统程序。入口核对不代表凭据已授权；每次使用仍核对程序身份与版本。',
          ),
        ),
        if (snapshot.hasError)
          const SettingsNotice('工具状态无法读取', '请检查应用是否完整，并重新打开或刷新。', error: true),
        for (final tool in snapshot.data ?? <CredentialToolLocation>[])
          SettingsRow(
            switch (tool.receiver) {
              'gh_token' => 'GH ${tool.version}',
              'aws_shared_credentials' => 'AWS CLI ${tool.version}',
              _ => '系统 SSH',
            },
            tool.available
                ? '${tool.executable}\n${tool.source == 'app_bundle' ? '随包入口摘要已核对。' : '版本将在使用时核对。'}'
                : tool.source == 'system'
                ? '系统 SSH 不可用，请检查系统程序。'
                : '工具未随包提供或入口校验失败，请使用完整的 Mac Release 构建。',
            control: settingsAction(
              context,
              '复制路径',
              tool.available && tool.executable != null
                  ? () async {
                      try {
                        await Clipboard.setData(
                          ClipboardData(text: tool.executable!),
                        );
                        if (mounted) setState(() => _message = '已复制工具路径。');
                      } on Object {
                        if (mounted) setState(() => _message = '复制未完成，请重试。');
                      }
                    }
                  : null,
              key: ValueKey('copy-tool-${tool.receiver}'),
            ),
          ),
        if (_message != null) Text(_message!),
        Align(
          alignment: Alignment.centerLeft,
          child: settingsAction(context, '刷新随包工具状态', () {
            setState(() {
              _message = null;
              _tools = _read();
            });
          }),
        ),
      ],
    ),
  );
}
