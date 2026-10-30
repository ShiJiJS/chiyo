#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
flutter_root="$project_root/.tools/flutter"
flutter_revision=abaf9c523780a608bd46686fd5e53740a07077f8
export PUB_CACHE="$project_root/.cache/pub"
export FLUTTER_SUPPRESS_ANALYTICS=true
export DART_SUPPRESS_ANALYTICS=true
export PATH="$flutter_root/bin:$PATH"
# Keep the selected Apple toolchain scoped to this project. An explicit caller
# override takes precedence, including when several Xcode versions are present.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

usage() {
  cat <<'EOF'
Usage: ./scripts/dev-macos.sh <command> [arguments]
  setup         Fetch the pinned SDK, macOS artifacts and locked dependencies
  doctor        Show Flutter and native toolchain diagnostics
  check         Analyze and test all Dart packages and desktop widgets
  build         Compile release with fixed GH/AWS tools (requires full Xcode)
                Optional --with-focused-fill-candidate embeds a disabled XPC candidate
  run           Open the macOS app in debug mode (requires full Xcode)
  preview       Run the isolated Zhiyu UI with its own application identity
  preview-check [--library] Run the sandboxed native Zhiyu UI integration check
  preview-profile-check <new-dir> [--runs 1..3] [--library] Check AOT, then restore preview
  preview-lifecycle <new-dir> Check native close/quit and restore the UI preview
  bundle <dir>  Compile CLI/hook installation materials into a NEW directory
  flutter ...   Run the project Flutter SDK in your current working directory
  dart ...      Run the bundled Dart SDK in your current working directory
EOF
}

require_sdk() {
  if [[ ! -x "$flutter_root/bin/flutter" ]]; then
    echo 'SDK missing. Run ./scripts/dev-macos.sh setup first.' >&2
    exit 1
  fi
  local actual_revision
  actual_revision="$(git -C "$flutter_root" rev-parse HEAD)"
  if [[ "$actual_revision" != "$flutter_revision" ]]; then
    echo "SDK revision mismatch: expected $flutter_revision, got $actual_revision" >&2
    exit 1
  fi
}

require_xcode() {
  if ! xcodebuild -version >/dev/null 2>&1; then
    echo 'Full Xcode is required. Install and open Xcode, then select it:' >&2
    echo '  sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer' >&2
    echo '  sudo xcodebuild -runFirstLaunch' >&2
    exit 1
  fi
}

get_dependencies() {
  local package
  for package in info_core info_cli info_storage; do
    (cd "$project_root/packages/$package" && dart pub get --enforce-lockfile)
  done
  (cd "$project_root/apps/desktop" && flutter pub get --enforce-lockfile)
}

command_name="${1:-help}"
if [[ $# -gt 0 ]]; then shift; fi
case "$command_name" in
  help|-h|--help) usage; exit 0 ;;
esac
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'This launcher is for macOS.' >&2
  exit 1
fi
# macOS's default /var temporary path resolves through /private/var. Use a
# canonical, project-local path so native fixture identity checks agree without
# weakening their symlink protections, and keep test materials in this checkout.
mkdir -p "$project_root/.cache/tmp"
export TMPDIR="$(cd "$project_root/.cache/tmp" && pwd -P)/"

case "$command_name" in
  setup)
    mkdir -p "$project_root/.tools" "$PUB_CACHE"
    # Keep machine-local SDKs and caches out of all repository branches.
    exclude_file="$(git -C "$project_root" rev-parse --absolute-git-dir)/info/exclude"
    for excluded in /.tools/ /.cache/ /.downloads/; do
      if ! grep -Fxq "$excluded" "$exclude_file"; then
        printf '%s\n' "$excluded" >> "$exclude_file"
      fi
    done
    if [[ ! -d "$flutter_root" ]]; then
      git clone --depth 1 --branch 3.47.7 https://github.com/flutter/flutter.git "$flutter_root"
    fi
    require_sdk
    flutter --version
    flutter precache --macos
    get_dependencies
    ;;
  doctor)
    require_sdk
    flutter doctor -v
    ;;
  check)
    require_sdk
    get_dependencies
    checks_failed=0
    for package in info_core info_cli info_storage; do
      if (
        cd "$project_root/packages/$package" &&
        dart analyze --fatal-infos &&
        dart test
      ); then
        echo "$package checks passed."
      else
        checks_failed=1
        echo "$package checks failed; continuing with the other modules." >&2
      fi
    done
    if (
      cd "$project_root/apps/desktop" &&
      flutter analyze --fatal-infos --no-pub &&
      flutter test --no-pub test/
    ); then
      echo 'Desktop checks passed.'
    else
      checks_failed=1
      echo 'Desktop checks failed.' >&2
    fi
    exit "$checks_failed"
    ;;
  preview-profile-check)
    require_sdk
    require_xcode
    python3 "$project_root/scripts/qa/run-zhiyu-profile.py" "$@"
    ;;
  preview|preview-check|preview-lifecycle)
    require_sdk
    require_xcode
    export FLUTTER_MACOS_ARM64_ONLY=true
    # Xcode's scoped override also applies when Flutter tests build a generated
    # listener.dart entry point. Never edit the shared generated xcconfig.
    export XCODE_XCCONFIG_FILE="$project_root/apps/desktop/macos/Runner/Configs/Preview.xcconfig"
    if [[ "$command_name" == preview-lifecycle ]]; then
      if [[ $# -ne 1 ]]; then usage >&2; exit 64; fi
      case "$1" in
        /*) lifecycle_output="$1" ;;
        *) lifecycle_output="$PWD/$1" ;;
      esac
    fi
    cd "$project_root/apps/desktop"
    if [[ "$command_name" == preview ]]; then
      flutter run -d macos --no-pub --target lib/preview_main.dart "$@"
    elif [[ "$command_name" == preview-check ]]; then
      preview_test=integration_test/zhiyu_foundation_native_test.dart
      if [[ "${1:-}" == --library ]]; then
        preview_test=integration_test/zhiyu_library_native_test.dart
        shift
      fi
      flutter test --no-pub -d macos "$preview_test" "$@"
    else
      flutter build macos --debug --no-pub --target tool/zhiyu_preview_lifecycle.dart
      python3 "$project_root/scripts/qa/zhiyu-preview-lifecycle.py" \
        --app "$project_root/apps/desktop/build/macos/Build/Products/Debug/info_desktop.app" \
        --output "$lifecycle_output"
      flutter build macos --debug --no-pub --target lib/preview_main.dart
    fi
    ;;
  build|run)
    require_sdk
    require_xcode
    if [[ "$(uname -m)" != arm64 ]]; then
      echo 'The current Mac application and bundled worker support ARM64 only.' >&2
      exit 1
    fi
    # Scope architecture selection to this invocation, not Flutter's global
    # preferences. The shipped worker and Dart CLI are ARM64 as well.
    export FLUTTER_MACOS_ARM64_ONLY=true
    with_focused_fill_candidate=false
    flutter_arguments=()
    for argument in "$@"; do
      if [[ "$argument" == --with-focused-fill-candidate ]]; then
        if [[ "$command_name" != build ]]; then
          echo 'The focused-fill candidate option is available for build only.' >&2
          exit 64
        fi
        with_focused_fill_candidate=true
      else
        flutter_arguments+=("$argument")
      fi
    done
    # macOS Bash 3.2 treats an empty array as unset with nounset. Preserve an
    # empty argument list without passing an extra empty string to Flutter.
    set -- ${flutter_arguments[@]+"${flutter_arguments[@]}"}
    cd "$project_root/apps/desktop"
    if [[ "$command_name" == build ]]; then
      python3 "$project_root/scripts/build-macos-release.py" "$flutter_root" "$@"
      python3 "$project_root/scripts/bundle-macos-tools.py" \
        "$project_root/apps/desktop/build/macos/Build/Products/Release/info_desktop.app"
      if [[ "$with_focused_fill_candidate" == true ]]; then
        python3 "$project_root/scripts/bundle-macos-focused-helper.py" \
          "$project_root/apps/desktop/build/macos/Build/Products/Release/info_desktop.app" \
          --with-focused-fill-candidate
      else
        python3 "$project_root/scripts/bundle-macos-focused-helper.py" \
          "$project_root/apps/desktop/build/macos/Build/Products/Release/info_desktop.app"
      fi
    else
      flutter run -d macos "$@"
    fi
    ;;
  bundle)
    require_sdk
    if [[ $# -ne 1 ]]; then usage >&2; exit 64; fi
    # Resolve relative output paths against the caller's working directory.
    case "$1" in
      /*) bundle_destination="$1" ;;
      *) bundle_destination="$PWD/$1" ;;
    esac
    cd "$project_root/packages/info_cli"
    dart run tool/prepare_codex.dart "$bundle_destination"
    ;;
  flutter|dart)
    require_sdk
    "$flutter_root/bin/$command_name" "$@"
    ;;
  *) usage >&2; exit 64 ;;
esac
