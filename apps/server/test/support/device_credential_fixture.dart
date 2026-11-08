import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_remote/agent_connection.dart';
import 'package:info_remote/owner_client.dart';
import 'package:info_server/agent_devices.dart';
import 'package:info_server/mounted_database_key_store.dart';
import 'package:info_server/online_server.dart';
import 'package:info_server/server_configuration.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_workspace/host_transport.dart';
import 'package:info_workspace/workspace_source.dart';
import 'tls_fixture.dart';

class DeviceCredentialFixture {
  DeviceCredentialFixture(
    this.root,
    this.tls,
    this.trust,
    this.token,
    this.certificate,
    this.clock,
  );
  final Directory root;
  final SecurityContext tls, trust;
  final String token, certificate;
  final DateTime Function()? clock;
  late EncryptedInformationRepository repo;
  late OnlineInformationRuntime runtime;
  late OnlineServer server;
  late OwnerClient owner;
  final profiles = <AgentConnectionProfile>[];
  final agents = <AgentConnection>[];
  HttpServer? proxy;
  HttpClient? upstream;
  int claimPosts = 0;
  Future<void> importHostTrust(List<int> bytes) async {
    final upload = await owner.request('POST', '/v1/owner/ssh-hosts/inputs', {
      'version': 1,
      'operationId': 'fixture-ssh-trust',
      'name': 'synthetic-known_hosts',
      'bytes': base64Encode(bytes),
    });
    final file = hostFileFromJson(upload['file']);
    final preview = await owner.request(
      'GET',
      '/v1/owner/ssh-hosts/previews/${file.selectionId}',
    );
    final change = WorkspaceHostImportChange(
      'fixture-import-ssh-trust',
      hostImportPreviewFromJson(preview['preview']),
    );
    final receipt = hostImportReceiptFromJson(
      await owner.request(
        'POST',
        '/v1/owner/ssh-hosts/imports',
        hostImportChangeToJson(change),
      ),
    );
    if (!receipt.matches(change))
      throw StateError('Synthetic SSH trust receipt mismatch');
  }

  static Future<DeviceCredentialFixture> create({
    bool loseFirstClaim = false,
    DateTime Function()? clock,
  }) async {
    final root = await Directory.systemTemp.createTemp(
      'device-credential-operation-',
    );
    await initializeServerSecrets('${root.path}/secrets');
    final files = await createTlsFixture(root);
    final tls = SecurityContext()
      ..useCertificateChain(files.certificate)
      ..usePrivateKey(files.privateKey);
    final trust = SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificates(files.ca);
    final token = base64Url
        .encode(await File('${root.path}/secrets/owner.token').readAsBytes())
        .replaceAll('=', '');
    final f = DeviceCredentialFixture(
      root,
      tls,
      trust,
      token,
      await File(files.ca).readAsString(),
      clock,
    );
    await f.open();
    if (loseFirstClaim) await f._proxy();
    for (var i = 0; i < 2; i++) {
      final device = await f.owner.request('POST', '/v1/owner/devices', {
        'operationId': 'device-$i',
        'name': 'Synthetic device $i',
      });
      final profile = AgentConnectionProfile(
        address: f.proxy == null
            ? f.owner.address
            : Uri.parse('https://127.0.0.1:${f.proxy!.port}'),
        deviceToken: device['deviceToken'] as String,
        serverId: f.owner.serverId,
        certificate: f.certificate,
      );
      f.profiles.add(profile);
      f.agents.add(AgentConnection(profile));
    }
    return f;
  }

  Future<void> _proxy() async {
    upstream = HttpClient(context: trust);
    proxy = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, tls);
    proxy!.listen((request) async {
      try {
        final next = await upstream!.openUrl(
          request.method,
          Uri.parse(
            'https://127.0.0.1:${server.port}',
          ).resolve(request.uri.toString()),
        );
        for (final key in [
          'authorization',
          'content-type',
          'x-chiyo-server-id',
        ]) {
          final value = request.headers.value(key);
          if (value != null) next.headers.set(key, value);
        }
        await next.addStream(request);
        final response = await next.close();
        final bytes = await response.fold<List<int>>(
          [],
          (a, b) => a..addAll(b),
        );
        final claiming =
            request.uri.path == '/v1/agent/credential-use/device/operation';
        if (claiming) claimPosts++;
        if (claiming && claimPosts == 1) {
          (await request.response.detachSocket(writeHeaders: false)).destroy();
          return;
        }
        request.response.statusCode = response.statusCode;
        request.response.headers.contentType = ContentType.json;
        request.response.headers.set(
          'x-chiyo-server-id',
          'synthetic-device-credential-operations',
        );
        request.response.add(bytes);
        await request.response.close();
      } on Object {
        try {
          await request.response.close();
        } on Object {
          /* disconnected */
        }
      }
    });
  }

  Future<Map<String, dynamic>> tokenOperation() async {
    final c = await runtime.run(() async {
      final raw = await runtime.service.owner.createStringCredential(
        name: 'Synthetic lost claim',
        publicPurpose: '',
        secret: 'SYNTHETIC_LOST_CLAIM_TOKEN',
      );
      return runtime.service.owner.updateCredentialMetadata(
        raw.id,
        raw.revision,
        name: raw.name,
        publicPurpose: '',
        privateNote: '',
        suggestedBinding: 'material',
        discoverable: true,
      );
    });
    final chat = await agents.first.call('/session/lifecycle', {
      'chatLabel': 'Synthetic lost claim chat',
    });
    final session = chat['sessionSecret'] as String;
    final input = CredentialUseInput.fromJson({
      'protocolVersion': 2,
      'command': 'request-use',
      'purpose': 'Synthetic loss',
      'credentials': [
        {'alias': 'material', 'credentialId': c.id, 'version': 1},
      ],
      'launch': {
        'receiver': 'gh_token',
        'executable': '/execution-device/gh',
        'argv': ['api', 'user'],
        'cwd': '/execution-device/work',
        'env': {
          'GH_TOKEN': {'secret': 'material'},
        },
      },
    });
    final prepared = DeviceCredentialLaunch.fromPrivateJson({
      'version': 1,
      'planHash': input.launch.planHash,
      'executable': {
        'path': input.launch.path,
        'byteLength': 100,
        'modifiedMicros': 1,
        'sha256': 'sha256:${'a' * 64}',
      },
      'cwd': input.launch.cwd,
    });
    final r = await runtime.run(
      () => runtime.service.agent.requestDeviceCredentialUse(
        profiles.first.deviceToken.split('.').first,
        session,
        input,
        prepared,
      ),
    );
    await runtime.run(
      () => runtime.service.owner.decideCredentialUse(
        r.id,
        approveCredential: true,
      ),
    );
    return {
      'protocolVersion': 2,
      'command': 'run-use',
      'requestId': r.id,
      'operationId': 'lost-once',
      'launch': input.launch.toJson(),
      'sessionSecret': session,
      'deviceLaunch': prepared.toPrivateJson(),
      'deviceJob': 'macos:AgentInfoRuntime-${'c' * 32}',
    };
  }

  Future<void> open([int port = 0]) async {
    repo = await EncryptedInformationRepository.openOnline(
      '${root.path}/data',
      MountedDatabaseKeyStore('${root.path}/secrets/database.key'),
      clock: clock,
    );
    runtime = await OnlineInformationRuntime.open(
      repository: repo,
      clock: clock,
    );
    server = await OnlineServer.start(
      runtime: runtime,
      devices: AgentDeviceRegistry(repo),
      tls: tls,
      ownerToken: token,
      serverId: 'synthetic-device-credential-operations',
      port: port,
      backups: repo.backups,
      backupDirectory: Directory('${root.path}/backup-transfers'),
      policyState: repo,
    );
    owner = await OwnerClient.connect(
      address: Uri.parse('https://127.0.0.1:${server.port}'),
      token: token,
      trust: trust,
    );
  }

  Future<void> close() async {
    for (final a in agents) {
      a.close();
    }
    owner.close();
    await server.close();
    await runtime.close();
    await repo.close();
  }

  Future<void> reopen() async {
    final port = server.port;
    await close();
    await open(port);
    agents.clear();
    agents.addAll(profiles.map(AgentConnection.new));
  }

  Future<void> dispose() async {
    await close();
    await proxy?.close(force: true);
    upstream?.close(force: true);
    await root.delete(recursive: true);
  }
}
