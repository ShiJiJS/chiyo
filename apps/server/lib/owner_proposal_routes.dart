import 'package:info_workspace/owner_workspace_proposals.dart';
import 'package:info_workspace/proposal_transport.dart';
import 'package:info_workspace/workspace_transport.dart';

/// Authenticated by OnlineServer before entry. All validation and admission
/// remain in the shared owner adapter; this only translates transport data.
final class OwnerProposalRoutes {
  OwnerProposalRoutes(this.proposals);
  final OwnerWorkspaceProposals proposals;
  Future<(int, Object)> dispatch(
    String method,
    List<String> path,
    Map<String, dynamic>? body,
  ) async {
    if (path.length == 4 && path.last == 'query' && method == 'POST') {
      return (
        200,
        proposalResultsToJson(
          await proposals.query(
            proposalQueryFromJson(body!),
            keepSelection: body['keepSelection'] as String?,
          ),
        ),
      );
    }
    if (path.length == 4 && path.last == 'catalog' && method == 'GET') {
      return (200, workspaceCatalogToJson(await proposals.catalog()));
    }
    if (path.length == 4 && path.last == 'decisions' && method == 'POST') {
      return (
        200,
        proposalReceiptToJson(
          await proposals.change(proposalChangeFromJson(body!)),
        ),
      );
    }
    if (path.length == 5 && path[3] == 'operations' && method == 'GET') {
      final receipt = await proposals.receipt(path.last);
      return receipt == null
          ? (404, {'error': 'operation_not_found'})
          : (200, proposalReceiptToJson(receipt));
    }
    if (path.length == 4 && method == 'GET') {
      return (200, proposalDetailToJson(await proposals.read(path.last)));
    }
    if (path.length == 5 && path.last == 'current' && method == 'GET') {
      return (
        200,
        workspaceDetailToJson(await proposals.currentTarget(path[3])),
      );
    }
    if (path.length == 5 && method == 'POST') {
      final input = body!;
      final record = recordRefFromJson(input['record']);
      switch (path.last) {
        case 'snapshot':
          return (
            200,
            workspaceArchiveToJson(await proposals.snapshot(path[3], record)),
          );
        case 'saved':
          return (
            200,
            proposalItemToJson(await proposals.savedPreview(path[3], record)),
          );
        case 'related':
          return (
            200,
            proposalItemToJson(
              await proposals.previewRelated(
                path[3],
                input['version'] as int,
                record,
                review: input['review'] == null
                    ? null
                    : proposalReviewFromJson(input['review']),
              ),
            ),
          );
      }
    }
    if (path.length == 6 && path[4] == 'relations' && method == 'POST') {
      final input = body!;
      final relations = proposals.relations(
        path[3],
        input['itemId'] as String,
        input['version'] as int,
      );
      if (path.last == 'query') {
        return (
          200,
          workspaceResultsToJson(
            await relations.queryRelationCandidates(
              relationQueryFromJson(input['query']),
            ),
          ),
        );
      }
      if (path.last == 'summaries') {
        return (
          200,
          {
            'items': (await relations.readSummaries(
              (input['records'] as List).map(recordRefFromJson),
            )).map(recordSummaryToJson).toList(),
          },
        );
      }
    }
    return (404, {'error': 'not_found'});
  }
}
