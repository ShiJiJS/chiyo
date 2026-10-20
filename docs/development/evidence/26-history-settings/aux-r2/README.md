# #26 auxiliary visual corrections — aux-r2

This folder is a new immutable evidence set for the six groups from the independent auxiliary first-round report. It contains 36 raw production Flutter screenshots at 1440×900 / 1280×800, with actual fonts and shadows enabled. The default history/appearance r3 set is not regenerated or reopened.

`manifest.json` fixes the source commit, source hashes, all raw image hashes, and sixteen unchanged dedicated HTML reference hashes. Each `compare-*` folder contains the same-size wrapper screenshot and oil-ui-pro `shoot.mjs --compare` output. Wrapper pixels were checked to be identical to the corresponding raw Flutter PNG. Comparison percentages are not acceptance scores. `self-check.json` records only narrow producer measurements, not independent approval.

Restore previews retain actual counts (including the absence of credential history) and the real recovery boundary. Extra content increases natural height and requires scrolling; top and bottom screenshots are both retained. Readability checks include 200% records, template and backup controls, plus the disabled completion action. `settings-records-200-changed-*` follows a real owner preference save to one hour. File picker adapters return temporary paths; actual key-file I/O, encryption, export, authentication and empty-library restore run through SQLCipher. These images are not evidence of OS dialog operation.

Reproduce from `apps/desktop`:

```powershell
C:/Users/Todoki/.local/share/flutter/bin/flutter.bat test --no-pub tool/capture_history_settings_aux.dart
```

Use a new `--dart-define=AUX_EVIDENCE_DIRECTORY=<new-folder>` to preserve this frozen set. The capture performs no native OS picker or notification probe, and never opens the user profile.

Checks: `capture.log` (2 viewports), `widgets.log` (8 affected existing tests), `restore-contrast.log` (2 restore/export tests repeated after adding disabled-label contrast assertions), `analyze.log`, `contrast-analyze.log`, `compare.log`. The previous complete 229-test run is not repeated or relabeled. First native accessibility/semantics runner failure and subsequent successful screenshot-only runner remain in the parent evidence folder.

Independent visual verification of these corrections is pending. The parent integration task will perform the final combined Windows four-picker run; macOS actual acceptance remains deferred.
