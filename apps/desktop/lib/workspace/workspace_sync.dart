import 'package:flutter/foundation.dart';

/// The existing toolbar observes sync state without depending on its storage
/// mode. Data transfer and connection lifetime remain with the composition root.
abstract interface class WorkspaceSync implements Listenable {
  bool get enabled;
  bool get busy;
  bool get needsReview;
  DateTime? get updatedAt;
  Object? get failure;
  Future<void> synchronize();
}
