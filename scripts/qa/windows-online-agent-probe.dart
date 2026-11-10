import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:info_core/info_core.dart';
import 'package:info_remote/agent_connection.dart';
import 'package:info_remote/connection_profile.dart';
import 'package:info_remote/owner_client.dart';
import 'package:info_workspace/approval_transport.dart';
import 'package:info_workspace/workspace_approvals.dart';

/// Explicit real-NAS check using a NEW, isolated validation chat. Retains only
/// references returned to this check; never discovers an existing association.
/// Owner approval is a separate coordinator, never an Agent CLI capability.
Future<void> main(List<String> args) async {
  OwnerClient? owner;
  var phase = 'arguments';
  try {
    if (!Platform.isWindows ||
        args.length != 3 ||
        !{'--prepare', '--after-restart', '--finish-end'}.contains(args[0])) {
      throw StateError(
        'Expected mode, owner profile directory, private check directory',
      );
    }
    final profileRoot = Directory(args[1]).absolute;
    final checkRoot = WindowsPrivateFiles.directory(
      Directory(args[2]).absolute,
    );
    final stateFile = File('${checkRoot.path}/flow.dpapi');
    final cli = Directory(
      '${File(Platform.script.toFilePath()).parent.path}/cli',
    );
    // The compiled probe is deliberately beside its fresh AOT CLI directory.
    check(await File('${cli.path}/info-codex.exe').exists(), 'AOT CLI missing');
    final profile = await PrivateConnectionProfileStore(profileRoot.path)
        .read();
    check(profile != null, 'Owner profile missing');
    final trust = SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificatesBytes(utf8.encode(profile!.certificate));
    owner = await OwnerClient.connect(
      address: Uri.parse(profile.address),
      token: profile.token,
      expectedServerId: profile.serverId,
      trust: trust,
    );
    final deviceFile = File('${profileRoot.path}/agent-connection.json');
    final device = await AgentConnectionProfile.read(deviceFile);
    check(device.serverId == owner.serverId, 'Device server differs');
    Future<Map<String, dynamic>> invoke(
      String executable,
      Map<String, Object?> input, {
      List<String> arguments = const [],
      String chat = '',
    }) async {
      final process = await Process.start(
        '${cli.path}/$executable.exe',
        arguments,
        environment: {'CODEX_THREAD_ID': chat},
      );
      final output = utf8.decoder.bind(process.stdout).join();
      final errors = utf8.decoder.bind(process.stderr).join();
      process.stdin.writeln(jsonEncode(input));
      await process.stdin.close();
      final code = await process.exitCode.timeout(
        const Duration(seconds: 45),
        onTimeout: () {
          process.kill();
          throw StateError('AOT child deadline');
        },
      );
      check(code == 0 && (await errors).isEmpty, 'AOT child failed');
      final text = await output;
      check(
        !text.contains(profile.token) &&
            !text.contains(device.deviceToken) &&
            !text.contains('"sessionSecret"') &&
            !text.contains('"endCapability"'),
        'Private protocol data escaped',
      );
      return Map<String, dynamic>.from(jsonDecode(text) as Map);
    }

    void save(Map<String, dynamic> state) =>
        WindowsPrivateFiles.writeSecret(stateFile, jsonEncode(state));
    Map<String, dynamic> state;
    if (args[0] == '--prepare') {
      check(
        !stateFile.existsSync(),
        'Original check state exists; do not create another chat',
      );
      final nonce = List.generate(
        12,
        (_) => Random.secure().nextInt(16).toRadixString(16),
      ).join();
      state = {
        'purpose': 'windows-w110-new-isolated-validation',
        'serverId': owner.serverId,
        'chat': 'windows-w110-$nonce',
        'phase': 'created',
        'nonce': nonce,
      };
      save(state);
    } else {
      state = Map<String, dynamic>.from(
        jsonDecode(
          WindowsPrivateFiles.readSecret(stateFile) ??
              (throw StateError('Original check state missing')),
        ) as Map,
      );
      check(
        state['purpose'] == 'windows-w110-new-isolated-validation' &&
            state['serverId'] == owner.serverId &&
            (args[0] == '--after-restart' && state['phase'] == 'prepared' ||
                args[0] == '--finish-end' &&
                    state['phase'] == 'end_pending' &&
                    state['restartVerified'] == true &&
                    state['revocationVerified'] == true),
        'Expected original prepared check',
      );
    }
    final chat = state['chat'] as String;
    final stateRoot = '${checkRoot.path}/codex';
    Future<Map<String, dynamic>> command(
      String name,
      Map<String, Object?> input, {
      String? reference,
      String? chatId,
    }) => invoke('info-codex', {
      'association': reference ?? state['association'],
      'command': name,
      ...input,
    }, chat: chatId ?? chat);
    Future<Map<String, dynamic>> read({
      String? reference,
      String? chatId,
      bool other = false,
    }) => command(
      'read',
      {
        'requestId': state['requestId'],
        'itemId': state[other ? 'otherItemId' : 'itemId'],
        'fieldId': state[other ? 'otherFieldId' : 'fieldId'],
      },
      reference: reference,
      chatId: chatId,
    );
    Future<WorkspaceApprovalDetail> review(String requestId) async =>
        approvalDetailFromJson(
          await owner!.request(
            'GET',
            '/v1/owner/approvals/${Uri.encodeComponent(requestId)}',
          ),
        );
    Future<void> decide(
      String requestId,
      WorkspaceApprovalAction action,
      String operation, {
      bool includeSelected = false,
    }) async {
      final detail = await review(requestId);
      final selected = includeSelected
          ? [
              detail.scopes
                  .singleWhere(
                    (scope) =>
                        scope.record.id == state['itemId'] &&
                        scope.fieldId == state['fieldId'],
                  )
                  .id,
            ]
          : <String>[];
      await owner!.request(
        'POST',
        '/v1/owner/approvals/decisions',
        approvalChangeToJson(
          WorkspaceApprovalChange(
            operationId: operation,
            requestId: requestId,
            reviewToken: detail.reviewToken,
            action: action,
            selected: selected,
            fieldMinutes: 10,
          ),
        ),
      );
    }

    String digestValue(Map<String, dynamic> response) {
      check(
        response['status'] == 'ok' && response.containsKey('value'),
        'Expected scoped read',
      );
      return sha256
          .convert(utf8.encode(jsonEncode(response['value'])))
          .toString();
    }

    if (args[0] == '--prepare') {
      phase = 'restricted device management boundary';
      final http = HttpClient(context: trust);
      try {
        for (final endpoint in [
          '/v1/owner/information',
          '/v1/owner/approvals/decisions',
        ]) {
          final request = await http.openUrl(
            endpoint.endsWith('/decisions') ? 'POST' : 'GET',
            device.address.resolve(endpoint),
          );
          request.followRedirects = false;
          request.headers.set(
            HttpHeaders.authorizationHeader,
            'Bearer ${device.deviceToken}',
          );
          request.headers.contentType = ContentType.json;
          if (endpoint.endsWith('/decisions')) request.write('{}');
          final response = await request.close();
          check(
            response.statusCode == 401 || response.statusCode == 403,
            'Agent gained owner capability',
          );
          await response.drain<void>();
        }
      } finally {
        http.close(force: true);
      }
      phase = 'new isolated hook association';
      final start = await invoke(
        'info-codex-hook',
        {
          'hook_event_name': 'SessionStart',
          'source': 'startup',
          'session_id': chat,
        },
        arguments: ['--connection', deviceFile.path, '--state-root', stateRoot],
      );
      final context =
          (start['hookSpecificOutput'] as Map?)?['additionalContext'];
      check(context is String, 'Hook did not deliver new association');
      state['association'] =
          (jsonDecode(context as String) as Map)['association'];
      check(state['association'] is String, 'Missing new reference');
      state['phase'] = 'associated';
      save(state);
      check(
        !File(state['association'] as String)
            .readAsStringSync()
            .contains(profile.token),
        'Owner Token entered Agent material',
      );
      final records = await owner.information();
      final documentation = records.singleWhere(
        (item) => item.name == 'Windows 知予接入说明',
      );
      check(
        documentation.fields.isNotEmpty,
        'Documentation has no readable field',
      );
      final first = documentation.fields.first;
      final otherItem = documentation.fields.length > 1
          ? documentation
          : records.firstWhere(
              (item) => item.id != documentation.id && item.fields.isNotEmpty,
            );
      final otherField = otherItem == documentation
          ? documentation.fields.last
          : otherItem.fields.first;
      state.addAll({
        'itemId': documentation.id,
        'fieldId': first.id,
        'otherItemId': otherItem.id,
        'otherFieldId': otherField.id,
        'requestOperation': 'w110-request-${state['nonce']}',
      });
      save(state);
      phase = 'request and bounded wait';
      final requested = await command('request', {
        'operationId': state['requestOperation'],
        'purpose': 'Windows 开发接入：核对限定读取和重启后的原许可',
        'fields': [
          {'itemId': documentation.id, 'fieldId': first.id},
          {'itemId': otherItem.id, 'fieldId': otherField.id},
        ],
      });
      check(requested['status'] == 'pending', 'Request did not remain pending');
      state['requestId'] = requested['requestId'];
      state['phase'] = 'requested';
      save(state);
      check(
        (await command('wait', {
              'requestId': state['requestId'],
              'timeoutMs': 10,
            }))['waitTimedOut'] ==
            true,
        'Wait timeout changed request',
      );
      check(
        (await command('request-status', {
              'operationId': state['requestOperation'],
            }))['requestId'] ==
            state['requestId'],
        'Wait created a different request',
      );
      check((await read())['status'] == 'pending', 'Read before approval');
      phase = 'owner approves selected field';
      await decide(
        state['requestId'] as String,
        WorkspaceApprovalAction.approve,
        'w110-approve-${state['nonce']}',
        includeSelected: true,
      );
      state['valueDigest'] = digestValue(await read());
      check(
        (await read(other: true))['status'] == 'unauthorized',
        'Unselected field readable',
      );
      state['expiresAt'] = (await review(state['requestId'] as String))
          .fieldExpiresAt!
          .toIso8601String();
      phase = 'delegated child and wrong chat';
      state['childChat'] = '$chat-child';
      final delegated = await command('delegate', {
        'childChatId': state['childChat'],
      });
      state['childAssociation'] = delegated['privateAssociation'];
      check(state['childAssociation'] is String, 'Child reference missing');
      save(state);
      check(
        digestValue(
              await read(
                reference: state['childAssociation'] as String,
                chatId: state['childChat'] as String,
              ),
            ) ==
            state['valueDigest'],
        'Child scope differs',
      );
      check(
        (await read(chatId: '$chat-unrelated'))['status'] ==
            'association_unavailable',
        'Wrong chat used reference',
      );
      final childEnd = await invoke(
        'info-codex-hook',
        {'hook_event_name': 'SessionEnd', 'session_id': state['childChat']},
        arguments: ['--state-root', stateRoot],
      );
      check(
        (childEnd['systemMessage'] as String).contains('no_active_session'),
        'Child ended root',
      );
      check(
        digestValue(await read()) == state['valueDigest'],
        'Root ended with child',
      );
      state['phase'] = 'prepared';
      save(state);
      stdout.writeln(
        jsonEncode({
          'status': 'prepared_for_existing_NAS_restart',
          'restrictedDevice': true,
          'AotHookAssociation': true,
          'boundedWaitSameRequest': true,
          'selectedReadAndDeniedOther': true,
          'childSharesScope': true,
          'wrongChatRefused': true,
          'ownerTokenExcluded': true,
        }),
      );
    } else {
      if (args[0] == '--after-restart') {
        phase = 'original grant after ordinary server restart';
        check(
          digestValue(await read()) == state['valueDigest'],
          'Original grant lost',
        );
        check(
          digestValue(
                await read(
                  reference: state['childAssociation'] as String,
                  chatId: state['childChat'] as String,
                ),
              ) ==
              state['valueDigest'],
          'Child grant lost',
        );
        check(
          (await review(state['requestId'] as String)).fieldExpiresAt!
                  .toIso8601String() ==
              state['expiresAt'],
          'Original grant expiry changed',
        );
        state['restartVerified'] = true;
        save(state);
        phase = 'separate request revocation';
        final pending = await command('request', {
          'operationId': 'w110-revoke-request-${state['nonce']}',
          'purpose': 'Windows 开发接入：核对撤销',
          'fields': [
            {'itemId': state['itemId'], 'fieldId': state['fieldId']},
          ],
        });
        final revokedId = pending['requestId'] as String;
        state['revokeRequestId'] = revokedId;
        save(state);
        await decide(
          revokedId,
          WorkspaceApprovalAction.approve,
          'w110-second-approve-${state['nonce']}',
          includeSelected: true,
        );
        check(
          (await command('read', {
                'requestId': revokedId,
                'itemId': state['itemId'],
                'fieldId': state['fieldId'],
              }))['status'] ==
              'ok',
          'Second grant unavailable',
        );
        await decide(
          revokedId,
          WorkspaceApprovalAction.revoke,
          'w110-revoke-${state['nonce']}',
        );
        check(
          (await command('read', {
                'requestId': revokedId,
                'itemId': state['itemId'],
                'fieldId': state['fieldId'],
              }))['status'] ==
              'unauthorized',
          'Revoked scope readable',
        );
        state['revocationVerified'] = true;
        state['phase'] = 'end_pending';
        save(state);
      }
      phase = 'root SessionEnd';
      var confirmedEnd = false;
      for (var attempt = 0; attempt < 3 && !confirmedEnd; attempt++) {
        final ended = await invoke(
          'info-codex-hook',
          {'hook_event_name': 'SessionEnd', 'session_id': chat},
          arguments: ['--state-root', stateRoot],
        );
        final message = ended['systemMessage'] as String;
        state['endStatus'] = message;
        save(state);
        confirmedEnd =
            message.contains('ended') || message.contains('no_active_session');
      }
      check(confirmedEnd, 'Original end-only credential remains pending');
      check(
        (await review(state['requestId'] as String)).request.state ==
            WorkspaceApprovalState.sessionEnded,
        'Original request not ended',
      );
      check((await read())['status'] == 'unauthorized', 'Ended root readable');
      check(
        (await read(
              reference: state['childAssociation'] as String,
              chatId: state['childChat'] as String,
            ))['status'] ==
            'unauthorized',
        'Ended child readable',
      );
      state['phase'] = 'completed';
      save(state);
      stdout.writeln(
        jsonEncode({
          'status': 'completed',
          'originalGrantSurvivedRestart': true,
          'expiryUnchanged': true,
          'revocationEnforced': true,
          'rootEndRevokedChild': true,
          'freshAotProcessPerCommand': true,
        }),
      );
    }
  } on Object catch (error) {
    // Deliberately avoid arbitrary exception text, response bodies or paths to
    // new private associations. Preserve exact state for explicit recovery.
    stderr.writeln(
      jsonEncode({
        'status': 'failed',
        'phase': phase,
        'errorType': error.runtimeType.toString(),
        if (error is StateError) 'check': error.message,
        if (error is RemoteFailure) 'code': error.code,
      }),
    );
    exitCode = 1;
  } finally {
    owner?.close();
  }
}

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}
