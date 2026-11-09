import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:info_cli/device_information_files.dart';
import 'package:info_cli/codex_end_index.dart';
import 'package:info_cli/private_device_state.dart';
import 'package:info_core/info_core.dart';
import 'package:info_remote/agent_connection.dart';
import 'package:info_remote/connection_profile.dart';
import 'package:info_remote/owner_client.dart';
import 'package:info_workspace/approval_transport.dart';
import 'package:info_workspace/workspace_approvals.dart';

/// Explicit existing-NAS probe. Creates one NEW isolated validation chat;
/// never searches for an existing chat association or prints private facts.
/// Compile from apps/desktop with its package configuration, then run beside
/// cli/{info-codex,info-codex-hook,info-runtime-worker}.exe.
Future<void> main(List<String> args) async {
  OwnerClient? owner;
  var phase = 'arguments';
  try {
    require(
      Platform.isWindows && args.length == 3,
      'Windows mode/profile/private directory required',
    );
    require(
      {
        '--prepare',
        '--resume-prepare',
        '--resume-concurrent',
        '--inspect',
        '--after-restart',
        '--finish-expiry',
        '--finish-end',
      }.contains(args[0]),
      'Unknown mode',
    );
    final root = WindowsPrivateFiles.directory(Directory(args[2]).absolute);
    final stateFile = File('${root.path}/flow.dpapi');
    final profile = (await PrivateConnectionProfileStore(
      Directory(args[1]).absolute.path,
    ).read())!;
    owner = await OwnerClient.connect(
      address: Uri.parse(profile.address),
      token: profile.token,
      expectedServerId: profile.serverId,
      trust: SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificatesBytes(utf8.encode(profile.certificate)),
    );
    final deviceFile = File(
      '${Directory(args[1]).absolute.path}/agent-connection.json',
    );
    final device = await AgentConnectionProfile.read(deviceFile);
    require(device.serverId == owner.serverId, 'Device identity differs');
    final cli = '${File(Platform.script.toFilePath()).parent.path}/cli';
    for (final name in [
      'info-codex',
      'info-codex-hook',
      'info-runtime-worker',
    ]) {
      require(
        File('$cli/$name.exe').existsSync(),
        'Matching AOT component missing',
      );
    }
    final previous = WindowsPrivateFiles.readSecret(stateFile);
    final state = previous == null
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(jsonDecode(previous) as Map);
    void save() =>
        WindowsPrivateFiles.writeSecret(stateFile, jsonEncode(state));
    if (previous == null) {
      require(args[0] == '--prepare', 'Original probe state required');
      final nonce = List.generate(
        16,
        (_) => Random.secure().nextInt(16).toRadixString(16),
      ).join();
      state.addAll({
        'purpose': 'windows-w112-isolated-validation',
        'serverId': owner.serverId,
        'nonce': nonce,
        'chat': 'windows-w112-$nonce',
        'phase': 'created',
      });
      save();
    }
    require(
      state['purpose'] == 'windows-w112-isolated-validation' &&
          state['serverId'] == owner.serverId,
      'Original probe scope differs',
    );
    final chat = state['chat'] as String;
    final hookState = '${root.path}/codex';
    Future<Map<String, dynamic>> invoke(
      String name,
      Map<String, Object?> input, {
      List<String> arguments = const [],
      bool dropReply = false,
    }) async {
      final child = await Process.start(
        '$cli/$name.exe',
        arguments,
        environment: {'CODEX_THREAD_ID': chat},
        runInShell: false,
      );
      final output = utf8.decoder.bind(child.stdout).join();
      final errors = utf8.decoder.bind(child.stderr).join();
      child.stdin.writeln(jsonEncode(input));
      await child.stdin.close();
      require(
        await child.exitCode.timeout(const Duration(seconds: 70)) == 0,
        'AOT child failed',
      );
      require((await errors).isEmpty, 'Unexpected AOT diagnostics');
      final text = await output;
      require(
        !text.contains(profile.token) &&
            !text.contains(device.deviceToken) &&
            !text.contains('"sessionSecret"') &&
            !text.contains('"cleanupCapability"') &&
            !text.contains('"controlCapability"') &&
            !text.contains('"endCapability"'),
        'Private data escaped public output',
      );
      if (dropReply) return {'dropped': true};
      return Map<String, dynamic>.from(jsonDecode(text) as Map);
    }

    Future<Map<String, dynamic>> command(
      String name,
      Map<String, Object?> input, {
      bool dropReply = false,
    }) => invoke('info-codex', {
      'association': state['association'],
      'command': name,
      ...input,
    }, dropReply: dropReply);
    Map<String, Object?> fetchInput(String operation, {String? request}) => {
      'requestId': request ?? state['requestId'],
      'itemId': state['itemId'],
      'fieldId': state['fieldId'],
      'operationId': 'w112-$operation-${state['nonce']}',
    };
    Future<WorkspaceApprovalDetail> review(String request) async =>
        approvalDetailFromJson(
          await owner!.request(
            'GET',
            '/v1/owner/approvals/${Uri.encodeComponent(request)}',
          ),
        );
    Future<void> approve(String request, int minutes) async {
      final detail = await review(request);
      final scope = detail.scopes.singleWhere(
        (s) => s.record.id == state['itemId'] && s.fieldId == state['fieldId'],
      );
      require(
        scope.fileVersions.length == 1 &&
            scope.fileVersions.single.ref.version == state['attachmentVersion'],
        'Approval file version differs',
      );
      await owner!.request(
        'POST',
        '/v1/owner/approvals/decisions',
        approvalChangeToJson(
          WorkspaceApprovalChange(
            operationId: 'w112-approve-${sha256.convert(utf8.encode(request))}',
            requestId: request,
            reviewToken: detail.reviewToken,
            action: WorkspaceApprovalAction.approve,
            selected: [scope.id],
            fileVersions: {scope.id: scope.fileVersions.single.ref.version},
            fieldMinutes: minutes,
          ),
        ),
      );
    }

    Future<String> request(String kind, int minutes) async {
      final operation = 'w112-request-$kind-${state['nonce']}';
      state['requestOperation:$kind'] = operation;
      save();
      final result = await command('request', {
        'operationId': operation,
        'purpose': 'Windows 附件开发核对：$kind；只使用本轮 Windows 附件说明',
        'fields': [
          {'itemId': state['itemId'], 'fieldId': state['fieldId']},
        ],
      });
      require(result['status'] == 'pending', 'Expected fresh pending request');
      final id = result['requestId'] as String;
      state['request:$kind'] = id;
      save();
      if (kind == 'main') {
        final unapproved = await command(
          'file-fetch',
          fetchInput('unapproved', request: id),
        );
        require(
          unapproved['status'] != 'ok' &&
              !(unapproved['delivery'] as Map? ?? {}).containsKey('path'),
          'Unapproved file delivered',
        );
      }
      await approve(id, minutes);
      require(
        (await command('claim', {'requestId': id}))['status'] == 'ok',
        'Approved request not claimable',
      );
      return id;
    }

    String journalDirectory() =>
        '${File(state['association'] as String).parent.path}/device-files';
    File journal(String delivery) => File(
      '${journalDirectory()}/${sha256.convert(utf8.encode(delivery))}.json',
    );
    Future<Map<String, dynamic>> record(String delivery) async =>
        (await readPrivateDeviceState(journal(delivery))) ??
        (throw StateError('Original journal missing'));
    Future<void> maintain() => DeviceInformationFiles(
      device,
      Directory(journalDirectory()),
    ).maintain();
    Future<Map<String, dynamic>> ready(
      String operation, {
      String? request,
    }) async {
      final result = await command(
        'file-fetch',
        fetchInput(operation, request: request),
      );
      require(
        result['status'] == 'ok' && result['delivery'] is Map,
        'Expected approved file delivery: ${result['status']}/${result['errorCode']}',
      );
      final delivery = Map<String, dynamic>.from(result['delivery'] as Map);
      require(
        delivery['state'] == 'ready' &&
            delivery['attachmentVersion'] == state['attachmentVersion'] &&
            delivery['path'] is String &&
            RegExp(r'^[A-Za-z]:[\\/]').hasMatch(delivery['path'] as String),
        'Expected current immutable Windows local file',
      );
      final bytes = await File(delivery['path'] as String).readAsBytes();
      require(
        sha256.convert(bytes).toString() == state['originalDigest'] &&
            bytes.length == state['originalLength'],
        'Local bytes differ from NAS original',
      );
      final local = await record(delivery['deliveryId'] as String);
      require(
        local['lease'] is Map &&
            !local.containsKey('sessionSecret') &&
            !local.containsKey('association') &&
            local['manifest'] is Map &&
            (local['manifest'] as Map)['cleanupCapability'] is String,
        'Journal must hold cleanup capability only',
      );
      final lease = InformationDeliveryLease.fromPrivateJson(
        Map<String, dynamic>.from(local['lease'] as Map),
      );
      await NativeInformationDeliveryFiles().verify(
        lease,
        bytes.length,
        state['originalDigest'] as String,
      );
      return delivery;
    }

    Future<void> cleaned(String id) async {
      for (var n = 0; n < 60; n++) {
        final local = await record(id);
        if (local['lease'] == null &&
            {'released', 'expired'}.contains(local['phase'])) {
          return;
        }
        await maintain();
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      throw StateError('Original cleanup not acknowledged');
    }

    Future<void> release(String id) async {
      final result = await command('file-release', {'deliveryId': id});
      require(
        result['status'] == 'ok',
        'Release outcome not acknowledged: ${result['status']}/${result['errorCode']}',
      );
      await cleaned(id);
    }

    Future<void> end({bool recovery = false}) async {
      state['phase'] = 'end_pending';
      save();
      if (recovery) {
        // Outside the two-second host callback, finish only this probe's
        // already retained end-only index with an explicit bounded deadline.
        final outcome = await CodexEndIndex(
          Directory(hookState),
        ).end(chat, timeout: const Duration(seconds: 20));
        require(
          outcome == 'ended' || outcome == 'no_active_session',
          'Original end-only recovery not confirmed',
        );
        return;
      }
      final result = await invoke(
        'info-codex-hook',
        {'hook_event_name': 'SessionEnd', 'session_id': chat},
        arguments: ['--state-root', hookState],
      );
      final message = result['systemMessage'] as String? ?? '';
      require(
        message.contains('ended') || message.contains('no_active_session'),
        'Original end-only operation remains pending',
      );
    }

    if (args[0] == '--inspect') {
      final local = <Map<String, Object?>>[];
      final directory = Directory(journalDirectory());
      if (directory.existsSync()) {
        for (final entry in directory.listSync(followLinks: false)) {
          if (entry is! File ||
              !RegExp(
                r'^[0-9a-f]{64}\.json$',
              ).hasMatch(entry.uri.pathSegments.last)) {
            continue;
          }
          final value = (await readPrivateDeviceState(entry))!;
          final lease = value['lease'] is Map
              ? InformationDeliveryLease.fromPrivateJson(
                  Map<String, dynamic>.from(value['lease'] as Map),
                )
              : null;
          local.add({
            'keyNames': value.keys.toList(),
            'workerPidType': value['workerPid'].runtimeType.toString(),
            'workerIdentityType': value['workerIdentity'].runtimeType
                .toString(),
            'workerPid': value['workerPid'],
            'phase': value['phase'],
            'leaseHeld': lease != null,
            'copyExists': lease != null && File(lease.filePath).existsSync(),
            'workerActive':
                value['workerPid'] is int && value['workerIdentity'] is String
                ? CredentialProcessIdentity.isActive(
                    value['workerPid'] as int,
                    value['workerIdentity'] as String,
                  )
                : null,
          });
        }
      }
      final status = await command('file-status', {
        'operationId': fetchInput(
          state['concurrentOperation'] as String? ?? 'concurrent',
        )['operationId'],
      });
      final approval = await review(state['requestId'] as String);
      final pendingRevocation = await command('file-status', {
        'operationId': fetchInput('revoked-copy')['operationId'],
      });
      final ending = state['endRequest'] is String
          ? await review(state['endRequest'] as String)
          : null;
      stdout.writeln(
        jsonEncode({
          'phase': state['phase'],
          'endingState': ending?.request.state.name,
          'occupiedVerified': state['occupiedVerified'] == true,
          'approvalState': approval.request.state.name,
          'approvalExpiresAt': approval.fieldExpiresAt?.toIso8601String(),
          'failedRevocationStatus': pendingRevocation['status'],
          'failedRevocationError': pendingRevocation['errorCode'],
          'localBeforeMaintenance': local,
          'originalStatus': status['status'],
          'originalDeliveryState': (status['delivery'] as Map?)?['state'],
          'errorCode': status['errorCode'],
        }),
      );
    } else if (args[0] == '--prepare' ||
        args[0] == '--resume-prepare' ||
        args[0] == '--resume-concurrent') {
      if (args[0] == '--prepare') {
        require(
          state['phase'] == 'created',
          'Probe already started; reconcile its recorded phase',
        );
        phase = 'new isolated hook association';
        state['phase'] = 'hook_starting';
        save();
        final started = await invoke(
          'info-codex-hook',
          {
            'hook_event_name': 'SessionStart',
            'source': 'startup',
            'session_id': chat,
          },
          arguments: [
            '--connection',
            deviceFile.path,
            '--state-root',
            hookState,
          ],
        );
        final context =
            (started['hookSpecificOutput'] as Map?)?['additionalContext'];
        require(context is String, 'New hook reference missing');
        state['association'] =
            (jsonDecode(context as String) as Map)['association'];
        require(state['association'] is String, 'New association missing');
        state['phase'] = 'associated';
        save();
        final documentation = (await owner.information()).singleWhere(
          (e) => e.name == 'Windows 知予附件说明',
        );
        final field = documentation.fields.singleWhere(
          (e) => e.kind == FieldKind.file,
        );
        state.addAll({
          'itemId': documentation.id,
          'fieldId': field.id,
          'attachmentVersion': field.attachment!.attachmentVersion,
        });
        save();
        final original = await owner.request('POST', '/v1/owner/files/read', {
          'record': {'kind': 'information', 'id': documentation.id},
          'fieldKey': 'file',
          'version': field.attachment!.attachmentVersion,
        });
        final bytes = base64Decode(original['bytes'] as String);
        state.addAll({
          'originalDigest': sha256.convert(bytes).toString(),
          'originalLength': bytes.length,
        });
        save();
      } else if (args[0] == '--resume-prepare') {
        require(
          state['phase'] == 'associated' &&
              state['request:main'] is String &&
              state['originalDigest'] is String,
          'Only the original rejected approval may resume',
        );
      } else {
        require(
          state['phase'] == 'concurrent_pending',
          'Original concurrent check required',
        );
        final original = await command('file-status', {
          'operationId': fetchInput(
            state['concurrentOperation'] as String? ?? 'concurrent',
          )['operationId'],
        });
        require(
          original['status'] == 'ok' &&
              (original['delivery'] as Map)['state'] == 'released',
          'Resolve original release before another verification operation',
        );
        await maintain();
        await cleaned((original['delivery'] as Map)['deliveryId'] as String);
        final attempt = (state['concurrentAttempt'] as int? ?? 1) + 1;
        final detail = await review(state['requestId'] as String);
        if (detail.request.state != WorkspaceApprovalState.approved ||
            !detail.fieldExpiresAt!.isAfter(
              DateTime.now().toUtc().add(const Duration(minutes: 3)),
            )) {
          state['oldRequestId'] = state['requestId'];
          state['requestId'] = await request('main-recovered-$attempt', 10);
        }
        state['concurrentAttempt'] = attempt;
        state['concurrentOperation'] = 'concurrent-fixed-$attempt';
        save();
      }
      phase = 'normal owner approval';
      if (args[0] == '--resume-concurrent') {
        require(
          state['requestId'] is String,
          'Original recovery approval missing',
        );
      } else if (state['request:main'] is String) {
        final original = state['request:main'] as String;
        final detail = await review(original);
        require(
          detail.request.state == WorkspaceApprovalState.pending,
          'Original request is not pending',
        );
        await approve(original, 10);
        require(
          (await command('claim', {'requestId': original}))['status'] == 'ok',
          'Original approval not claimable',
        );
        state['requestId'] = original;
      } else {
        state['requestId'] = await request('main', 10);
      }
      save();
      phase = 'independent concurrent AOT fetches';
      state['phase'] = 'concurrent_pending';
      save();
      final concurrent =
          state['concurrentOperation'] as String? ?? 'concurrent';
      final together = await Future.wait([
        ready(concurrent),
        ready(concurrent),
      ]);
      require(
        together[0]['deliveryId'] == together[1]['deliveryId'] &&
            together[0]['path'] == together[1]['path'],
        'Concurrent CLIs produced different copies',
      );
      final first = together.first;
      final worker = await record(first['deliveryId'] as String);
      final retried = await ready(concurrent);
      final same = await record(retried['deliveryId'] as String);
      require(
        worker['workerPid'] == same['workerPid'] &&
            worker['workerIdentity'] == same['workerIdentity'],
        'Retry replaced guardian',
      );
      await release(first['deliveryId'] as String);
      require(
        !File(first['path'] as String).existsSync(),
        'Released local copy remains',
      );
      phase = 'lost CLI response';
      state['phase'] = 'lost_reply_pending';
      save();
      await command('file-fetch', fetchInput('lost-reply'), dropReply: true);
      final status = await command('file-status', {
        'operationId': fetchInput('lost-reply')['operationId'],
      });
      require(status['status'] == 'ok', 'Original lost-reply receipt missing');
      final lost = await ready('lost-reply');
      require(
        (status['delivery'] as Map)['deliveryId'] == lost['deliveryId'],
        'Lost reply created another delivery',
      );
      await release(lost['deliveryId'] as String);
      phase = 'guardian abnormal exit recovery';
      state['phase'] = 'crash_pending';
      save();
      final crash = await ready('crash');
      final crashed = await record(crash['deliveryId'] as String);
      final processId = crashed['workerPid'] as int;
      require(
        CredentialProcessIdentity.isActive(
              processId,
              crashed['workerIdentity'] as String,
            ) ==
            true,
        'Expected this probe guardian alive',
      );
      final heldProcess = CredentialProcessIdentity.capture(processId);
      try {
        require(
          heldProcess?.value == crashed['workerIdentity'],
          'Owned guardian identity changed',
        );
        require(
          Process.killPid(processId),
          'Could not stop owned probe guardian',
        );
      } finally {
        heldProcess?.close();
      }
      for (
        var n = 0;
        n < 40 &&
            CredentialProcessIdentity.isActive(
                  processId,
                  crashed['workerIdentity'] as String,
                ) !=
                false;
        n++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      require(
        CredentialProcessIdentity.isActive(
              processId,
              crashed['workerIdentity'] as String,
            ) ==
            false,
        'Guardian death inconclusive',
      );
      await maintain();
      await cleaned(crash['deliveryId'] as String);
      require(
        !File(crash['path'] as String).existsSync(),
        'Crashed guardian copy not cleaned',
      );
      final afterCrash = await command('file-fetch', fetchInput('crash'));
      require(
        afterCrash['status'] != 'ok' ||
            (afterCrash['delivery'] as Map?)?['state'] != 'ready',
        'Crashed operation downloaded again',
      );
      phase = 'prepare existing NAS restart';
      final restart = await ready('restart');
      state.addAll({
        'restartDelivery': restart['deliveryId'],
        'restartPath': restart['path'],
        'grantExpiresAt': (await review(
          state['requestId'] as String,
        )).fieldExpiresAt!.toIso8601String(),
        'phase': 'prepared',
        'prepareVerified': true,
      });
      save();
      stdout.writeln(
        jsonEncode({
          'status': 'prepared_for_existing_NAS_restart',
          'AotConcurrentCopyShared': true,
          'lostReplyOriginalOperation': true,
          'abnormalGuardianRecovered': true,
          'realWindowsPathAndBytes': true,
          'privateProofsExcluded': true,
        }),
      );
    } else if (args[0] == '--after-restart') {
      require(
        state['phase'] == 'prepared' && state['prepareVerified'] == true,
        'Original prepared check required',
      );
      phase = 'original delivery after server restart';
      require(
        (await review(
              state['requestId'] as String,
            )).fieldExpiresAt!.toIso8601String() ==
            state['grantExpiresAt'],
        'Restart changed grant deadline',
      );
      final current = await command('file-status', {
        'operationId': fetchInput('restart')['operationId'],
      });
      require(
        current['status'] == 'ok' &&
            (current['delivery'] as Map)['deliveryId'] ==
                state['restartDelivery'],
        'Restart lost original delivery',
      );
      await release(state['restartDelivery'] as String);
      require(
        !File(state['restartPath'] as String).existsSync(),
        'Restart copy not physically cleaned',
      );
      state['restartVerified'] = true;
      save();
      phase = 'revocation stops new delivery';
      // The original deadline is immutable; time spent restarting cannot
      // extend it. Revocation is a separate check with its own explicit grant.
      final revokeRequest = await request('revocation', 10);
      state['revocationRequest'] = revokeRequest;
      save();
      final revokeCopy = await ready('revocation', request: revokeRequest);
      final detail = await review(revokeRequest);
      await owner.request(
        'POST',
        '/v1/owner/approvals/decisions',
        approvalChangeToJson(
          WorkspaceApprovalChange(
            operationId: 'w112-revoke-${state['nonce']}',
            requestId: revokeRequest,
            reviewToken: detail.reviewToken,
            action: WorkspaceApprovalAction.revoke,
          ),
        ),
      );
      final denied = await command(
        'file-fetch',
        fetchInput('after-revoke', request: revokeRequest),
      );
      require(
        denied['status'] != 'ok' &&
            !(denied['delivery'] as Map? ?? {}).containsKey('path'),
        'Revoked grant delivered new file',
      );
      await cleaned(revokeCopy['deliveryId'] as String);
      require(
        !File(revokeCopy['path'] as String).existsSync(),
        'Revoked copy remains',
      );
      phase = 'prepare expiry';
      final expires = await request('expiry', 1);
      final expiringCopy = await ready('expiry', request: expires);
      state.addAll({
        'expiryRequest': expires,
        'expiryDelivery': expiringCopy['deliveryId'],
        'expiryPath': expiringCopy['path'],
        'expiryAt': (await review(expires)).fieldExpiresAt!.toIso8601String(),
        'restartVerified': true,
        'revocationVerified': true,
        'phase': 'expiry_pending',
      });
      save();
      stdout.writeln(
        jsonEncode({
          'status': 'awaiting_original_expiry',
          'originalRestartDeliveryReconciled': true,
          'deadlineUnchanged': true,
          'revokedNewFetchDenied': true,
          'revokedCopyCleaned': true,
          'expiresAt': state['expiryAt'],
        }),
      );
    } else if (args[0] == '--finish-expiry') {
      require(
        state['phase'] == 'expiry_pending' &&
            state['restartVerified'] == true &&
            state['revocationVerified'] == true,
        'Original expiry check required',
      );
      phase = 'expired grant and original cleanup';
      require(
        DateTime.now().toUtc().isAfter(
          DateTime.parse(state['expiryAt'] as String),
        ),
        'Original deadline not reached',
      );
      await cleaned(state['expiryDelivery'] as String);
      require(
        !File(state['expiryPath'] as String).existsSync(),
        'Expired copy remains',
      );
      final denied = await command(
        'file-fetch',
        fetchInput('after-expiry', request: state['expiryRequest'] as String),
      );
      require(
        denied['status'] != 'ok' &&
            !(denied['delivery'] as Map? ?? {}).containsKey('path'),
        'Expired grant delivered file',
      );
      phase = 'occupied copy and ended chat';
      final endRequest = await request('ending', 10);
      final ending = await ready('ending', request: endRequest);
      final blocker = _LockedCopy(ending['path'] as String);
      state.addAll({
        'endRequest': endRequest,
        'endDelivery': ending['deliveryId'],
        'endPath': ending['path'],
        'expiryVerified': true,
        'phase': 'end_pending',
      });
      save();
      try {
        await end();
        for (var n = 0; n < 50; n++) {
          if ((await record(ending['deliveryId'] as String))['phase'] ==
              'cleanup_pending') {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        require(
          File(ending['path'] as String).existsSync(),
          'Occupied copy was declared deleted',
        );
        final held = await record(ending['deliveryId'] as String);
        require(
          held['phase'] == 'cleanup_pending' && held['lease'] != null,
          'Occupied cleanup outcome was discarded',
        );
        state['occupiedVerified'] = true;
        save();
      } finally {
        // Preserve the occupied-object observation even if the bounded hook
        // reply is lost after the server ended the session. Recovery must
        // still confirm the original end-only operation separately.
        final held = await record(ending['deliveryId'] as String);
        if (held['phase'] == 'cleanup_pending' &&
            held['lease'] != null &&
            File(ending['path'] as String).existsSync()) {
          state['occupiedVerified'] = true;
          save();
        }
        blocker.close();
      }
      await maintain();
      await cleaned(ending['deliveryId'] as String);
      require(
        !File(ending['path'] as String).existsSync(),
        'Released occupied copy not cleaned',
      );
      final ended = await command(
        'file-fetch',
        fetchInput('after-end', request: endRequest),
      );
      require(
        ended['status'] != 'ok' &&
            !(ended['delivery'] as Map? ?? {}).containsKey('path'),
        'Ended chat delivered a file',
      );
      state['phase'] = 'completed';
      save();
      stdout.writeln(
        jsonEncode({
          'status': 'completed',
          'expiredNewFetchDenied': true,
          'expiredCopyCleaned': true,
          'occupiedCopyRetainedUntilRelease': true,
          'endedNewFetchDenied': true,
          'cleanupWithoutReadProof': true,
          'AotCliAndWorker': true,
        }),
      );
    } else {
      require(
        state['phase'] == 'end_pending' && state['expiryVerified'] == true,
        'Original pending end required',
      );
      phase = 'original end-only recovery';
      _LockedCopy? blocker;
      if (state['occupiedVerified'] != true) {
        final local = await record(state['endDelivery'] as String);
        require(
          local['lease'] is Map && local['phase'] == 'ready',
          'Original ready copy required for occupied recovery',
        );
        final lease = InformationDeliveryLease.fromPrivateJson(
          Map<String, dynamic>.from(local['lease'] as Map),
        );
        require(
          lease.filePath == state['endPath'],
          'Original copy binding differs',
        );
        await NativeInformationDeliveryFiles().verify(
          lease,
          state['originalLength'] as int,
          state['originalDigest'] as String,
        );
        blocker = _LockedCopy(lease.filePath);
      }
      try {
        await end(recovery: true);
        if (blocker != null) {
          for (var n = 0; n < 60; n++) {
            if ((await record(state['endDelivery'] as String))['phase'] ==
                'cleanup_pending') {
              break;
            }
            await Future<void>.delayed(const Duration(milliseconds: 200));
          }
          final held = await record(state['endDelivery'] as String);
          require(
            held['phase'] == 'cleanup_pending' &&
                held['lease'] != null &&
                File(state['endPath'] as String).existsSync(),
            'Occupied original cleanup was not preserved',
          );
          state['occupiedVerified'] = true;
          save();
        }
      } finally {
        blocker?.close();
      }
      await maintain();
      await cleaned(state['endDelivery'] as String);
      require(
        !File(state['endPath'] as String).existsSync(),
        'Pending end copy not cleaned',
      );
      require(
        state['occupiedVerified'] == true,
        'Occupied check must be explicitly completed',
      );
      final ended = await command(
        'file-fetch',
        fetchInput('after-end', request: state['endRequest'] as String),
      );
      require(
        ended['status'] != 'ok' &&
            !(ended['delivery'] as Map? ?? {}).containsKey('path'),
        'Ended chat delivered a file',
      );
      state['phase'] = 'completed';
      save();
      stdout.writeln(
        jsonEncode({'status': 'completed', 'originalEndRecovered': true}),
      );
    }
  } on Object catch (error) {
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

void require(bool valid, String message) {
  if (!valid) throw StateError(message);
}

/// Hold only this probe's explicitly returned copy without FILE_SHARE_DELETE.
/// This is a real Windows consumer lock, not a fabricated cleanup result.
class _LockedCopy {
  _LockedCopy(String path) {
    final text = path.toNativeUtf16();
    try {
      handle = _open(text, 0x80000000, 1, nullptr, 3, 0, 0);
      require(handle != -1, 'Could not hold this probe copy');
    } finally {
      calloc.free(text);
    }
  }
  late int handle;
  static final _kernel = DynamicLibrary.open('kernel32.dll');
  static final _open = _kernel
      .lookupFunction<
        IntPtr Function(
          Pointer<Utf16>,
          Uint32,
          Uint32,
          Pointer<Void>,
          Uint32,
          Uint32,
          IntPtr,
        ),
        int Function(Pointer<Utf16>, int, int, Pointer<Void>, int, int, int)
      >('CreateFileW');
  static final _close = _kernel
      .lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');
  void close() {
    if (handle != -1) {
      _close(handle);
      handle = -1;
    }
  }
}
