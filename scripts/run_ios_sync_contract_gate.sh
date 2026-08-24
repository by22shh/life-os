#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

print_help() {
  cat <<'EOF'
Usage:
  bash scripts/run_ios_sync_contract_gate.sh [--refresh-fixtures] [--user-id <uuid>] [--allow-missing]

Options:
  --refresh-fixtures  Refresh Sync contract JSON fixtures before running tests.
  --user-id <uuid>    User id filter passed to fixture refresh script.
  --allow-missing     Pass --allow-missing to fixture refresh script.
  -h, --help          Show this help message.

Required env for --refresh-fixtures:
  SUPABASE_URL
  SUPABASE_SERVICE_ROLE_KEY (or SUPABASE_ANON_KEY)
EOF
}

REFRESH_FIXTURES=0
ALLOW_MISSING=0
USER_ID="${SYNC_FIXTURE_USER_ID:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --refresh-fixtures)
      REFRESH_FIXTURES=1
      shift
      ;;
    --user-id)
      if [[ $# -lt 2 ]]; then
        echo "error: --user-id requires a value" >&2
        exit 2
      fi
      USER_ID="$2"
      shift 2
      ;;
    --allow-missing)
      ALLOW_MISSING=1
      shift
      ;;
    -h|--help)
      print_help
      exit 0
      ;;
    *)
      echo "error: unknown argument '$1'" >&2
      print_help >&2
      exit 2
      ;;
  esac
done

if [[ "$REFRESH_FIXTURES" -eq 1 ]]; then
  refresh_cmd=(python3 scripts/refresh_sync_contract_fixtures.py)
  if [[ -n "$USER_ID" ]]; then
    refresh_cmd+=(--user-id "$USER_ID")
  fi
  if [[ "$ALLOW_MISSING" -eq 1 ]]; then
    refresh_cmd+=(--allow-missing)
  fi

  echo "== Refreshing sync contract fixtures =="
  "${refresh_cmd[@]}"
fi

SIM_NAME="${SIM_NAME:-$(xcrun simctl list devices available | awk -F '[()]' '/iPhone/ {name=$1; gsub(/^[[:space:]]+|[[:space:]]+$/, "", name); print name; exit}')}"
if [[ -z "$SIM_NAME" ]]; then
  echo "No available iPhone simulator found"
  exit 1
fi

EXTRA_ARGS=()
if [[ -n "${DERIVED_DATA_PATH:-}" ]]; then
  EXTRA_ARGS+=(-derivedDataPath "$DERIVED_DATA_PATH")
fi

echo "== Running sync contract gate on: $SIM_NAME =="
xcodebuild test \
  -skipMacroValidation \
  -skipPackagePluginValidation \
  -project ios/LifeOS.xcodeproj \
  -scheme LifeOS \
  -destination "platform=iOS Simulator,name=${SIM_NAME}" \
  "${EXTRA_ARGS[@]}" \
  -only-testing:LifeOSTests/SyncTableRegistryTests \
  -only-testing:LifeOSTests/SyncModelContractTests \
  -only-testing:LifeOSTests/SyncEnginePerfBenchTests

echo "Sync contract gate passed."
