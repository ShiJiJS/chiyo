import 'dart:async';
import 'package:flutter/material.dart';
import 'proposal_directory.dart';
import 'workspace_source.dart';

/// Directory metadata only: locating a record never enlarges its approved scope.
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
  StreamSubscription<WorkspaceRecordRef?>? _changes;
  late Future<(WorkspaceCatalog, WorkspaceRecordSummary?)> _location;
  @override
  void initState() {
    super.initState();
    _bind();
  }

  void _bind() {
    _changes?.cancel();
    _location = _load();
    _changes = widget.source.changes.listen((ref) {
      if (mounted && (ref == null || ref == widget.record)) {
        setState(() {
          _location = _load();
        });
      }
    });
  }

  @override
  void didUpdateWidget(ApprovalDirectoryLocation oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source ||
        oldWidget.record != widget.record) {
      _bind();
    }
  }

  @override
  void dispose() {
    _changes?.cancel();
    super.dispose();
  }

  Future<(WorkspaceCatalog, WorkspaceRecordSummary?)> _load() async {
    final source = widget.source, record = widget.record;
    return (
      await source.loadCatalog(),
      (await source.readSummaries([record])).firstOrNull,
    );
  }

  @override
  Widget build(BuildContext context) =>
      FutureBuilder<(WorkspaceCatalog, WorkspaceRecordSummary?)>(
        future: _location,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text('目录位置暂不可用'),
                TextButton(
                  onPressed: () {
                    setState(() {
                      _location = _load();
                    });
                  },
                  child: const Text('重新读取位置'),
                ),
              ],
            );
          }
          final value = snapshot.data;
          if (snapshot.connectionState != ConnectionState.done ||
              value == null) {
            return const SizedBox(height: 2, child: LinearProgressIndicator());
          }
          if (value.$2 == null) return const Text('资料已删除或不可用');
          return ProposalDirectoryLocation(
            catalog: value.$1,
            directoryId: value.$2!.directoryId,
          );
        },
      );
}
