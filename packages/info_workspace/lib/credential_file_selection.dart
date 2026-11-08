import 'dart:async';
import 'workspace_credentials.dart';

/// A caller-selected credential file. No source path or native picker is
/// embedded in this shared input; platform adapters own actual file selection.
class SelectedCredentialFile {
  SelectedCredentialFile(this.name, Iterable<int> bytes)
    : bytes = List.unmodifiable(bytes);
  final String name;
  final List<int> bytes;
}

/// Trusted host input seam. Implementations may stage locally or send the
/// private input to the authenticated owner service; UI/DTOs see metadata only.
abstract interface class CredentialInputStaging {
  void check();
  FutureOr<WorkspaceCredentialCandidate> string(String secret);
  FutureOr<WorkspaceCredentialCandidate> file(SelectedCredentialFile file);
  FutureOr<void> release(String id);
  FutureOr<void> cancelPending();
}
