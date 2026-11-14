#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output="${1:?Supply an output executable path under build/}"
mkdir -p "$(dirname "$output")"
swiftc -O -target arm64-apple-macos11.0 "$root/packages/info_cli/macos/ssh_session/main.swift" -o "$output"
