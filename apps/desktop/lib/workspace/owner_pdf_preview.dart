import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'workspace_source.dart';

abstract interface class OwnerPdfPreviewRenderer {
  Future<WorkspaceFilePreview> render(
    WorkspaceFileVersion file,
    Uint8List bytes,
    int page,
  );
}

/// Owner bytes in, one bounded PNG page out. No paths or external PDF viewer.
class NativeOwnerPdfPreview implements OwnerPdfPreviewRenderer {
  const NativeOwnerPdfPreview();
  static const _channel = MethodChannel('agent_info_manage/owner_pdf_preview');
  @override
  Future<WorkspaceFilePreview> render(
    WorkspaceFileVersion file,
    Uint8List bytes,
    int page,
  ) async {
    if (page < 0 || bytes.isEmpty || bytes.length > 10 * 1024 * 1024) {
      throw const WorkspaceFailure('invalid_request', '页码或PDF原文无效。');
    }
    if (defaultTargetPlatform != TargetPlatform.macOS) {
      throw const WorkspaceFailure('pdf_unsupported', '此平台尚未接入PDF预览。');
    }
    try {
      final result = await _channel.invokeMapMethod<String, Object?>(
        'renderPage',
        {'bytes': bytes, 'page': page},
      );
      if (result == null ||
          result.length != 5 ||
          result['png'] is! Uint8List ||
          result['width'] is! int ||
          result['height'] is! int ||
          result['pageCount'] is! int ||
          result['page'] != page) {
        throw const FormatException();
      }
      final png = result['png'] as Uint8List,
          width = result['width'] as int,
          height = result['height'] as int,
          count = result['pageCount'] as int;
      if (width < 1 ||
          height < 1 ||
          width > 1600 ||
          height > 1600 ||
          count < 1 ||
          count > 4096 ||
          page >= count ||
          png.length < 33 ||
          png.length > 12 * 1024 * 1024) {
        throw const FormatException();
      }
      const signature = [
        137,
        80,
        78,
        71,
        13,
        10,
        26,
        10,
        0,
        0,
        0,
        13,
        73,
        72,
        68,
        82,
      ];
      for (var i = 0; i < signature.length; i++) {
        if (png[i] != signature[i]) throw const FormatException();
      }
      final header = ByteData.sublistView(png);
      if (header.getUint32(16) != width || header.getUint32(20) != height) {
        throw const FormatException();
      }
      return WorkspaceFilePreview(
        file: file,
        kind: WorkspaceFilePreviewKind.image,
        page: page,
        pageCount: count,
        pixelWidth: width,
        pixelHeight: height,
        image: png,
      );
    } on PlatformException catch (e) {
      throw WorkspaceFailure(
        switch (e.code) {
          'invalid_request' ||
          'invalid_pdf' ||
          'pdf_locked' ||
          'pdf_unsupported' ||
          'preview_busy' => e.code,
          _ => 'preview_unavailable',
        },
        switch (e.code) {
          'invalid_request' => 'PDF页码超出范围，请重新读取文件。',
          'invalid_pdf' => 'PDF内容损坏或无效，无法预览。',
          'pdf_locked' => '此PDF需要密码，暂不能预览；原文仍保留。',
          'pdf_unsupported' => 'PDF页数或页面尺寸超过预览范围，原文仍保留。',
          'preview_busy' => '正在准备另一页PDF，请稍后重试。',
          _ => 'PDF预览暂时不可用，请重试。',
        },
      );
    } on Object {
      throw const WorkspaceFailure('preview_unavailable', 'PDF预览暂时不可用，请重试。');
    }
  }
}
