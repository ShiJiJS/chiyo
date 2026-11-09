import 'package:info_workspace/owner_workspace_history.dart' as shared;
import 'owner_workspace_information.dart';
import 'workspace_records.dart';

/// Native composition keeps its existing information projection; rules are shared.
class OwnerWorkspaceHistory extends shared.OwnerWorkspaceHistory {
  OwnerWorkspaceHistory({
    required OwnerWorkspaceInformation information,
    void Function(WorkspaceRecordRef)? onChanged,
  }) : super(
         owner: information.owner,
         information: information,
         onChanged: onChanged,
       );
}
