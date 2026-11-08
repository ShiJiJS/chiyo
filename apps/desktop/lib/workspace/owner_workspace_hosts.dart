import 'package:info_workspace/owner_workspace_hosts.dart' as shared;
import '../information_files.dart';
import 'host_file_selection.dart';
import 'workspace_source.dart';

/// Native file choice stays on the device. Trust decisions and projections are
/// shared with the independent server, not duplicated in this Flutter adapter.
class OwnerWorkspaceHosts extends shared.OwnerWorkspaceHosts {
  OwnerWorkspaceHosts({
    required super.owner,
    required super.changed,
    this.picker = const NativeInformationFilePicker(),
  });
  final InformationFilePicker picker;
  Future<WorkspaceHostFile?> pick() async {
    await checkSelectionAvailable();
    final selected = await selectHostFile(picker);
    return selected == null ? null : stage(selected.name, selected.bytes);
  }
}
