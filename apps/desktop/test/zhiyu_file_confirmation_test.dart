import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/desktop_controls.dart';
import 'package:info_desktop/desktop_fonts.dart';
import 'package:info_desktop/workspace/library_file_dialogs.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_desktop/workspace/zhiyu_theme.dart';

const resume = WorkspaceRecordRef(WorkspaceRecordKind.information, 'resume');

/// A retained version disappears or another attachment reuses its version
/// number in the host's refreshed metadata. Writes
/// still use the real sample source, so a disabled button must prevent them.
class _RetainedFilesSource extends SampleWorkspaceSource {
  _RetainedFilesSource()
    : super(
        readAsset: (name) async {
          final data = await rootBundle.load(name);
          return data.buffer.asUint8List(
            data.offsetInBytes,
            data.lengthInBytes,
          );
        },
      );
  bool hideHistory = false;
  bool substituteIdentity = false;
  int writes = 0;
  @override
  Future<WorkspaceFileHistory> loadFileHistory(
    WorkspaceRecordRef record,
    String fieldKey,
  ) async {
    final history = await super.loadFileHistory(record, fieldKey);
    return hideHistory
        ? WorkspaceFileHistory(
            recordVersion: history.recordVersion,
            current: history.current,
            versions: [
              history.current,
              if (substituteIdentity)
                for (final file in history.versions.where(
                  (f) => f.ref != history.current.ref,
                ))
                  WorkspaceFileVersion(
                    ref: WorkspaceFileRef(
                      'different-attachment',
                      file.ref.version,
                    ),
                    filename: file.filename,
                    mediaType: file.mediaType,
                    byteLength: file.byteLength,
                    createdAt: file.createdAt,
                  ),
            ],
          )
        : history;
  }

  @override
  Future<WorkspaceFileRef> changeFile(WorkspaceFileChange change) {
    writes++;
    return super.changeFile(change);
  }
}

void main() {
  const evidence = String.fromEnvironment('UI_EVIDENCE_DIR');
  setUpAll(() async {
    if (evidence.isEmpty) return;
    final fonts = await loadDesktopFonts();
    await Directory(evidence).create(recursive: true);
    await File('$evidence/fonts.json').writeAsString(jsonEncode(fonts));
  });
  for (final width in [1440.0, 1280.0]) {
    for (final dark in [false, true]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets(
          'file restore identity and vanished/substituted target $width dark=$dark scale=$scale',
          (t) async {
            final shadows = debugDisableShadows;
            if (evidence.isNotEmpty) debugDisableShadows = false;
            try {
              t.view.physicalSize = Size(width, width == 1440 ? 900 : 800);
              t.view.devicePixelRatio = 1;
              t.platformDispatcher.textScaleFactorTestValue = scale;
              addTearDown(t.view.resetPhysicalSize);
              addTearDown(t.view.resetDevicePixelRatio);
              addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
              final source = _RetainedFilesSource()
                ..substituteIdentity = scale == 2;
              addTearDown(source.dispose);
              final history = (await t.runAsync(
                () => source.loadFileHistory(resume, 'file'),
              ))!;
              final old = history.versions.singleWhere(
                (f) => f.ref.version == 1,
              );
              bool? result;
              await t.pumpWidget(
                MaterialApp(
                  theme: zhiyuTheme(dark ? Brightness.dark : Brightness.light),
                  home: Builder(
                    builder: (context) => Scaffold(
                      body: DesktopButton(
                        onPressed: () async {
                          result = await showLibraryFileChange(
                            context,
                            source,
                            resume,
                            'file',
                            history,
                            restoreVersion: 1,
                          );
                        },
                        child: const Text('恢复旧文件'),
                      ),
                    ),
                  ),
                  builder: (context, child) => RepaintBoundary(
                    key: const ValueKey('file-confirmation-capture'),
                    child: child!,
                  ),
                ),
              );
              Future<void> tap(Finder f) async {
                await t.ensureVisible(f);
                await t.tap(f);
                for (var i = 0; i < 200; i++) {
                  await t.runAsync(
                    () => Future<void>.delayed(const Duration(milliseconds: 2)),
                  );
                  await t.pump(const Duration(milliseconds: 16));
                  if (!t
                      .widgetList<DesktopButton>(find.byType(DesktopButton))
                      .any((b) => b.busy)) {
                    break;
                  }
                }
                await t.pumpAndSettle();
                expect(t.takeException(), isNull);
              }

              Finder key(String name) => find.byKey(ValueKey(name));
              Future<void> capture(String state) async {
                if (evidence.isEmpty) return;
                await t.runAsync(() async {
                  final boundary = t.renderObject<RenderRepaintBoundary>(
                    key('file-confirmation-capture'),
                  );
                  final image = await boundary.toImage(pixelRatio: 1);
                  final data = await image.toByteData(
                    format: ui.ImageByteFormat.png,
                  );
                  await File(
                    '$evidence/confirm-${width.toInt()}-${dark ? 'dark' : 'light'}-${(scale * 100).toInt()}-$state.png',
                  ).writeAsBytes(data!.buffer.asUint8List());
                  image.dispose();
                });
              }

              await tap(find.text('恢复旧文件'));
              for (final (id, file) in [
                ('current', history.current),
                ('target', old),
              ]) {
                final summary = key('library-file-change-$id');
                final text = t
                    .widgetList<SelectableText>(
                      find.descendant(
                        of: summary,
                        matching: find.byType(SelectableText),
                      ),
                    )
                    .map((w) => w.data)
                    .join('\n');
                expect(text, contains(file.filename));
                expect(text, contains(file.mediaType));
                expect(text, contains('${file.byteLength} 字节'));
              }
              expect(find.text('恢复来源 · 历史 v1'), findsOneWidget);
              expect(find.textContaining('创建新文件版本 v3'), findsOneWidget);
              await capture('review');
              source.nextSaveFailure = const WorkspaceFailure(
                'conflict',
                '文件版本已变化，请重新核对。',
              );
              await tap(key('library-file-change-submit'));
              expect(source.writes, 1);
              source.hideHistory = true;
              await tap(find.text('重新读取核对'));
              expect(
                key('library-file-change-target-unavailable'),
                findsOneWidget,
              );
              expect(key('library-file-change-target'), findsNothing);
              expect(
                t
                    .widget<DesktopButton>(key('library-file-change-submit'))
                    .onPressed,
                isNull,
              );
              await tap(key('library-file-change-submit'));
              expect(source.writes, 1);
              expect(
                WorkspaceFileRef.fromJson(
                  (await t.runAsync(
                    () => source.readDetail(resume),
                  ))!.values['file'],
                ).version,
                2,
              );
              await capture('target-unavailable');
              await tap(find.text('取消'));
              expect(result, false);
              expect(find.byType(DesktopDialog), findsNothing);
              await t.pumpWidget(const SizedBox());
              await t.pumpAndSettle();
            } finally {
              debugDisableShadows = shadows;
            }
          },
        );
      }
    }
  }
}
