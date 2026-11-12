import 'dart:io';

import 'package:flutter/services.dart';
import 'package:info_core/info_core.dart';
import 'package:info_remote/local_library_configuration.dart';
import 'package:info_storage/info_storage.dart';

import '../desktop_bootstrap.dart';
import '../bundled_focused_fill.dart';
import '../macos_focused_fill.dart';

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
      privateFile: true,
    );
  } else {
    throw const StorageFailure('platform_unsupported');
  }
  final repository = await EncryptedInformationRepository.open(
    configuration.libraryDirectory,
    keys,
  );
  FocusedFillDriver? fill;
  if (Platform.isMacOS) {
    // Constructing the driver is inert. Permission is requested only from
    // Settings, and every actual fill rechecks the native helper and target.
    fill = MacOSFocusedFillDriver();
  } else if (Platform.isWindows) {
    try {
      fill = await loadBundledFocusedFill();
    } on FocusedFillBundleFailure {
      // A missing optional helper must not prevent opening the user's library.
      // A null driver leaves the capability unavailable instead of pretending
      // a request can be fulfilled.
    }
  }
  return DesktopLibrary(
    service: InformationService(
      repository: repository,
      focusedFillDriver: fill,
      informationDeliveryFiles: Platform.isWindows
          ? WindowsInformationDeliveryFiles()
          : NativeInformationDeliveryFiles(),
    ),
    close: repository.close,
    backups: repository.backups,
    fileOutputs: repository.fileOutputs,
    fileOpens: repository.fileOpens,
    replication: LibraryReplication(repository),
  );
}
