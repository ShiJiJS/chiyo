import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart';
import 'information_files.dart';
import 'prototype_ui.dart';
import 'ui_palette.dart';

/// Loads version metadata only; scrolling and rebuilding never load a body.
class InformationFileSummary extends StatefulWidget {
  const InformationFileSummary({
    super.key,
    required this.owner,
    required this.reference,
    this.actions,
    this.compact = false,
    this.onLoaded,
  });
  final OwnerAccess owner;
  final InformationAttachmentRef reference;
  final Widget Function(InformationAttachmentVersion version)? actions;
  final bool compact;
  final ValueChanged<InformationAttachmentVersion>? onLoaded;
  @override
  State<InformationFileSummary> createState() => _InformationFileSummaryState();
}

class _InformationFileSummaryState extends State<InformationFileSummary> {
  late Future<InformationAttachmentVersion> _version = _load();
  Future<InformationAttachmentVersion> _load() async {
    final reference = widget.reference;
    final versions = await widget.owner.informationAttachmentVersions(
      reference.attachmentId,
    );
    final version = versions.firstWhere(
      (version) => version.reference == reference,
      orElse: () => throw const AccessFailure('attachment_missing'),
    );
    if (mounted) widget.onLoaded?.call(version);
    return version;
  }

  @override
  void didUpdateWidget(InformationFileSummary old) {
    super.didUpdateWidget(old);
    if (old.owner != widget.owner || old.reference != widget.reference) {
      _version = _load();
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: _version,
    builder: (context, snapshot) {
      final p = UiPalette.of(context), version = snapshot.data;
      if (version == null) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              snapshot.hasError ? '文件说明未能加载' : '正在读取文件说明…',
              style: prototypeText(context, 13, color: p.muted),
            ),
            if (snapshot.hasError)
              TextButton(
                style: prototypeButton(context, size: 12),
                onPressed: () => setState(() => _version = _load()),
                child: const Text('重试'),
              ),
          ],
        );
      }
      if (widget.compact) {
        return Text(
          '${version.originalName} · ${informationFileSize(version.byteLength)} · 版本 ${version.reference.attachmentVersion}${version.available ? '' : ' · 原文件已清理'}',
          style: prototypeText(context, 12, family: 'Consolas', height: 1.6),
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SelectableText(
            version.originalName,
            style: prototypeText(context, 14, weight: FontWeight.w600),
          ),
          Text(
            '${informationFileSize(version.byteLength)} · ${version.mediaType} · 版本 ${version.reference.attachmentVersion}',
            style: prototypeText(context, 13, color: p.muted, height: 1.8),
          ),
          if (!version.available)
            Text(
              '原文件已清理，仅保留版本记录。',
              style: prototypeText(context, 12, color: p.muted),
            ),
          if (widget.actions != null) widget.actions!(version),
        ],
      );
    },
  );
}
