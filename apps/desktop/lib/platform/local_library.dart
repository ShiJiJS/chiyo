import 'dart:io';

import 'package:flutter/services.dart';
import 'package:info_core/info_core.dart';
import 'package:info_remote/local_library_configuration.dart';
import 'package:info_storage/info_storage.dart';

import '../desktop_bootstrap.dart';

/// Opens only the explicitly selected library. Its persisted identity selects
/// its system key, including when another library has the same display name.
Future<DesktopLibrary> openLocalLibrary(
  LocalLibraryConfiguration configuration, {
  bool requestKeyAccess = false,
  DatabaseKeyStore? keyStore,
}) async {
  DatabaseKeyStore keys;
  if (keyStore != null) {
    keys = keyStore;
  } else if (Platform.isMacOS) {
    const channel = MethodChannel('agent_info_manage/database_key');
    keys = MacOsDatabaseKeyStore.forLibrary(
      configuration.libraryId,
      channel.invokeMethod<Object?>,
      requestKeyAccess: requestKeyAccess,
    );
  } else if (Platform.isWindows) {
    keys = WindowsDatabaseKeyStore(
      '${configuration.libraryDirectory}/database-key.dpapi',
    );
  } else {
    throw const StorageFailure('platform_unsupported');
  }
  final repository = await EncryptedInformationRepository.open(
    configuration.libraryDirectory,
    keys,
  );
  return DesktopLibrary(
    service: InformationService(
      repository: repository,
      informationDeliveryFiles: Platform.isWindows
          ? WindowsInformationDeliveryFiles()
          : NativeInformationDeliveryFiles(),
    ),
    close: repository.close,
    backups: repository.backups,
    fileOutputs: repository.fileOutputs,
    fileOpens: repository.fileOpens,
  );
}
