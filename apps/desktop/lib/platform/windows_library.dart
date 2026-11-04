import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import '../bundled_focused_fill.dart';
import '../desktop_bootstrap.dart';

/// Legacy Windows startup stays outside the supported Mac application setup.
Future<DesktopLibrary> openWindowsLibrary() async {
  final base = Platform.environment['LOCALAPPDATA'];
  if (base == null || base.isEmpty) {
    throw const StorageFailure('directory_unavailable');
  }
  final directory = '$base/AgentInfoManage';
  final keys = WindowsDatabaseKeyStore('$directory/database-key.dpapi');
  final fill = await loadBundledFocusedFill();
  final repository = await EncryptedInformationRepository.open(directory, keys);
  return DesktopLibrary(
    service: InformationService(
      repository: repository,
      focusedFillDriver: fill,
      informationDeliveryFiles: WindowsInformationDeliveryFiles(),
    ),
    close: repository.close,
    backups: repository.backups,
    fileOutputs: repository.fileOutputs,
    fileOpens: repository.fileOpens,
  );
}
