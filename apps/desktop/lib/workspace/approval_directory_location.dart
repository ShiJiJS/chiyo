import 'package:flutter/material.dart';
import 'proposal_directory.dart';
import 'workspace_source.dart';

/// Only directory metadata is requested here; viewing location does not read
/// field content or enlarge the scope being approved.
class ApprovalDirectoryLocation extends StatefulWidget {
  const ApprovalDirectoryLocation({
    super.key,
    required this.source,
    required this.record,
  });
  final WorkspaceSource source;
  final WorkspaceRecordRef record;
  @override
  State<ApprovalDirectoryLocation> createState() =>
      _ApprovalDirectoryLocationState();
}

class _ApprovalDirectoryLocationState extends State<ApprovalDirectoryLocation> {
  late final _location = _load();
  Future<(WorkspaceCatalog, WorkspaceRecordSummary?)> _load() async => (
    await widget.source.loadCatalog(),
    (await widget.source.readSummaries([widget.record])).firstOrNull,
  );
  @override
  Widget build(BuildContext context) =>
      FutureBuilder<(WorkspaceCatalog, WorkspaceRecordSummary?)>(
        future: _location,
        builder: (context, snapshot) {
          final value = snapshot.data;
          if (value == null || value.$2 == null) return const SizedBox.shrink();
          return ProposalDirectoryLocation(
            catalog: value.$1,
            directoryId: value.$2!.directoryId,
          );
        },
      );
}
