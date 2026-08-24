#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

run_with_timeout() {
  local timeout_seconds="$1"
  shift
  local label="$1"
  shift

  local safe_label="${label//[^A-Za-z0-9_.-]/_}"
  local log_file="${TMPDIR:-/tmp}/lifeos_${safe_label}_$$.log"

  "$@" >"$log_file" 2>&1 &
  local cmd_pid=$!
  local elapsed=0

  while kill -0 "$cmd_pid" 2>/dev/null; do
    if (( elapsed >= timeout_seconds )); then
      echo "Timed out after ${timeout_seconds}s: ${label}" >&2
      echo "--- Last output (${label}) ---" >&2
      tail -n 40 "$log_file" >&2 || true
      kill -TERM "$cmd_pid" 2>/dev/null || true
      sleep 1
      kill -KILL "$cmd_pid" 2>/dev/null || true
      wait "$cmd_pid" 2>/dev/null || true
      rm -f "$log_file"
      return 124
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  local status=0
  wait "$cmd_pid" || status=$?
  cat "$log_file"
  rm -f "$log_file"
  return "$status"
}

cleanup() {
  run_with_timeout 45 "supabase stop (cleanup)" \
    supabase stop --workdir . --no-backup --yes >/dev/null 2>&1 || true
}

require_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "Docker CLI is required for local Supabase tests but was not found in PATH." >&2
    exit 1
  fi

  if ! run_with_timeout 15 "docker ps" docker ps >/dev/null; then
    echo "Docker daemon is unavailable. Start Docker Desktop (or the Docker service) and retry." >&2
    exit 1
  fi
}

require_docker

# Stop only this project stack to avoid impacting other local Supabase workspaces.
run_with_timeout 45 "supabase stop (preflight)" \
  supabase stop --workdir . --no-backup --yes >/dev/null 2>&1 || true
run_with_timeout 240 "supabase start" \
  supabase start --workdir . --exclude edge-runtime
trap cleanup EXIT

run_with_timeout 180 "supabase db reset" \
  supabase db reset --workdir . --no-seed --yes

run_with_timeout 45 "supabase table grants" \
  bash scripts/check_supabase_table_grants.sh

if ! STATUS_ENV="$(run_with_timeout 45 "supabase status env" supabase status -o env --workdir .)"; then
  echo "Failed to get Supabase status env output"
  exit 1
fi
while IFS='=' read -r key value; do
  [[ "${key:-}" =~ ^[A-Z0-9_]+$ ]] || continue
  [[ -z "${key:-}" ]] && continue
  value="${value%\"}"
  value="${value#\"}"
  export "$key=$value"
done <<< "$STATUS_ENV"

if [[ -z "${API_URL:-}" ]]; then
  echo "API_URL is missing from supabase status output"
  exit 1
fi

export SUPABASE_URL="$API_URL"
export SUPABASE_ANON_KEY="${SUPABASE_ANON_KEY:-${ANON_KEY:-}}"
export SUPABASE_SERVICE_ROLE_KEY="${SUPABASE_SERVICE_ROLE_KEY:-${SERVICE_ROLE_KEY:-}}"
export FOODS_PROVIDER_ENABLED="${FOODS_PROVIDER_ENABLED:-0}"

if [[ -z "${SUPABASE_ANON_KEY:-}" || -z "${SUPABASE_SERVICE_ROLE_KEY:-}" ]]; then
  echo "SUPABASE_ANON_KEY or SUPABASE_SERVICE_ROLE_KEY missing"
  exit 1
fi

deno run -A supabase/functions/tests/edge_local_e2e.ts
