#!/usr/bin/env bash
# Production configuration preflight for Life OS.
#
# Validates that the operator-supplied environment (a hosted Supabase project,
# OpenRouter, APNs and the iOS Release build settings) is complete and
# well-formed *before* deploying or archiving. It never prints secret values,
# only lengths and masked prefixes. Missing optional integrations are warnings
# unless --strict is passed.
#
# Usage:
#   set -a; source .env; set +a
#   bash scripts/check_production_config.sh            # required checks only
#   bash scripts/check_production_config.sh --strict   # warnings fail too
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

STRICT=0
for arg in "$@"; do
  case "$arg" in
    --strict) STRICT=1 ;;
    -h|--help)
      sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

failures=0
warnings=0

fail() { echo "  FAIL: $*" >&2; failures=$((failures + 1)); }
warn() { echo "  WARN: $*" >&2; warnings=$((warnings + 1)); }
ok()   { echo "  ok:   $*"; }

is_placeholder() {
  case "$1" in
    ""|*localhost.invalid*|*your-*|*your_*|*example*|*placeholder*|*missing-anon-key*|*project-ref*|*1234567890*|*"<"*|*">"*) return 0 ;;
    *) return 1 ;;
  esac
}

require_https() {
  local label="$1" value="$2"
  [[ "$value" == https://* ]] || fail "$label must be an absolute https URL"
}

# Accept either a legacy three-segment JWT or a modern Supabase key prefix.
is_jwt() { [[ "$1" == eyJ*.*.* ]]; }
is_anon_key() { is_jwt "$1" || [[ "$1" == sb_publishable_* ]]; }
is_service_key() { is_jwt "$1" || [[ "$1" == sb_secret_* ]]; }

check_required() {
  local label="$1" value="$2"
  if [[ -z "${value:-}" ]]; then
    fail "$label is not set"
    return 1
  fi
  if is_placeholder "$value"; then
    fail "$label still uses a placeholder value"
    return 1
  fi
  return 0
}

echo "== Life OS production configuration preflight =="

echo "-- Supabase backend (edge functions runtime) --"
if check_required "SUPABASE_URL" "${SUPABASE_URL:-}"; then
  require_https "SUPABASE_URL" "$SUPABASE_URL"
  [[ "$SUPABASE_URL" == *.supabase.co* || "$SUPABASE_URL" == *.supabase.in* ]] \
    || warn "SUPABASE_URL does not look like a hosted Supabase project URL"
fi
if check_required "SUPABASE_ANON_KEY" "${SUPABASE_ANON_KEY:-}"; then
  is_anon_key "$SUPABASE_ANON_KEY" || fail "SUPABASE_ANON_KEY is neither a JWT nor sb_publishable_ key"
fi
if check_required "SUPABASE_SERVICE_ROLE_KEY" "${SUPABASE_SERVICE_ROLE_KEY:-}"; then
  is_service_key "$SUPABASE_SERVICE_ROLE_KEY" || fail "SUPABASE_SERVICE_ROLE_KEY is neither a JWT nor sb_secret_ key"
  [[ "${SUPABASE_SERVICE_ROLE_KEY:-}" == "${SUPABASE_ANON_KEY:-}" ]] \
    && fail "SUPABASE_SERVICE_ROLE_KEY must not equal the anon key"
fi
check_required "SUPABASE_ACCESS_TOKEN" "${SUPABASE_ACCESS_TOKEN:-}" || true

echo "-- AI provider (OpenRouter) --"
if check_required "OPENROUTER_API_KEY" "${OPENROUTER_API_KEY:-}"; then
  [[ "$OPENROUTER_API_KEY" == sk-or-* || "$OPENROUTER_API_KEY" == sk-* ]] \
    || warn "OPENROUTER_API_KEY does not look like an OpenRouter key"
fi

echo "-- Push notifications (APNs) --"
for var in APNS_TEAM_ID APNS_KEY_ID APNS_PRIVATE_KEY_P8 APNS_BUNDLE_ID; do
  value="${!var:-}"
  if [[ -z "$value" ]] || is_placeholder "$value"; then
    warn "$var is not set; push notifications will report delivery_state=not_configured"
  fi
done
if [[ -n "${APNS_PRIVATE_KEY_P8:-}" && "$APNS_PRIVATE_KEY_P8" != *"BEGIN PRIVATE KEY"* ]]; then
  fail "APNS_PRIVATE_KEY_P8 does not contain a PEM private key"
fi

echo "-- Force update / App Store metadata --"
if [[ -z "${APP_STORE_ID:-}" && -z "${APP_STORE_URL:-}" ]]; then
  warn "APP_STORE_ID and APP_STORE_URL are unset; force-update will fall back to a search URL"
else
  [[ -z "${APP_STORE_URL:-}" ]] || require_https "APP_STORE_URL" "$APP_STORE_URL"
  [[ -z "${APP_STORE_ID:-}" || "${APP_STORE_ID:-}" =~ ^[0-9]+$ ]] || fail "APP_STORE_ID must be numeric"
fi

echo "-- iOS Release build settings --"
if check_required "LIFEOS_SUPABASE_URL" "${LIFEOS_SUPABASE_URL:-}"; then
  require_https "LIFEOS_SUPABASE_URL" "$LIFEOS_SUPABASE_URL"
fi
check_required "LIFEOS_SUPABASE_ANON_KEY" "${LIFEOS_SUPABASE_ANON_KEY:-}" || true

echo "-- Optional vector memory (Pinecone) --"
if [[ -n "${PINECONE_INDEX_HOST:-}${PINECONE_API_KEY:-}" ]]; then
  check_required "PINECONE_INDEX_HOST" "${PINECONE_INDEX_HOST:-}" || true
  check_required "PINECONE_API_KEY" "${PINECONE_API_KEY:-}" || true
else
  warn "Pinecone is not configured; vector memory and retrieval stay disabled"
fi

echo "-- Cross-checks --"
if [[ -n "${LIFEOS_SUPABASE_URL:-}" && -n "${SUPABASE_URL:-}" && "$LIFEOS_SUPABASE_URL" != "$SUPABASE_URL" ]]; then
  warn "LIFEOS_SUPABASE_URL and SUPABASE_URL differ; the iOS app and edge runtime will target different projects"
fi

echo
if [[ "$failures" -gt 0 ]]; then
  echo "Production configuration INVALID: $failures failure(s), $warnings warning(s)."
  exit 1
fi
if [[ "$STRICT" == "1" && "$warnings" -gt 0 ]]; then
  echo "Production configuration INCOMPLETE (--strict): $warnings warning(s)."
  exit 1
fi
echo "Production configuration preflight passed ($warnings warning(s))."
