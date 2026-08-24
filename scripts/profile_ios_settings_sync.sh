#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PROFILE_DURATION_SECONDS="${PROFILE_DURATION_SECONDS:-20}"
PROFILE_CAPTURE_DELAY_SECONDS="${PROFILE_CAPTURE_DELAY_SECONDS:-${PROFILE_START_DELAY_SECONDS:-2}}"
PROFILE_APP_WAIT_SECONDS="${PROFILE_APP_WAIT_SECONDS:-600}"
DEFAULT_TMP_ROOT="${TMPDIR:-/tmp}"
DEFAULT_TMP_ROOT="${DEFAULT_TMP_ROOT%/}"
ARTIFACTS_ROOT="${LIFEOS_ARTIFACTS_DIR:-${DEFAULT_TMP_ROOT}/life-os}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-${ARTIFACTS_ROOT}/derived-data/profile-settings-sync-${TIMESTAMP}}"
OUTPUT_DIR="${OUTPUT_DIR:-${ARTIFACTS_ROOT}/profiles/${TIMESTAMP}}"

mkdir -p "$(dirname "$DERIVED_DATA_PATH")"
mkdir -p "$OUTPUT_DIR"

SIM_LINE="$(xcrun simctl list devices available | awk '/iPhone/ {print; exit}')"
SIM_NAME="${SIM_NAME:-$(echo "$SIM_LINE" | awk -F '[()]' '{name=$1; gsub(/^[[:space:]]+|[[:space:]]+$/, "", name); print name}')}"
SIM_UDID="${SIM_UDID:-$(echo "$SIM_LINE" | awk -F '[()]' '{id=$2; gsub(/^[[:space:]]+|[[:space:]]+$/, "", id); print id}')}"

if [[ -z "$SIM_NAME" || -z "$SIM_UDID" ]]; then
  echo "No available iPhone simulator found."
  exit 1
fi

echo "Using simulator: $SIM_NAME"
echo "Using simulator UDID: $SIM_UDID"
echo "DerivedData path: $DERIVED_DATA_PATH"
echo "Output directory: $OUTPUT_DIR"

CURRENT_UI_TEST_PID=""
LIFEOS_CAPTURE_PID=""
cleanup() {
  if [[ -n "${CURRENT_UI_TEST_PID:-}" ]] && kill -0 "$CURRENT_UI_TEST_PID" >/dev/null 2>&1; then
    kill "$CURRENT_UI_TEST_PID" >/dev/null 2>&1 || true
    wait "$CURRENT_UI_TEST_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

TIME_TRACE="$OUTPUT_DIR/time_profiler_settings_sync.trace"
ALLOC_TRACE="$OUTPUT_DIR/allocations_settings_sync.trace"
TIME_UI_LOG="$OUTPUT_DIR/settings_sync_ui_time_profiler.log"
TIME_UI_RESULT_BUNDLE="$OUTPUT_DIR/settings_sync_ui_time_profiler.xcresult"
ALLOC_UI_LOG="$OUTPUT_DIR/settings_sync_ui_allocations.log"
ALLOC_UI_RESULT_BUNDLE="$OUTPUT_DIR/settings_sync_ui_allocations.xcresult"

run_ui_flow() {
  local label="$1"
  local log_path="$2"
  local result_bundle="$3"

  rm -rf "$result_bundle"
  echo "Starting Settings/Sync UI flow for ${label}..."
  xcodebuild test \
    -skipMacroValidation \
    -skipPackagePluginValidation \
    -project ios/LifeOS.xcodeproj \
    -scheme LifeOS \
    -destination "platform=iOS Simulator,id=${SIM_UDID}" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -resultBundlePath "$result_bundle" \
    -only-testing:LifeOSUITests/EndToEndScenariosUITests/testSyncConflictScenario \
    -only-testing:LifeOSUITests/EndToEndScenariosUITests/testNotificationRulesScenario \
    >"$log_path" 2>&1 &

  CURRENT_UI_TEST_PID=$!
}

lifeos_process_pid() {
  ps -axo pid=,command= | awk -v udid="$SIM_UDID" \
    '$0 ~ "/CoreSimulator/Devices/" udid "/" && $0 ~ /\/LifeOS\.app\/LifeOS([[:space:]]|$)/ {print $1; exit}' || true
}

ensure_ui_flow_is_running() {
  local label="$1"
  local log_path="$2"

  if kill -0 "$CURRENT_UI_TEST_PID" >/dev/null 2>&1; then
    return
  fi

  echo "UI test finished before ${label} capture could start."
  echo "UI test log: $log_path"
  wait "$CURRENT_UI_TEST_PID"
  exit 1
}

wait_for_lifeos_process() {
  local label="$1"
  local log_path="$2"
  local waited=0

  while (( waited < PROFILE_APP_WAIT_SECONDS )); do
    local app_pid
    app_pid="$(lifeos_process_pid)"
    if [[ -n "$app_pid" ]]; then
      LIFEOS_CAPTURE_PID="$app_pid"
      echo "LifeOS process detected for ${label}: pid ${app_pid}"
      return
    fi

    ensure_ui_flow_is_running "$label" "$log_path"
    sleep 1
    waited=$((waited + 1))
  done

  echo "Timed out waiting ${PROFILE_APP_WAIT_SECONDS}s for LifeOS process before ${label} capture."
  echo "UI test log: $log_path"
  exit 1
}

finish_ui_flow() {
  local label="$1"
  local log_path="$2"

  if wait "$CURRENT_UI_TEST_PID"; then
    CURRENT_UI_TEST_PID=""
    echo "Settings/Sync UI flow completed for ${label}."
    return
  fi

  local status=$?
  CURRENT_UI_TEST_PID=""
  echo "Settings/Sync UI flow failed for ${label}; log: $log_path"
  exit "$status"
}

write_result_summary() {
  local result_bundle="$1"
  local summary_path="${result_bundle%.xcresult}.summary.json"

  if [[ -d "$result_bundle" ]]; then
    xcrun xcresulttool get test-results summary --path "$result_bundle" >"$summary_path" || true
  fi
}

run_ui_flow "Time Profiler" "$TIME_UI_LOG" "$TIME_UI_RESULT_BUNDLE"
wait_for_lifeos_process "Time Profiler" "$TIME_UI_LOG"
echo "Waiting ${PROFILE_CAPTURE_DELAY_SECONDS}s before Time Profiler capture..."
sleep "$PROFILE_CAPTURE_DELAY_SECONDS"
ensure_ui_flow_is_running "Time Profiler" "$TIME_UI_LOG"

echo "Recording Time Profiler (${PROFILE_DURATION_SECONDS}s, process name LifeOS on ${SIM_NAME})..."
xcrun xctrace record \
  --quiet \
  --template "Time Profiler" \
  --device "$SIM_UDID" \
  --attach "LifeOS" \
  --time-limit "${PROFILE_DURATION_SECONDS}s" \
  --output "$TIME_TRACE"
finish_ui_flow "Time Profiler" "$TIME_UI_LOG"
write_result_summary "$TIME_UI_RESULT_BUNDLE"

run_ui_flow "Allocations" "$ALLOC_UI_LOG" "$ALLOC_UI_RESULT_BUNDLE"
wait_for_lifeos_process "Allocations" "$ALLOC_UI_LOG"
echo "Waiting ${PROFILE_CAPTURE_DELAY_SECONDS}s before Allocations capture..."
sleep "$PROFILE_CAPTURE_DELAY_SECONDS"
ensure_ui_flow_is_running "Allocations" "$ALLOC_UI_LOG"

echo "Recording Allocations (${PROFILE_DURATION_SECONDS}s, process name LifeOS)..."
xcrun xctrace record \
  --quiet \
  --template "Allocations" \
  --device "$SIM_UDID" \
  --attach "LifeOS" \
  --time-limit "${PROFILE_DURATION_SECONDS}s" \
  --output "$ALLOC_TRACE"
finish_ui_flow "Allocations" "$ALLOC_UI_LOG"
write_result_summary "$ALLOC_UI_RESULT_BUNDLE"
trap - EXIT

echo "Profiling completed."
echo "Time Profiler UI result bundle: $TIME_UI_RESULT_BUNDLE"
echo "Allocations UI result bundle: $ALLOC_UI_RESULT_BUNDLE"
echo "Time Profiler trace: $TIME_TRACE"
echo "Allocations trace: $ALLOC_TRACE"
