import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/anchored_surface.dart';
import 'package:info_desktop/desktop_scroll.dart';

void main() {
  testWidgets(
    'appearance change closes a menu whose anchor moves without a window resize',
    (t) async {
      final mode = ValueNotifier(DesktopScrollbarStyle.legacy);
      addTearDown(mode.dispose);
      final focus = FocusNode();
      addTearDown(focus.dispose);
      var picked = false;
      await t.pumpWidget(
        ValueListenableBuilder<DesktopScrollbarStyle>(
          valueListenable: mode,
          builder: (_, style, _) => DesktopScrollbarScope(
            style: style,
            child: MaterialApp(
              home: Scaffold(
                body: Builder(
                  builder: (context) => Padding(
                    padding: EdgeInsets.only(
                      right: DesktopScrollbarScope.gutterOf(context, 11),
                    ),
                    child: Align(
                      alignment: Alignment.topRight,
                      child: Builder(
                        builder: (triggerContext) => TextButton(
                          key: const ValueKey('anchor'),
                          focusNode: focus,
                          onPressed: () async {
                            final result = await showAnchoredSurface<bool>(
                              triggerContext,
                              builder: (popup) => TextButton(
                                onPressed: () => Navigator.of(popup).pop(true),
                                child: const Text('Choose'),
                              ),
                            );
                            picked = result == true;
                          },
                          child: const Text('Menu'),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      focus.requestFocus();
      await t.pump();
      final original = t.getRect(find.byKey(const ValueKey('anchor')));
      await t.tap(find.text('Menu'));
      await t.pumpAndSettle();
      expect(find.text('Choose'), findsOneWidget);
      mode.value = DesktopScrollbarStyle.overlay;
      await t.pumpAndSettle();
      expect(find.text('Choose'), findsNothing);
      expect(
        t.getRect(find.byKey(const ValueKey('anchor'))).left,
        original.left + 11,
      );
      expect(picked, false);
      expect(focus.hasFocus, true);
      await t.tap(find.text('Menu'));
      await t.pumpAndSettle();
      await t.tap(find.text('Choose'));
      await t.pumpAndSettle();
      expect(picked, true);
      expect(find.byType(Scaffold), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    },
  );
}
