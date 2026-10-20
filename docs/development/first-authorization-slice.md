# First local authorization slice (#2)

This slice uses fictional in-memory information only. It does not implement encryption, persistence, Codex integration, or application distribution. Never enter real personal information into this demo.

## Approved test boundary

Tests exercise the public core service use cases shared by the desktop and CLI. A small transport/CLI test and Flutter desktop approval test cover real adapters. Time is injected at the service boundary to verify expiry without waiting eight hours. Platform demonstration evidence is recorded separately from automated behavior tests.

## Local protocol

The Flutter process owns the core and binds an HTTP server exclusively to IPv4 loopback (`127.0.0.1`, port 47125 by default). Only agent operations are routed: public catalog, opening a session, requesting access, viewing request status, claiming approved access, and reading one explicitly selected field. Approval and revocation are direct in-process desktop operations, with no HTTP routes. Binding failure is shown rather than connecting to an unknown owner service.

Requests use POST with JSON, an exact loopback Host header, no Origin header, and bounded bodies. This prevents ordinary websites from using the local service through browser requests; this is not isolation from other applications running as the same OS user. The loopback transport is not a remote API. Endpoint authentication and remote transport are outside this slice.

Chat labels and purposes are untrusted display text. A fresh authorization session receives a cryptographically random secret. Request IDs are lookup handles, not credentials: status and claim require the session secret, and a request is bound to its originating session. Only a secret-bearing claim delivers a separate random grant token. Public responses never include these secrets. Approved grants save explicit item/field pairs and an absolute expiration, default eight hours. Every read checks validity and membership again. All authorization state is in memory; service shutdown and restart invalidate it.

## CLI credential delivery

The CLI is a long-running JSON-lines process. It opens a session and retains the returned secret and claimed grant tokens in process memory. Commands carry only public handles; neither command-line arguments nor JSON-lines stdout include credentials. Sensitive field values are output only for an explicit successful read. Closing the CLI discards its credential copies; a new CLI process cannot recover grants by knowing a chat label or request ID. Durable Codex chat credential association is future ticket #6.

## Development commands

Install Flutter stable with its bundled Dart SDK and the native desktop build toolchain. From `packages/info_core`, run `dart pub get` and `dart test`; from `packages/info_cli`, run `dart pub get` and `dart test`. From `apps/desktop`, run `flutter pub get`, `flutter test`, then `flutter run -d windows` (or `-d macos` on macOS).

From `packages/info_cli`, start `dart run bin/info.dart`. Send one JSON command per line:

```json
{"command":"catalog"}
{"command":"session","chatLabel":"fictional-demo"}
{"command":"request","purpose":"Use the fictional server address","fields":[{"itemId":"demo-server","fieldId":"host"},{"itemId":"demo-server","fieldId":"username"}]}
```

Use the request ID printed by the request command in subsequent `status`, `claim`, and `read` commands. In the desktop select only the address field and approve. Claim using `{"command":"claim","requestId":"RETURNED_ID"}`, then read with `{"command":"read","requestId":"RETURNED_ID","itemId":"demo-server","fieldId":"host"}`. A read of `username` must return `unauthorized`. Revoke in the desktop and retry the address read; it must return `unauthorized` too.

Each command yields one JSON result. Status strings include `ok`, `pending`, `unauthorized`, `invalid_request`, and `service_unavailable`; additional terminal request states will extend this contract in #4. Invalid input does not echo submitted values. The CLI does not retry a failed request automatically. Its default endpoint is loopback port 47125; `--port NUMBER` selects another local port without accepting remote hosts.

## Verification evidence — 2026-10-16

Verified on Windows 11 x64 with Flutter 3.47.7 / Dart 3.13.5 and Visual Studio 2022 Build Tools 17.14.38.

- Core: `cd packages/info_core; dart analyze; dart test` — analyzer clean; 8 public-use-case/transport tests passed. Incremental red → green cycles exercised catalog privacy, pending/forged claims, field-limited approval, revocation, eight-hour expiry, service restart, owner inspection, and loopback transport. Transport test verifies no approval/revocation route and rejection of browser Origin requests.
- CLI: `cd packages/info_cli; dart analyze; dart test` — analyzer clean; 1 separate-process test passed. The test runs the real CLI, checks pending/claim/read/revoke results, secret-free command output and stderr, and service-unavailable behavior.
- Desktop: `cd apps/desktop; flutter analyze; flutter test` — analyzer clean; 1 widget workflow test passed.
- Native desktop + CLI: from `apps/desktop`, `flutter test integration_test/desktop_cli_test.dart -d windows --dart-define=DART_EXECUTABLE=C:/Users/Todoki/.local/share/flutter/bin/cache/dart-sdk/bin/dart.exe --dart-define=CLI_DIRECTORY=C:/Project/network_config/info-manage-worktrees/ticket-2/packages/info_cli` — 1 test passed in the native Windows runner. This invokes the real desktop main, spawns an independent CLI, submits a request, unchecks username in the desktop, approves host, verifies host success and username denial, revokes through the desktop, and verifies host denial. Replace the two absolute paths for your checkout/SDK.
- Release: `cd apps/desktop; flutter build windows --release` — succeeded. Output: `apps/desktop/build/windows/x64/runner/Release/info_desktop.exe` (keep its adjacent DLLs and data directory).

The macOS runner and release network-server entitlement are included but were not executed on a Mac. This evidence does not establish macOS distribution, encrypted storage, background tray behavior, or Codex integration. Those remain separate tickets.
