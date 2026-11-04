import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/workspace/library_document.dart';
import 'package:info_desktop/workspace/library_file.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_desktop/workspace/zhiyu_theme.dart';

const body = '# 个人信息\n\n- 示例内容\n\n| 项目 | 值 |\n| --- | --- |\n| 类别 | 合成资料 |';

void main() {
  testWidgets(
    'old text/plain Markdown attachments render with shared document reader and can show source',
    (t) async {
      Future<void> open(String filename, {int version = 1}) async {
        final file = WorkspaceFileVersion(
          ref: WorkspaceFileRef('synthetic-document', version),
          filename: filename,
          mediaType: 'text/plain',
          byteLength: body.length,
          createdAt: DateTime.utc(2026, 11, 4),
        );
        await t.pumpWidget(
          MaterialApp(
            theme: zhiyuTheme(Brightness.light),
            home: Scaffold(
              body: SingleChildScrollView(
                child: LibraryFilePreviewView(
                  preview: WorkspaceFilePreview(
                    file: file,
                    kind: WorkspaceFilePreviewKind.text,
                    text: body,
                  ),
                  onPage: (_) =>
                      fail('Text preview must not request PDF pages'),
                ),
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
      }

      await open('个人信息汇总.MD');
      expect(find.byType(LibraryDocument), findsOneWidget);
      expect(find.byType(Table), findsOneWidget);
      expect(find.text(body), findsNothing);
      expect(find.text('显示原文'), findsOneWidget);
      await t.tap(find.text('显示原文'));
      await t.pumpAndSettle();
      expect(find.text(body), findsOneWidget);
      expect(find.byType(Table), findsNothing);
      await t.tap(find.text('阅读排版'));
      await t.pumpAndSettle();
      expect(find.byType(Table), findsOneWidget);
      await t.tap(find.text('显示原文'));
      await t.pumpAndSettle();
      await open('旧稿.markdown', version: 2);
      expect(find.byType(Table), findsOneWidget);
      expect(find.text('显示原文'), findsOneWidget);
      await open('记录.txt', version: 3);
      expect(find.byType(LibraryDocument), findsNothing);
      expect(find.byType(Table), findsNothing);
      expect(find.text(body), findsOneWidget);
      expect(find.text('显示原文'), findsNothing);
      expect(t.takeException(), isNull);
    },
  );
}
