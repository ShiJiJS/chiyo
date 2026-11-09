@TestOn('!windows')
library;

// Real OnlineServer fixture uses POSIX secret mounts. Windows behavior is
// exercised by the explicit existing-NAS tests, without relaxing that boundary.
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_desktop/desktop_controls.dart';
import 'package:info_desktop/online_desktop_launcher.dart';
import 'package:info_desktop/workspace/library_page.dart';
import 'package:info_desktop/workspace/library_document.dart';
import 'package:info_desktop/workspace/plugins_page.dart';
import 'package:info_desktop/workspace/remote_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_remote/connection_profile.dart';
import 'package:info_server/agent_devices.dart';
import 'package:info_server/mounted_database_key_store.dart';
import 'package:info_server/online_server.dart';
import 'package:info_server/server_configuration.dart';
import 'package:info_storage/info_storage.dart';
import '../../server/test/support/tls_fixture.dart';
import '../../server/test/support/template_fixture.dart';

class _RealHttp extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final previous = HttpOverrides.current;
  setUpAll(() => HttpOverrides.global = _RealHttp());
  tearDownAll(() => HttpOverrides.global = previous);
  testWidgets(
    'normal online App installs and uses a plugin, preserves its frozen display after changes',
    (t) async {
      t.view.physicalSize = const Size(1500, 1100);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      late Directory root;
      late EncryptedInformationRepository repo;
      late core.OnlineInformationRuntime runtime;
      late OnlineServer server;
      late PrivateConnectionProfileStore profiles;
      late File package;
      RemoteWorkspaceSource? live;
      var chooserCalls = 0;
      const channel = MethodChannel('agent_info_manage/backup_files');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method != 'templatePackageInput') {
              throw StateError('Unexpected native operation');
            }
            chooserCalls++;
            return package.path;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      Future<void> until(bool Function() ready) async {
        for (var i = 0; i < 300; i++) {
          if (ready()) return;
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await t.pump(const Duration(milliseconds: 80));
        }
        fail(
          'UI did not finish: ${find.byType(Text).evaluate().map((e) => (e.widget as Text).data).whereType<String>().join(' | ')}',
        );
      }

      Future<T> connected<T>(Future<T> Function() action) async {
        T? value;
        Object? error;
        var done = false;
        action().then(
          (result) {
            value = result;
            done = true;
          },
          onError: (Object failure) {
            error = failure;
            done = true;
          },
        );
        await until(() => done);
        if (error != null) throw error!;
        return value as T;
      }

      Finder key(String value) => find.byKey(ValueKey(value));
      Future<void> tap(String value) async {
        await until(() {
          if (key(value).evaluate().isEmpty) return false;
          final widget = key(value).evaluate().single.widget;
          return widget is! DesktopButton || widget.onPressed != null;
        });
        await t.ensureVisible(key(value));
        await t.pump();
        await t.runAsync(() => t.tap(key(value)));
        await t.pump(const Duration(milliseconds: 250));
      }

      Future<void> submitPlugin() async {
        await until(
          () =>
              key('plugin-change-submit').evaluate().isNotEmpty &&
              t.widget<DesktopButton>(key('plugin-change-submit')).onPressed !=
                  null,
        );
        await tap('plugin-change-submit');
        await until(() => key('plugin-change-submit').evaluate().isEmpty);
      }

      await t.runAsync(() async {
        root = await Directory.systemTemp.createTemp('chiyo-online-plugin-ui-');
        await initializeServerSecrets('${root.path}/secrets');
        final fixture = await createTlsFixture(root);
        final tls = SecurityContext()
          ..useCertificateChain(fixture.certificate)
          ..usePrivateKey(fixture.privateKey);
        final token = base64Url
            .encode(
              await File('${root.path}/secrets/owner.token').readAsBytes(),
            )
            .replaceAll('=', '');
        repo = await EncryptedInformationRepository.open(
          '${root.path}/data',
          MountedDatabaseKeyStore('${root.path}/secrets/database.key'),
        );
        runtime = await core.OnlineInformationRuntime.open(repository: repo);
        server = await OnlineServer.start(
          runtime: runtime,
          devices: AgentDeviceRegistry(repo),
          tls: tls,
          ownerToken: token,
          serverId: 'online-plugins-synthetic',
        );
        profiles = PrivateConnectionProfileStore('${root.path}/profile');
        await profiles.save(
          ConnectionProfile(
            address: 'https://127.0.0.1:${server.port}',
            token: token,
            serverId: 'online-plugins-synthetic',
            certificate: await File(fixture.ca).readAsString(),
          ),
        );
        package = File('${root.path}/plugin.json');
        await package.writeAsString(
          jsonEncode(syntheticTemplatePackage('1.0.0')),
        );
      });
      try {
        await t.pumpWidget(OnlineDesktopLauncher(profiles: profiles));
        await until(() => find.byType(LibraryPage).evaluate().isNotEmpty);
        final source =
            t.widget<LibraryPage>(find.byType(LibraryPage)).controller.source
                as RemoteWorkspaceSource;
        live = source;
        await tap('workspace-nav-settings');
        await tap('settings-section-plugins');
        await until(() => find.byType(PluginsPage).evaluate().isNotEmpty);
        await tap('plugin-install');
        await submitPlugin();
        expect(chooserCalls, 1);
        final plugins = t
            .widget<PluginsPage>(find.byType(PluginsPage))
            .controller;
        await until(() => plugins.selected?.id == 'local.synthetic');
        await tap('plugin-tab-instructions');
        expect(
          find.textContaining('Put configuration steps in body'),
          findsOneWidget,
        );
        await tap('plugin-tab-preview');
        await tap('plugin-create');
        await until(() => key('library-edit-body').evaluate().isNotEmpty);
        await t.enterText(key('library-edit-name'), 'Online plugin record');
        await tap('library-edit-format');
        await t.tap(find.text('Markdown').last);
        await t.pump(const Duration(milliseconds: 250));
        await t.enterText(
          key('library-edit-body'),
          '## Online heading\n\n- A synthetic step',
        );
        await tap('library-edit-save');
        await until(
          () =>
              find.byType(LibraryPage).evaluate().isNotEmpty &&
              t
                      .widget<LibraryPage>(find.byType(LibraryPage))
                      .controller
                      .detail
                      ?.record
                      .name ==
                  'Online plugin record',
        );
        final detail = t
            .widget<LibraryPage>(find.byType(LibraryPage))
            .controller
            .detail!;
        expect(detail.record.type.id, 'local.synthetic/note');
        expect(detail.definition['templateVersion'], '1.0.0');
        expect(find.byType(LibraryDocument), findsOneWidget);
        expect(find.text('## Online heading'), findsNothing);
        await tap('workspace-nav-settings');
        await until(() => find.byType(PluginsPage).evaluate().isNotEmpty);
        await tap('plugin-toggle');
        await submitPlugin();
        await until(() => plugins.selected?.enabled == false);
        final disabled = await connected(
          () => source.readDetail(detail.record.ref),
        );
        expect(disabled.templateState, WorkspaceTemplateState.disabled);
        expect(disabled.definition, detail.definition);
        expect(disabled.values, detail.values);
        await t.runAsync(
          () => package.writeAsString(
            jsonEncode(syntheticTemplatePackage('2.0.0', extra: true)),
          ),
        );
        await tap('plugin-install');
        await submitPlugin();
        await until(() => plugins.selected?.version == '2.0.0');
        // Updating preserves the user's disabled choice; re-enable explicitly.
        expect(plugins.selected!.enabled, false);
        await tap('plugin-toggle');
        await submitPlugin();
        await until(() => plugins.selected?.enabled == true);
        expect(
          (await connected(
            () => source.loadTemplate('local.synthetic/note'),
          ))['templateVersion'],
          '2.0.0',
        );
        await tap('plugin-remove');
        await submitPlugin();
        final removed = await connected(
          () => source.readDetail(detail.record.ref),
        );
        expect(removed.templateState, WorkspaceTemplateState.missing);
        expect(removed.record.type.id, detail.record.type.id);
        expect(removed.definition, detail.definition);
        expect(removed.values, detail.values);
        expect(
          (await connected(
            source.loadCatalog,
          )).types.any((type) => type.id == detail.record.type.id),
          true,
        );
        expect(t.takeException(), isNull);
      } finally {
        await t.pumpWidget(const SizedBox());
        if (live != null) await connected(live.dispose);
        await t.runAsync(() async {
          await server.close();
          await runtime.close();
          await repo.close();
          await root.delete(recursive: true);
        });
      }
    },
  );
}
