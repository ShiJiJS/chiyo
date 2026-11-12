import 'dart:async';
import 'package:flutter/material.dart';
import 'package:info_remote/connection_profile.dart';
import 'connection_view.dart';
import 'local_library_sync.dart';
import 'onboarding/setup_configuration.dart';
import 'onboarding/server_setup_controller.dart';

/// Everyday connection management. Only a first connection to an uninitialized
/// server opens the shared one-time password prompt, never the startup wizard.
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
  final Future<void> Function(bool) onSaved;
  final ValueChanged<bool> onBusy;
  final Future<void> Function()? beforeSave;
  @override
  State<LocalSyncSettings> createState() => _LocalSyncSettingsState();
}

class _LocalSyncSettingsState extends State<LocalSyncSettings> {
  ServerSetupController? _controller;
  String? _error;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final stored = await widget.sync.readConfiguration();
      if (!mounted) return;
      final controller = ServerSetupController(
        previous: stored['server'] == null
            ? null
            : ConnectionProfile.fromJson(
                Map<String, dynamic>.from(stored['server'] as Map),
              ),
        syncEnabled: stored['enabled'] as bool,
        onBusy: widget.onBusy,
        onConnected: (profile, client) async {
          await widget.beforeSave?.call();
          await widget.sync.connect(profile, connection: client);
          await widget.onSaved(true);
        },
        onLocal: () async {
          await widget.beforeSave?.call();
          await widget.sync.disable();
          await widget.onSaved(false);
        },
      );
      setState(() => _controller = controller);
    } on Object {
      if (mounted) setState(() => _error = '无法读取同步设置，原资料和连接均已保留。');
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_controller case final controller?) {
      return ConnectionSettings(draft: controller, onBack: widget.onBack);
    }
    return ConnectionSurface(
      embedded: true,
      title: '存储与同步',
      description: _error ?? '',
      loading: _error == null,
      children: const [],
    );
  }
}
