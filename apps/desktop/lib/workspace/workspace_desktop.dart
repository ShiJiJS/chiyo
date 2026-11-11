import 'package:flutter/foundation.dart';
import '../desktop_scroll.dart';
import 'workspace_source.dart';

/// Owner window interaction only. A host supplies appearance/navigation and
/// closes the resources it owns before quitting. An independent server and
/// the Agent's chat/execution lifetime are not owned by an online App window.
abstract interface class WorkspaceDesktop {
  void Function(WorkspacePage page)? get onNavigate;
  set onNavigate(void Function(WorkspacePage page)? callback);
  ValueListenable<DesktopScrollbarStyle> get scrollbarStyle;
  Future<void> setNavigationEnabled(bool enabled);
  Future<void> quit();
}

/// Optional routing for a native notification. The opaque ID only selects a
/// record; it never carries or confers permission to decide the request.
abstract interface class WorkspaceRequestNavigation {
  void Function(String requestId)? get onOpenRequest;
  set onOpenRequest(void Function(String requestId)? callback);
}

/// A menu row selects the matching queue and object in the workspace.
abstract interface class WorkspaceMenuNavigation {
  void Function(WorkspacePage page, String id)? get onOpenMenuDetail;
  set onOpenMenuDetail(void Function(WorkspacePage page, String id)? callback);
}
