import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:info_cli/codex_end_index.dart';
import 'package:info_cli/device_credential_host.dart';
import 'package:info_cli/private_device_state.dart';
import 'package:info_core/info_core.dart';
import 'package:info_remote/agent_connection.dart';
import 'package:info_remote/connection_profile.dart';
import 'package:info_remote/owner_client.dart';
import 'package:info_workspace/approval_transport.dart';
import 'package:info_workspace/credential_transport.dart';
import 'package:info_workspace/workspace_source.dart';

// Explicit existing-NAS validation, using a NEW isolated QA identity. Does not
// find or recover this Codex chat's association. All private flow data is DPAPI.
Future<void> main(List<String> args) async {
  OwnerClient? owner;
  HttpServer? sts;
  var phase = 'arguments';
  try {
    require(
      Platform.isWindows && args.length == 4,
      'mode/profile/private root/tools required',
    );
    require(
      {
        '--prepare',
        '--after-restart',
        '--finish',
        '--inspect',
        '--lifetime',
        '--expiry-check',
        '--last-operation',
      }.contains(args[0]),
      'Unknown mode',
    );
    final root = WindowsPrivateFiles.directory(Directory(args[2]).absolute);
    final stateFile = File('${root.path}/flow.dpapi');
    final previous = WindowsPrivateFiles.readSecret(stateFile);
    final state = previous == null
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(jsonDecode(previous) as Map);
    void save() =>
        WindowsPrivateFiles.writeSecret(stateFile, jsonEncode(state));
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
    require(device.serverId == owner.serverId, 'Wrong device/server');
    final build = File(Platform.script.toFilePath()).parent;
    final cli = '${build.path}/cli';
    final tools = Directory(args[3]).absolute;
    const token = 'ghp_WINDOWS_W113_SYNTHETIC_TOKEN_NEVER_VALID';
    const access = 'WINDOWS_W113_SYNTHETIC_ACCESS';
    const secret = 'windows-w113-synthetic-secret-never-valid';
    const awsBytes =
        '[default]\naws_access_key_id=$access\naws_secret_access_key=$secret\n';
    if (previous == null) {
      require(args[0] == '--prepare', 'Original flow required');
      final nonce = List.generate(
        16,
        (_) => Random.secure().nextInt(16).toRadixString(16),
      ).join();
      state.addAll({
        'purpose': 'windows-w113-isolated-validation',
        'serverId': owner.serverId,
        'nonce': nonce,
        'chat': 'windows-w113-$nonce',
        'phase': 'created',
      });
      state['information'] = {
        for (final item in await owner.information())
          item.id: sha256
              .convert(utf8.encode(jsonEncode(informationToJson(item))))
              .toString(),
      };
      save();
    }
    require(
      state['purpose'] == 'windows-w113-isolated-validation' &&
          state['serverId'] == owner.serverId,
      'Wrong original flow',
    );
    final chat = state['chat'] as String;
    final work = WindowsPrivateFiles.directory(Directory('${root.path}/work'));
    final hookRoot = Directory('${root.path}/codex');
    Directory hostFiles() => Directory(
      '${File(state['association'] as String).parent.path}/device-files',
    );
    Future<Map<String, dynamic>> invoke(
      String name,
      Map<String, Object?> input, {
      List<String> arguments = const [],
      bool drop = false,
    }) async {
      final child = await Process.start(
        '$cli/$name.exe',
        arguments,
        runInShell: false,
        environment: {
          'CODEX_THREAD_ID': chat,
          'CHIYO_POISON_AUTH': 'must-not-inherit',
        },
      );
      final output = utf8.decoder.bind(child.stdout).join();
      final errors = utf8.decoder.bind(child.stderr).join();
      child.stdin.writeln(jsonEncode(input));
      await child.stdin.close();
      require(
        await child.exitCode.timeout(const Duration(seconds: 80)) == 0,
        'AOT adapter failed',
      );
      require((await errors).isEmpty, 'Unexpected adapter diagnostics');
      final text = await output;
      for (final value in [profile.token, device.deviceToken, token, secret]) {
        require(!text.contains(value), 'Private value in adapter output');
      }
      require(
        !text.contains('"sessionSecret"') &&
            !text.contains('"executionCapability"') &&
            !text.contains('"controlCapability"'),
        'Private proof escaped',
      );
      return drop
          ? {'dropped': true}
          : Map<String, dynamic>.from(jsonDecode(text) as Map);
    }

    Future<Map<String, dynamic>> command(
      String name,
      Map<String, Object?> input, {
      bool drop = false,
    }) => invoke('info-codex', {
      'association': state['association'],
      'protocolVersion': 2,
      'command': name,
      ...input,
    }, drop: drop);
    Future<WorkspaceApprovalDetail> review(String id) async =>
        approvalDetailFromJson(
          await owner!.request(
            'GET',
            '/v1/owner/approvals/details/${Uri.encodeComponent(id)}',
          ),
        );
    Future<void> decide(
      String id,
      WorkspaceApprovalAction action,
      String operation, {
      int? minutes,
    }) async {
      final detail = await review(id);
      await owner!.request(
        'POST',
        '/v1/owner/approvals/decisions',
        approvalChangeToJson(
          WorkspaceApprovalChange(
            operationId: '$operation-${state['nonce']}',
            requestId: id,
            reviewToken: detail.reviewToken,
            action: action,
            selected: action == WorkspaceApprovalAction.approve
                ? detail.scopes.map((s) => s.id)
                : const [],
            credentialMinutes: minutes,
          ),
        ),
      );
    }

    Future<String> credential(
      String kind, {
      String? value,
      List<int>? bytes,
    }) async {
      final key = 'credential-$kind';
      final stored = Map<String, dynamic>.from(state[key] as Map? ?? {});
      state[key] = stored;
      if (stored['id'] != null) return stored['id'] as String;
      stored['inputOp'] ??= 'w113-$kind-input-${state['nonce']}';
      stored['writeOp'] ??= 'w113-$kind-save-${state['nonce']}';
      save();
      if (stored['candidate'] == null) {
        final uploaded = await owner!.request(
          'POST',
          '/v1/owner/credentials/inputs',
          {
            'operationId': stored['inputOp'],
            'form': bytes == null ? 'string' : 'file',
            if (bytes == null)
              'secret': value
            else ...{
              'filename': kind == 'ssh' ? 'identity' : 'credentials',
              'bytes': base64Encode(bytes),
            },
          },
        );
        stored['candidate'] = credentialCandidateFromJson(
          uploaded['candidate'],
        ).id;
        save();
      }
      final write = WorkspaceCredentialWrite(
        operationId: stored['writeOp'] as String,
        name: 'Windows 开发验证凭据 $kind',
        purpose: '仅用于 Windows #113 开发验证，不是实际账号',
        binding: 'material',
        candidateId: stored['candidate'] as String,
        discoverable: true,
      );
      Map<String, dynamic>? response;
      try {
        response = await owner!.request(
          'GET',
          '/v1/owner/credentials/operations/${write.operationId}',
        );
      } on RemoteFailure catch (e) {
        if (e.code != 'operation_not_found') rethrow;
      }
      response ??= await owner!.request(
        'POST',
        '/v1/owner/credentials/save',
        credentialWriteToJson(write),
      );
      final receipt = credentialReceiptFromJson(response);
      require(
        receipt.commandDigest == write.commandDigest,
        'Credential receipt differs',
      );
      stored['id'] = receipt.ref.id;
      save();
      return receipt.ref.id;
    }

    Future<Map<String, Object?>> launch(String kind) async => {
      'receiver': switch (kind) {
        'gh' || 'gh-native' => 'gh_token',
        'aws' => 'aws_shared_credentials',
        _ => 'ssh_identity',
      },
      'executable': switch (kind) {
        'gh' => '${tools.path}/gh/bin/gh.exe',
        'gh-native' => '${build.path}/receivers/gh.exe',
        'aws' => '${tools.path}/aws-cli/aws.exe',
        _ => '${build.path}/receivers/ssh.exe',
      },
      'argv': switch (kind) {
        'gh' || 'gh-native' => ['api', 'user', '--method', 'GET'],
        'aws' => [
          'sts',
          'get-caller-identity',
          '--region',
          'us-east-1',
          '--endpoint-url',
          'http://127.0.0.1:${sts!.port}',
          '--cli-connect-timeout',
          '3',
          '--cli-read-timeout',
          '10',
        ],
        _ => [
          '-T',
          '-o',
          'BatchMode=yes',
          '-i',
          {'file': 'material'},
          '-p',
          '1',
          'fixture@127.0.0.1',
          'SYNTHETIC_WINDOWS_SSH_ONLY',
        ],
      },
      'cwd': work.path,
      'env': switch (kind) {
        'gh' || 'gh-native' => {
          'GH_TOKEN': {'secret': 'material'},
        },
        'aws' => {
          'AWS_SHARED_CREDENTIALS_FILE': {'file': 'material'},
        },
        _ => <String, Object?>{},
      },
    };
    Future<String> request(
      String kind,
      String suffix, {
      int? minutes = 30,
    }) async {
      final key = 'request-$suffix';
      if (state[key] == null) {
        state['phase'] = 'requesting-$suffix';
        save();
        final result = await command('request-use', {
          'purpose': 'Windows #113 $suffix / synthetic validation only',
          'credentials': [
            {
              'alias': 'material',
              'credentialId': (state['credential-$kind'] as Map)['id'],
              'version': 1,
            },
          ],
          'launch': await launch(kind),
        });
        require(
          result['status'] == 'pending',
          'Request failed: ${result['errorCode']}',
        );
        state[key] = result['requestId'];
        save();
      }
      final id = state[key] as String;
      final detail = await review(id);
      if (detail.credential?.state == WorkspaceCredentialRequestState.pending) {
        final denied = await command('run-use', {
          'requestId': id,
          'operationId': 'w113-before-$suffix',
          'launch': await launch(kind),
        });
        require(
          denied['status'] != 'accepted',
          'Unapproved execution accepted',
        );
        await decide(
          id,
          WorkspaceApprovalAction.approve,
          'w113-approve-$suffix',
          minutes: minutes,
        );
      }
      final approved = await review(id);
      require(
        approved.credential!.state == WorkspaceCredentialRequestState.approved,
        'Approval not active',
      );
      state['expiry-$suffix'] ??= approved.credentialExpiresAt
          ?.toUtc()
          .toIso8601String();
      save();
      return id;
    }

    Future<Map<String, dynamic>> operation(
      String kind,
      String request,
      String suffix, {
      bool drop = false,
    }) async {
      final key = 'operation-$suffix';
      if (state[key] == null) {
        state[key] = {
          'requestId': request,
          'operationId': 'w113-$suffix-${state['nonce']}',
          'launch': await launch(kind),
        };
        save();
      }
      final result = await command(
        'run-use',
        Map<String, Object?>.from(state[key] as Map),
        drop: drop,
      );
      if (suffix.startsWith('ssh-app-exit')) {
        stdout.writeln(
          jsonEncode({
            'check': suffix,
            'status': result['status'],
            'errorCode': result['errorCode'],
          }),
        );
      }
      return result;
    }

    Future<void> settled(
      String id, {
      String? contains,
      int expectedCode = 0,
    }) async {
      final deadline = DateTime.now().add(const Duration(seconds: 55));
      while (true) {
        final result = await command('execution-status', {'executionId': id});
        if (result['executionState'] == 'exited' &&
            {'complete', 'not_needed'}.contains(result['cleanupState'])) {
          require(
            result['exitCode'] == expectedCode,
            'Receiver exit code: ${result['exitCode']} / ${result['errorCode']}',
          );
          break;
        }
        require(
          DateTime.now().isBefore(deadline),
          'Original execution did not settle: ${result['executionState']} / ${result['cleanupState']} / ${result['errorCode']}',
        );
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      final response = await command('execution-output', {'executionId': id});
      require(response['status'] == 'ok', 'Output unavailable');
      final output = utf8.decode(
        (response['chunks'] as List)
            .expand<int>((c) => base64Decode(c['dataBase64'] as String))
            .toList(),
      );
      for (final value in [
        token,
        access,
        secret,
        awsBytes,
        '-----BEGIN OPENSSH PRIVATE KEY-----',
      ]) {
        require(!output.contains(value), 'Unfiltered credential output');
      }
      if (contains != null) {
        require(output.contains(contains), 'Receiver output missing');
      }
    }

    var stsCalls = 0;
    final stsErrors = <String>[];
    Future<void> startSts() async {
      sts = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      sts!.listen((request) async {
        try {
          final body = await utf8.decoder.bind(request).join();
          require(
            request.headers
                        .value('authorization')
                        ?.contains('Credential=$access/') ==
                    true &&
                body.contains('Action=GetCallerIdentity'),
            'AWS did not use injected credential',
          );
          stsCalls++;
          request.response.headers.contentType = ContentType('text', 'xml');
          request.response.write(
            '<GetCallerIdentityResponse xmlns="https://sts.amazonaws.com/doc/2011-06-15/"><GetCallerIdentityResult><Arn>arn:aws:iam::123456789012:user/windows-fixture</Arn><UserId>WINDOWS_W113_STS_OK</UserId><Account>123456789012</Account></GetCallerIdentityResult><ResponseMetadata><RequestId>w113</RequestId></ResponseMetadata></GetCallerIdentityResponse>',
          );
        } catch (_) {
          stsErrors.add('invalid synthetic STS request');
          request.response.statusCode = 400;
        } finally {
          await request.response.close();
        }
      });
    }

    phase = 'original scope';
    if (args[0] == '--last-operation') {
      final key = state.keys.lastWhere(
        (k) => k.startsWith('operation-ssh-app-exit'),
      );
      final result = await command(
        'operation-status',
        Map<String, Object?>.from(state[key] as Map),
      );
      stdout.writeln(
        jsonEncode({
          'operation': key.substring(10),
          for (final name in [
            'status',
            'errorCode',
            'executionState',
            'cleanupState',
            'attemptConsumed',
          ])
            if (result.containsKey(name)) name: result[name],
        }),
      );
      return;
    }
    if (args[0] == '--inspect') {
      stdout.writeln(
        jsonEncode({
          'phase': state['phase'],
          'hasAssociation': state['association'] is String,
          'credentials': state.keys
              .where((k) => k.startsWith('credential-'))
              .length,
          'requests': state.keys.where((k) => k.startsWith('request-')).length,
          'appQuitAttemptSuffix': state['appQuitAttemptSuffix'],
          'appQuitVerified': state['appQuitVerified'],
          'naturalExpiryChecked': state['naturalExpiryChecked'],
          'lastAppQuit': state['lastAppQuit'],
          'operations': state.keys
              .where((k) => k.startsWith('operation-'))
              .map((k) => k.substring(10))
              .toList(),
        }),
      );
      return;
    }
    await startSts();
    if (args[0] == '--prepare') {
      require(
        state['phase'] != 'completed' && state['phase'] != 'restart-ready',
        'Do not replay completed preparation',
      );
      if (state['association'] == null) {
        phase = 'new isolated QA association';
        require(state['phase'] == 'created', 'Reconcile original hook first');
        state['phase'] = 'hook-starting';
        save();
        final result = await invoke(
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
            hookRoot.path,
          ],
        );
        final context =
            (result['hookSpecificOutput'] as Map)['additionalContext']
                as String;
        state['association'] = (jsonDecode(context) as Map)['association'];
        state['phase'] = 'associated';
        save();
      }
      phase = 'own development credential inputs';
      await credential('gh', value: token);
      await credential('aws', bytes: utf8.encode(awsBytes));
      final trust = await owner.request('GET', '/v1/owner/ssh-hosts');
      state['originalSshTrust'] ??= trust;
      save();
      require(
        trust['imported'] != null,
        'Existing SSH trust required; do not replace original trust',
      );
      if ((state['credential-ssh'] as Map?)?['id'] == null) {
        final key = File('${root.path}/synthetic-key');
        if (!key.existsSync()) {
          final result = await Process.run(
            '${Platform.environment['SystemRoot']}/System32/OpenSSH/ssh-keygen.exe',
            [
              '-q',
              '-t',
              'ed25519',
              '-N',
              '',
              '-C',
              'windows-w113-synthetic-only',
              '-f',
              key.path,
            ],
          );
          require(result.exitCode == 0, 'Synthetic key generation failed');
        }
        await credential('ssh', bytes: await key.readAsBytes());
        await key.delete();
        await File('${key.path}.pub').delete();
      }
      phase = 'real GH concurrent/lost-output execution';
      final gh = await request('gh', 'gh');
      // A separate 15-minute approval expires naturally while restart/lifetime
      // checks run. Do not shorten production rules or advance a fake clock.
      await request('gh', 'gh-expiry', minutes: 15);
      final actual = await operation('gh', gh, 'gh-real');
      require(
        actual['status'] == 'accepted',
        'Real GH not accepted: ${actual['errorCode']}',
      );
      await settled(
        actual['executionId'] as String,
        expectedCode: 1,
        contains: '401',
      );
      await File('${work.path}/gh-release').writeAsString('release');
      final a = await operation('gh-native', gh, 'gh-once');
      require(a['status'] == 'accepted', 'GH not accepted: ${a['errorCode']}');
      final results = await Future.wait([
        operation('gh-native', gh, 'gh-once'),
        operation('gh-native', gh, 'gh-once'),
      ]);
      require(
        results.every((r) => r['executionId'] == a['executionId']),
        'Concurrent operation replaced execution',
      );
      await settled(a['executionId'] as String);
      await operation('gh-native', gh, 'gh-dropped', drop: true);
      final recovered = await command(
        'operation-status',
        Map<String, Object?>.from(state['operation-gh-dropped'] as Map),
      );
      require(
        recovered['executionId'] is String,
        'Lost output original operation not found',
      );
      await settled(
        recovered['executionId'] as String,
        contains: 'WINDOWS_RECEIVER_COMPLETED',
      );
      require(
        (await File('${work.path}/gh-counter').readAsLines()).length == 2,
        'GH receiver launched more than once per operation',
      );
      phase = 'real AWS injected file / local STS';
      final aws = await request('aws', 'aws');
      final b = await operation('aws', aws, 'aws-once');
      require(b['status'] == 'accepted', 'AWS not accepted: ${b['errorCode']}');
      await settled(
        b['executionId'] as String,
        contains: 'WINDOWS_W113_STS_OK',
      );
      require(
        stsCalls == 1 && stsErrors.isEmpty,
        'AWS target call count/identity differs',
      );
      phase = 'native SSH private key receiver';
      await File('${work.path}/ssh-release').writeAsString('release');
      final ssh = await request('ssh', 'ssh', minutes: null);
      final c = await operation('ssh', ssh, 'ssh-once');
      require(c['status'] == 'accepted', 'SSH not accepted: ${c['errorCode']}');
      await settled(
        c['executionId'] as String,
        contains: 'WINDOWS_RECEIVER_COMPLETED',
      );
      state['phase'] = 'restart-ready';
      save();
      stdout.writeln(
        jsonEncode({
          'status': 'restart-ready',
          'realGh': true,
          'realAwsSignedLocalSts': true,
          'nativeSshKeyReceiver': true,
          'concurrentSameId': true,
          'lostOutputRecovered': true,
        }),
      );
    } else if (args[0] == '--after-restart') {
      require(
        state['phase'] == 'restart-ready',
        'Original restart-ready flow required',
      );
      phase = 'unchanged original grants after NAS restart';
      for (final kind in ['gh', 'aws', 'ssh']) {
        final current = await review(state['request-$kind'] as String);
        require(
          current.credential!.state ==
                  WorkspaceCredentialRequestState.approved &&
              current.credentialExpiresAt?.toUtc().toIso8601String() ==
                  state['expiry-$kind'],
          'Original grant/deadline changed',
        );
        final result = await operation(
          kind,
          state['request-$kind'] as String,
          '$kind-after-restart',
        );
        require(
          result['status'] == 'accepted',
          'Post-restart not accepted: ${result['errorCode']}',
        );
        await settled(
          result['executionId'] as String,
          expectedCode: kind == 'gh' ? 1 : 0,
          contains: kind == 'aws'
              ? 'WINDOWS_W113_STS_OK'
              : kind == 'gh'
              ? '401'
              : null,
        );
      }
      require(
        stsCalls == 1 && stsErrors.isEmpty,
        'Post-restart AWS target differs',
      );
      state['phase'] = 'restart-verified';
      save();
      stdout.writeln(
        jsonEncode({
          'status': 'restart-verified',
          'originalDeadlines': true,
          'sessionBoundSsh': true,
        }),
      );
    } else if (args[0] == '--expiry-check') {
      final expiry = DateTime.parse(state['expiry-gh-expiry'] as String);
      if (DateTime.now().toUtc().isBefore(expiry)) {
        stdout.writeln(
          jsonEncode({
            'status': 'waiting-expiry',
            'remainingSeconds': expiry
                .difference(DateTime.now().toUtc())
                .inSeconds,
          }),
        );
        return;
      }
      final current = await review(state['request-gh-expiry'] as String);
      require(
        current.credential!.state != WorkspaceCredentialRequestState.approved,
        'Expired approval still active',
      );
      final result = await operation(
        'gh',
        state['request-gh-expiry'] as String,
        'gh-after-natural-expiry',
      );
      require(result['status'] != 'accepted', 'Expired approval executed');
      require(
        current.credentialExpiresAt?.toUtc().toIso8601String() ==
            state['expiry-gh-expiry'],
        'Natural expiry changed original deadline',
      );
      state['naturalExpiryChecked'] = true;
      save();
      stdout.writeln(
        jsonEncode({
          'status': 'expiry-verified',
          'originalDeadlineUnchanged':
              current.credentialExpiresAt?.toUtc().toIso8601String() ==
              state['expiry-gh-expiry'],
        }),
      );
    } else if (args[0] == '--lifetime') {
      require(
        state['phase'] == 'restart-verified',
        'Verify original restart first',
      );
      require(
        state['lifetimeChecked'] != true,
        'Do not replay completed lifetime checks',
      );
      final journalDirectory = Directory(
        '${hostFiles().parent.path}/credential-executions',
      );
      Future<Map<String, dynamic>> journal(String execution) async {
        final file = File(
          '${journalDirectory.path}/${sha256.convert(utf8.encode(execution))}.json',
        );
        final value = await readPrivateDeviceState(file);
        require(
          value?['executionId'] == execution,
          'Original execution journal required',
        );
        return value!;
      }

      Future<void> until(Future<bool> Function() test, String message) async {
        final end = DateTime.now().add(const Duration(seconds: 25));
        while (!await test()) {
          require(DateTime.now().isBefore(end), message);
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }

      // Reconcile the first fault-injection execution before a distinct check.
      // That check had an overly strict assertion while its descendant lived.
      if (state['appQuitVerified'] == true &&
          state['operation-ssh-worker-crash'] != null &&
          state['crashAttemptSuffix'] == null) {
        phase = 'reconcile original fault-injection result';
        await File('${work.path}/ssh-release').writeAsString('release');
        final previous = await command(
          'operation-status',
          Map<String, Object?>.from(state['operation-ssh-worker-crash'] as Map),
        );
        require(
          previous['executionId'] is String,
          'Original crash execution required',
        );
        await until(() async {
          final result = await command('execution-status', {
            'executionId': previous['executionId'],
          });
          return result['executionState'] == 'unknown' &&
              result['cleanupState'] == 'complete';
        }, 'Reconcile original fault-injection cleanup first');
        state['crashAttemptSuffix'] = 'ssh-worker-crash-recheck';
        save();
      }

      if (state['appQuitVerified'] != true) {
        final previousSuffix =
            state['appQuitAttemptSuffix'] as String? ?? 'ssh-app-exit';
        if (state['operation-$previousSuffix'] != null) {
          final previous = await operation(
            'ssh',
            state['request-ssh'] as String,
            previousSuffix,
          );
          require(
            previous['executionId'] is String,
            'Reconcile original App-exit execution first',
          );
          await settled(
            previous['executionId'] as String,
            contains: 'WINDOWS_RECEIVER_COMPLETED',
          );
          state['appQuitAttemptSuffix'] = '$previousSuffix-recheck';
          save();
        }
      }
      final gate = File('${work.path}/ssh-release');
      if (await gate.exists()) await gate.delete();
      final treeMode = File('${work.path}/tree-mode');
      if (await treeMode.exists()) await treeMode.delete();
      final counter = File('${work.path}/ssh-counter');
      final previousCount = (await counter.readAsLines()).length;
      if (state['appQuitVerified'] != true) {
        phase = 'actual App exit with live credential worker';
        final app = File('${tools.parent.path}/app/info_desktop.exe');
        final appData = Directory(args[1]).absolute.parent.parent;
        final desktop = await Process.start(
          app.path,
          [],
          environment: {'APPDATA': appData.path},
        );
        desktop.stdout.listen((_) {});
        desktop.stderr.listen((_) {});
        final desktopIdentity = CredentialProcessIdentity.capture(desktop.pid);
        require(
          desktopIdentity != null,
          'Actual candidate App identity missing',
        );
        try {
          final running = await operation(
            'ssh',
            state['request-ssh'] as String,
            state['appQuitAttemptSuffix'] as String? ?? 'ssh-app-exit',
          );
          require(
            running['status'] == 'accepted',
            'App lifetime operation rejected: ${running['status']}/${running['errorCode']}',
          );
          await until(
            () async =>
                (await counter.readAsLines()).length == previousCount + 1,
            'Receiver did not start',
          );
          final fact = await journal(running['executionId'] as String);
          final lease = CredentialMaterialLease.fromPrivateJson(
            Map<String, dynamic>.from(fact['lease'] as Map),
          );
          ManagedCredentialFiles.verify(lease);
          require(
            CredentialProcessIdentity.isActive(
                  desktop.pid,
                  desktopIdentity!.value,
                ) ==
                true,
            'App exited before quit check',
          );
          final quit = await Process.run('${tools.parent.path}/cli/info.exe', [
            'app',
            'quit',
            '--pid',
            '${desktop.pid}',
            '--timeout-ms',
            '60000',
          ]);
          final quitResult = jsonDecode(quit.stdout.toString()) as Map;
          state['lastAppQuit'] = {
            'exitCode': quit.exitCode,
            'status': quitResult['status'],
          };
          save();
          require(
            quit.exitCode == 0 && quit.stdout.toString().contains('exited'),
            'Same-package normal App quit failed: ${quit.exitCode}/${quitResult['status']}',
          );
          await desktop.exitCode.timeout(const Duration(seconds: 15));
          final status = await command('execution-status', {
            'executionId': running['executionId'],
          });
          require(
            status['executionState'] == 'running',
            'App quit interrupted credential execution',
          );
          ManagedCredentialFiles.verify(lease);
          await gate.writeAsString('release');
          await settled(
            running['executionId'] as String,
            contains: 'WINDOWS_RECEIVER_COMPLETED',
          );
          require(
            !Directory(lease.path).existsSync(),
            'Finished execution materials remained',
          );
          state['appQuitVerified'] = true;
          save();
        } finally {
          if (desktopIdentity != null &&
              CredentialProcessIdentity.isActive(
                    desktop.pid,
                    desktopIdentity.value,
                  ) ==
                  true) {
            await Process.run('${tools.parent.path}/cli/info.exe', [
              'app',
              'quit',
              '--pid',
              '${desktop.pid}',
              '--timeout-ms',
              '60000',
            ]);
          }
          desktopIdentity?.close();
        }
      }
      phase = 'original worker crash and live descendant retention';
      if (await gate.exists()) await gate.delete();
      await treeMode.writeAsString('own synthetic descendant only');
      final descendantPidFile = File('${work.path}/descendant-pid');
      if (await descendantPidFile.exists()) await descendantPidFile.delete();
      final crash = await operation(
        'ssh',
        state['request-ssh'] as String,
        state['crashAttemptSuffix'] as String? ?? 'ssh-worker-crash',
      );
      require(crash['status'] == 'accepted', 'Crash operation rejected');
      final execution = crash['executionId'] as String;
      await until(descendantPidFile.exists, 'Synthetic descendant missing');
      final descendantPid = int.parse(await descendantPidFile.readAsString());
      final descendantIdentity = CredentialProcessIdentity.capture(
        descendantPid,
      );
      require(descendantIdentity != null, 'Owned descendant identity missing');
      final fact = await journal(execution);
      final lease = CredentialMaterialLease.fromPrivateJson(
        Map<String, dynamic>.from(fact['lease'] as Map),
      );
      final workerPid = fact['workerPid'] as int;
      final workerIdentity = fact['workerIdentity'] as String;
      require(
        CredentialProcessIdentity.isActive(workerPid, workerIdentity) == true,
        'Original registered worker already ended',
      );
      require(
        CredentialProcessJob.isActive(
              fact['jobName'] as String,
              workerPid: workerPid,
              workerCreatedAt: workerIdentity,
            ) ==
            true,
        'Original job not live',
      );
      require(
        Process.killPid(workerPid),
        'Owned worker fault injection failed',
      );
      try {
        await until(
          () async =>
              CredentialProcessIdentity.isActive(workerPid, workerIdentity) ==
              false,
          'Original worker did not end',
        );
        final count = (await counter.readAsLines()).length;
        final retry = await operation(
          'ssh',
          state['request-ssh'] as String,
          state['crashAttemptSuffix'] as String? ?? 'ssh-worker-crash',
        );
        require(
          retry['executionId'] == execution,
          'Crash retry replaced original execution',
        );
        final status = await command('execution-status', {
          'executionId': execution,
        });
        require(
          {'running', 'unknown'}.contains(status['executionState']),
          'Worker loss guessed terminal success',
        );
        require(
          status['cleanupState'] != 'complete',
          'Live descendant prematurely cleaned',
        );
        require(
          CredentialProcessIdentity.isActive(
                descendantPid,
                descendantIdentity!.value,
              ) ==
              true,
          'Descendant terminated with worker',
        );
        ManagedCredentialFiles.verify(lease);
        require(
          (await counter.readAsLines()).length == count,
          'Unknown execution automatically replayed',
        );
        await gate.writeAsString('release');
        await until(
          () async =>
              CredentialProcessIdentity.isActive(
                descendantPid,
                descendantIdentity.value,
              ) ==
              false,
          'Owned descendant did not end',
        );
        await until(() async {
          final result = await command('execution-status', {
            'executionId': execution,
          });
          return result['executionState'] == 'unknown' &&
              result['cleanupState'] == 'complete';
        }, 'Unknown execution cleanup not acknowledged');
        require(
          !Directory(lease.path).existsSync(),
          'Crash materials remained after tree ended',
        );
      } finally {
        await gate.writeAsString('release');
        descendantIdentity?.close();
        await treeMode.delete();
      }
      state['lifetimeChecked'] = true;
      save();
      stdout.writeln(
        jsonEncode({
          'status': 'lifetime-verified',
          'actualAppQuit': true,
          'workerCrashUnknown': true,
          'liveDescendantRetained': true,
          'noReplay': true,
          'materialsCleanedAfterTreeEnded': true,
        }),
      );
    } else if (args[0] == '--finish') {
      require(
        state['phase'] == 'restart-verified',
        'Original verified flow required',
      );
      require(
        state['lifetimeChecked'] == true &&
            state['naturalExpiryChecked'] == true,
        'Complete actual lifetime and natural expiry checks first',
      );
      phase = 'revocation';
      final beforeRevoke = await review(state['request-gh'] as String);
      if (beforeRevoke.credential!.state ==
          WorkspaceCredentialRequestState.approved) {
        await decide(
          state['request-gh'] as String,
          WorkspaceApprovalAction.revoke,
          'w113-revoke-gh',
        );
      } else {
        require(
          beforeRevoke.credential!.state ==
              WorkspaceCredentialRequestState.revoked,
          'Original grant must be active or already revoked',
        );
      }
      require(
        (await operation(
              'gh',
              state['request-gh'] as String,
              'gh-after-revoke',
            ))['status'] !=
            'accepted',
        'Revocation allowed new operation',
      );
      phase = 'original end-only shutdown';
      final ended = await CodexEndIndex(
        hookRoot,
      ).end(chat, timeout: const Duration(seconds: 20));
      require(ended == 'ended', 'Original end not confirmed: $ended');
      require(
        (await operation(
              'ssh',
              state['request-ssh'] as String,
              'ssh-after-end',
            ))['status'] !=
            'accepted',
        'Ended SSH allowed new operation',
      );
      require(
        (await operation(
              'aws',
              state['request-aws'] as String,
              'aws-after-end',
            ))['status'] !=
            'accepted',
        'Ended AWS allowed new operation',
      );
      final host = DeviceCredentialHost(
        device,
        hostFiles(),
        workerExecutable: '$cli/info-runtime-worker.exe',
      );
      require(
        (await host.stopIfIdle())['status'] == 'ok',
        'Owned host did not stop',
      );
      phase = 'original records unchanged';
      final original = state['information'] as Map;
      final current = await owner.information();
      require(
        current.length == original.length &&
            current.every(
              (i) =>
                  original[i.id] ==
                  sha256
                      .convert(utf8.encode(jsonEncode(informationToJson(i))))
                      .toString(),
            ),
        'Original information changed',
      );
      require(
        jsonEncode(await owner.request('GET', '/v1/owner/ssh-hosts')) ==
            jsonEncode(state['originalSshTrust']),
        'Original SSH trust changed',
      );
      state['phase'] = 'completed';
      save();
      stdout.writeln(
        jsonEncode({
          'status': 'completed',
          'revokedAndEndedBlocked': true,
          'originalInformationAndSshTrustUnchanged': true,
        }),
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
    await sts?.close(force: true);
    owner?.close();
  }
}

void require(bool value, String message) {
  if (!value) throw StateError(message);
}
