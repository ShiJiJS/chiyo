@TestOn('windows')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_cli/agent_client.dart';
import 'package:info_cli/codex_end_index.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/desktop_runtime.dart';
import 'package:info_desktop/online_desktop_runtime.dart';
import 'package:info_desktop/workspace/remote_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_remote/agent_connection.dart';
import 'package:info_remote/connection_profile.dart';
import 'package:info_remote/owner_client.dart';
import 'support/desktop_platform_fixture.dart';

class _Http extends HttpOverrides {
  bool offline = false;
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _Client(super.createHttpClient(context), this);
}

class _Client implements HttpClient {
  _Client(this.inner, this.observation);
  final HttpClient inner;
  final _Http observation;
  @override
  Duration? get connectionTimeout => inner.connectionTimeout;
  @override
  set connectionTimeout(Duration? value) => inner.connectionTimeout = value;
  @override
  void close({bool force = false}) => inner.close(force: force);
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) {
    if (observation.offline) {
      throw const SocketException('Synthetic desktop disconnect');
    }
    return inner.openUrl(method, url);
  }

  @override
  Future<HttpClientRequest> postUrl(Uri url) => openUrl('POST', url);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Unexpected HTTP operation');
}

class _Native extends NativeDesktopFixture {
  final ids = <String>[];
  int exits = 0;
  bool exitFails = false;
  Future<void>? showGate;
  @override
  Future<bool> notifyNewRequest(String id) async {
    ids.add(id);
    return super.notifyNewRequest(id);
  }

  @override
  Future<void> showWindow() async {
    await showGate;
    await super.showWindow();
  }

  @override
  Future<void> terminate() async {
    exits++;
    if (exitFails) throw StateError('Synthetic native exit failure');
    await super.terminate();
  }
}

void main() {
  const profileDirectory = String.fromEnvironment(
    'CHIYO_NAS_PROFILE_DIRECTORY',
  );
  const privateDirectory = String.fromEnvironment(
    'CHIYO_NAS_DESKTOP_DIRECTORY',
  );
  test(
    'existing NAS: Windows local preferences, notices, modal routes, reconnect and App exit preserve the independent chat',
    () async {
      final observation = _Http();
      await HttpOverrides.runWithHttpOverrides(() async {
        final parent = WindowsPrivateFiles.directory(
          Directory(privateDirectory).absolute,
        );
        final root = WindowsPrivateFiles.directory(
          await parent.createTemp('w115-desktop-'),
        );
        final profile = (await PrivateConnectionProfileStore(
          profileDirectory,
        ).read())!;
        final device = await AgentConnectionProfile.read(
          File('$profileDirectory/agent-connection.json'),
        );
        final agent = AgentClient.remote(device);
        RemoteWorkspaceSource? source;
        OnlineDesktopRuntime? runtime;
        CodexEndIndex? endIndex;
        final chat =
            'windows-w115-${root.uri.pathSegments.where((p) => p.isNotEmpty).last}';
        var endConfirmed = false, resourceCloses = 0, resumes = 0;
        Future<OwnerClient> owner({String? serverId}) => OwnerClient.connect(
          address: Uri.parse(profile.address),
          token: profile.token,
          expectedServerId: serverId ?? profile.serverId,
          trust: SecurityContext(withTrustedRoots: false)
            ..setTrustedCertificatesBytes(utf8.encode(profile.certificate)),
        );
        Future<RemoteWorkspaceSource> connect() async => RemoteWorkspaceSource(
          await owner(),
          deviceFilesDirectory: '${root.path}/device',
        );
        Future<void> preferences(
          WorkspacePreferences Function(WorkspacePreferences) change,
        ) async {
          final before = await source!.settings.read();
          await source!.settings.change(
            WorkspaceSettingsChange(
              operationId: workspaceOperationId(),
              expectedVersion: before.version,
              desired: change(before),
            ),
          );
        }

        try {
          source = await connect();
          final beforeInformation = await source.client.information();
          final owned = beforeInformation.singleWhere(
            (i) => i.name == 'Windows 知予接入说明',
          );
          final field = owned.fields.firstWhere(
            (f) => f.kind != FieldKind.file,
          );
          await preferences(
            (p) => p.copyWith(
              theme: WorkspaceTheme.dark,
              notifications: true,
              background: true,
            ),
          );
          final native = _Native();
          runtime = OnlineDesktopRuntime(
            platform: native,
            beforeExit: () async {
              resourceCloses++;
              final current = source;
              if (current != null) {
                await runtime!.release(current);
                await current.dispose();
                source = null;
              }
            },
            onResume: () async {
              resumes++;
              await source!.cache.synchronize();
            },
          );
          await runtime.start();
          await runtime.bind(source);
          expect(native.ids.isEmpty, true);
          expect(native.permissionRequests, 0);
          expect(
            (await agent.openLifecycleSession('Windows #115 独立桌面验证'))['status'],
            'ok',
          );
          endIndex = CodexEndIndex(root);
          await endIndex.register(
            chat,
            device.address.port,
            agent.endCapability!,
            connection: device,
          );
          Future<String> request(String suffix) async {
            final result = await agent.execute({
              'command': 'request',
              'operationId': '$chat-$suffix',
              'purpose': 'Windows #115 桌面通知与退出验证，不读取正文',
              'fields': [
                {'itemId': owned.id, 'fieldId': field.id},
              ],
            });
            expect(result['status'], 'pending');
            return result['requestId'] as String;
          }

          final first = await request('first');
          await runtime.refresh();
          await runtime.refresh();
          expect(native.ids, [first]);
          await native.events!(DesktopEvent.closeWindow);
          expect(runtime.windowHidden && native.hidden, true);
          final routes = <String>[], pages = <WorkspacePage>[];
          runtime.onOpenRequest = routes.add;
          runtime.onNavigate = pages.add;
          native.openedRequestId = first;
          await native.events!(DesktopEvent.openApprovals);
          expect(routes, [first]);
          final second = await request('second');
          await runtime.refresh();
          expect(native.ids, [first, second]);
          final gate = Completer<void>();
          native.showGate = gate.future;
          native.openedRequestId = second;
          final delayed = native.events!(DesktopEvent.openApprovals);
          await runtime.setNavigationEnabled(false);
          await runtime.setNavigationEnabled(true);
          gate.complete();
          await delayed;
          native.showGate = null;
          expect(routes, [first]);
          await native.events!(DesktopEvent.openApprovals);
          expect(routes, [first, second]);
          observation.offline = true;
          await runtime.refresh();
          expect(runtime.notificationReadFailed, true);
          observation.offline = false;
          await native.events!(DesktopEvent.resumed);
          expect(resumes, 1);
          expect(runtime.notificationReadFailed, false);
          expect(native.ids, [first, second]);
          expect(native.permissionRequests, 0);
          await expectLater(
            owner(serverId: 'wrong-w115-server'),
            throwsA(
              isA<RemoteFailure>().having(
                (e) => e.code,
                'code',
                'server_changed',
              ),
            ),
          );
          await preferences((p) => p.copyWith(background: false));
          await runtime.refresh();
          await runtime.setNavigationEnabled(false);
          await native.events!(DesktopEvent.closeWindow);
          expect(native.exits, 0);
          await runtime.setNavigationEnabled(true);
          native.exitFails = true;
          await native.events!(DesktopEvent.closeWindow);
          expect(runtime.shutdownFailed && runtime.resourcesClosed, true);
          expect(resourceCloses, 1);
          expect(
            (await agent.execute({
              'command': 'status',
              'requestId': first,
            }))['status'],
            'pending',
          );
          native.exitFails = false;
          await runtime.quit();
          expect(runtime.closed, true);
          expect(resourceCloses, 1);
          expect(native.exits, 2);
          runtime.dispose();
          runtime = null;
          source = await connect();
          final saved = await source!.settings.read();
          expect(
            saved.theme == WorkspaceTheme.dark &&
                !saved.background &&
                saved.notifications,
            true,
          );
          final nextNative = _Native();
          runtime = OnlineDesktopRuntime(
            platform: nextNative,
            beforeExit: () async {},
            onResume: () async {},
          );
          await runtime.start();
          await runtime.bind(source);
          expect(
            nextNative.ids.isEmpty,
            true,
            reason: 'Reopen must not replay notices',
          );
          expect(
            (await agent.execute({
              'command': 'status',
              'requestId': second,
            }))['status'],
            'pending',
          );
          expect(
            (await source!.client.information()).length,
            beforeInformation.length,
          );
          expect(
            await endIndex.end(chat, timeout: const Duration(seconds: 20)),
            'ended',
          );
          endConfirmed = true;
          await File('${root.path}/result.json').writeAsString(
            jsonEncode({
              'status': 'passed',
              'nativeNotices': native.ids.length,
              'resumes': resumes,
              'resourceCloses': resourceCloses,
              'preferencesReopened': true,
              'independentChatSurvivedAppExit': true,
              'wrongServerRejected': true,
              'freshValidationChatEnded': true,
            }),
            flush: true,
          );
        } finally {
          observation.offline = false;
          if (!endConfirmed && endIndex != null) {
            await endIndex.end(chat, timeout: const Duration(seconds: 20));
          }
          runtime?.dispose();
          await source?.dispose();
          agent.close();
        }
      }, observation);
    },
    skip: profileDirectory.isEmpty || privateDirectory.isEmpty,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
