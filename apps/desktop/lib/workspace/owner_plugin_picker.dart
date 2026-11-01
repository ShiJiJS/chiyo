import 'package:flutter/services.dart';
import '../information_files.dart';

class NativeTemplatePackagePicker extends NativeInformationFilePicker {
  const NativeTemplatePackagePicker();
  static const _files = MethodChannel('agent_info_manage/backup_files');
  @override
  Future<String?> choose() =>
      _files.invokeMethod<String>('templatePackageInput');
}
