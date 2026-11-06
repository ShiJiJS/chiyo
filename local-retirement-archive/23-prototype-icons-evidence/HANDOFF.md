# #23 exact prototype icons

Commit: `848bde8cb0b14bc3d39bb62d0d3fab813dd5f251`

Worktree: `C:/Project/network_config/info-manage-worktrees/23-prototype-icons`

Only committed file: `apps/desktop/lib/prototype_icons.dart`. No layout, palette,
pubspec or shared product files changed. Flutter's generated plugin registrant
changes from dependency resolution were restored. Worktree is clean.

## API

```dart
import 'prototype_icons.dart';

const PrototypeIcon(PrototypeIconGlyph.layers, size: 26);
PrototypeIcon(PrototypeIconGlyph.inbox, color: palette.strong);
```

`PrototypeIcon(glyph, {Key? key, double size = 18, Color? color,
String? semanticLabel})`. Color inherits IconTheme (including opacity) unless
explicitly supplied; size remains 18 unless explicitly supplied, matching the
HTML global SVG size. Fixed 24-unit viewBox, centered uniform scaling, 1.65 stroke,
round caps/joins, no fill or RTL mirroring. No dependencies added. Painter is
private; consumers need only the widget and enum.

Exact glyph IDs, in contact-sheet column order:
`layers, inbox, folder, search, clock, plus, tune, chev, shield, link, file, edit, key`.

Geometry comes directly from every symbol in round-05/index.html, identical to
baseline-index.html. Link arcs use Flutter's SVG-compatible arcToPoint with radius
4 and the original sweep; shield retains the original cubic/smooth-cubic controls.

## Verification

- SDK: `C:/Users/Todoki/.local/share/flutter/bin`.
- `flutter analyze lib/prototype_icons.dart`: no issues.
- `dart format --output=none --set-exit-if-changed ...`: no changes.
- External temporary Flutter render harness: one passing render check, all 13
  glyphs at 18/26/72 logical pixels, 1x DPR. This uses actual Flutter rendering,
  without changing the product app or tests.
- `source-icons.html` uses original HTML symbol markup verbatim. Oil screenshot
  tool rendered it at the same 1248x288 viewport and compared against Flutter.
- Personally viewed `compare/page-compare.png` (Flutter reference upper left,
  original SVG current upper right, overlay and diff below). Shapes, stroke and
  placement align. The tool rounds changed-pixel coverage to 0%; this is not a
  claim of universal pixel equality or page-level fidelity approval.
- No independent visual reviewer or page-level integration check performed in
  this isolated helper task. The lead owns actual page integration and acceptance.

Evidence in this directory:
`flutter-icons.png`, `source/page.png`, `compare/page-compare.png`,
`compare/report.json`, `render_icons_test.dart`, `build-source-sheet.mjs`.

No GitHub writes, push, merge or server sync performed.
