import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:info_core/info_core.dart';
import 'package:info_remote/agent_connection.dart';
import 'private_device_state.dart';
import 'ssh_session.dart';
import 'ssh_session_launch.dart';
import 'ssh_session_macos.dart';
import 'ssh_session_transport.dart';
import 'ssh_session_windows.dart';

const _base = '/credential-use/batch';
String _hash(Object? value) =>
    'sha256:${sha256.convert(utf8.encode(jsonEncode(value)))}';
String _nonce() =>
    base64Url.encode(List.generate(24, (_) => Random.secure().nextInt(256)));
void _ok(Map<String, dynamic> value) {
  if (value['status'] != 'ok') {
    throw SshTransportFailure(
      (value['errorCode'] ?? value['status'] ?? 'service_unavailable')
          as String,
    );
  }
}

/// Lives in the existing local execution worker in BOTH library modes. The
/// library owns grants and durable operation admission; this device owns SSH.
class SshSessionHost {
  SshSessionHost(
    this.profile,
    this.directory, {
    this.launcher,
    this.sshExecutable,
  }) {
    _timer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(_poll()),
    );
  }
  final AgentConnectionProfile profile;
  final Directory directory;
  final SshTransportLauncher? launcher;
  final String? sshExecutable;
  final _entries = <String, _Entry>{};
  final _inflight = <String, Future<Map<String, dynamic>>>{};
  final _digests = <String, String>{};
  Timer? _timer;
  bool _polling = false, _closed = false;
  bool get canStop =>
      _inflight.isEmpty &&
      _entries.values.every(
        (e) => {'closed', 'lost'}.contains(e.session.state),
      );
  bool get isIdle => canStop;
  SshSessionBinding _binding(String session) =>
      SshSessionBinding(profile.serverId, _hash(profile.deviceToken), session);
  AgentConnection _connection() => AgentConnection(profile);
  Future<Map<String, dynamic>> _call(
    String path,
    Map<String, dynamic> body,
  ) async {
    final connection = _connection();
    try {
      return await connection.call(path, body);
    } finally {
      connection.close();
    }
  }

  Future<Map<String, dynamic>> _grant(
    String controller,
    String request, {
    bool trust = false,
  }) async {
    final result = await _call('$_base/ssh-check', {
      'sessionSecret': controller,
      'requestId': request,
      'includeTrust': trust,
    });
    _ok(result);
    return result;
  }

  Future<void> _poll() async {
    if (_polling || _closed) return;
    _polling = true;
    try {
      await maintain();
      for (final entry in _entries.values.toList()) {
        if (!{'ready', 'busy'}.contains(entry.session.state)) continue;
        try {
          await _grant(entry.controller, entry.request);
        } on Object {
          await entry.session.authorizationLost();
        }
      }
    } finally {
      _polling = false;
    }
  }

  Future<File> _record(String controller, String operation) async {
    final folder = await privateDeviceDirectory(directory);
    return File(
      '${folder.path}/${sha256.convert(utf8.encode('$controller\n$operation'))}.json',
    );
  }

  Future<void> maintain() async {
    final folder = await privateDeviceDirectory(directory);
    await for (final entity in folder.list(followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      final record = await readPrivateDeviceState(entity);
      if (record?['lease'] is! Map) continue;
      bool? active;
      if (record!['brokerPid'] == null) {
        // The platform cannot start SSH before the registration callback. If
        // this host died before registration, no consumer was ever admitted.
        active = CredentialProcessIdentity.isActive(
          record['hostPid'] as int,
          record['hostIdentity'] as String,
        );
      } else if (Platform.isMacOS) {
        active = CredentialProcessJob.isActive(
          record['jobName'] as String,
          workerPid: record['brokerPid'] as int,
          workerCreatedAt: record['brokerIdentity'] as String,
        );
      } else {
        // Windows native owns a non-inherited KILL_ON_JOB_CLOSE job. Once its
        // exact broker ends, all admitted SSH/ASKPASS consumers end with it.
        active = CredentialProcessIdentity.isActive(
          record['brokerPid'] as int,
          record['brokerIdentity'] as String,
        );
      }
      if (active != false) continue;
      try {
        ManagedCredentialFiles.cleanup(
          CredentialMaterialLease.fromPrivateJson(
            Map<String, dynamic>.from(record['lease'] as Map),
          ),
        );
        record.remove('lease');
        await writePrivateDeviceState(entity, record);
      } on Object {
        /* Preserve uncertain material identity for later cleanup. */
      }
    }
  }

  _Entry _entry(String controller, String id) {
    final entry = _entries[id];
    if (entry == null) throw const SshTransportFailure('session_lost');
    entry.session.requireController(_binding(controller));
    return entry;
  }

  Future<Map<String, dynamic>> execute(
    String controller,
    Map<String, dynamic> input,
  ) async {
    try {
      if (_closed) throw const SshTransportFailure('service_unavailable');
      final command = input['command'];
      if (command == 'ssh-capabilities') {
        return {
          'status': 'ok',
          'localHost': true,
          'background': true,
          'remoteRequirements': [
            'python3',
            'bash',
            'pty',
            'unix-peer-credentials',
            'descendant-subreaper',
            'kernel-children',
          ],
          'fullScreenRendering': false,
        };
      }
      if (command == 'ssh-open') return await _open(controller, input);
      final entry = _entry(controller, input['sessionId'] as String);
      final session = entry.session;
      switch (command) {
        case 'ssh-status':
          return session.status(runId: input['runId'] as String?);
        case 'ssh-output':
          return session.output(
            cursor: input['cursor'] as int? ?? 0,
            runId: input['runId'] as String?,
          );
        case 'ssh-interrupt':
          return await session.interrupt(input['runId'] as String);
        case 'ssh-close':
          return await session.close(force: input['force'] == true);
        case 'ssh-credential-request':
          return await _credentialRequest(entry, input);
        case 'ssh-run':
          if (session.state != 'ready' || entry.reserving) {
            final cached = await _cached(entry.controller, input);
            if (cached != null) return cached;
            return {
              'status': session.state == 'busy' || entry.reserving
                  ? 'busy'
                  : 'session_closed',
            };
          }
          entry.reserving = true;
          try {
            return await _operate(
              entry,
              input,
              'run',
              () => session.run(
                input['operationId'] as String,
                input['text'] as String,
              ),
            );
          } finally {
            entry.reserving = false;
          }
        case 'ssh-input':
          return await _operate(
            entry,
            input,
            'input',
            () => session.input(
              input['runId'] as String,
              input['operationId'] as String,
              utf8.encode(input['text'] as String),
            ),
          );
        case 'ssh-credential-use':
          final receiver = session.status()['run'] as Map?;
          final action = (receiver?['credentialReceiver'] as Map?)?['actionId'];
          if (receiver?['runId'] != input['runId'] ||
              action != input['actionId'] ||
              entry.receiverRequests[input['requestId']] !=
                  '${input['runId']}:${input['actionId']}') {
            return {'status': 'stale_receiver'};
          }
          return await _operate(
            entry,
            input,
            'credential',
            () => throw StateError('claim gate'),
            request: input['requestId'] as String,
            materialWork: (secret, deliveryGuard) => session.credential(
              input['runId'] as String,
              input['operationId'] as String,
              input['actionId'] as String,
              () async => secret,
              authorizeDelivery: deliveryGuard,
            ),
          );
        default:
          throw const SshTransportFailure('invalid_request');
      }
    } on SshTransportFailure catch (error) {
      return {'status': error.code};
    } on CredentialUseFailure catch (error) {
      return {'status': error.code};
    } on Object {
      return {'status': 'service_unavailable'};
    }
  }

  Future<Map<String, dynamic>?> _cached(
    String controller,
    Map<String, dynamic> input,
  ) async {
    final operation = input['operationId'] as String;
    final key = '$controller\n$operation';
    final digest = _hash(input);
    if (_digests.containsKey(key) && _digests[key] != digest) {
      throw const SshTransportFailure('operation_conflict');
    }
    if (_inflight[key] case final pending?) return await pending;
    final record = await readPrivateDeviceState(
      await _record(controller, operation),
    );
    if (record == null) return null;
    if (record['digest'] != digest) {
      throw const SshTransportFailure('operation_conflict');
    }
    return Map<String, dynamic>.from(
      record['result'] as Map? ??
          {'status': 'operation_unknown', 'operationId': operation},
    );
  }

  Future<Map<String, dynamic>> _once(
    String controller,
    String operation,
    Object value,
    Future<Map<String, dynamic>> Function(
      File file,
      Map<String, dynamic> record,
    )
    work,
  ) async {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(operation)) {
      throw const SshTransportFailure('invalid_operation_id');
    }
    final key = '$controller\n$operation', digest = _hash(value);
    if (_digests.containsKey(key) && _digests[key] != digest) {
      throw const SshTransportFailure('operation_conflict');
    }
    _digests[key] = digest;
    if (_inflight[key] case final pending?) return pending;
    final future = (() async {
      final file = await _record(controller, operation);
      final existing = await readPrivateDeviceState(file);
      if (existing != null) {
        if (existing['digest'] != digest) {
          throw const SshTransportFailure('operation_conflict');
        }
        if (value is Map &&
            value['command'] == 'ssh-open' &&
            existing['sessionId'] is String &&
            !_entries.containsKey(existing['sessionId'])) {
          return {
            'status': 'session_lost',
            'sessionId': existing['sessionId'],
            'operationId': operation,
            'sessionState': 'lost',
          };
        }
        return Map<String, dynamic>.from(
          existing['result'] as Map? ??
              {
                'status': 'operation_unknown',
                'sessionId': existing['sessionId'],
                'operationId': operation,
              },
        );
      }
      final host = CredentialProcessIdentity.capture(pid);
      if (host == null) {
        throw const SshTransportFailure('process_identity_unavailable');
      }
      final record = <String, dynamic>{
        'version': 1,
        'digest': digest,
        'hostPid': pid,
        'hostIdentity': host.value,
        'operationId': operation,
      };
      host.close();
      await writePrivateDeviceState(file, record);
      late Map<String, dynamic> result;
      try {
        result = await work(file, record);
      } on Object catch (error) {
        if (record['lease'] is Map && record['brokerPid'] == null) {
          try {
            ManagedCredentialFiles.cleanup(
              CredentialMaterialLease.fromPrivateJson(
                Map<String, dynamic>.from(record['lease'] as Map),
              ),
            );
            record.remove('lease');
          } on Object {
            /* Retain identity-bound cleanup evidence. */
          }
        }
        record['result'] = {
          'status': error is SshTransportFailure
              ? error.code
              : 'operation_unknown',
          'operationId': operation,
        };
        await writePrivateDeviceState(file, record);
        rethrow;
      }
      record['result'] = result;
      await writePrivateDeviceState(file, record);
      return result;
    })();
    _inflight[key] = future;
    try {
      return await future;
    } finally {
      _inflight.remove(key);
    }
  }

  Future<Map<String, dynamic>> _begin(
    String controller,
    String request,
    String operation,
    SshSessionOperationContext context,
  ) async {
    final result = await _call('$_base/begin', {
      'sessionSecret': controller,
      'requestId': request,
      'operationId': operation,
      'sshContext': context.toJson(),
    });
    _ok(result);
    return result;
  }

  Future<List<int>> _material(
    String proof,
    String controller,
    String request,
  ) async {
    final status = await _call('$_base/status', {
      'sessionSecret': controller,
      'requestId': request,
    });
    final items = (status['items'] as List).cast<Map>();
    final result = await _call('$_base/material', {
      'privateProof': proof,
      'observations': {
        for (final item in items) item['id'] as String: item['destination'],
      },
    });
    _ok(result);
    return base64Decode((result['materials'] as Map).values.single as String);
  }

  Future<void> _authorize(String proof, {_Entry? credentialEntry}) async => _ok(
    await _call('$_base/authorize', {
      'privateProof': proof,
      if (credentialEntry != null) ...{
        'sshLoginSession': credentialEntry.controller,
        'sshLoginRequestId': credentialEntry.request,
      },
    }),
  );
  Future<void> _finish(
    String proof,
    Map<String, dynamic> result,
    List<String> ids,
  ) async {
    final sent = {
      'accepted',
      'ready',
      'delivered',
      'duplicate',
    }.contains(result['status']);
    await _call('$_base/finish', {
      'privateProof': proof,
      'state': sent
          ? 'filled'
          : result['status'] == 'operation_unknown'
          ? 'unknown'
          : 'failed',
      'itemResults': {for (final id in ids) id: sent ? 'sent' : 'unknown'},
      'errorCode': null,
    });
  }

  Future<Map<String, dynamic>> _operate(
    _Entry entry,
    Map<String, dynamic> input,
    String kind,
    Future<Map<String, dynamic>> Function() work, {
    String? request,
    Future<Map<String, dynamic>> Function(List<int>, Future<void> Function())?
    materialWork,
  }) => _once(entry.controller, input['operationId'] as String, input, (
    file,
    record,
  ) async {
    final operation = input['operationId'] as String;
    final runId = kind == 'run' ? operation : input['runId'] as String;
    final targetRequest = request ?? entry.request;
    final context = SshSessionOperationContext(
      kind: kind,
      sessionId: entry.session.id,
      runId: runId,
      actionId: input['actionId'] as String?,
      digest: _hash(input['text'] ?? input['actionId']),
      byteLength: input['text'] == null
          ? null
          : utf8.encode(input['text'] as String).length,
    );
    await _grant(entry.controller, entry.request);
    if (targetRequest != entry.request) {
      await _grant(entry.controller, targetRequest);
    }
    final claim = await _begin(
      entry.controller,
      targetRequest,
      operation,
      context,
    );
    final proof = claim['privateProof'] as String?;
    if (proof == null) {
      return {'status': 'operation_unknown', 'operationId': operation};
    }
    final secret = materialWork == null
        ? null
        : await _material(proof, entry.controller, targetRequest);
    await _authorize(
      proof,
      credentialEntry: kind == 'credential' ? entry : null,
    );
    final result = materialWork == null
        ? await work()
        : await materialWork(
            secret!,
            () => _authorize(proof, credentialEntry: entry),
          );
    await _finish(proof, result, (claim['itemIds'] as List).cast<String>());
    return {...result, 'operationId': operation};
  });
  Future<Map<String, dynamic>> _open(
    String controller,
    Map<String, dynamic> input,
  ) => _once(controller, input['operationId'] as String, input, (
    file,
    record,
  ) async {
    if (_entries.length >= 16) {
      throw const SshTransportFailure('session_capacity');
    }
    final request = input['requestId'] as String;
    final grant = await _grant(controller, request, trust: true);
    final target = SshSessionTarget.fromJson(
      Map<String, dynamic>.from(grant['target'] as Map),
    );
    if (target.credentialUse != 'login') {
      throw const SshTransportFailure('scope_not_approved');
    }
    final id = 'ssh-${_nonce()}';
    record['sessionId'] = id;
    await writePrivateDeviceState(file, record);
    final claim = await _begin(
      controller,
      request,
      input['operationId'] as String,
      SshSessionOperationContext(
        kind: 'open',
        sessionId: id,
        digest: _hash(target.toJson()),
      ),
    );
    final proof = claim['privateProof'] as String?;
    if (proof == null) {
      return {
        'status': 'operation_unknown',
        'operationId': input['operationId'],
        'sessionId': id,
      };
    }
    var lease = ManagedCredentialFiles.create();
    record['lease'] = lease.toPrivateJson();
    record['jobName'] = CredentialProcessJob.nameFor(_nonce());
    await writePrivateDeviceState(file, record);
    lease = ManagedCredentialFiles.reserve(lease, [
      'credential.bin',
      'known-hosts',
      'global-known-hosts',
    ]);
    record['lease'] = lease.toPrivateJson();
    await writePrivateDeviceState(file, record);
    final secret = await _material(proof, controller, request);
    ManagedCredentialFiles.write(
      lease,
      'known-hosts',
      base64Decode(grant['knownHostsBase64'] as String),
    );
    ManagedCredentialFiles.write(lease, 'global-known-hosts', const []);
    if (target.authentication == 'publickey') {
      ManagedCredentialFiles.write(lease, 'credential.bin', secret);
    }
    await _authorize(proof);
    final executable =
        sshExecutable ??
        (Platform.isWindows
            ? '${Platform.environment['SystemRoot']}\\System32\\OpenSSH\\ssh.exe'
            : '/usr/bin/ssh');
    final platform =
        launcher ??
        (Platform.isWindows
            ? WindowsSshTransportLauncher()
            : MacOsSshTransportLauncher(
                helperPath:
                    '${File(Platform.resolvedExecutable).parent.path}/info-ssh-session',
              ));
    var registered = false, challenged = false;
    SshSession? session;
    final transport = await platform.start(
      sshSessionLaunch(
        target: target,
        executable: executable,
        knownHostsPath: '${lease.path}/known-hosts',
        emptyConfigPath: '${lease.path}/global-known-hosts',
        privateKeyPath: target.authentication == 'publickey'
            ? '${lease.path}/credential.bin'
            : null,
        onProcessCreated: (processId, identity) async {
          if (Platform.isMacOS) {
            final deadline = DateTime.now().add(const Duration(seconds: 2));
            while (true) {
              try {
                CredentialProcessJob.observe(
                  record['jobName'] as String,
                  processId,
                  workerPid: processId,
                ).close();
                break;
              } on Object {
                if (DateTime.now().isAfter(deadline)) rethrow;
                await Future<void>.delayed(const Duration(milliseconds: 10));
              }
            }
          }
          record['brokerPid'] = processId;
          record['brokerIdentity'] = identity;
          await writePrivateDeviceState(file, record);
          await _grant(controller, request);
          await _authorize(proof);
          registered = true;
        },
        onLoginChallenge: (challenge) async {
          if (!registered ||
              challenged ||
              target.authentication != 'password' ||
              challenge.category != 'password') {
            return null;
          }
          if (session != null && session.state != 'opening') return null;
          challenged = true;
          await _grant(controller, request);
          await _authorize(proof);
          if (session != null && session.state != 'opening') return null;
          session?.registerSecret(secret);
          return secret;
        },
      ),
    );
    if (!registered) {
      await transport.terminate();
      throw const SshTransportFailure('transport_registration_unavailable');
    }
    session = SshSession(
      id: id,
      binding: _binding(controller),
      transport: transport,
      secrets: [secret],
      authorize: (_) async {
        await _grant(controller, request);
      },
    );
    final entry = _Entry(session, controller, request, target);
    _entries[id] = entry;
    unawaited(
      transport.exitCode.then((_) async {
        await maintain();
      }),
    );
    try {
      await transport.send(sshSessionRemoteSource);
      await session.ready.timeout(const Duration(seconds: 30));
      final result = {
        'status': 'ready',
        'sessionId': id,
        'operationId': input['operationId'],
        'capabilities': session.capabilities,
      };
      await _finish(proof, result, (claim['itemIds'] as List).cast<String>());
      return result;
    } on Object {
      await session.close(force: true);
      final result = <String, dynamic>{
        'status': 'session_lost',
        'sessionId': id,
        'reason': session.closeReason,
      };
      await _finish(proof, result, (claim['itemIds'] as List).cast<String>());
      return result;
    }
  });
  Future<Map<String, dynamic>> _credentialRequest(
    _Entry entry,
    Map<String, dynamic> input,
  ) async {
    await _grant(entry.controller, entry.request);
    final run = entry.session.status()['run'] as Map?;
    final receiver = run?['credentialReceiver'] as Map?;
    if (run?['runId'] != input['runId'] ||
        receiver?['actionId'] != input['actionId']) {
      return {'status': 'stale_receiver'};
    }
    final target = SshSessionTarget(
      host: entry.target.host,
      port: entry.target.port,
      user: entry.target.user,
      authentication: 'password',
      credentialUse: 'sudo',
      validity: input['validity'] as String? ?? 'session',
    );
    var response = await _call('$_base/ssh-reuse', {
      'sessionSecret': entry.controller,
      'credentialId': input['credentialId'],
      'version': input['version'],
      'target': target.toJson(),
    });
    if (response['status'] == 'not_found') {
      response = await _call('$_base/request', {
        'sessionSecret': entry.controller,
        'operationId': input['operationId'],
        'input': {
          'protocolVersion': 3,
          'purpose': input['purpose'],
          'agentName': input['agentName'],
          'externalChatId': input['externalChatId'],
          'items': [
            {
              'credentialId': input['credentialId'],
              'version': input['version'],
              'destination': {'via': 'ssh', 'target': target.toJson()},
            },
          ],
        },
      });
    }
    if (response['requestId'] is String) {
      entry.receiverRequests[response['requestId'] as String] =
          '${input['runId']}:${input['actionId']}';
    }
    return response;
  }

  Future<void> close() async {
    _closed = true;
    _timer?.cancel();
    for (final entry in _entries.values) {
      await entry.session.close(force: true);
    }
    await maintain();
  }
}

class _Entry {
  _Entry(this.session, this.controller, this.request, this.target);
  final SshSession session;
  final String controller, request;
  final SshSessionTarget target;
  final receiverRequests = <String, String>{};
  bool reserving = false;
}
