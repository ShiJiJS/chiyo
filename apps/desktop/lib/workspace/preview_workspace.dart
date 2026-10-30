import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'sample_workspace_source.dart';
import 'workspace_app.dart';
import 'workspace_source.dart';
import 'workspace_inputs.dart';
import 'zhiyu_app.dart';
import 'mac_preview_desktop.dart';

/// The isolated entry owns its sample data and native preview bridge. Production
/// composes WorkspaceApp directly and does not import this provider.
class PreviewWorkspace extends StatefulWidget {
  const PreviewWorkspace({
    super.key,
    this.pageBuilder,
    this.desktop,
    this.inputsBuilder,
  });
  final WorkspacePageBuilder? pageBuilder;
  final MacPreviewDesktop? desktop;
  final WorkspaceInputs Function(BuildContext)? inputsBuilder;
  @override
  State<PreviewWorkspace> createState() => _PreviewWorkspaceState();
}

class _PreviewWorkspaceState extends State<PreviewWorkspace> {
  late final SampleWorkspaceSource _source = SampleWorkspaceSource(
    readAsset: (asset) async {
      final data = await rootBundle.load(asset);
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    },
  );

  @override
  void dispose() {
    _source.dispose();
    widget.desktop?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => WorkspaceApp(
    source: _source,
    windowTitle: MacPreviewDesktop.windowTitle,
    initialSelection: const WorkspaceRecordRef(
      WorkspaceRecordKind.information,
      'azure',
    ),
    desktop: widget.desktop,
    pageBuilder: widget.pageBuilder,
    inputsBuilder: widget.inputsBuilder,
  );
}
