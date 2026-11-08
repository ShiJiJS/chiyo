import 'package:info_core/info_core.dart' show AccessFailure;

String informationFileError(Object error) => switch (error) {
  AccessFailure(status: 'attachment_too_large') => '单个文件最多10 MiB，请选择较小的文件。',
  AccessFailure(status: 'attachment_capacity_exceeded') =>
    '附件容量或记录数量已达上限。请到设置的“备份与恢复”查看用量；保留内容清理前仍占容量。',
  AccessFailure(status: 'file_read_failed') => '无法读取文件，请检查文件是否存在以及访问权限。',
  AccessFailure(status: 'file_changed') => '读取期间文件已变化，请重新选择。',
  AccessFailure(status: 'version_conflict' || 'information_conflict') =>
    '当前信息已变化。输入已保留，请取消后重新打开并核对版本。',
  AccessFailure(status: 'stage_unavailable') => '文件草稿已失效，请取消并重新打开。',
  AccessFailure(status: 'output_exists') => '目标文件已存在，请选择新的文件名。',
  AccessFailure(status: 'attachment_missing') => '该文件版本已不可用。',
  AccessFailure(status: 'attachment_integrity_failed') => '文件完整性校验失败，操作未完成。',
  _ => '操作结果未确认。当前输入已保留，请重试。',
};
