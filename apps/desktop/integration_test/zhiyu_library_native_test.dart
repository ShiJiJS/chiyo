import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:info_desktop/desktop_controls.dart';
import 'package:info_desktop/desktop_fonts.dart';
import 'package:info_desktop/workspace/library_page.dart';
import 'package:info_desktop/workspace/library_file.dart';
import 'package:info_desktop/workspace/library_widgets.dart';
import 'package:info_desktop/workspace/mac_preview_desktop.dart';
import 'package:info_desktop/workspace/preview_workspace.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'support/native_frame_recording.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets('Mac library query, edit failure, related return and viewport matrix', (
    tester,
  ) async {
    if (!Platform.isMacOS) {
      throw StateError('This isolated check requires macOS.');
    }
    final fonts = await loadDesktopFonts(), desktop = MacPreviewDesktop();
    final native = await desktop.initialize();
    final directory = (await MacPreviewDesktop.channel.invokeMethod<String>(
      'createEvidenceDirectory',
    ))!;
    // ignore: avoid_print
    print('ZHIYU_NATIVE_EVIDENCE=$directory');
    final root = Directory(directory),
        boundary = GlobalKey(),
        checks = <String>[];
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: PreviewWorkspace(desktop: desktop),
      ),
    );
    await tester.pumpAndSettle();
    final model = tester
        .widget<LibraryPage>(find.byType(LibraryPage))
        .controller;
    Future<void> tap(Finder target) async {
      await tester.ensureVisible(target);
      await tester.pumpAndSettle();
      await tester.tap(target);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }

    Future<void> enter(String key, String text) async {
      final target = find.descendant(
        of: find.byKey(ValueKey(key)),
        matching: find.byType(TextField),
      );
      await tester.ensureVisible(target);
      await tester.enterText(target, text);
      await tester.pumpAndSettle();
    }

    Future<void> screenshot(String name) async {
      await tester.pumpAndSettle();
      final image =
          await (boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary)
              .toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(
        '$directory/$name.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    }

    Future<void> resize(Size size) async {
      await MacPreviewDesktop.channel.invokeMethod<void>('setContentSize', {
        'width': size.width,
        'height': size.height,
      });
      for (var frame = 0; frame < 60; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        if (tester.view.physicalSize / tester.view.devicePixelRatio == size) {
          break;
        }
      }
      expect(tester.view.physicalSize / tester.view.devicePixelRatio, size);
      await tester.pumpAndSettle();
    }

    await resize(const Size(1440, 900));
    expect(
      await MacPreviewDesktop.channel.invokeMethod<bool>(
        'activateMenu',
        'settings',
      ),
      isTrue,
    );
    await tester.pumpAndSettle();
    expect(
      await MacPreviewDesktop.channel.invokeMethod<bool>(
        'activateMenu',
        'search',
      ),
      isTrue,
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('library-search')))
          .focusNode!
          .hasFocus,
      isTrue,
    );
    checks.add('native-search-menu-opens-library-and-focuses-search');
    await tap(find.byKey(const ValueKey('library-directory-all')));
    await tap(find.byKey(const ValueKey('library-group')));
    await tap(find.text('按类型').last);
    await tap(find.byKey(const ValueKey('library-sort')));
    await tap(find.text('按名称').last);
    final nameOrder = model.results!.items.map((r) => r.ref.key).toList();
    expect(model.results!.total, 31);
    expect(nameOrder.take(7), [
      'credential:aliyunkey',
      'credential:sshkey',
      'credential:blinkokey',
      'credential:github-token',
      'credential:tgsession',
      'credential:vikunja-password',
      'credential:vikunjakey',
    ]);
    await screenshot('mac-chinese-name-order');
    checks.add(
      'native-CoreFoundation-zh-CN-name-sort-and-first-appearance-groups',
    );
    await tap(find.byKey(const ValueKey('library-group')));
    await tap(find.text('不分组').last);
    await tap(find.byKey(const ValueKey('library-sort')));
    await tap(find.text('最近更新优先').last);
    await tap(find.byKey(const ValueKey('library-directory-selfhost')));
    final recording = NativeFrameRecording(boundary, root, '', '');
    addTearDown(recording.dispose);
    await recording.start();
    recording.mark('chooser-open-with-sharp-surface-and-blurred-barrier');
    await tap(find.byKey(const ValueKey('library-create')));
    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(
      await MacPreviewDesktop.channel.invokeMethod<bool>(
        'activateMenu',
        'settings',
      ),
      isFalse,
    );
    await screenshot('chooser-1440-light-recording');
    recording.mark('chooser-close-without-reverse-animation');
    await tester.tap(find.byKey(const ValueKey('desktop-dialog-close')));
    await tester.pump();
    await tester.pump();
    expect(find.byType(DesktopDialog), findsNothing);
    expect(find.byType(BackdropFilter), findsNothing);
    checks.add(
      'native-chooser-blurred-barrier-locked-menu-and-immediate-close',
    );
    recording.mark('query-server-and-tag');
    await tap(find.byKey(const ValueKey('library-type-filter')));
    await tap(find.text('服务器信息').last);
    await tap(find.byKey(const ValueKey('library-tag-filter')));
    await tap(find.text('生产环境').last);
    await tester.enterText(find.byKey(const ValueKey('library-search')), '日本');
    await tester.pumpAndSettle();
    expect(model.results!.total, 1);
    expect(model.selection?.id, 'azure');
    await screenshot('filtered-1440-light');
    checks.add('native-widget-filter-intersection');
    recording.mark('failed-save-preserves-draft');
    (model.source as SampleWorkspaceSource).nextSaveFailure =
        const WorkspaceFailure('offline', '保存失败，请重试。');
    await tap(find.text('编辑信息'));
    expect(
      await MacPreviewDesktop.channel.invokeMethod<bool>(
        'activateMenu',
        'settings',
      ),
      isFalse,
    );
    await enter('library-edit-description', '公网入口与 Mac 编辑核对');
    await tap(find.byKey(const ValueKey('library-edit-save')));
    expect(find.text('保存失败，请重试。'), findsOneWidget);
    expect(
      tester.getRect(find.byKey(const ValueKey('library-edit-status'))).bottom,
      lessThan(
        tester.getRect(find.byKey(const ValueKey('library-edit-save'))).top,
      ),
    );
    await screenshot('edit-failure-light');
    await tap(find.byKey(const ValueKey('library-edit-save')));
    expect(find.byType(DesktopDialog), findsNothing);
    expect(model.detail!.record.description, '公网入口与 Mac 编辑核对');
    checks.add('native-widget-save-failure-draft-and-success-readback');
    recording.mark('open-related-and-return');
    await tap(
      find.byKey(const ValueKey('library-relation-information:aliyun')),
    );
    expect(model.selection?.id, 'aliyun');
    expect(model.query.typeId, 'server');
    expect(model.query.keyword, '');
    await tap(find.byKey(const ValueKey('library-back')));
    expect(model.selection?.id, 'azure');
    expect(model.query.keyword, '日本');
    checks.add('native-widget-related-query-return');
    await recording.stop('native-controls');
    final viewports = <Map<String, Object>>[];
    final credentialFormChecks = <Map<String, Object>>[];
    final chooserViewports = <Map<String, Object>>[];
    (model.source as SampleWorkspaceSource).reset();
    await model.apply(const WorkspaceQuery(directoryId: 'selfhost'));
    await tester.pumpAndSettle();
    for (final size in [const Size(1440, 900), const Size(1280, 800)]) {
      await resize(size);
      for (final dark in [false, true]) {
        await tap(find.byKey(const ValueKey('preview-guide')));
        await tap(
          find.byKey(ValueKey('preview-theme-${dark ? 'dark' : 'light'}')),
        );
        tester
            .state<ScrollableState>(
              find
                  .descendant(
                    of: find.byKey(const ValueKey('library-detail-scroll')),
                    matching: find.byType(Scrollable),
                  )
                  .first,
            )
            .position
            .jumpTo(0);
        await screenshot(
          '${dark ? 'dark' : 'light'}-${size.width.toInt()}-library',
        );
        await tap(find.byKey(const ValueKey('library-create')));
        expect(find.byType(BackdropFilter), findsOneWidget);
        await screenshot(
          '${dark ? 'dark' : 'light'}-${size.width.toInt()}-chooser',
        );
        final close = tester.getRect(
          find.byKey(const ValueKey('desktop-dialog-close')),
        );
        final surface = tester.getRect(
          find
              .descendant(
                of: find.byType(DesktopDialog),
                matching: find.byType(Container),
              )
              .first,
        );
        chooserViewports.add({
          'width': size.width,
          'height': size.height,
          'dark': dark,
          'surface': {
            'x': surface.left,
            'y': surface.top,
            'width': surface.width,
            'height': surface.height,
          },
          'close': {
            'x': close.left,
            'y': close.top,
            'width': close.width,
            'height': close.height,
          },
          'devicePixelRatio': tester.view.devicePixelRatio,
        });
        await tester.tap(find.byKey(const ValueKey('desktop-dialog-close')));
        await tester.pump();
        await tester.pump();
        expect(find.byType(DesktopDialog), findsNothing);
        expect(find.byType(BackdropFilter), findsNothing);
        final actualScrollbarWidth =
            tester
                .getSize(find.byKey(const ValueKey('library-detail-scroll')))
                .width -
            (RenderAbstractViewport.of(
                      tester.renderObject(
                        find.byKey(const ValueKey('library-detail-title')),
                      ),
                    )
                    as RenderBox)
                .size
                .width;
        final expectedScrollbarWidth = native['scrollbarStyle'] == 'overlay'
            ? 0.0
            : 11.0;
        expect(actualScrollbarWidth, closeTo(expectedScrollbarWidth, .001));
        await tap(find.byKey(const ValueKey('library-directory-all')));
        await tap(find.byKey(const ValueKey('library-search')));
        await tester.enterText(
          find.byKey(const ValueKey('library-search')),
          '',
        );
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('library-search')),
          'HTTPS',
        );
        await tester.pumpAndSettle();
        for (
          var frame = 0;
          frame < 120 && model.loadState == WorkspaceLoad.loading;
          frame++
        ) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(
          model.query.keyword,
          'HTTPS',
          reason:
              'Search text: ${tester.widget<TextField>(find.byKey(const ValueKey('library-search'))).controller!.text}',
        );
        expect(model.loadState, WorkspaceLoad.ready);
        final documentRow = find.byKey(
          const ValueKey('library-record-information:https'),
        );
        if (documentRow.evaluate().isEmpty) {
          await tester.scrollUntilVisible(
            documentRow,
            150,
            scrollable: find
                .descendant(
                  of: find.byKey(const ValueKey('library-results-scroll')),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
        }
        await tap(
          find.byKey(const ValueKey('library-record-information:https')),
        );
        final originalBody = model.detail!.values['body'];
        Map<String, double> box(Finder finder) {
          final r = tester.getRect(finder);
          return {
            'x': r.left,
            'y': r.top,
            'width': r.width,
            'height': r.height,
          };
        }

        final documentBoxes = <String, Object>{
          'detail-title': box(
            find.byKey(const ValueKey('library-detail-title')),
          ),
        };
        for (final (i, heading) in ['用途与适用范围', '访问入口', '维护步骤'].indexed) {
          documentBoxes['document-heading-$i'] = box(
            find.byWidgetPredicate(
              (w) =>
                  w is SelectableText &&
                  (w.data ?? w.textSpan?.toPlainText()) == heading,
            ),
          );
        }
        for (final (part, index) in [
          ('paragraph-0', 1),
          ('table', 3),
          ('list', 5),
          ('code', 6),
          ('paragraph-1', 7),
        ]) {
          documentBoxes['document-$part'] = box(
            find.byKey(ValueKey('library-document-block-$index')),
          );
        }
        final documentTable = tester.widget<Table>(find.byType(Table));
        for (var r = 0; r < documentTable.children.length; r++) {
          for (var c = 0; c < documentTable.children[r].children.length; c++) {
            documentBoxes['document-table-cell-$r-$c'] = box(
              find.byWidget(documentTable.children[r].children[c]),
            );
          }
        }
        final listItems = find.descendant(
          of: find.byKey(const ValueKey('library-document-block-5')),
          matching: find.byType(Expanded),
        );
        for (var i = 0; i < 3; i++) {
          documentBoxes['document-list-item-$i'] = box(listItems.at(i));
        }
        await screenshot(
          '${dark ? 'dark' : 'light'}-${size.width.toInt()}-document',
        );
        await tap(find.byKey(const ValueKey('library-document-raw')));
        expect(
          tester
              .widget<SelectableText>(
                find.byKey(const ValueKey('library-document-text')),
              )
              .data,
          originalBody,
        );
        await tap(find.byKey(const ValueKey('library-document-raw')));
        final attachmentBoxes = <String, Object>{};
        for (final (query, ref) in [
          ('服务端开发简历', 'information:resume'),
          ('Azure SSH', 'credential:sshkey'),
        ]) {
          await tap(find.byKey(const ValueKey('library-directory-all')));
          final search = find.byKey(const ValueKey('library-search'));
          await tap(search);
          await tester.enterText(search, '');
          await tester.pumpAndSettle();
          await tester.enterText(search, query);
          await tester.pumpAndSettle();
          for (
            var frame = 0;
            frame < 120 && model.loadState == WorkspaceLoad.loading;
            frame++
          ) {
            await tester.pump(const Duration(milliseconds: 16));
          }
          expect(model.query.keyword, query);
          expect(model.loadState, WorkspaceLoad.ready);
          final row = find.byKey(ValueKey('library-record-$ref'));
          if (row.evaluate().isEmpty) {
            await tester.scrollUntilVisible(
              row,
              150,
              scrollable: find
                  .descendant(
                    of: find.byKey(const ValueKey('library-results-scroll')),
                    matching: find.byType(Scrollable),
                  )
                  .first,
            );
          }
          await tap(row);
          if (ref == 'information:resume') {
            final image = find.descendant(
              of: find.byType(LibraryFilePreviewView),
              matching: find.byWidgetPredicate(
                (w) => w is RawImage && w.image != null,
              ),
            );
            for (
              var frame = 0;
              frame < 120 && image.evaluate().isEmpty;
              frame++
            ) {
              await tester.pump(const Duration(milliseconds: 16));
            }
            expect(image, findsOneWidget);
            attachmentBoxes['resume'] = {
              'detail-title': box(
                find.byKey(const ValueKey('library-detail-title')),
              ),
              'file-stage': box(
                find.byKey(const ValueKey('library-file-stage')),
              ),
            };
          } else {
            expect(
              find.byKey(const ValueKey('credential-mask')),
              findsOneWidget,
            );
            expect(
              tester
                  .widget<LibraryReadingText>(
                    find.byKey(const ValueKey('credential-binding-value')),
                  )
                  .span
                  .toPlainText(),
              'SSH_KEY_FILE',
            );
            attachmentBoxes['sshkey'] = {
              for (final key in [
                'credential-summary',
                'credential-summary-format',
                'credential-status',
                'credential-section-purpose-title',
                'credential-purpose',
                'credential-section-use-title',
                'credential-delivery-fact',
                'credential-delivery-label',
                'credential-binding-fact',
                'credential-binding-label',
                'credential-use-note',
                'credential-section-relations-title',
                'library-relation-frame-information:azure',
                'library-relation-icon-information:azure',
                'library-relation-text-information:azure',
                'library-relation-description-information:azure',
                'library-relation-chevron-information:azure',
              ])
                key: box(find.byKey(ValueKey(key))),
            };
          }
          await screenshot(
            '${dark ? 'dark' : 'light'}-${size.width.toInt()}-${ref.split(':').last}',
          );
          if (ref == 'credential:sshkey' && !dark && size.width == 1440) {
            const credential = WorkspaceRecordRef(
              WorkspaceRecordKind.credential,
              'sshkey',
            );
            final before = await model.source.credentials.read(credential);
            await tap(find.byKey(const ValueKey('credential-replace')));
            await enter('credential-edit-binding', 'NATIVE_CUSTOM_REFERENCE');
            await tap(find.byKey(const ValueKey('credential-edit-candidate')));
            await tap(
              find.byKey(const ValueKey('credential-candidate-ssh-file')),
            );
            expect(
              tester
                  .widget<DesktopTextField>(
                    find.byKey(const ValueKey('credential-edit-binding')),
                  )
                  .controller!
                  .text,
              'NATIVE_CUSTOM_REFERENCE',
            );
            await tester.ensureVisible(
              find.byKey(const ValueKey('credential-edit-binding')),
            );
            await tester.pumpAndSettle();
            final metrics = <String, Object>{};
            for (final (id, caption) in [
              ('name', '凭据名称'),
              ('binding', '建议引用名'),
            ]) {
              final owner = find.byKey(ValueKey('credential-edit-$id'));
              final label = find.descendant(
                of: owner,
                matching: find.text(caption),
              );
              final input = find.descendant(
                of: owner,
                matching: find.byType(TextField),
              );
              final lr = tester.getRect(label), ir = tester.getRect(input);
              metrics[id] = {
                'labelHeight': lr.height,
                'gap': ir.top - lr.bottom,
                'inputHeight': ir.height,
                'labelFontSize': tester.widget<Text>(label).style!.fontSize!,
                'labelWeight': tester
                    .widget<Text>(label)
                    .style!
                    .fontWeight!
                    .value,
              };
              expect(ir.top - lr.bottom, 8);
              expect(ir.height, 44);
            }
            credentialFormChecks.add({
              'viewport': {
                'width': size.width,
                'height': size.height,
                'dpr': tester.view.devicePixelRatio,
              },
              'theme': 'light',
              'replace': true,
              'fields': metrics,
            });
            await screenshot('credential-replacement-reference-1440-light');
            await tap(find.text('取消').last);
            await tap(find.text('放弃修改'));
            final after = await model.source.credentials.read(credential);
            expect(after.binding, before.binding);
            expect(after.materialVersion, before.materialVersion);
            checks.add(
              'native-credential-replacement-keeps-custom-reference-and-field-metrics',
            );
            // Prepare retained metadata through the isolated source; the
            // confirmation/back/cancel path below uses the actual widgets.
            for (var i = 0; i < 6; i++) {
              final current = await model.source.credentials.read(credential);
              await model.source.credentials.save(
                WorkspaceCredentialWrite(
                  operationId: 'native-material-confirmation-$i',
                  ref: credential,
                  expectedRecordVersion: current.recordVersion,
                  expectedMaterialVersion: current.materialVersion,
                  name: current.record.name,
                  purpose: current.record.description,
                  privateNote: current.privateNote,
                  binding: current.binding,
                  directoryId: current.record.directoryId,
                  tagIds: current.record.tags.map((t) => t.id),
                  candidateId: 'ssh-file',
                ),
              );
            }
            await tester.pumpAndSettle();
            final retained = await model.source.credentials.read(credential);
            await tap(find.byKey(const ValueKey('library-record-actions')));
            await tap(find.text('材料版本'));
            final old = find.byKey(const ValueKey('credential-material-1'));
            await tap(old);
            final offset = Scrollable.of(tester.element(old)).position.pixels;
            final restore = find.byKey(
              const ValueKey('credential-material-restore'),
            );
            final focus = tester.widget<DesktopButton>(restore).focusNode!;
            focus.requestFocus();
            await tester.pump();
            await tap(restore);
            expect(
              find.byKey(const ValueKey('credential-material-2')),
              findsNothing,
            );
            expect(
              find.text('恢复后凭据将停用，旧授权不会恢复。').hitTestable(),
              findsOneWidget,
            );
            expect(focus.hasFocus, true);
            await screenshot('material-restore-confirmation-1440-light');
            await tap(find.byKey(const ValueKey('credential-material-back')));
            expect(
              Scrollable.of(tester.element(old)).position.pixels,
              closeTo(offset, .1),
            );
            expect(tester.widget<DesktopButton>(old).selected, true);
            expect(focus.hasFocus, true);
            await tap(find.byKey(const ValueKey('credential-material-close')));
            final cancelled = await model.source.credentials.read(credential);
            expect(cancelled.materialVersion, retained.materialVersion);
            expect(cancelled.binding, retained.binding);
            checks.add(
              'native-material-confirmation-back-keeps-selection-scroll-focus-and-cancel',
            );
            (model.source as SampleWorkspaceSource).reset();
            await tester.pumpAndSettle();
          }
          if (ref == 'information:resume' && !dark && size.width == 1440) {
            final file = tester
                .widget<LibraryFilePreviewView>(
                  find.byType(LibraryFilePreviewView),
                )
                .preview
                .file;
            final initialWidth = tester.getSize(find.byType(Image)).width;
            await tap(find.byKey(const ValueKey('library-file-metadata-file')));
            expect(
              tester
                  .widget<SelectableText>(
                    find.byKey(const ValueKey('library-file-metadata-content')),
                  )
                  .data,
              contains('${file.byteLength} 字节'),
            );
            await tap(find.text('关闭'));
            await tap(find.byKey(const ValueKey('library-file-zoom-in')));
            await tap(find.byKey(const ValueKey('library-file-text-mode')));
            await tap(find.byKey(const ValueKey('library-file-actions-file')));
            await tap(
              find.byKey(const ValueKey('library-file-preview-refresh-file')),
            );
            for (
              var frame = 0;
              frame < 120 &&
                  find
                      .byKey(const ValueKey('library-file-extracted-text'))
                      .evaluate()
                      .isEmpty;
              frame++
            ) {
              await tester.pump(const Duration(milliseconds: 16));
            }
            expect(
              find.byKey(const ValueKey('library-file-extracted-text')),
              findsOneWidget,
            );
            await tap(find.byKey(const ValueKey('library-file-text-mode')));
            expect(
              tester.getSize(find.byType(Image)).width,
              closeTo(initialWidth * 1.5, .1),
            );
            await tap(find.byKey(const ValueKey('library-file-zoom-out')));
            checks.add(
              'native-file-metadata-and-menu-refresh-preserve-reading-state',
            );
            await tap(find.byKey(const ValueKey('library-file-versions-file')));
            Finder historyPreview() => find.descendant(
              of: find.byType(DesktopDialog),
              matching: find.byType(LibraryFilePreviewView),
            );
            Future<void> waitHistory(int version, int page) async {
              bool ready() =>
                  historyPreview().evaluate().isNotEmpty &&
                  tester
                          .widget<LibraryFilePreviewView>(historyPreview())
                          .preview
                          .file
                          .ref
                          .version ==
                      version &&
                  tester
                          .widget<LibraryFilePreviewView>(historyPreview())
                          .preview
                          .page ==
                      page;
              for (var frame = 0; frame < 120 && !ready(); frame++) {
                await tester.pump(const Duration(milliseconds: 16));
              }
              expect(ready(), true);
            }

            await waitHistory(2, 0);
            await tap(
              find.descendant(
                of: find.byType(DesktopDialog),
                matching: find.byKey(const ValueKey('library-file-page-next')),
              ),
            );
            await waitHistory(2, 1);
            await tap(find.byKey(const ValueKey('library-file-version-2')));
            expect(
              tester
                  .widget<LibraryFilePreviewView>(historyPreview())
                  .preview
                  .page,
              1,
            );
            await tap(find.byKey(const ValueKey('library-file-version-1')));
            await waitHistory(1, 0);
            await tap(find.byKey(const ValueKey('library-file-restore')));
            final old = (await model.source.loadFileHistory(
              const WorkspaceRecordRef(
                WorkspaceRecordKind.information,
                'resume',
              ),
              'file',
            )).versions.singleWhere((f) => f.ref.version == 1);
            final target = find.descendant(
              of: find.byKey(const ValueKey('library-file-change-target')),
              matching: find.byType(SelectableText),
            );
            final displayed = tester
                .widgetList<SelectableText>(target)
                .map((w) => w.data)
                .join('\n');
            expect(displayed, contains(old.filename));
            expect(displayed, contains('${old.byteLength} 字节'));
            expect(find.text('恢复来源 · 历史 v1'), findsOneWidget);
            await screenshot('file-restore-review-1440-light');
            await tap(find.text('取消').last);
            await tap(find.text('关闭').last);
            expect(
              tester
                  .widget<LibraryFilePreviewView>(
                    find.byType(LibraryFilePreviewView),
                  )
                  .preview
                  .file
                  .ref,
              file.ref,
            );
            checks.add(
              'native-file-history-same-version-page-and-restore-identity-cancel',
            );
          }
        }
        viewports.add({
          'width': size.width,
          'height': size.height,
          'dark': dark,
          'devicePixelRatio': tester.view.devicePixelRatio,
          'nativeWindowResized': true,
          'scrollbarStyle': native['scrollbarStyle']!,
          'actualScrollbarWidth': actualScrollbarWidth,
          'documentBoxes': documentBoxes,
          'attachmentBoxes': attachmentBoxes,
        });
        await model.resetView();
        await tester.pumpAndSettle();
      }
    }
    checks.add(
      'native-credential-purpose-use-facts-relation-body-two-viewports-two-themes',
    );
    checks.add('native-window-two-content-viewports-and-both-themes');
    checks.add('native-AppKit-scrollbar-style-matches-rendered-library-gutter');
    checks.add('native-chooser-two-viewports-two-themes-no-residual-barrier');
    checks.add(
      'native-document-two-viewports-two-themes-table-list-code-and-complete-raw-reading',
    );
    checks.add(
      'native-file-real-frame-and-credential-summary-two-viewports-two-themes',
    );
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpAndSettle();
    await screenshot('dark-1280-large-text');
    await tap(find.text('编辑信息'));
    await enter('library-edit-name', 'Mac 放大文字核对');
    await tap(find.byKey(const ValueKey('library-edit-save')));
    expect(find.byType(DesktopDialog), findsNothing);
    checks.add('native-rendered-large-text-edit-and-save');
    tester.platformDispatcher.textScaleFactorTestValue = 1;
    await tester.pumpAndSettle();
    const azure = WorkspaceRecordRef(WorkspaceRecordKind.information, 'azure');
    await tap(find.byKey(const ValueKey('library-record-actions')));
    await tap(find.text('内容版本'));
    await tap(find.byKey(const ValueKey('library-version-1')));
    await screenshot('revision-compare-1280-dark');
    await tap(find.byKey(const ValueKey('library-restore-version')));
    expect((await model.source.readDetail(azure)).version, 3);
    checks.add('native-widget-revision-comparison-restore-and-readback');
    await tap(find.byKey(const ValueKey('library-record-actions')));
    await tap(find.text('移到回收站'));
    await tap(find.byKey(const ValueKey('library-recycle-submit')));
    expect((await model.source.loadSummary()).records, 30);
    await tap(find.byKey(const ValueKey('library-open-recycle')));
    final entry = (await model.source.queryRecycled()).items.singleWhere(
      (e) => e.record.ref == azure,
    );
    await screenshot('recycle-1280-dark');
    await tap(find.byKey(ValueKey('library-recycle-view-${entry.id}')));
    await tap(find.byKey(const ValueKey('library-recycle-submit')));
    expect((await model.source.readDetail(azure)).version, 5);
    await tap(find.text('查看已恢复资料'));
    expect(model.selection, azure);
    checks.add('native-widget-whole-record-recycle-restore-and-return');
    await tap(find.byKey(const ValueKey('preview-guide')));
    await tap(find.byKey(const ValueKey('preview-dataset-stress')));
    expect(model.results!.total, 208);
    await screenshot('stress-1280-dark');
    await tap(find.byTooltip('下一页'));
    expect(model.query.offset, 50);
    checks.add('native-widget-pressure-fixture-and-pagination');

    await File('$directory/native-checks.json').writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'platform': 'macos',
        'fonts': fonts,
        'nativeIsolationChecked': true,
        'nativePreview': native,
        'checks': checks,
        'nameOrder': nameOrder,
        'contentViewports': viewports,
        'credentialFormChecks': credentialFormChecks,
        'chooserViewports': chooserViewports,
        'productionBootstrapUsed': false,
        'databaseOpened': false,
        'inputScope':
            'native Flutter framebuffer and Widget input; own AppKit window/menu only; no global OS input',
        'status':
            'in-progress; current-source browsing/edit, revision/recycle and pressure coverage; full R01-R04 geometry/motion and actual OS input remain pending',
      }),
    );
    await tester.pumpWidget(const SizedBox());
  }, timeout: const Timeout(Duration(minutes: 3)));
}
