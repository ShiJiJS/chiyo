import 'package:info_core/info_core.dart';

class MaintenanceRepository extends MemoryInformationRepository {
  bool fail = false;
  int attempts = 0;
  @override
  Future<void> commitCredentials(
    List<ManagedCredential> credentials,
    List<CredentialMaterial> materials,
  ) async {
    attempts++;
    if (fail) throw const AccessFailure('synthetic_storage_failure');
    await super.commitCredentials(credentials, materials);
  }
}
