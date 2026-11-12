@TestOn('!windows')
library;

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_cli/agent_client.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/desktop_runtime.dart';
import 'package:info_desktop/storage_desktop_launcher.dart';
import 'package:info_remote/automatic_connection.dart';
import 'package:info_remote/connection_profile.dart';
import 'package:info_remote/private_connection_files.dart';
import '../../server/test/support/device_credential_fixture.dart';
import 'support/desktop_platform_fixture.dart';
import 'support/focused_fill_fixture.dart';
import 'support/online_ui_harness.dart';

class _Http extends HttpOverrides {}

class _Driver extends WidgetFillDriver implements FocusedFillDiscoveryDriver {
  final application = FocusedFillApplication.fromJson({
    'executable': '/synthetic-device/Browser',
    'sha256': 'a' * 64,
  });
  @override
  Future<FocusedFillTarget> inspectTarget() async =>
      FocusedFillTarget.ready(application);
}

void main() {
  final previous = HttpOverrides.current;
  setUpAll(() => HttpOverrides.global = _Http());
  tearDownAll(() => HttpOverrides.global = previous);
  testWidgets(
    'desktop launcher owns NAS fill host and closes it before terminating',
    (t) async {
      final ui = OnlineUiHarness(t);
      final f = await ui.resolve(DeviceCredentialFixture.create);
      final root = Directory('${f.root.path}/desktop-private');
      final store = PrivateConnectionProfileStore(root.path);
      await ui.resolve(
        () => AutomaticConnectionStore(root.path).publish(
          ConnectionProfile(
            address: f.owner.address.toString(),
            token: f.token,
            serverId: f.owner.serverId,
            certificate: f.certificate,
          ).toJson(),
          f.profiles.first,
        ),
      );
      final driver = _Driver(), platform = NativeDesktopFixture();
      final chat = await ui.resolve(
        () => f.agents.first.call('/session/lifecycle', {
          'chatLabel': 'Synthetic desktop host',
        }),
      );
      final client = AgentClient.remote(
        f.profiles.first,
        sessionSecret: chat['sessionSecret'] as String,
        focusedFillHostDirectory: root,
      );
      try {
        await t.pumpWidget(
          StorageDesktopLauncher(
            profiles: store,
            platform: platform,
            focusedFillDriver: driver,
            localBuilder: (_) => const SizedBox(),
          ),
        );
        await ui.resolve(() async {
          for (var i = 0; i < 100; i++) {
            final support = await client.execute({'command': 'capabilities'});
            if ((support['capabilities'] as List? ?? []).contains(
              'credential-focused-fill.v1',
            )) {
              return;
            }
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
          fail('App host did not become ready');
        });
        final c = await ui.resolve(
          () => f.runtime.run(() async {
            final raw = await f.runtime.service.owner.createStringCredential(
              name: 'Synthetic password',
              publicPurpose: '',
              secret: 'SYNTHETIC_DESKTOP_ONLY',
            );
            return f.runtime.service.owner.updateCredentialMetadata(
              raw.id,
              raw.revision,
              name: raw.name,
              publicPurpose: '',
              privateNote: '',
              suggestedBinding: 'password',
              discoverable: true,
            );
          }),
        );
        final request = await ui.resolve(
          () => client.execute({
            'protocolVersion': 2,
            'command': 'request-use',
            'purpose': 'Synthetic desktop login',
            'credentials': [
              {'alias': 'password', 'credentialId': c.id, 'version': 1},
            ],
            'fill': FocusedFillPlan(driver.application, '').toJson(),
          }),
        );
        expect(request['status'], 'pending');
        final id = request['requestId'] as String;
        await ui.resolve(
          () => f.runtime.run(
            () => f.runtime.service.owner.decideCredentialUse(
              id,
              approveCredential: true,
            ),
          ),
        );
        final operation = {
          'protocolVersion': 2,
          'command': 'fill-use',
          'requestId': id,
          'operationId': 'desktop',
        };
        expect(
          (await ui.resolve(
            () => client.execute(operation),
          ))['operationClaimed'],
          true,
        );
        await ui.resolve(() async {
          Map<String, dynamic>? last;
          for (var i = 0; i < 100; i++) {
            last = await client.execute({
              ...operation,
              'command': 'fill-status',
            });
            if (last['fillState'] == 'sent') return;
            if (last['fillState'] != 'checking') {
              fail('Desktop fill failed: $last');
            }
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
          fail('Desktop fill did not settle: $last');
        });
        expect(driver.sends, greaterThan(0));
        await ui.until(() => platform.events != null);
        await ui.resolve(() => platform.events!(DesktopEvent.quit));
        expect(platform.terminated, true);
        expect(
          (await ui.resolve(
            () => PrivateConnectionFiles.read(
              File('${root.path}/focused-fill-host/endpoint.json'),
            ),
          ))!['phase'],
          'closed',
        );
        expect(
          (await ui.resolve(
            () => client.execute({'command': 'capabilities'}),
          ))['capabilities'],
          isNot(contains('credential-focused-fill.v1')),
        );
      } finally {
        client.close();
        await t.pumpWidget(const SizedBox());
        await ui.resolve(f.dispose);
      }
    },
  );
}
