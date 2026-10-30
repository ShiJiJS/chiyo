import 'package:flutter/foundation.dart';
import '../desktop_scroll.dart';
import 'workspace_source.dart';

/// Owner window interaction only. A host supplies appearance/navigation and
/// performs quit after its runtime confirms that services have stopped.
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
