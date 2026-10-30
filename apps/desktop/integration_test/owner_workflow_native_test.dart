// Native test entry only; never used by the shipped application.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:info_cli/agent_client.dart';
import 'package:info_desktop/desktop_fonts.dart';
import 'package:info_desktop/desktop_runtime.dart';
import '../tool/check_owner_ui.dart';

class _HttpClient implements OwnerUiClient {
  _HttpClient(int port) : client = AgentClient(port);
  final AgentClient client;
  @override
  int? get processId => null;
  @override
  Future<Map<String, dynamic>> command(Map<String, Object?> value) async {
    final result = await client.execute(value);
    for (final key in ['token', 'sessionSecret', 'endCapability']) {
      expect(result.containsKey(key), isFalse);
    }
    return result;
  }

  @override
  Future<void> close() async {
    await client.drainCredentialExecutions();
    client.close();
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  const run = String.fromEnvironment('OWNER_NATIVE_WORKFLOW_RUN');
  if (!Platform.isMacOS ||
      !const bool.fromEnvironment('OWNER_NATIVE_SYNTHETIC') ||
      !RegExp(r'^[a-f0-9]{32}$').hasMatch(run)) {
    throw StateError('An isolated native workflow invocation is required');
  }
  runOwnerUiCheck(
    createNative: () async {
      final fonts = await loadDesktopFonts();
      final root = Directory(
        '${Directory.systemTemp.path}/owner-workflow-$run',
      );
      final marker = File('${root.path}/fixture-marker');
      final first = !await root.exists();
      if (first) {
        await root.create();
        await marker.writeAsString('disposable-owner-ui-v1');
      } else if (await marker.readAsString() != 'disposable-owner-ui-v1') {
        throw StateError('Refuse an unknown native fixture');
      }
      final phase = first ? 'live' : 'reopen';
      final images = <String, String>{};
      var passed = false;
      binding.reportData = {
        'phase': phase,
        'fixtureDirectory': root.path,
        'passed': false,
      };
      addTearDown(() async {
        if (phase == 'reopen' || !passed) {
          if (await root.exists()) await root.delete(recursive: true);
          binding.reportData?['fixtureRemoved'] = !await root.exists();
        }
      });
      return NativeOwnerUiEnvironment(
        root: root,
        phase: phase,
        platform: NativeDesktopPlatform(),
        createClient: (port) async => _HttpClient(port),
        scope:
            'native Cocoa/Flutter Debug shell, SQLCipher and in-process CLI AgentClient over real HTTP; synthetic key/widget input, not packaged Release or actual AI host acceptance',
        capture: (key, name) async {
          await binding.endOfFrame;
          final render =
              key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = await render.toImage(pixelRatio: 1);
          try {
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            images[name] = base64Encode(bytes!.buffer.asUint8List());
          } finally {
            image.dispose();
          }
        },
        report: (result) async {
          expect(
            fonts.keys,
            containsAll(['Zhiyu System', 'PingFang SC', 'Menlo']),
          );
          passed = true;
          binding.reportData = {
            ...result,
            'runtime': {
              'platform': Platform.operatingSystem,
              'debugMode': true,
            },
            'fixtureDirectory': root.path,
            'nativeFonts': fonts.keys.toList(),
            'imagesPngBase64': images,
          };
        },
      );
    },
  );
}
