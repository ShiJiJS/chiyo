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
  final root = await Directory.systemTemp.createTemp('aim-mac-codex-live-');
  await File('${root.path}/.qa-owner').writeAsString(owner);
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
  final item = await service.owner.createInformation(
    'Synthetic Mac server',
    'Codex acceptance only',
    [
      const FieldInput('Address', 'May be approved', 'synthetic-host.invalid'),
      const FieldInput(
        'Username',
        'Remain unapproved',
        'synthetic-private-user',
      ),
    ],
  );
  final source = File('${root.path}/synthetic-file.bin');
  await source.writeAsBytes(List.generate(1024, (i) => (i * 37 + 11) % 256));
  final draft = await service.owner.beginInformationFileDraft();
  final stage = await service.owner.stageInformationFile(draft, source.path);
  final file = await service.owner.commitInformationDraft(
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
  Future<Map<String, Object?>> status() async {
    final history = await service.owner.history();
    return {
      'ready': true,
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
    if (action == 'quit') {
      await write('reply-${index + 1}.json', {
        'quitting': true,
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
        lifetime: const Duration(hours: 1),
      );
    } else if (action == 'revoke') {
      service.owner.revoke(data['requestId'] as String);
    } else if (action != 'status') {
      throw StateError('Unknown QA owner action');
    }
    await write('reply-${index + 1}.json', await status());
    index++;
  }
}
