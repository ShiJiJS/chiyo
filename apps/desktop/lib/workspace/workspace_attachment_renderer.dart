import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'owner_pdf_preview.dart';
import 'workspace_source.dart';

/// One native renderer for verified local and remotely delivered originals.
class WorkspaceAttachmentRenderer {
  const WorkspaceAttachmentRenderer({this.pdf = const NativeOwnerPdfPreview()});
  final OwnerPdfPreviewRenderer pdf;
  Future<WorkspaceFilePreview> renderContent(
    WorkspaceFileVersion file,
    Uint8List bytes, {
    int page = 0,
  }) async {
    if (page < 0) throw const WorkspaceFailure('invalid_request', '页码无效。');
    try {
      if (file.mediaType == 'application/pdf') {
        return await pdf.render(file, bytes, page);
      }
      if (page != 0) throw const WorkspaceFailure('invalid_request', '页码超出范围。');
      if (file.mediaType == 'text/plain' || file.mediaType == 'text/markdown') {
        return WorkspaceFilePreview(
          file: file,
          kind: WorkspaceFilePreviewKind.text,
          text: utf8.decode(bytes),
        );
      }
      if (!{'image/png', 'image/jpeg', 'image/webp'}.contains(file.mediaType)) {
        return WorkspaceFilePreview(
          file: file,
          kind: WorkspaceFilePreviewKind.unsupported,
        );
      }
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      ui.ImageDescriptor? descriptor;
      ui.Codec? codec;
      ui.Image? image;
      try {
        descriptor = await ui.ImageDescriptor.encoded(buffer);
        if (descriptor.width < 1 ||
            descriptor.height < 1 ||
            descriptor.width > 16384 ||
            descriptor.height > 16384 ||
            descriptor.width * descriptor.height > 16 * 1024 * 1024) {
          return WorkspaceFilePreview(
            file: file,
            kind: WorkspaceFilePreviewKind.unsupported,
          );
        }
        codec = await descriptor.instantiateCodec();
        image = (await codec.getNextFrame()).image;
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        if (png == null) throw const FormatException();
        return WorkspaceFilePreview(
          file: file,
          kind: WorkspaceFilePreviewKind.image,
          image: png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
          pixelWidth: image.width,
          pixelHeight: image.height,
        );
      } finally {
        image?.dispose();
        codec?.dispose();
        descriptor?.dispose();
        buffer.dispose();
      }
    } on WorkspaceFailure {
      rethrow;
    } on Object {
      throw const WorkspaceFailure('preview_unavailable', '文件内容无法预览，未修改原文件。');
    }
  }
}
