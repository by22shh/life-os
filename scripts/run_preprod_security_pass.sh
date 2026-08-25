#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "== Security pass: secret/key exposure scan =="
if rg -n \
  --glob '!ios/build/**' \
  --glob '!output/**' \
  --glob '!tmp/**' \
  --glob '!.git/**' \
  --glob '!.codex-tmp/**' \
  --glob '!.coverage/**' \
  --glob '!.deno-coverage-functions*/**' \
  --glob '!.serena/**' \
  --glob '!.supergoal/**' \
  --glob '!**/*.log' \
  --glob '!**/*.xcresult/**' \
  --glob '!**/*.trace/**' \
  --glob '!*.min.*' \
  "(SUPABASE_SERVICE_ROLE_KEY\\s*=\\s*['\\\"][A-Za-z0-9]|OPENROUTER_API_KEY\\s*=\\s*['\\\"][A-Za-z0-9]|sk-[A-Za-z0-9]{20,}|sb_secret_[A-Za-z0-9]{10,}|sb_publishable_[A-Za-z0-9]{10,}|-----BEGIN (RSA|EC|OPENSSH) PRIVATE KEY-----)" \
  . ; then
  echo "Potential hardcoded secret material detected."
  exit 1
fi

echo "== Security pass: transport hardening checks =="
ATS_TMP_FILE="$(mktemp "${TMPDIR:-/tmp}/lifeos_ats_check.XXXXXX")"
trap 'rm -f "$ATS_TMP_FILE"' EXIT
if /usr/libexec/PlistBuddy -c "Print :NSAppTransportSecurity:NSAllowsArbitraryLoads" ios/LifeOS/App/Info.plist >"$ATS_TMP_FILE" 2>/dev/null; then
  if grep -q "true" "$ATS_TMP_FILE"; then
    echo "ATS is weakened: NSAllowsArbitraryLoads=true"
    exit 1
  fi
fi

if ! rg -q "scheme\\?\\.lowercased\\(\\)\\s*==\\s*\"https\"" ios/LifeOS/Modules/Shared/Network/SupabaseConfig.swift; then
  echo "Missing explicit HTTPS enforcement guard in SupabaseConfig."
  exit 1
fi

echo "== Security pass: server-side rate-limit and abuse-case tests =="
deno test -A \
  supabase/functions/tests/payload_malformed.test.ts \
  supabase/functions/tests/rate_limit_security.test.ts \
  supabase/functions/tests/correlation_property.test.ts

if [[ "${SECURITY_PASS_SKIP_EDGE_E2E:-0}" == "1" ]]; then
  echo "== Security pass: edge abuse-case integration suite skipped (SECURITY_PASS_SKIP_EDGE_E2E=1) =="
else
  echo "== Security pass: edge abuse-case integration suite =="
  bash scripts/run_supabase_edge_e2e.sh
fi

echo "Pre-prod security pass completed successfully."
