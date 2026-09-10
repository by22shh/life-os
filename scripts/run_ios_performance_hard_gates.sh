#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

SIM_NAME="${SIM_NAME:-$(xcrun simctl list devices available | awk -F '[()]' '/iPhone/ {name=$1; gsub(/^[[:space:]]+|[[:space:]]+$/, "", name); print name; exit}')}"
if [[ -z "$SIM_NAME" ]]; then
  echo "No available iPhone simulator found"
  exit 1
fi

XCODEBUILD_ARGS=(
  -skipMacroValidation
  -skipPackagePluginValidation
  -project ios/LifeOS.xcodeproj
  -scheme LifeOS
  -destination "platform=iOS Simulator,name=${SIM_NAME}"
)
if [[ -n "${DERIVED_DATA_PATH:-}" ]]; then
  XCODEBUILD_ARGS+=(-derivedDataPath "$DERIVED_DATA_PATH")
fi
XCODEBUILD_ARGS+=(
  -only-testing:LifeOSTests/PerformanceBudgetTests
  -only-testing:LifeOSTests/PerformanceHardGateTests
  -only-testing:LifeOSUITests/PerformanceHardGateUITests
)

export LIFEOS_STARTUP_BUDGET_MS="${LIFEOS_STARTUP_BUDGET_MS:-4000}"
export LIFEOS_SYNC_LATENCY_BUDGET_MS="${LIFEOS_SYNC_LATENCY_BUDGET_MS:-2500}"
export LIFEOS_SYNC_MEMORY_BUDGET_MB="${LIFEOS_SYNC_MEMORY_BUDGET_MB:-450}"
export LIFEOS_SYNC_MEMORY_GROWTH_BUDGET_MB="${LIFEOS_SYNC_MEMORY_GROWTH_BUDGET_MB:-64}"
export LIFEOS_PERFORMANCE_HARD_GATES=1

# xcodebuild(1), ENVIRONMENT: only TEST_RUNNER_<VAR> explicitly forwards
# a shell variable to every test runner, stripping the TEST_RUNNER_ prefix.
# Both the unit-test host and UI-test runner read these LIFEOS_* variables.
export TEST_RUNNER_LIFEOS_STARTUP_BUDGET_MS="$LIFEOS_STARTUP_BUDGET_MS"
export TEST_RUNNER_LIFEOS_SYNC_LATENCY_BUDGET_MS="$LIFEOS_SYNC_LATENCY_BUDGET_MS"
export TEST_RUNNER_LIFEOS_SYNC_MEMORY_BUDGET_MB="$LIFEOS_SYNC_MEMORY_BUDGET_MB"
export TEST_RUNNER_LIFEOS_SYNC_MEMORY_GROWTH_BUDGET_MB="$LIFEOS_SYNC_MEMORY_GROWTH_BUDGET_MB"
export TEST_RUNNER_LIFEOS_PERFORMANCE_HARD_GATES="$LIFEOS_PERFORMANCE_HARD_GATES"

echo "Running iOS performance hard-gates on simulator: $SIM_NAME"
echo "Budgets: startup=${LIFEOS_STARTUP_BUDGET_MS}ms sync_latency=${LIFEOS_SYNC_LATENCY_BUDGET_MS}ms sync_memory=${LIFEOS_SYNC_MEMORY_BUDGET_MB}MB sync_memory_growth=${LIFEOS_SYNC_MEMORY_GROWTH_BUDGET_MB}MB"

xcodebuild test "${XCODEBUILD_ARGS[@]}"

echo "iOS performance hard-gates passed."
