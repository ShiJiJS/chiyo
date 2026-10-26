import 'dart:math';

final _random = Random.secure();

/// Keep one identity while reconciling an uncertain write; never reuse it for
/// a new intent, including after the process restarts.
String workspaceOperationId() =>
    'workspace-${List.generate(16, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
