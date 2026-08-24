#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

DEFAULT_TMP_ROOT="${TMPDIR:-/tmp}"
DEFAULT_TMP_ROOT="${DEFAULT_TMP_ROOT%/}"
ARTIFACTS_ROOT="${LIFEOS_ARTIFACTS_DIR:-${DEFAULT_TMP_ROOT}/life-os}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-${ARTIFACTS_ROOT}/derived-data/release-gate-local-${TIMESTAMP}}"

mkdir -p "$(dirname "$DERIVED_DATA_PATH")"
echo "DerivedData path: $DERIVED_DATA_PATH"

echo "== Deno: fmt/lint/check/test/coverage =="
deno fmt --check supabase/functions
deno lint supabase/functions
find supabase/functions -type f -name '*.ts' -print0 | xargs -0 deno check
rm -rf .codex-tmp/supabase-deno-coverage
deno test -A --coverage=.codex-tmp/supabase-deno-coverage supabase/functions/tests
deno coverage .codex-tmp/supabase-deno-coverage

echo "== Supabase edge e2e =="
bash scripts/run_supabase_edge_e2e.sh

echo "== Supabase edge load =="
bash scripts/run_supabase_edge_load.sh

echo "== Pre-prod security pass =="
SECURITY_PASS_SKIP_EDGE_E2E=1 bash scripts/run_preprod_security_pass.sh

echo "== iOS release config guard =="
bash scripts/check_ios_release_config.sh

if [[ "${RUN_EDGE_SOAK:-0}" == "1" ]]; then
  echo "== Supabase edge soak =="
  bash scripts/run_supabase_edge_soak.sh
fi

SIM_NAME="${SIM_NAME:-$(xcrun simctl list devices available | awk -F '[()]' '/iPhone/ {name=$1; gsub(/^[[:space:]]+|[[:space:]]+$/, "", name); print name; exit}')}"
if [[ -z "$SIM_NAME" ]]; then
  echo "No available iPhone simulator found"
  exit 1
fi

echo "== iOS unit tests ($SIM_NAME) =="
xcodebuild test \
  -skipMacroValidation \
  -skipPackagePluginValidation \
  -project ios/LifeOS.xcodeproj \
  -scheme LifeOS \
  -destination "platform=iOS Simulator,name=${SIM_NAME}" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -only-testing:LifeOSTests \
  -only-testing:LifeOSWidgetsTests

echo "== iOS UI tests ($SIM_NAME) =="
xcodebuild test \
  -skipMacroValidation \
  -skipPackagePluginValidation \
  -project ios/LifeOS.xcodeproj \
  -scheme LifeOS \
  -destination "platform=iOS Simulator,name=${SIM_NAME}" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -only-testing:LifeOSUITests

echo "== iOS performance hard-gates ($SIM_NAME) =="
DERIVED_DATA_PATH="$DERIVED_DATA_PATH" bash scripts/run_ios_performance_hard_gates.sh

echo "== iOS analyze ($SIM_NAME) =="
xcodebuild analyze \
  -skipMacroValidation \
  -skipPackagePluginValidation \
  -project ios/LifeOS.xcodeproj \
  -scheme LifeOS \
  -destination "platform=iOS Simulator,name=${SIM_NAME}" \
  -derivedDataPath "$DERIVED_DATA_PATH"

echo "== watchOS build =="
xcodebuild build \
  -skipMacroValidation \
  -skipPackagePluginValidation \
  -project ios/LifeOS.xcodeproj \
  -scheme LifeOSWatch \
  -destination "generic/platform=watchOS Simulator" \
  -derivedDataPath "$DERIVED_DATA_PATH"

WATCH_NAME="${WATCH_NAME:-$(xcrun simctl list devices available | awk -F '[()]' '/Apple Watch/ {name=$1; gsub(/^[[:space:]]+|[[:space:]]+$/, "", name); print name; exit}')}"
if [[ -z "$WATCH_NAME" ]]; then
  echo "No available Apple Watch simulator found"
  exit 1
fi

echo "== watchOS tests ($WATCH_NAME) =="
xcodebuild test \
  -skipMacroValidation \
  -skipPackagePluginValidation \
  -project ios/LifeOS.xcodeproj \
  -scheme LifeOSWatch \
  -destination "platform=watchOS Simulator,name=${WATCH_NAME}" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -only-testing:LifeOSWatchTests

echo "Release gate local run passed."
