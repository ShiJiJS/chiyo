import 'package:flutter/material.dart';
import 'package:info_remote/connection_profile.dart';
import 'package:info_remote/owner_client.dart';

import 'connection_view.dart';
import 'local_library_sync.dart';

/// The approved connection form backed by the actual local sync coordinator.
class LocalSyncSettings extends StatefulWidget {
  const LocalSyncSettings({
    super.key,
    required this.sync,
    required this.onBack,
    required this.onSaved,
    required this.onBusy,
    this.beforeSave,
  });
  final LocalLibrarySync sync;
  final VoidCallback onBack;
  final ValueChanged<bool> onSaved, onBusy;
  final Future<void> Function()? beforeSave;
  @override
  State<LocalSyncSettings> createState() => _LocalSyncSettingsState();
}

class _LocalSyncSettingsState extends State<LocalSyncSettings> {
  final _address = TextEditingController(),
      _token = TextEditingController(),
      _certificate = TextEditingController();
  ConnectionProfile? _saved;
  bool _loading = true, _busy = false, _enabled = false;
  bool _activeEnabled = false;
  bool _serverChanged = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _address.addListener(_draftChanged);
    _token.addListener(_draftChanged);
    _certificate.addListener(_draftChanged);
    _load();
  }

  void _draftChanged() {
    if (mounted) {
      setState(() {
        _error = null;
        _serverChanged = false;
      });
    }
  }

  Future<void> _load() async {
    try {
      final stored = await widget.sync.readConfiguration();
      if (!mounted) return;
      _enabled = stored['enabled'] as bool;
      _activeEnabled = _enabled;
      if (stored['server'] != null) {
        _saved = ConnectionProfile.fromJson(
          Map<String, dynamic>.from(stored['server'] as Map),
        );
        _address.text = _saved!.address;
        _token.text = _saved!.token;
        _certificate.text = _saved!.certificate;
      }
    } on Object {
      _error = '无法读取同步设置，原资料不会被替换。';
    }
    if (mounted) setState(() => _loading = false);
  }

  String _message(Object error) => switch (error) {
    RemoteFailure(code: 'unauthorized') => 'Token 不正确，请重新填写。',
    RemoteFailure(code: 'invalid_connection') ||
    FormatException() => '请填写完整的 HTTPS 服务器地址和 Token。',
    RemoteFailure(code: 'different_libraries') =>
      '本机和服务器都有不同的资料。已保留双方内容，请先导出备份，再选择空的目标资料库。',
    RemoteFailure(code: 'server_changed') => '服务器身份与原连接不一致，请核对地址和证书。',
    RemoteFailure(code: 'untrusted_server') => '服务器证书未通过核验，请检查地址和证书。',
    RemoteFailure(code: 'unsupported_sync') => '服务器版本暂不支持资料同步，请先更新服务器。',
    RemoteFailure(code: 'sync_pending_other_library') =>
      '上次同步还未完成，请先恢复原连接并核对结果。',
    RemoteFailure(code: 'sync_base_changed') =>
      '资料库的同步记录与当前连接不一致。资料已保留，请先备份，再使用空目标重新建立同步。',
    RemoteFailure(code: 'sync_transfer_expired') => '上次传输已过期，原资料没有被覆盖。请重新准备同步。',
    _ => '尚未确认同步完成，可以重试。已有资料会保留。',
  };

  Future<void> _selectMode(bool enabled) async {
    if (_busy || _loading || _enabled == enabled) return;
    setState(() {
      _enabled = enabled;
      _error = null;
    });
    // Connecting needs an address and successful verification. Local mode can
    // take effect immediately, including while the server is unavailable.
    if (!enabled) await _save();
  }

  Future<void> _save({bool confirmServer = false}) async {
    if (_busy || _loading) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    widget.onBusy(true);
    try {
      await widget.beforeSave?.call();
      if (_enabled) {
        final address = _address.text.trim();
        final uri = Uri.tryParse(address);
        if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
          throw const RemoteFailure('invalid_connection');
        }
        await widget.sync.connect(
          ConnectionProfile(
            address: address,
            token: _token.text.trim(),
            certificate: _certificate.text.trim(),
            serverId: !confirmServer && _saved?.address == address
                ? _saved!.serverId
                : '',
          ),
        );
      } else {
        await widget.sync.disable();
      }
      _activeEnabled = _enabled;
      widget.onSaved(_activeEnabled);
      final stored = await widget.sync.readConfiguration();
      if (mounted && stored['server'] != null) {
        _saved = ConnectionProfile.fromJson(
          Map<String, dynamic>.from(stored['server'] as Map),
        );
      }
    } on Object catch (error) {
      if (mounted) {
        _error = _message(error);
        _serverChanged =
            error is RemoteFailure && error.code == 'server_changed';
        if (!_enabled) _enabled = _activeEnabled;
      }
    } finally {
      widget.onBusy(false);
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _address.dispose();
    _token.dispose();
    _certificate.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const ConnectionSurface(
        embedded: true,
        title: '存储与同步',
        description: '',
        loading: true,
        children: [],
      );
    }
    final verified =
        _saved != null &&
        _saved!.address == _address.text &&
        _saved!.certificate == _certificate.text;
    return ConnectionForm(
      embedded: true,
      address: _address,
      token: _token,
      certificate: _certificate,
      busy: _busy,
      syncEnabled: _enabled,
      onSyncChanged: _selectMode,
      onConnect: _save,
      onConfirmServer: _serverChanged ? () => _save(confirmServer: true) : null,
      onCancel: widget.onBack,
      error: _error,
      certificateStatus: verified && !_serverChanged
          ? ConnectionCertificateStatus.verified
          : _certificate.text.isEmpty
          ? ConnectionCertificateStatus.unconfigured
          : ConnectionCertificateStatus.unverified,
    );
  }
}
