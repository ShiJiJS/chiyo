import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/online_desktop_launcher.dart';
import 'package:info_desktop/desktop_controls.dart';
import 'package:info_desktop/workspace/library_widgets.dart';
import 'package:info_desktop/workspace/library_page.dart';
import 'package:info_desktop/workspace/remote_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_app.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_remote/connection_profile.dart';
import 'support/desktop_platform_fixture.dart';
import 'support/nas_ui_harness.dart';

class _Http extends HttpOverrides {
  bool loseNextSave = false;
  int saves = 0;
  String? lostOperation, reconciledOperation;
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _ObservedClient(super.createHttpClient(context), this);
}

class _ObservedClient implements HttpClient {
  _ObservedClient(this.inner, this.observation);
  final HttpClient inner;
  final _Http observation;
  @override
  Duration? get connectionTimeout => inner.connectionTimeout;
  @override
  set connectionTimeout(Duration? value) => inner.connectionTimeout = value;
  @override
  void close({bool force = false}) => inner.close(force: force);
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    final save = method == 'POST' && url.path.startsWith('/v1/owner/saves/');
    if (save) observation.saves++;
    if (method == 'GET' && url.path.startsWith('/v1/owner/operations/')) {
      observation.reconciledOperation = url.pathSegments.last;
    }
    return _ObservedRequest(
      await inner.openUrl(method, url),
      observation,
      save ? url.pathSegments.last : null,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Unexpected HTTP client operation');
}

class _ObservedRequest implements HttpClientRequest {
  _ObservedRequest(this.inner, this.observation, this.operation);
  final HttpClientRequest inner;
  final _Http observation;
  final String? operation;
  @override
  HttpHeaders get headers => inner.headers;
  @override
  bool get followRedirects => inner.followRedirects;
  @override
  set followRedirects(bool value) => inner.followRedirects = value;
  @override
  void write(Object? object) => inner.write(object);
  @override
  void abort([Object? exception, StackTrace? stackTrace]) =>
      inner.abort(exception, stackTrace);
  @override
  Future<HttpClientResponse> close() async {
    final response = await inner.close();
    if (operation != null &&
        observation.loseNextSave &&
        response.statusCode == 200) {
      observation.loseNextSave = false;
      observation.lostOperation = operation;
      // The real NAS has acknowledged its durable write. Withhold that reply
      // from the UI to exercise its original-operation reconciliation path.
      await response.drain<void>();
      throw const SocketException(
        'Synthetic lost save reply after acknowledgement',
      );
    }
    return response;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Unexpected HTTP request operation');
}

/// Opt-in against the user's existing NAS. Only the named Windows development
/// documentation item is written; existing records and credentials are kept.
/// No Token or information body is printed in ordinary test output.
void main() {
  const profileDirectory = String.fromEnvironment(
    'CHIYO_NAS_PROFILE_DIRECTORY',
  );
  const name = 'Windows 知予接入说明';
  const description = 'Windows 开发版连接现有知予 NAS 的使用说明。';
  const body =
      '# Windows 接入知予\n\n'
      '本机项目：C:\\Project\\agent_ask\\agent_info。\n\n'
      '连接现有飞牛 NAS 上的知予服务，使用私人 CA 和固定服务器身份核对。'
      '管理 Token 由当前用户 DPAPI 保护，不记录在这份说明中。\n\n'
      'Windows AI 使用单独登记的设备身份，资料使用仍经过申请和审批。'
      '正式安装、全局接入和系统认证留到完整交付时集中处理。';

  testWidgets(
    'existing NAS: normal launcher saves Chinese documentation and reopens it',
    (t) async {
      final previousHttp = HttpOverrides.current;
      final observation = _Http();
      HttpOverrides.global = observation;
      final ui = NasUiHarness(t);
      final sources = <RemoteWorkspaceSource>[];
      t.view.physicalSize = const Size(1440, 1000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final profiles = PrivateConnectionProfileStore(profileDirectory);
      Future<LibraryPage> open() async {
        await t.pumpWidget(
          OnlineDesktopLauncher(
            profiles: profiles,
            desktopPlatform: NativeDesktopFixture(),
          ),
        );
        await ui.until(
          () =>
              find.byType(WorkspaceApp).evaluate().isNotEmpty &&
              find.byType(LibraryPage).evaluate().isNotEmpty,
        );
        final source =
            t.widget<WorkspaceApp>(find.byType(WorkspaceApp)).source
                as RemoteWorkspaceSource;
        sources.add(source);
        final page = t.widget<LibraryPage>(find.byType(LibraryPage));
        await ui.until(() => page.controller.loadState == WorkspaceLoad.ready);
        return page;
      }

      try {
        var page = await open();
        await ui.resolve(
          () => page.controller.apply(
            page.controller.query.copyWith(keyword: name),
          ),
        );
        final existing = page.controller.results!.items
            .where((item) => item.name == name)
            .toList();
        expect(
          existing.length,
          lessThanOrEqualTo(1),
          reason: 'Do not create another ambiguous documentation record',
        );
        if (existing.isEmpty) {
          ui.phase = 'create documentation';
          await ui.tap('library-create');
          await ui.tap('library-new-type-document');
          await ui.until(
            () => ui.key('library-edit-name').evaluate().isNotEmpty,
          );
          await t.enterText(ui.key('library-edit-name'), name);
          await t.enterText(ui.key('library-edit-description'), description);
          await t.enterText(ui.key('library-edit-body'), body);
          await ui.tap('library-edit-save');
          await ui.until(
            () =>
                ui.key('library-edit-name').evaluate().isEmpty &&
                page.controller.detail?.record.name == name,
          );
        } else {
          await ui.resolve(
            () => page.controller.openRelated(existing.single.ref),
          );
        }
        final original = page.controller.detail!;
        expect(original.record.name, name);
        expect(original.values['body'], body);
        final catalog = page.controller.catalog!;
        final targetDirectory = catalog.directories.singleWhere(
          (d) => d.name == '维护说明',
        );
        final targetTag = catalog.tags.singleWhere((tag) => tag.name == 'NAS');
        final targets = await ui.resolve(
          () => sources.last.queryRecords(
            const WorkspaceQuery(keyword: '飞牛 NAS', typeId: 'server'),
          ),
        );
        final nas = targets.items
            .singleWhere((item) => item.name == '飞牛 NAS')
            .ref;
        final candidates = await ui.resolve(
          () => sources.last.queryRelationCandidates(
            WorkspaceRelationQuery(
              typeId: original.record.type.id,
              key: 'related',
              source: original.record.ref,
              keyword: '飞牛 NAS',
            ),
          ),
        );
        expect(
          candidates.items.any((item) => item.ref == nas),
          isTrue,
          reason: 'Existing NAS must remain an eligible relation target',
        );
        ui.phase = 'update description';
        final updatedDescription =
            '$description 保存与重开核对：基于版本 ${original.version}。';
        final editButton = find.text('编辑信息').first;
        await t.ensureVisible(editButton);
        await t.tap(editButton);
        await ui.until(
          () => ui.key('library-edit-description').evaluate().isNotEmpty,
        );
        await t.enterText(
          ui.key('library-edit-description'),
          updatedDescription,
        );
        ui.phase = 'choose existing directory and tag';
        if (original.record.directoryId != targetDirectory.id) {
          final directoryChoice = find.descendant(
            of: find.byType(LibraryDirectorySelect),
            matching: find.byType(DesktopSelect<String?>),
          );
          final directoryCaption =
              (t
                          .widget<DesktopSelect<String?>>(directoryChoice)
                          .items
                          .singleWhere(
                            (item) => item.value == targetDirectory.id,
                          )
                          .child
                      as Text)
                  .data!;
          await t.ensureVisible(directoryChoice);
          await t.tap(directoryChoice);
          await t.pumpAndSettle();
          final directoryOption = find.text(directoryCaption).last;
          await t.ensureVisible(directoryOption);
          await t.tap(directoryOption);
          await t.pumpAndSettle();
        }
        final editor = find
            .ancestor(
              of: ui.key('library-edit-name'),
              matching: find.byType(DesktopDialog),
            )
            .first;
        final tag = find.descendant(
          of: editor,
          matching: find.widgetWithText(LibraryTag, 'NAS'),
        );
        if (!t.widget<LibraryTag>(tag).selected) {
          await t.ensureVisible(tag);
          await t.tap(tag);
          await t.pump();
        }
        if (!(original.relations['related'] ?? []).contains(nas)) {
          ui.phase = 'choose existing NAS relation';
          await ui.tap('library-relation-choose-related');
          await ui.until(
            () =>
                ui.key('library-relation-search-related').evaluate().isNotEmpty,
          );
          // Searching starts real HTTPS I/O; keep its deadlines outside the
          // Flutter fake clock just like the real NAS action buttons.
          await t.runAsync(
            () => t.enterText(
              ui.key('library-relation-search-related'),
              '飞牛 NAS',
            ),
          );
          final wanted = ui.key('library-relation-option-related-${nas.key}');
          for (var candidatePage = 0; candidatePage < 5; candidatePage++) {
            await ui.until(
              () =>
                  find.text('正在查找关联资料…').evaluate().isEmpty &&
                  find.byType(ListView).evaluate().isNotEmpty,
            );
            final popupScroll = find.descendant(
              of: find.byType(ListView).last,
              matching: find.byType(Scrollable),
            );
            for (
              var scroll = 0;
              scroll < 25 && wanted.evaluate().isEmpty;
              scroll++
            ) {
              final position = t.state<ScrollableState>(popupScroll).position;
              if (position.pixels >= position.maxScrollExtent - 1) break;
              await t.drag(popupScroll, const Offset(0, -220));
              await t.pump(const Duration(milliseconds: 100));
            }
            if (wanted.evaluate().isNotEmpty) break;
            final next = find.widgetWithText(DesktopButton, '下一页');
            expect(
              t.widget<DesktopButton>(next).onPressed,
              isNotNull,
              reason:
                  'Expected relation target must be reachable through candidate pages',
            );
            await t.runAsync(() => t.tap(next));
            await t.pump();
          }
          expect(wanted, findsOneWidget);
          await ui.tap('library-relation-option-related-${nas.key}');
          await ui.tap('library-relation-done-related');
        }
        await ui.until(
          () =>
              ModalRoute.of(
                t.element(ui.key('library-edit-name')),
              )?.isCurrent ==
              true,
        );
        ui.phase = 'save and withhold acknowledged reply';
        final beforeSaves = observation.saves;
        observation.loseNextSave = true;
        await ui.tap('library-edit-save');
        await ui.until(
          () => ui.key('library-edit-reconcile').evaluate().isNotEmpty,
        );
        expect(observation.lostOperation, isNotNull);
        expect(observation.saves, beforeSaves + 1);
        ui.phase = 'reconcile original receipt and refresh detail';
        ui.diagnostic = () =>
            'editor=${ui.key('library-edit-name').evaluate().length}, '
            'reconcile=${ui.key('library-edit-reconcile').evaluate().length}, '
            'status=${ui.key('library-edit-status').evaluate().map((e) => (e.widget as Text).data).join()}, '
            'load=${page.controller.loadState}, '
            'detailAdvanced=${(page.controller.detail?.version ?? 0) > original.version}, '
            'detailFailure=${page.controller.detailFailure?.code}, '
            'queryFailure=${page.controller.failure?.code}, '
            'receiptRequested=${observation.reconciledOperation == observation.lostOperation}';
        await ui.tap('library-edit-reconcile');
        await ui.until(
          () =>
              (ui.key('library-edit-name').evaluate().isEmpty &&
                  (page.controller.detail?.version ?? 0) > original.version) ||
              find.text('仍无法确认结果，请稍后核对。').evaluate().isNotEmpty,
        );
        if (ui.key('library-edit-name').evaluate().isNotEmpty) {
          try {
            final receipt = await ui.resolve(
              () => sources.last.recordOperationReceipt(
                observation.lostOperation!,
              ),
            );
            fail(
              'Receipt reconciliation failed: receiptPresent=${receipt != null}, '
              'intentMatches=${receipt?.intent.matches(WorkspaceOperationIntent(kind: WorkspaceOperationKind.edit, ref: original.record.ref, typeId: original.record.type.id, expectedVersion: original.version))}, versionAdvanced=${(receipt?.result.version ?? 0) > original.version}',
            );
          } on WorkspaceFailure catch (error) {
            fail('Receipt read failed: ${error.code}');
          }
        }
        final saved = page.controller.detail!;
        expect(observation.saves, beforeSaves + 1);
        expect(observation.reconciledOperation, observation.lostOperation);
        expect(saved.values['body'], body);
        expect(saved.record.directoryId, targetDirectory.id);
        expect(saved.record.tags.any((tag) => tag.id == targetTag.id), isTrue);
        expect(saved.relations['related'], contains(nas));
        await t.pumpWidget(const SizedBox());
        await ui.resolve(sources.last.dispose);
        ui.phase = 'reopen original profile';
        page = await open();
        await ui.resolve(() => page.controller.openRelated(saved.record.ref));
        expect(page.controller.detail!.version, saved.version);
        expect(page.controller.detail!.values['body'], body);
        expect(page.controller.detail!.record.directoryId, targetDirectory.id);
        expect(
          page.controller.detail!.record.tags.any(
            (tag) => tag.id == targetTag.id,
          ),
          isTrue,
        );
        expect(page.controller.detail!.relations['related'], contains(nas));
        expect(page.controller.detail!.record.description, updatedDescription);
        expect(t.takeException(), isNull);
      } finally {
        await t.pumpWidget(const SizedBox());
        for (final source in sources) {
          await ui.resolve(source.dispose);
        }
        HttpOverrides.global = previousHttp;
      }
    },
    skip: !Platform.isWindows || profileDirectory.isEmpty,
    variant: TargetPlatformVariant({TargetPlatform.windows}),
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
