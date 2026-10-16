# #26 auxiliary micro corrections — aux-r3

Eight new raw Flutter screenshots cover retention, template editing, notifications and backups at 1440×900 / 1280×800. Only the three remaining independent aux-r2 items are changed: retention inner alignment, field-remove glyph, and 1px notice/row geometry. All earlier closed scopes remain closed; their screenshots are not regenerated.

`manifest.json` fixes the production source commit, source hashes, eight raw PNG hashes, and eight unchanged HTML reference hashes. `compare-*` contains same-size oil-ui-pro comparison output; wrapper pixels are checked against the raw PNG. Percentages are not acceptance scores. `self-check.json` is narrow producer measurement, not independent verification.

The capture uses real production widgets, actual fonts and enabled shadows, with temporary SQLCipher information/template fixtures. Micro mode does not run encryption/export/restore, native OS pickers, notification probes or app lifecycle. No real profile is accessed. To reproduce without overwriting this set, run from `apps/desktop`:

```powershell
C:/Users/Todoki/.local/share/flutter/bin/flutter.bat test --no-pub --dart-define=AUX_MICRO_ONLY=true --dart-define=AUX_EVIDENCE_DIRECTORY=<new-folder> tool/capture_history_settings_aux.dart
```

`capture.log` records the two viewport checks, `analyze.log` the desktop analysis, and `compare.log` the eight comparison runs. No unrelated complete suite or native acceptance was repeated. Existing native four-picker evidence does not prove actual Windows close-to-background or full quit because the fixture tray adapter is unavailable. That lifecycle acceptance remains OPEN for the parent task; macOS actual testing remains deferred.

Independent targeted visual verification is pending.
