#!/usr/bin/env bash
set -euo pipefail

# Invoked by the macOS Runner target, before Xcode signs the outer application.
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
: "${FLUTTER_ROOT:?Xcode must provide the selected Flutter SDK}"
: "${TARGET_BUILD_DIR:?Xcode build directory missing}"
: "${EXECUTABLE_FOLDER_PATH:?Xcode executable directory missing}"
if [[ "$(uname -m)" != arm64 ]]; then
  echo 'The macOS runtime worker currently supports ARM64 builds only.' >&2
  exit 1
fi
worker_output="$TARGET_BUILD_DIR/$EXECUTABLE_FOLDER_PATH/info-runtime-worker"
mkdir -p "$(dirname "$worker_output")"
(
  cd "$project_root/packages/info_cli"
  "$FLUTTER_ROOT/bin/dart" compile exe --target-os macos --target-arch arm64 \
    bin/runtime_worker.dart -o "$worker_output"
)
if [[ "${CODE_SIGNING_ALLOWED:-YES}" != NO ]]; then
  /usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" \
    --entitlements "$project_root/apps/desktop/macos/Runner/Worker.entitlements" \
    "$worker_output"
fi
