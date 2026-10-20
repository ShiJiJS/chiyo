import 'package:info_core/new_file_publish.dart';

/// Same-volume, no-replace publication of an already closed, verified backup.
/// Unsupported native/filesystem behavior fails instead of replacing a target.
void publishNewBackup(String source, String destination) =>
    publishNewFile(source, destination);
