/// Package consistency, not code signing, host trust or CLI connectivity.
class AgentBundleObservation {
  const AgentBundleObservation({
    required this.status,
    this.directory,
    this.sourceCommit,
    this.manifestDigest,
    this.embedded = false,
  });
  final String status;
  final String? directory, sourceCommit, manifestDigest;

  /// macOS may ship integration resources inside the signed application.
  final bool embedded;
  bool get verified => status == 'verified';
}
