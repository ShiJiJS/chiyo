import 'package:info_workspace/adoption_transport.dart';
import 'package:info_workspace/history_transport.dart'
    show historyEnvelope, historyText;
import 'package:info_workspace/owner_workspace_adoption.dart';
import 'owner_library.dart';

/// Reuses the original Owner mapping preview and atomic record save. Only the
/// authenticated management surface can reach this; no Agent auto-conversion.
final class OwnerAdoptionRoutes {
  OwnerAdoptionRoutes(OnlineOwnerLibrary library)
    : adoption = OwnerWorkspaceAdoption(library, library.plugins);
  final OwnerWorkspaceAdoption adoption;
  void dispose() => adoption.dispose();
  Future<(int, Object)> dispatch(
    String method,
    List<String> path,
    Map<String, dynamic>? body,
  ) async {
    final tail = path.skip(3).toList();
    if (method == 'POST' && tail.length == 1 && tail.single == 'previews') {
      return (
        200,
        adoptionPreviewToJson(
          await adoption.preview(adoptionDraftFromJson(body)),
        ),
      );
    }
    if (method == 'DELETE' && tail.length == 2 && tail.first == 'previews') {
      await adoption.release(historyText(tail.last));
      return (200, {'wireVersion': 1, 'released': true});
    }
    if (method == 'POST' && tail.length == 1 && tail.single == 'changes') {
      final b = historyEnvelope(body, ['operationId', 'planId']);
      return (
        200,
        adoptionReceiptToJson(
          await adoption.apply(
            historyText(b['operationId']),
            historyText(b['planId']),
          ),
        ),
      );
    }
    return (404, {'error': 'not_found'});
  }
}
