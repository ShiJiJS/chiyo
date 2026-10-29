import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/desktop_fonts.dart';
import 'package:info_desktop/workspace/agents_page.dart';
import 'package:info_desktop/workspace/backup_page.dart';
import 'package:info_desktop/workspace/classification_page.dart';
import 'package:info_desktop/workspace/library_page.dart';
import 'package:info_desktop/workspace/plugins_page.dart';
import 'package:info_desktop/workspace/preview_workspace.dart';
import 'package:info_desktop/workspace/runtime_page.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/settings_controller.dart';
import 'package:info_desktop/workspace/settings_page.dart';
import 'package:info_desktop/workspace/settings_layout.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

void main() {
  const evidence = String.fromEnvironment('UI_EVIDENCE_DIR');
  setUpAll(() async {
    if (evidence.isEmpty) return;
    final fonts = await loadDesktopFonts();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    await Directory(evidence).create(recursive: true);
    await File('$evidence/fonts.json').writeAsString(jsonEncode(fonts));
  });
  Future<void> ready(WidgetTester t) async {
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
  }

  Future<void> tap(WidgetTester t, String key) async {
    final f = find.byKey(ValueKey(key));
    if (f.evaluate().isEmpty && key.startsWith('settings-section-')) {
      final current = t
          .widget<WorkspaceSettingsPage>(find.byType(WorkspaceSettingsPage))
          .controller
          .section;
      final target = WorkspaceSettingsSection.values.singleWhere(
        (s) => key == 'settings-section-${s.name}',
      );
      await t.scrollUntilVisible(
        f,
        target.index < current.index ? -300 : 300,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('settings-sidebar-scroll')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
    }
    await t.ensureVisible(f);
    await t.pump();
    await t.tap(f);
    await ready(t);
  }

  Future<void> capture(WidgetTester t, String name) async {
    if (evidence.isEmpty) return;
    await t.runAsync(() async {
      final b = t.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('settings-audit-capture')),
          ),
          i = await b.toImage(pixelRatio: 1),
          bytes = await i.toByteData(format: ui.ImageByteFormat.png);
      await File(
        '$evidence/$name.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      i.dispose();
    });
  }

  for (final (width, dark, large) in [
    (1440.0, false, false),
    (1280.0, false, false),
    (1440.0, true, false),
    (1280.0, true, false),
    (1440.0, true, true),
    (1280.0, true, true),
  ]) {
    final prefix =
        'settings-handoff-${width.toInt()}-${dark ? 'dark' : 'light'}${large ? '200' : ''}';
    testWidgets(
      '$prefix all eight sidebar destinations share saved state without system effects or creating grants',
      (t) async {
        t.view.physicalSize = Size(width, width == 1440 ? 900 : 800);
        t.view.devicePixelRatio = 1;
        t.platformDispatcher.textScaleFactorTestValue = large ? 2 : 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
        await t.pumpWidget(
          const RepaintBoundary(
            key: ValueKey('settings-audit-capture'),
            child: PreviewWorkspace(),
          ),
        );
        await ready(t);
        final s =
            t.widget<LibraryPage>(find.byType(LibraryPage)).controller.source
                as SampleWorkspaceSource;
        if (dark) {
          await tap(t, 'preview-guide');
          await tap(t, 'preview-theme-dark');
        }
        final before = (await s.approvals.query(
          const WorkspaceApprovalQuery(),
        )).total;
        await tap(t, 'workspace-nav-settings');
        await tap(t, 'settings-section-notifications');
        await tap(t, 'settings-notifications');
        expect((await s.settings.read()).notifications, false);
        final saved = await s.settings.read(),
            observations = <String, Object>{};
        if (evidence.isNotEmpty) {
          final geometry = <String, Object>{};
          for (final key in [
            'zhiyu-appbar',
            'zhiyu-brand',
            'workspace-nav-library',
            'workspace-nav-approvals',
            'workspace-nav-proposals',
            'workspace-nav-history',
            'workspace-nav-settings',
            'preview-guide',
          ]) {
            final rect = t.getRect(find.byKey(ValueKey(key)));
            geometry[key] = {
              'x': rect.left,
              'y': rect.top,
              'width': rect.width,
              'height': rect.height,
            };
          }
          await t.runAsync(
            () => File(
              '$evidence/$prefix-header.json',
            ).writeAsString(jsonEncode(geometry)),
          );
        }
        for (final section in WorkspaceSettingsSection.values) {
          await tap(t, 'settings-section-${section.name}');
          final page = t.widget<WorkspaceSettingsPage>(
            find.byType(WorkspaceSettingsPage),
          );
          expect(page.controller.section, section);
          switch (section) {
            case WorkspaceSettingsSection.appearance:
              expect(
                find.byKey(const ValueKey('settings-theme-light')),
                findsOneWidget,
              );
            case WorkspaceSettingsSection.notifications:
              expect(
                t
                    .widget<Switch>(
                      find.byKey(const ValueKey('settings-notifications')),
                    )
                    .value,
                false,
              );
            case WorkspaceSettingsSection.records:
              expect(
                find.byKey(const ValueKey('settings-request-minutes')),
                findsOneWidget,
              );
            case WorkspaceSettingsSection.plugins:
              expect(find.byType(PluginsPage), findsOneWidget);
              expect(page.plugins.catalog!.packages, isNotEmpty);
            case WorkspaceSettingsSection.classifications:
              expect(find.byType(ClassificationPage), findsOneWidget);
              expect(page.classifications.catalog, isNotNull);
            case WorkspaceSettingsSection.backups:
              expect(find.byType(WorkspaceBackupPage), findsOneWidget);
              expect(page.backups.value!.keyCreated, false);
            case WorkspaceSettingsSection.runtime:
              expect(find.byType(WorkspaceRuntimePage), findsOneWidget);
              expect(page.runtime.value!.closed, false);
            case WorkspaceSettingsSection.agents:
              expect(find.byType(WorkspaceAgentsPage), findsOneWidget);
              expect(page.agents.value!.session.activeGrants, 0);
          }
          expect((await s.settings.read()).values, saved.values);
          observations[section.name] = {
            'selected': page.controller.section.name,
            'preferencesVersion': page.controller.value!.version,
          };
          if (section != WorkspaceSettingsSection.plugins) {
            final heading = find.byType(SettingsPageHeading).first;
            final scrollers = find.ancestor(
              of: heading,
              matching: find.byType(Scrollable),
            );
            if (scrollers.evaluate().isNotEmpty) {
              t.state<ScrollableState>(scrollers.first).position.jumpTo(0);
            }
            await ready(t);
            final rect = t.getRect(heading);
            final title = find
                .descendant(of: heading, matching: find.byType(Text))
                .first;
            final paragraph = t.renderObject<RenderParagraph>(
              find.descendant(of: title, matching: find.byType(RichText)),
            );
            observations['${section.name}-heading'] = {
              'rect': [rect.left, rect.top, rect.width, rect.height],
              'titleBaseline': paragraph
                  .localToGlobal(
                    Offset(
                      0,
                      paragraph.getDryBaseline(
                        paragraph.constraints,
                        TextBaseline.alphabetic,
                      )!,
                    ),
                  )
                  .dy,
              'titleRect': [
                t.getRect(title).left,
                t.getRect(title).top,
                t.getRect(title).width,
                t.getRect(title).height,
              ],
            };
            final actual = observations['${section.name}-heading']! as Map;
            final appearance = observations['appearance-heading']! as Map;
            for (var axis = 0; axis < 3; axis++) {
              expect(
                (actual['titleRect'] as List)[axis],
                closeTo((appearance['titleRect'] as List)[axis] as num, 2),
                reason: '${section.name} shares the settings title frame',
              );
            }
            expect(
              actual['titleBaseline'],
              closeTo(appearance['titleBaseline'] as num, 2),
            );
            await capture(t, '$prefix-${section.name}');
          }
        }
        expect(
          (await s.approvals.query(const WorkspaceApprovalQuery())).total,
          before,
        );
        expect((await s.agents.read()).session.activeGrants, 0);
        // Recreate the settings page through real top navigation, not a local widget copy.
        await tap(t, 'workspace-nav-library');
        await tap(t, 'workspace-nav-settings');
        expect(
          t
              .widget<WorkspaceSettingsPage>(find.byType(WorkspaceSettingsPage))
              .controller
              .section,
          WorkspaceSettingsSection.agents,
        );
        await tap(t, 'settings-section-notifications');
        expect(
          t
              .widget<Switch>(
                find.byKey(const ValueKey('settings-notifications')),
              )
              .value,
          false,
        );
        if (evidence.isNotEmpty) {
          await t.runAsync(
            () => File(
              '$evidence/$prefix-paths.json',
            ).writeAsString(jsonEncode(observations)),
          );
        }
      },
    );
  }
}
