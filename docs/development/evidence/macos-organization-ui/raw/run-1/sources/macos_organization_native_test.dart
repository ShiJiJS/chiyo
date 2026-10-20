import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_core/agent_server.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/main.dart' show InformationApp;
import 'support/native_semantics_lifetime.dart';

class _Keys implements DatabaseKeyStore {
  List<int>? value;
  @override
  Future<List<int>?> read() async => value;
  @override
  Future<void> create(List<int> key) async => value = List.of(key);
}

// Native Flutter and SQLCipher with controlled concurrent edits/ephemeral key.
// The parent runs the independent shipped CLI outside the application sandbox.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Mac native scoped organization approval apply conflict revoke and reopen',
    (tester) async {
      expect(Platform.isMacOS, isTrue);
      const marker = String.fromEnvironment('MAC_QA_OWNER');
      expect(marker, matches(RegExp(r'^[a-f0-9]{32}$')));
      final root = await Directory.systemTemp.createTemp(
        'aim-mac-organization-ui-',
      );
      await File('${root.path}/.qa-owner').writeAsString(marker);
      debugPrint('MAC_ORGANIZATION_ROOT=${root.path}');
      final semantics = NativeSemanticsLifetime(tester);
      final shadows = debugDisableShadows;
      debugDisableShadows = false;
      final keys = _Keys();
      var repository = await EncryptedInformationRepository.open(
        '${root.path}/library',
        keys,
      );
      var service = InformationService(repository: repository);
      var server = await AgentServer.start(service.agent, port: 0);
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
        await tester.enterText(target, value);
        await tester.pumpAndSettle();
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

      final folder = await service.owner.createDirectory('Fixture folder');
      final tag = await service.owner.createTag('Fixture tag');
      final first = await service.owner.createInformation(
        'Mac organize first',
        'Public first',
        [const FieldInput('First field', 'Public field', 'private-first')],
        directoryId: folder.id,
        tagIds: [tag.id],
      );
      final second = await service.owner.createInformation(
        'Mac organize second',
        'Public second',
        [const FieldInput('Second field', 'Public field', 'private-second')],
        directoryId: folder.id,
      );
      final excluded = await service.owner.createInformation(
        'Mac excluded',
        'Public excluded',
        [const FieldInput('Excluded field', '', 'private-excluded')],
      );
      InformationItem current(String id) =>
          service.owner.information.firstWhere((i) => i.id == id);
      OrganizationTask task(String id) =>
          service.owner.organizationTasks.firstWhere((t) => t.id == id);
      Future<void> selectRequest(String id) async {
        await tap(find.byKey(const ValueKey('nav-0')));
        await tap(find.byKey(ValueKey('request-$id')));
      }

      Future<void> approve(String id) async {
        await selectRequest(id);
        await tap(find.text('批准整理范围'));
        expect(
          service.owner.organizationState(task(id)),
          OrganizationTaskState.active,
        );
      }

      await mount();
      final requested = await exchange('request', {
        'firstId': first.id,
        'firstField': first.fields.single.id,
        'secondId': second.id,
        'secondField': second.fields.single.id,
        'excludedId': excluded.id,
        'excludedField': excluded.fields.single.id,
      });
      final initialId = requested['taskId'] as String;
      final contentId = requested['requestId'] as String;
      await selectRequest(initialId);
      expect(find.text('允许整理的资料'), findsOneWidget);
      expect(find.textContaining('无需再次确认'), findsOneWidget);
      for (final value in [
        'private-first',
        'private-second',
        'private-excluded',
      ]) {
        expect(find.text(value), findsNothing);
      }
      await tap(find.byKey(ValueKey('organize-item-${excluded.id}')));
      await tap(find.byKey(ValueKey('organization-lifetime-$initialId')));
      await tap(find.text('15 分钟').last);
      await capture('01-narrowed-request');
      await tap(find.text('批准整理范围'));
      expect(task(initialId).itemVersions.keys.toSet(), {first.id, second.id});
      expect(
        task(initialId).expiresAt.difference(task(initialId).approvedAt!),
        const Duration(minutes: 15),
      );
      await capture('02-approved');
      await exchange('approved');
      expect(current(first.id).version, 1);
      expect(current(second.id).version, 1);
      expect(service.owner.directories, hasLength(1));
      expect(service.owner.tags, hasLength(1));
      // Content approval is a separate controlled owner action, not organization.
      service.owner.approve(contentId, [
        FieldRef(first.id, first.fields.single.id),
      ]);
      await exchange('content-approved');
      expect(task(initialId).state, OrganizationTaskState.confirmed);
      expect(current(first.id).version, 2);
      expect(current(second.id).version, 2);
      expect(current(first.id).fields.single.value, 'private-first');
      expect(current(second.id).fields.single.value, 'private-second');
      expect(current(first.id).fields.single.id, first.fields.single.id);
      expect(current(second.id).fields.single.id, second.fields.single.id);
      expect(current(excluded.id).version, 1);
      expect(current(excluded.id).directoryId, isNull);
      final organized = service.owner.directories.singleWhere(
        (d) => d.name == 'Mac organized',
      );
      final organizedTag = service.owner.tags.singleWhere(
        (t) => t.name == 'Mac organized tag',
      );
      for (final id in [first.id, second.id]) {
        expect(current(id).directoryId, organized.id);
        expect(current(id).tagIds, [organizedTag.id]);
      }
      expect(service.owner.directories, hasLength(2));
      expect(service.owner.tags, hasLength(2));
      await tap(find.byKey(const ValueKey('nav-2')));
      await tap(find.byKey(const ValueKey('proposal-filter-handled')));
      await tap(find.byKey(ValueKey('proposal-entry-$initialId')));
      expect(find.text('已在授权范围内完成整理'), findsOneWidget);
      expect(find.text('确认整批调整'), findsNothing);
      expect(find.text('private-first'), findsNothing);
      await capture('03-completed-result');
      final conflicting = await exchange('completed');
      final conflictId = conflicting['taskId'] as String;
      await approve(conflictId);
      // A concurrent owner correction invalidates the whole approved snapshot.
      await service.owner.correctValue(
        FieldRef(second.id, second.fields.single.id),
        'owner-corrected-second',
      );
      final revoking = await exchange('conflict');
      expect(task(conflictId).state, OrganizationTaskState.conflicted);
      expect(current(first.id).version, 2);
      expect(current(first.id).directoryId, organized.id);
      expect(current(second.id).version, 3);
      expect(current(second.id).directoryId, organized.id);
      expect(current(second.id).fields.single.value, 'owner-corrected-second');
      expect(service.owner.directories, hasLength(2));
      expect(service.owner.tags, hasLength(2));
      await selectRequest(conflictId);
      expect(find.textContaining('根据当前资料重新申请'), findsOneWidget);
      await capture('04-conflicted');
      final revokeId = revoking['taskId'] as String;
      await approve(revokeId);
      await tap(find.text('撤销整理'));
      expect(task(revokeId).state, OrganizationTaskState.cancelled);
      await capture('05-revoked');
      final rejecting = await exchange('revoked');
      final rejectId = rejecting['taskId'] as String;
      await selectRequest(rejectId);
      await tap(find.text('拒绝请求'));
      expect(task(rejectId).state, OrganizationTaskState.rejected);
      await capture('06-rejected');
      final empty = await exchange('rejected');
      final emptyId = empty['taskId'] as String;
      await approve(emptyId);
      await exchange('empty-approved');
      expect(task(emptyId).state, OrganizationTaskState.confirmed);
      expect(task(emptyId).changes, isEmpty);
      expect(current(first.id).version, 2);
      await tap(find.byKey(const ValueKey('nav-2')));
      await tap(find.byKey(const ValueKey('proposal-filter-handled')));
      await tap(find.byKey(ValueKey('proposal-entry-$emptyId')));
      expect(find.textContaining('没有分类或标签变化'), findsOneWidget);
      await capture('07-no-change-result');
      final pendingReopen = await exchange('empty-complete');
      final reopenId = pendingReopen['taskId'] as String;
      await approve(reopenId);
      await exchange('active-before-reopen');
      await tester.pumpWidget(const SizedBox());
      await server.close();
      await service.close();
      await repository.close();
      repository = await EncryptedInformationRepository.open(
        '${root.path}/library',
        keys,
      );
      service = InformationService(repository: repository);
      server = await AgentServer.start(service.agent, port: 0);
      expect(service.owner.organizationTasks, hasLength(6));
      expect(
        service.owner.organizationState(task(reopenId)),
        OrganizationTaskState.cancelled,
      );
      expect(task(initialId).state, OrganizationTaskState.confirmed);
      expect(task(conflictId).state, OrganizationTaskState.conflicted);
      expect(task(revokeId).state, OrganizationTaskState.cancelled);
      expect(task(rejectId).state, OrganizationTaskState.rejected);
      expect(task(emptyId).state, OrganizationTaskState.confirmed);
      expect(current(first.id).fields.single.id, first.fields.single.id);
      expect(current(first.id).fields.single.value, 'private-first');
      expect(current(first.id).version, 2);
      expect(current(first.id).directoryId, organized.id);
      expect(current(second.id).fields.single.id, second.fields.single.id);
      expect(current(second.id).fields.single.value, 'owner-corrected-second');
      expect(current(second.id).version, 3);
      expect(current(second.id).directoryId, organized.id);
      expect(current(excluded.id).fields.single.value, 'private-excluded');
      expect(current(excluded.id).version, 1);
      expect(repository.grantHistory.single.active, isFalse);
      await mount();
      await selectRequest(reopenId);
      expect(find.textContaining('已取消'), findsWidgets);
      expect(find.text('撤销整理'), findsNothing);
      await capture('08-reopened-cancelled');
      await tap(find.byKey(const ValueKey('nav-2')));
      await tap(find.byKey(const ValueKey('proposal-filter-handled')));
      await tap(find.byKey(ValueKey('proposal-entry-$initialId')));
      expect(find.text('已在授权范围内完成整理'), findsOneWidget);
      await capture('09-reopened-result');
      await exchange('repository-reopened');
      await File('${root.path}/result.json').writeAsString(
        jsonEncode({
          'complete': true,
          'phases': step + 1,
          'taskIds': [
            initialId,
            conflictId,
            revokeId,
            rejectId,
            emptyId,
            reopenId,
          ],
          'captures': captures,
          'scope':
              'Native tester-driven organization approval/narrowing/revoke/reject and read-only results; real SQLCipher and parent AOT CLI; fixture items, separate content approval and concurrent owner correction; same-process service/repository reopen, no physical input, Keychain, real Codex or sleep/expiry.',
        }),
        flush: true,
      );
      await exchange('complete');
    },
    semanticsEnabled: false,
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
