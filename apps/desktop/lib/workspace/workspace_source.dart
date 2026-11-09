// Shared pure Dart workspace contract/owner adapter.
export 'package:info_workspace/workspace_source.dart';

import 'dart:async';
import 'package:info_workspace/workspace_source.dart' show WorkspaceRecordRef;

/// Content refreshes are independent of access-request notifications.
abstract interface class WorkspaceLibraryNotifications {
  Stream<WorkspaceRecordRef?> get libraryChanges;
}
