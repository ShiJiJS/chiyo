# Background lifetime and request notifications (#8)

Implemented against the tested core/CLI contracts. Both platform runners expose
an owner-process-only `agent_info_manage/desktop` method channel. It is separate
from the existing macOS database-key bridge and is never an Agent HTTP route.
No independent OS service, login item or global user configuration is installed.

## Behavior

- Closing the main window asks the native runner to hide it only when a tray or
  menu-bar entry exists. The Flutter engine, local server and in-memory grants
  remain running. The existing pending requests and selections stay in memory.
- Windows uses `Shell_NotifyIconW` with version 4 callbacks, an open-approvals
  entry and an explicit full-quit entry. `TaskbarCreated` restores the icon after
  Explorer restarts. Failed restoration brings the window back and reports the
  unavailable background entry. Window hiding never destroys the engine.
- macOS uses `NSStatusItem` and `NSWindowDelegate`; opening from the menu bar,
  notification or Dock returns to the approvals tab. Cmd-Q, the application menu
  and the explicit quit entry all request the same Dart cleanup path.
- Full quit synchronously clears core authorization, stops the Agent server,
  closes the encrypted repository and only then asks the runner to terminate.
  Repeated quit actions share the same shutdown future. A crash or forced OS
  termination still destroys the process-local capability state.
- The CLI already returns `service_unavailable` for failed connections, distinct
  from `pending` and a bounded wait timeout. Restart never imports old grants.
- The coordinator subscribes once to `requestSubmitted`, including requests
  arriving while native initialization is pending. Polling, waiting, reopening
  and granting notification permission do not create another request notice.
- Notification API calls contain no request identifier, agent-provided text,
  information metadata, value, token or key. Native code chooses the fixed text
  “有新的访问请求。打开应用查看并审批。” It opens the approvals list, not a
  request-specific deep link. Native OS-generated notification IDs are random.
- macOS initially reads notification settings without prompting. Only pressing
  “启用或检查通知” may request notification authorization. Denied/unavailable
  notifications leave requests available in the app. Windows classic tray
  balloons have no permission prompt; delivery can still be suppressed by OS
  notification/quiet-time settings. A successful native API submission is not
  proof that the OS displayed it.
- The app shows tray and notification availability. A failed notification API
  submission updates that status, does not discard the request, and is not
  automatically retried. No backlog is replayed on permission enablement.

## Automated evidence (Windows host, 2026-10-16)

TDD at the previously approved public core/CLI/widget boundaries, with only the
native OS surface replaced by a supported platform fixture:

1. The first lifecycle test failed because the runtime interface did not exist;
   implementation then passed real AgentClient → AgentServer → core reads while
   hidden, full-quit connection refusal and old-session rejection in a fresh core.
2. A real CLI request arriving during delayed native startup initially produced
   no notification. Subscribing before initialization and waiting for its result
   fixed the race. The same test verifies one generic notice despite status,
   wait-timeout and reopen operations.
3. Failed native notification submission preserves the pending request and
   exposes `unavailable` status.
4. A headless widget test verifies unavailable-tray close keeps the window
   reachable, denied notifications preserve pending approvals, reopening selects
   the approvals tab, and permission is requested only by the explicit action.

`flutter analyze` and `flutter test test/` pass. Windows release compilation of
the real native runner succeeds. Compilation does not run the program, initialize
a tray icon, request permission or prove OS delivery. Widget tests and real-loopback
HTTP tests run in separate test libraries because the widget test binding replaces
HTTP globally within its test isolate.

## Acceptance still needed

This ticket remains open for real Windows and macOS acceptance. No desktop UI was
launched or operated during this implementation; no macOS toolchain is available
on this Windows host. macOS Swift code has not been compiled here.

On each platform, using fictional information only:

1. Start the release app, inspect the tray/menu-bar entry and its status. On
   macOS, verify no notification permission prompt appears before clicking the
   enable action; exercise both denied and allowed settings.
2. Approve a CLI request, close the window and confirm the same CLI can read its
   approved field. Submit another request while hidden; verify one generic notice.
   Query and wait repeatedly without another notice.
3. Open through the tray/menu bar and through the notification; confirm the same
   pending request remains and the approvals tab is selected. Reopen from the
   macOS Dock as well.
4. Use “完全退出” (and Cmd-Q on macOS), verify the existing CLI reports service
   unavailable, then restart and verify old session/grant capabilities fail.
5. On Windows, restart Explorer during a coordinated manual test and verify icon
   restoration or a visible fallback window. Exercise notification suppression
   by OS settings and unavailable-entry fallback without silently hiding the app.

Primary references:
[Windows notification area](https://learn.microsoft.com/en-us/windows/win32/shell/notification-area),
[Shell_NotifyIconW](https://learn.microsoft.com/en-us/windows/win32/api/shellapi/nf-shellapi-shell_notifyiconw),
[Apple notification authorization](https://developer.apple.com/documentation/usernotifications/asking-permission-to-use-notifications),
[Flutter app delegate](https://github.com/flutter/engine/blob/main/shell/platform/darwin/macos/framework/Headers/FlutterAppDelegate.h).
