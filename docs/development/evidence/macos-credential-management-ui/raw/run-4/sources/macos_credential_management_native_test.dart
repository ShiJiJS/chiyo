import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_core/agent_server.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/main.dart' show InformationApp;
import 'package:info_desktop/credential_management.dart';
import 'support/native_semantics_lifetime.dart';

class _Keys implements DatabaseKeyStore {
  List<int>? value;
  @override
  Future<List<int>?> read() async => value;
  @override
  Future<void> create(List<int> key) async => value = List.of(key);
}

// Native Flutter and SQLCipher with controlled owner approvals/ephemeral key.
// The parent runs the independent shipped CLI outside the application sandbox.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Mac native credential management and discovery lifecycle',
    (tester) async {
      expect(Platform.isMacOS, isTrue);
      const marker = String.fromEnvironment('MAC_QA_OWNER');
      expect(marker, matches(RegExp(r'^[a-f0-9]{32}$')));
      final root = await Directory.systemTemp.createTemp(
        'aim-mac-credential-management-ui-',
      );
      await File('${root.path}/.qa-owner').writeAsString(marker);
      debugPrint('MAC_CREDENTIAL_MANAGEMENT_ROOT=${root.path}');
      final semantics = NativeSemanticsLifetime(tester);
      final shadows = debugDisableShadows;
      debugDisableShadows = false;
      final keys = _Keys();
      var repository = await EncryptedInformationRepository.open(
        '${root.path}/library',
        keys,
      );
      var service = InformationService(repository: repository);
      var server = await AgentServer.start(
        service.agent,
        port: 0,
        enableReusableCredentialUse: true,
      );
      final boundary = GlobalKey();
      final captures = <String>[];
      var step = 0;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await server.close();
        await service.close();
        await repository.close();
        semantics.finishAfterUnmount();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        debugDisableShadows = shadows;
      });
      Future<Map<String, dynamic>> exchange(
        String phase, [
        Map<String, Object?> extra = const {},
      ]) async {
        step++;
        await File('${root.path}/phase-$step.json').writeAsString(
          jsonEncode({'phase': phase, 'port': server.port, ...extra}),
          flush: true,
        );
        final reply = File('${root.path}/reply-$step.json');
        final deadline = DateTime.now().add(const Duration(seconds: 60));
        while (!await reply.exists()) {
          expect(
            DateTime.now().isBefore(deadline),
            isTrue,
            reason: 'Independent CLI deadline',
          );
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        final result =
            jsonDecode(await reply.readAsString()) as Map<String, dynamic>;
        expect(result['ok'], isTrue);
        return result;
      }

      Future<void> mount() async {
        tester.view.physicalSize = const Size(1440, 1000);
        tester.view.devicePixelRatio = 1;
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: InformationApp(service: service, port: server.port),
          ),
        );
        await tester.pumpAndSettle();
      }

      Future<void> tap(Finder target) async {
        await tester.ensureVisible(target);
        await tester.pumpAndSettle();
        expect(target.hitTestable(), findsOneWidget);
        await tester.tap(target);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }

      Future<void> input(String key, String value) async {
        final target = find.byKey(ValueKey(key));
        await tester.ensureVisible(target);
        await tester.pumpAndSettle();
        await tester.tap(target);
        await tester.pumpAndSettle();
        if (value.isEmpty) {
          await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
        } else {
          await tester.enterText(target, value);
        }
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(target).controller!.text,
          value,
          reason: 'Input must reach the focused field',
        );
      }

      Future<void> capture(String name) async {
        expect(tester.takeException(), isNull);
        final image =
            await (boundary.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '${root.path}/$name.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
        captures.add('$name.png');
      }

      final item = await service.owner.createInformation(
        'Mac linked information',
        'Public information',
        [const FieldInput('Host', 'Public host', 'private-linked-value')],
      );
      await mount();
      Future<void> credentials() async {
        await tap(find.byKey(const ValueKey('nav-1')));
        final switcher = find.byKey(const ValueKey('library-credentials-mode'));
        if (switcher.evaluate().isNotEmpty) await tap(switcher);
      }

      Future<void> labelled(String label, String value) async {
        final column = find
            .ancestor(of: find.text(label), matching: find.byType(Column))
            .first;
        final field = find.descendant(
          of: column,
          matching: find.byType(TextField),
        );
        await tester.ensureVisible(field);
        await tester.enterText(field, value);
        await tester.pumpAndSettle();
      }

      Future<void> until(bool Function() done, String reason) async {
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (!done() && DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(done(), isTrue, reason: reason);
        expect(tester.takeException(), isNull);
      }

      Future<void> saveManagement({bool expectSuccess = true}) async {
        await tap(find.byKey(const ValueKey('save-credential-management')));
        if (expectSuccess)
          await until(
            () => find.byType(CredentialManagement).evaluate().isEmpty,
            'Credential save must complete and close',
          );
      }

      await credentials();
      await tap(find.byKey(const ValueKey('new-credential')));
      await input('credential-name', 'Mac managed token');
      await input('credential-secret', 'synthetic-native-secret-one');
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('credential-secret')))
            .obscureText,
        isTrue,
      );
      await input('credential-binding', 'GH_TOKEN');
      await tap(find.byKey(const ValueKey('save-credential')));
      final id = service.owner.credentials.single.id;
      ManagedCredential current() => service.owner.credential(id);
      void unchangedInfo() {
        final now = service.owner.information.single;
        expect(now.id, item.id);
        expect(now.version, 1);
        expect(now.fields.single.id, item.fields.single.id);
        expect(now.fields.single.value, 'private-linked-value');
      }

      void material(int version, String text) {
        final value = repository.credentialMaterials.singleWhere(
          (m) => m.credentialId == id && m.version == version,
        );
        expect(value.bytes, utf8.encode(text));
      }

      Future<void> checkpoint(String phase, {bool visible = true}) async {
        for (final secret in [
          'synthetic-native-secret-one',
          'synthetic-native-secret-two',
        ]) {
          expect(find.text(secret), findsNothing);
        }
        unchangedInfo();
        expect(service.owner.credentialUseRequests, isEmpty);
        expect(service.owner.credentialExecutions, isEmpty);
        await capture(phase);
        await exchange(phase, {
          'credentialId': id,
          'itemId': item.id,
          'fieldId': item.fields.single.id,
          'version': current().version,
          'availability': current().availability(DateTime.now()).name,
          'discoverable': current().discoverable,
          'catalogVisible': visible,
        });
      }

      expect(current().discoverable, isFalse);
      material(1, 'synthetic-native-secret-one');
      await checkpoint('01-created-hidden', visible: false);
      await tap(find.text('信息').last);
      await tap(find.byKey(ValueKey('information-${item.id}')));
      await tap(find.text('管理关联'));
      await tap(find.byKey(ValueKey('credential-link-$id')));
      await tap(find.byKey(const ValueKey('credential-save-links')));
      expect(current().linkedItemIds, [item.id]);
      expect(current().discoverable, isFalse);
      await checkpoint('02-linked-hidden', visible: false);
      await credentials();
      await tap(find.byKey(const ValueKey('credential-metadata')));
      await tap(find.text('编辑名称、用途与私有备注'));
      await labelled('名称', 'Mac reviewed token');
      await labelled('公开用途', 'Synthetic public token purpose');
      await labelled('私有备注', 'private-native-credential-note');
      await input('credential-expiry', 'not-a-date');
      await saveManagement(expectSuccess: false);
      expect(find.textContaining('凭据变更未保存'), findsOneWidget);
      expect(current().name, 'Mac managed token');
      expect(current().discoverable, isFalse);
      await input('credential-expiry', '');
      await tap(find.byKey(const ValueKey('credential-discoverable')));
      final metadata = tester.widget<CredentialManagement>(
        find.byType(CredentialManagement),
      );
      expect(
        metadata.credential.revision,
        current().revision,
        reason: 'Metadata editor must use current linked credential revision',
      );
      await capture('02-metadata-before-save');
      await saveManagement();
      expect(current().name, 'Mac reviewed token');
      expect(current().privateNote, 'private-native-credential-note');
      expect(current().discoverable, isTrue);
      await checkpoint('03-public');
      await tap(find.text('更换版本'));
      await input('credential-new-secret', 'synthetic-native-secret-two');
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('credential-new-secret')),
            )
            .obscureText,
        isTrue,
      );
      await saveManagement();
      expect(current().version, 2);
      material(1, 'synthetic-native-secret-one');
      material(2, 'synthetic-native-secret-two');
      expect(
        service.owner.credentialVersions(id).where((v) => v.retiredAt != null),
        hasLength(1),
      );
      await checkpoint('04-rotated');
      await tap(find.text('停用'));
      await saveManagement();
      expect(current().enabled, isFalse);
      await checkpoint('05-disabled');
      await tap(find.text('启用'));
      await saveManagement();
      expect(current().enabled, isTrue);
      await checkpoint('06-enabled');
      await tap(find.text('版本与恢复'));
      await tap(find.text('恢复为新版本'));
      await tap(find.text('恢复为新版本').last);
      await until(
        () => find.text('凭据版本与恢复').evaluate().isEmpty,
        'Version restore must close after commit',
      );
      expect(current().version, 3);
      expect(current().enabled, isFalse);
      material(3, 'synthetic-native-secret-one');
      await checkpoint('07-version-restored');
      await tap(find.text('启用'));
      await saveManagement();
      await checkpoint('08-version-enabled');
      await tap(find.text('删除'));
      await tap(find.text('取消').last);
      expect(service.owner.credentials, hasLength(1));
      expect(current().version, 3);
      await tap(find.text('删除'));
      await saveManagement();
      expect(service.owner.credentials, isEmpty);
      expect(service.owner.recycledCredentials, hasLength(1));
      await checkpoint('09-deleted', visible: false);
      await tap(find.text('凭据回收站'));
      await tap(find.text('恢复'));
      await saveManagement();
      expect(current().version, 4);
      expect(current().enabled, isFalse);
      material(4, 'synthetic-native-secret-one');
      expect(service.owner.recycledCredentials, isEmpty);
      await tap(find.text('×').last);
      expect(current().linkedItemIds, [item.id]);
      await checkpoint('10-recycle-restored');
      await tap(find.text('启用'));
      await saveManagement();
      await checkpoint('11-recycle-enabled');
      await tap(find.byKey(const ValueKey('credential-metadata')));
      await input('credential-expiry', '2020-01-01T00:00:00Z');
      await saveManagement();
      expect(
        current().availability(DateTime.now()),
        CredentialAvailability.expired,
      );
      await checkpoint('12-expired');
      await tap(find.byKey(const ValueKey('credential-metadata')));
      await input('credential-expiry', '');
      await tap(find.byKey(const ValueKey('credential-discoverable')));
      await saveManagement();
      expect(current().expiresAt, isNull);
      expect(current().enabled, isTrue);
      expect(current().discoverable, isFalse);
      await checkpoint('13-hidden', visible: false);
      await tester.pumpWidget(const SizedBox());
      await server.close();
      await service.close();
      await repository.close();
      repository = await EncryptedInformationRepository.open(
        '${root.path}/library',
        keys,
      );
      service = InformationService(repository: repository);
      server = await AgentServer.start(
        service.agent,
        port: 0,
        enableReusableCredentialUse: true,
      );
      expect(current().name, 'Mac reviewed token');
      expect(current().privateNote, 'private-native-credential-note');
      expect(current().linkedItemIds, [item.id]);
      expect(current().version, 4);
      expect(current().enabled, isTrue);
      expect(current().discoverable, isFalse);
      material(1, 'synthetic-native-secret-one');
      material(2, 'synthetic-native-secret-two');
      material(3, 'synthetic-native-secret-one');
      material(4, 'synthetic-native-secret-one');
      await mount();
      await credentials();
      await checkpoint('14-reopened', visible: false);
      await File('${root.path}/result.json').writeAsString(
        jsonEncode({
          'complete': true,
          'phases': step + 1,
          'captures': captures,
          'finalCredentialVersion': 4,
          'scope':
              'Native tester drives string credential creation, metadata, discovery, links, rotation, disable/enable, version restore, recycle restore and expiry; real SQLCipher plus independent CLI catalog/negative eligibility; fixture ordinary information, ephemeral key; no actual credential use grants/worker execution, physical input, file credential picker or Keychain.',
        }),
        flush: true,
      );
      await exchange('complete');
    },
    semanticsEnabled: false,
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
