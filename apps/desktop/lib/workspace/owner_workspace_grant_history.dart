import 'package:info_workspace/owner_workspace_grant_history.dart' as shared;
import 'owner_pdf_preview.dart';
import 'owner_workspace_files.dart';

/// Native rendering stays on the device; history/scope resolution is shared.
class OwnerWorkspaceGrantHistory extends shared.OwnerWorkspaceGrantHistory {
  OwnerWorkspaceGrantHistory({
    required super.owner,
    OwnerPdfPreviewRenderer pdfPreview = const NativeOwnerPdfPreview(),
  }) : super(
         filePreviewRenderer: (ref, original, page) {
           final reader = OwnerWorkspaceAttachmentPreview(
             owner,
             pdf: pdfPreview,
           );
           return original == null
               ? reader.read(ref, page: page)
               : reader.delivered(original, page: page);
         },
       );
}
