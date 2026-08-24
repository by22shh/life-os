#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PROJECT_PATH="ios/LifeOS.xcodeproj"
SCHEME="LifeOS"

if ! command -v xcrun >/dev/null 2>&1; then
  echo "xcrun is required but not found."
  exit 1
fi
if ! command -v xcodebuild >/dev/null 2>&1 || ! xcodebuild -version >/dev/null 2>&1; then
  echo "A full Xcode installation is required; Command Line Tools alone are insufficient."
  exit 1
fi

DEVICE_UDID="${DEVICE_UDID:-}"
if [[ -z "${DEVICE_UDID}" ]]; then
  DEVICE_UDID="$(
    xcrun xctrace list devices 2>/dev/null | awk '
      /iPhone|iPad/ && $0 !~ /Simulator/ {
        for (i = 1; i <= NF; i++) {
          if ($i ~ /^[0-9A-Fa-f-]{36}$/) {
            gsub(/[()]/, "", $i)
            print $i
            exit
          }
        }
      }
    '
  )" || true
fi

if [[ -z "${DEVICE_UDID}" ]]; then
  echo "No physical iOS device detected. Connect a device and retry."
  exit 2
fi

echo "Running real-device smoke on device id=${DEVICE_UDID}"

xcodebuild test \
  -skipMacroValidation \
  -skipPackagePluginValidation \
  -project "${PROJECT_PATH}" \
  -scheme "${SCHEME}" \
  -destination "id=${DEVICE_UDID}" \
  -only-testing:LifeOSTests/RealDeviceSmokeTests

echo "Real-device smoke tests passed."
echo "Run manual checklist: ios/PREPROD_REAL_DEVICE_SMOKE.md"
