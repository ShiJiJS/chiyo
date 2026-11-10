import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_remote/connection_profile.dart';
import 'package:info_remote/owner_client.dart';
import 'package:info_workspace/credential_use_transport.dart';
import 'package:info_workspace/workspace_credentials.dart';

// Read-only Owner validation of this project's completed, isolated #113 QA
// records. Never recovers this Codex chat, starts a session or changes a grant.
Future<void> main(List<String> args) async {
  OwnerClient? owner;
  var phase = 'arguments';
  try {
    check(
      Platform.isWindows && args.length == 2,
      'profile and original QA root required',
    );
    final raw = WindowsPrivateFiles.readSecret(
      File('${Directory(args[1]).absolute.path}/flow.dpapi'),
    );
    check(raw != null, 'Original QA facts required');
    final facts = jsonDecode(raw!) as Map<String, dynamic>;
    check(
      facts['purpose'] == 'windows-w113-isolated-validation' &&
          facts['phase'] == 'completed',
      'Only the completed original QA flow is supported',
    );
    final profile = await PrivateConnectionProfileStore(
      Directory(args[0]).absolute.path,
    ).read();
    check(
      profile != null && profile.serverId == facts['serverId'],
      'Original server required',
    );
    owner = await OwnerClient.connect(
      address: Uri.parse(profile!.address),
      token: profile.token,
      expectedServerId: profile.serverId,
      trust: SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificatesBytes(utf8.encode(profile.certificate)),
    );
    var requestsChecked = 0;
    var historyChecked = 0;
    var unknownCleanupChecked = false;
    var appExitChecked = false;
    for (final kind in ['gh', 'aws', 'ssh']) {
      final credentialId = (facts['credential-$kind'] as Map)['id'] as String;
      final expected = <String>{
        facts['request-$kind'] as String,
        if (kind == 'gh') facts['request-gh-expiry'] as String,
      };
      final prefix =
          '/v1/owner/credentials/${Uri.encodeComponent(credentialId)}';
      phase = 'requests-$kind';
      final requestResponse = await owner.request('GET', '$prefix/requests');
      check(
        requestResponse['version'] == 1,
        'Unsupported request metadata version',
      );
      final requests = (requestResponse['requests'] as List)
          .map(credentialUseRequestFromJson)
          .toList();
      check(
        requests.every((r) => r.ref.id == credentialId),
        'Wrong credential in response',
      );
      check(
        requests.map((r) => r.id).toSet().containsAll(expected),
        'Original requests missing',
      );
      for (final request in requests.where((r) => expected.contains(r.id))) {
        check(
          !{
            WorkspaceCredentialRequestState.pending,
            WorkspaceCredentialRequestState.approved,
            WorkspaceCredentialRequestState.partiallyApproved,
          }.contains(request.state),
          'Completed QA permission appears active',
        );
        requestsChecked++;
      }
      phase = 'history-$kind';
      final historyResponse = await owner.request('GET', '$prefix/history');
      check(
        historyResponse['version'] == 1 &&
            historyResponse['credentialId'] == credentialId,
        'Wrong history identity/version',
      );
      final history = (historyResponse['history'] as List)
          .map(credentialUseHistoryFromJson)
          .toList();
      check(
        history.map((h) => h.grantId).toSet().containsAll(expected),
        'Original history missing',
      );
      historyChecked += history
          .where((h) => expected.contains(h.grantId))
          .length;
      if (kind == 'ssh') {
        final original = history.singleWhere(
          (h) => h.grantId == facts['request-ssh'],
        );
        check(
          original.expiresAt == null,
          'Session-bound history gained a deadline',
        );
        final crash = facts['operation-ssh-worker-crash-recheck'] as Map;
        final app = facts['operation-ssh-app-exit-recheck'] as Map;
        unknownCleanupChecked = original.operations.any(
          (op) =>
              op.id == crash['operationId'] &&
              op.result.contains('unknown') &&
              op.result.contains('complete'),
        );
        appExitChecked = original.operations.any(
          (op) =>
              op.id == app['operationId'] &&
              op.result.contains('exited') &&
              op.result.contains('complete'),
        );
      }
      final encoded = jsonEncode([requestResponse, historyResponse]);
      check(!encoded.contains(profile.token), 'Owner authentication escaped');
      for (final key in [
        'sessionSecret',
        'executionCapability',
        'controlCapability',
        'deviceToken',
        'privateNote',
        'secret',
        'dataBase64',
      ]) {
        check(!encoded.contains('"$key"'), 'Private runtime field escaped');
      }
    }
    check(
      requestsChecked == 4 &&
          historyChecked == 4 &&
          unknownCleanupChecked &&
          appExitChecked,
      'Original QA history differs',
    );
    stdout.writeln(
      jsonEncode({
        'status': 'completed',
        'readOnly': true,
        'originalRequests': requestsChecked,
        'originalHistories': historyChecked,
        'unknownCleanupPreserved': unknownCleanupChecked,
        'appExitPreserved': appExitChecked,
      }),
    );
  } on RemoteFailure catch (error) {
    stdout.writeln(
      jsonEncode({
        'status': error.code == 'not_found'
            ? 'server_update_required'
            : 'failed',
        'phase': phase,
        'code': error.code,
      }),
    );
    exitCode = error.code == 'not_found' ? 2 : 1;
  } on Object catch (error) {
    stderr.writeln(
      jsonEncode({
        'status': 'failed',
        'phase': phase,
        'errorType': error.runtimeType.toString(),
        if (error is StateError) 'check': error.message,
      }),
    );
    exitCode = 1;
  } finally {
    owner?.close();
  }
}

void check(bool value, String message) {
  if (!value) throw StateError(message);
}
