// QA-only ordinary signed Flutter entry. Production UI/bootstrap/service/native
// files and worker; synthetic fixed key and owner-file control, never user data.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/desktop_bootstrap.dart';
import 'package:info_desktop/desktop_runtime.dart';
import 'package:info_desktop/main.dart';

class _Keys implements DatabaseKeyStore {
  @override
  Future<List<int>?> read() async => List.filled(32, 117);
  @override
  Future<void> create(List<int> key) async =>
      throw StateError('QA key already exists');
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final owner = Platform.environment['MAC_QA_OWNER'];
  if (!Platform.isMacOS ||
      owner == null ||
      !RegExp(r'^[a-f0-9]{32}$').hasMatch(owner)) {
    exit(64);
  }
  final reopenPath = Platform.environment['MAC_QA_REOPEN_ROOT'];
  final reopened = reopenPath != null;
  final root = reopened
      ? Directory(reopenPath)
      : await Directory.systemTemp.createTemp('aim-mac-codex-live-');
  if (reopened) {
    if (await root.resolveSymbolicLinks() != root.path ||
        !root.path.split('/').last.startsWith('aim-mac-codex-live-') ||
        await File('${root.path}/.qa-owner').readAsString() != owner) {
      exit(65);
    }
  } else {
    await File('${root.path}/.qa-owner').writeAsString(owner);
  }
  stdout.writeln('MAC_CODEX_LIVE_ROOT=${root.path}');
  var errors = 0;
  FlutterError.onError = (details) {
    errors++;
    FlutterError.presentError(details);
  };
  EncryptedInformationRepository? repository;
  var closed = 0;
  final bootstrap = DesktopBootstrap(
    platform: NativeDesktopPlatform(),
    port: 47125,
    openLibrary: () async {
      final opened = repository = await EncryptedInformationRepository.open(
        '${root.path}/library',
        _Keys(),
      );
      final service = InformationService(
        repository: opened,
        informationDeliveryFiles: NativeInformationDeliveryFiles(),
      );
      return DesktopLibrary(
        service: service,
        close: () async {
          await opened.close();
          closed++;
        },
        backups: opened.backups,
      );
    },
  );
  runApp(DesktopLauncher(bootstrap: bootstrap));
  while (bootstrap.state == DesktopStartupState.idle ||
      bootstrap.state == DesktopStartupState.starting) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  if (bootstrap.state != DesktopStartupState.ready) {
    stderr.writeln('MAC_CODEX_LIVE_START_FAILED');
    exit(1);
  }
  final service = bootstrap.library!.service;
  final item = reopened
      ? service.owner.information.singleWhere(
          (i) => i.name == 'Synthetic Mac server',
        )
      : await service.owner.createInformation(
          'Synthetic Mac server',
          'Codex acceptance only',
          [
            const FieldInput(
              'Address',
              'May be approved',
              'synthetic-host.invalid',
            ),
            const FieldInput(
              'Username',
              'Remain unapproved',
              'synthetic-private-user',
            ),
          ],
        );
  final InformationItem file;
  if (reopened) {
    file = service.owner.information.singleWhere(
      (i) => i.name == 'Synthetic ordinary file',
    );
  } else {
    final source = File('${root.path}/synthetic-file.bin');
    await source.writeAsBytes(List.generate(1024, (i) => (i * 37 + 11) % 256));
    final draft = await service.owner.beginInformationFileDraft();
    final stage = await service.owner.stageInformationFile(draft, source.path);
    file = await service.owner.commitInformationDraft(
      draft,
      'codex-file',
      InformationDraftInput(
        name: 'Synthetic ordinary file',
        description: 'Codex acceptance only',
        fields: [
          InformationDraftField.stagedFile(
            'Attachment',
            'Synthetic bytes',
            stage.id,
          ),
        ],
      ),
    );
    await service.owner.releaseInformationFileDraft(draft);
  }
  ManagedCredential? credential;
  final sshKey = Platform.environment['MAC_QA_SSH_KEY'];
  final sshPort = Platform.environment['MAC_QA_SSH_PORT'];
  if (sshKey != null) {
    if (reopened) {
      credential = service.owner.credentials.singleWhere(
        (c) => c.name == 'Synthetic Codex SSH key',
      );
    } else {
      await service.owner.configureSshKnownHosts(
        'Synthetic loopback SSH',
        utf8.encode(
          '[127.0.0.1]:$sshPort ${Platform.environment['MAC_QA_SSH_HOST']}\n',
        ),
      );
      final created = await service.owner.createFileCredential(
        name: 'Synthetic Codex SSH key',
        publicPurpose: 'Synthetic loopback acceptance only',
        fileName: 'synthetic_ed25519',
        bytes: base64Decode(sshKey),
      );
      credential = await service.owner.updateCredentialMetadata(
        created.id,
        created.revision,
        name: created.name,
        publicPurpose: created.publicPurpose,
        privateNote: '',
        suggestedBinding: 'ssh_key',
        discoverable: true,
      );
    }
  }
  Future<Map<String, Object?>> status() async {
    final history = await service.owner.history();
    return {
      'ready': true,
      'reopened': reopened,
      if (credential != null)
        'ssh': {
          'port': int.parse(sshPort!),
          'cwd': root.path,
          'credentialId': credential.id,
        },
      'port': bootstrap.boundPort,
      'cipherVersion': repository!.cipherVersion,
      'flutterErrors': errors,
      'libraryCloses': closed,
      'textItem': item.id,
      'addressField': item.fields.first.id,
      'usernameField': item.fields.last.id,
      'fileItem': file.id,
      'fileField': file.fields.single.id,
      'requests': [
        for (final r in service.owner.requests)
          {
            'id': r.id,
            'state': r.state.name,
            'chatLabel': r.chatLabel,
            'sessionEnded': r.sessionEnded,
            'fields': [
              for (final f in r.fields)
                {'itemId': f.itemId, 'fieldId': f.fieldId},
            ],
            'approvedFields': [
              for (final f in r.approvedFields ?? <FieldRef>[])
                {'itemId': f.itemId, 'fieldId': f.fieldId},
            ],
            'expiresAt': r.grantExpiresAt?.toIso8601String(),
          },
      ],
      'grants': [
        for (final g in history.grants)
          {
            'id': g.id,
            'requestId': g.requestId,
            'active': g.active,
            'expiresAt': g.expiresAt.toIso8601String(),
            'events': [for (final e in g.events) e.kind.name],
          },
      ],
      'accesses': [
        for (final a in history.accesses)
          {
            'id': a.id,
            'outcome': a.outcome.name,
            'grantId': a.grantId,
            'fieldId': a.fieldId,
          },
      ],
      'credentialRequests': [
        for (final r in service.owner.credentialUseRequests)
          {
            'id': r.id,
            'chatLabel': r.chatLabel,
            'state': service.owner.credentialUseState(r),
            'grantState': service.owner.credentialGrantState(r),
            'expiresAt': r.credentialExpiresAt?.toIso8601String(),
            'approved': r.credentialApproved,
          },
      ],
      'executions': [
        for (final e in service.owner.credentialExecutions)
          {
            'id': e.id,
            'requestId': e.requestId,
            'operationId': e.operationId,
            'state': e.state,
            'exitCode': e.exitCode,
            'errorCode': e.errorCode,
            'cleanup': e.cleanupState,
          },
      ],
      'deliveries': [
        for (final d in repository!.informationFileDeliveries)
          {'id': d.id, 'state': d.state, 'holdsCopy': d.holdsCopy},
      ],
    };
  }

  Future<void> write(String name, Object value) async {
    final temp = File('${root.path}/.$name.partial');
    await temp.writeAsString(jsonEncode(value), flush: true);
    await temp.rename('${root.path}/$name');
  }

  await write('ready.json', await status());
  stdout.writeln('MAC_CODEX_LIVE_READY=47125');
  var index = 0;
  if (reopened) {
    await for (final entry in root.list()) {
      final match = RegExp(
        r'^reply-(\d+)\.json$',
      ).firstMatch(entry.path.split('/').last);
      if (match != null) {
        final n = int.parse(match.group(1)!);
        if (n > index) index = n;
      }
    }
  }
  // The harness stays live until explicit owner quit. Observation timeouts do
  // not restart this service or create a replacement session.
  while (true) {
    final command = File('${root.path}/command-${index + 1}.json');
    if (!await command.exists()) {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      continue;
    }
    final data = jsonDecode(await command.readAsString()) as Map;
    if (data['owner'] != owner) throw StateError('Foreign QA owner command');
    final action = data['action'];
    if (action == 'quit' || action == 'restart') {
      await write('reply-${index + 1}.json', {
        'quitting': true,
        'restarting': action == 'restart',
        'status': await status(),
      });
      await bootstrap.runtime!.quit();
      return;
    }
    if (action == 'approve') {
      final fields = (data['fields'] as List).cast<String>();
      final allowed = {
        item.fields.first.id: FieldRef(item.id, item.fields.first.id),
        file.fields.single.id: FieldRef(file.id, file.fields.single.id),
      };
      if (fields.isEmpty || fields.any((f) => !allowed.containsKey(f))) {
        throw StateError('Unexpected QA approval scope');
      }
      service.owner.approve(
        data['requestId'] as String,
        fields.map((f) => allowed[f]!).toList(),
        lifetime: data['lifetimeSeconds'] == 60
            ? const Duration(minutes: 1)
            : const Duration(hours: 1),
      );
    } else if (action == 'approve-use') {
      final r = service.owner.credentialUseRequests.singleWhere(
        (r) => r.id == data['requestId'],
      );
      if (credential == null ||
          r.credentialId != credential.id ||
          r.alias != 'ssh_key' ||
          r.plan.receiver != 'ssh_identity') {
        throw StateError('Unexpected synthetic credential scope');
      }
      await service.owner.decideCredentialUse(
        r.id,
        approveCredential: true,
        fields: [
          for (final f in r.fields)
            if (f.itemId == file.id && f.fieldId == file.fields.single.id) f,
        ],
      );
    } else if (action == 'revoke-use') {
      await service.owner.revokeCredentialUse(data['requestId'] as String);
    } else if (action == 'revoke') {
      service.owner.revoke(data['requestId'] as String);
    } else if (action != 'status') {
      throw StateError('Unknown QA owner action');
    }
    await write('reply-${index + 1}.json', await status());
    index++;
  }
}
