#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if ! command -v xcodebuild >/dev/null 2>&1 || ! xcodebuild -version >/dev/null 2>&1; then
  echo "A full Xcode installation is required for the live-backend UI smoke." >&2
  exit 1
fi

LIVE_URL="${LIFEOS_UI_TEST_LIVE_SUPABASE_URL:-}"
LIVE_ANON_KEY="${LIFEOS_UI_TEST_LIVE_SUPABASE_ANON_KEY:-}"

if [[ -z "$LIVE_URL" || -z "$LIVE_ANON_KEY" ]]; then
  if ! command -v supabase >/dev/null 2>&1; then
    echo "Set LIFEOS_UI_TEST_LIVE_SUPABASE_URL and LIFEOS_UI_TEST_LIVE_SUPABASE_ANON_KEY, or start local Supabase." >&2
    exit 1
  fi

  STATUS_ENV="$(supabase status -o env --workdir .)"
  while IFS='=' read -r key value; do
    [[ "${key:-}" =~ ^[A-Z0-9_]+$ ]] || continue
    value="${value%\"}"
    value="${value#\"}"
    case "$key" in
      API_URL) LIVE_URL="$value" ;;
      ANON_KEY) LIVE_ANON_KEY="$value" ;;
    esac
  done <<< "$STATUS_ENV"
fi

if [[ -z "$LIVE_URL" || -z "$LIVE_ANON_KEY" ]]; then
  echo "The live Supabase URL or anon key is missing." >&2
  exit 1
fi

SIM_NAME="${SIM_NAME:-$(xcrun simctl list devices available | awk -F '[()]' '/iPhone/ {name=$1; gsub(/^[[:space:]]+|[[:space:]]+$/, "", name); print name; exit}')}"
if [[ -z "$SIM_NAME" ]]; then
  echo "No available iPhone simulator found." >&2
  exit 1
fi

DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-${TMPDIR:-/tmp}/lifeos-live-backend-derived-data}"

echo "Running live-backend UI smoke on ${SIM_NAME} against ${LIVE_URL}"
LIFEOS_UI_TEST_LIVE_BACKEND=1 \
LIFEOS_UI_TEST_LIVE_SUPABASE_URL="$LIVE_URL" \
LIFEOS_UI_TEST_LIVE_SUPABASE_ANON_KEY="$LIVE_ANON_KEY" \
TEST_RUNNER_LIFEOS_UI_TEST_LIVE_BACKEND=1 \
TEST_RUNNER_LIFEOS_UI_TEST_LIVE_SUPABASE_URL="$LIVE_URL" \
TEST_RUNNER_LIFEOS_UI_TEST_LIVE_SUPABASE_ANON_KEY="$LIVE_ANON_KEY" \
xcodebuild test \
  -skipMacroValidation \
  -skipPackagePluginValidation \
  -project ios/LifeOS.xcodeproj \
  -scheme LifeOS \
  -destination "platform=iOS Simulator,name=${SIM_NAME}" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -only-testing:LifeOSUITests/EndToEndScenariosUITests/testLiveBackendAnonymousBootstrapSmoke

echo "Live-backend UI smoke passed."
