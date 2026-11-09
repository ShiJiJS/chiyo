import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_remote/agent_connection.dart';
import 'package:info_remote/owner_client.dart';
import 'package:info_server/mounted_database_key_store.dart';
import 'package:info_server/server_configuration.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_workspace/approval_transport.dart';
import 'package:info_workspace/workspace_approvals.dart';
import '../test/support/tls_fixture.dart';

/// Synthetic QA coordination only. The Agent gets the separate agent directory;
/// owner secrets stay in private/. All decisions use the normal owner HTTPS API.
Future<void> main(List<String> args) async {
  if (args.length < 2)
    throw const FormatException('command and new trial root required');
  final command = args[0], root = Directory(args[1]).absolute;
  final private = Directory('${root.path}/private');
  final evidence = Directory('${root.path}/evidence');
  if (command == 'prepare') {
    if (await root.exists())
      throw const FormatException('Trial root already exists');
    await root.create(recursive: true);
    await Process.run('/bin/chmod', ['700', root.path]);
    await private.create();
    await evidence.create();
    await initializeServerSecrets('${private.path}/secrets');
    final fixture = await createTlsFixture(private);
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();
    final config = {
      'dataDirectory': 'data',
      'secretsDirectory': 'secrets',
      'tlsCertificate': File(fixture.certificate).uri.pathSegments.last,
      'tlsPrivateKey': File(fixture.privateKey).uri.pathSegments.last,
      'address': '127.0.0.1',
      'port': port,
    };
    await File('${private.path}/server.json').writeAsString(jsonEncode(config));
    final repo = await EncryptedInformationRepository.open(
      '${private.path}/data',
      MountedDatabaseKeyStore('${private.path}/secrets/database.key'),
    );
    final runtime = await OnlineInformationRuntime.open(repository: repo);
    try {
      final parent = await runtime.run(
        () => runtime.service.owner.createDirectory('合成验收资料'),
      );
      final child = await runtime.run(
        () => runtime.service.owner.createDirectory('服务器', parentId: parent.id),
      );
      await File(
        '${evidence.path}/fixture.json',
      ).writeAsString(jsonEncode({'directoryId': child.id, 'port': port}));
    } finally {
      await runtime.close();
      await repo.close();
    }
    stdout.writeln(jsonEncode({'state': 'prepared', 'port': port}));
    return;
  }
  final config = await ServerConfiguration.read('${private.path}/server.json');
  if (command == 'audit') {
    Socket? probe;
    try {
      probe = await Socket.connect(
        InternetAddress.loopbackIPv4,
        config.port,
        timeout: const Duration(milliseconds: 300),
      );
    } on SocketException {
      /* stopped host */
    }
    if (probe != null) {
      probe.destroy();
      throw const FormatException('Stop the synthetic host before auditing');
    }
    final repo = await EncryptedInformationRepository.open(
      config.dataDirectory,
      MountedDatabaseKeyStore(config.databaseKeyFile),
    );
    try {
      final grants = {for (final g in repo.grantHistory) g.requestId: g};
      final result = {
        'requests': [
          for (final r in repo.requestHistory)
            {
              'requestId': r.id,
              'state': r.state.name,
              'sessionEnded': r.sessionEnded,
              'grantFields': grants[r.id]?.fields
                  .map((f) => f.fieldName)
                  .toList(),
              'endEvent': grants[r.id]?.events.last.kind.name,
              'allowedReads': repo.accessRecords
                  .where(
                    (a) =>
                        a.grantId == grants[r.id]?.id &&
                        a.outcome == AccessOutcome.allowed,
                  )
                  .length,
            },
        ],
        'grants': repo.grantHistory.length,
        'activeGrants': repo.grantHistory.where((g) => g.active).length,
        'otherFieldReads': repo.accessRecords
            .where(
              (a) =>
                  a.outcome == AccessOutcome.allowed && a.fieldName != '访问地址',
            )
            .length,
      };
      await File(
        '${evidence.path}/durable-audit.json',
      ).writeAsString(const JsonEncoder.withIndent('  ').convert(result));
      stdout.writeln(jsonEncode(result));
    } finally {
      await repo.close();
    }
    return;
  }
  final trust = SecurityContext(withTrustedRoots: false)
    ..setTrustedCertificates('${private.path}/ca.pem');
  final client = await OwnerClient.connect(
    address: Uri.parse('https://127.0.0.1:${config.port}'),
    token: config.ownerToken,
    trust: trust,
  );
  try {
    final manifestFile = File('${evidence.path}/fixture.json');
    final manifest =
        jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>;
    if (command == 'seed') {
      final receipt = await client.request(
        'POST',
        '/v1/owner/saves/independent-agent-trial',
        {
          'name': '合成部署服务器',
          'description': '只用于验证独立 Agent 查询和获批读取，不连接真实服务。',
          'directoryId': manifest['directoryId'],
          'fields': [
            {
              'name': '访问地址',
              'description': '当前合成服务的入口',
              'text': 'https://a03-gateway.example.invalid:8443',
            },
            {
              'name': '内部备注',
              'description': '本任务不需要读取的附加字段',
              'text': 'SYNTHETIC_NOT_SELECTED',
            },
          ],
        },
      );
      final enrolled = await client.request('POST', '/v1/owner/devices', {
        'operationId': 'independent-agent-device',
        'name': '独立 Agent 合成设备',
      });
      final profile = AgentConnectionProfile(
        address: client.address,
        deviceToken: enrolled['deviceToken'] as String,
        serverId: client.serverId,
        certificate: await File('${private.path}/ca.pem').readAsString(),
      );
      final file = await profile.saveIn(
        Directory('${root.path}/agent/connection'),
      );
      await manifestFile.writeAsString(
        jsonEncode({
          ...manifest,
          'recordId': receipt['itemId'],
          'serverId': client.serverId,
        }),
      );
      stdout.writeln(jsonEncode({'state': 'seeded', 'profilePath': file.path}));
    } else if (command == 'pending' || command == 'all') {
      stdout.writeln(
        jsonEncode(
          await client.request(
            'POST',
            '/v1/owner/approvals/query',
            approvalQueryToJson(
              WorkspaceApprovalQuery(
                filter: command == 'all'
                    ? WorkspaceApprovalFilter.all
                    : WorkspaceApprovalFilter.pending,
              ),
            ),
          ),
        ),
      );
    } else if (command == 'approve' && args.length == 3) {
      final detail = approvalDetailFromJson(
        await client.request(
          'GET',
          '/v1/owner/approvals/${Uri.encodeComponent(args[2])}',
        ),
      );
      final selected = detail.scopes
          .where(
            (s) =>
                s.record.id == manifest['recordId'] &&
                s.label == '访问地址' &&
                s.requested &&
                s.available,
          )
          .toList();
      if (selected.length != 1)
        throw const FormatException('Unexpected synthetic request');
      final change = WorkspaceApprovalChange(
        operationId:
            'trial-approve-${args[2].replaceAll(RegExp('[^A-Za-z0-9]'), '')}',
        requestId: args[2],
        reviewToken: detail.reviewToken,
        action: WorkspaceApprovalAction.approve,
        selected: [selected.single.id],
        fieldMinutes: 5,
      );
      final receipt = await client.request(
        'POST',
        '/v1/owner/approvals/decisions',
        approvalChangeToJson(change),
      );
      stdout.writeln(
        jsonEncode({
          'state': 'approved',
          'requestId': receipt['requestId'],
          'revision': receipt['revision'],
        }),
      );
    } else {
      throw const FormatException('Unknown trial command');
    }
  } finally {
    client.close();
  }
}
