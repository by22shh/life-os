#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "== Security pass: secret/key exposure scan =="
if rg -n \
  --glob '!ios/build/**' \
  --glob '!output/**' \
  --glob '!**/*.log' \
  --glob '!**/*.xcresult/**' \
  --glob '!**/*.trace/**' \
  "(SUPABASE_SERVICE_ROLE_KEY\\s*=\\s*['\\\"][A-Za-z0-9]|OPENROUTER_API_KEY\\s*=\\s*['\\\"][A-Za-z0-9]|sk-[A-Za-z0-9]{20,}|-----BEGIN (RSA|EC|OPENSSH) PRIVATE KEY-----)" \
  ios supabase scripts README.md; then
  echo "Potential hardcoded secret material detected."
  exit 1
fi

echo "== Security pass: transport hardening checks =="
if /usr/libexec/PlistBuddy -c "Print :NSAppTransportSecurity:NSAllowsArbitraryLoads" ios/LifeOS/App/Info.plist >/tmp/lifeos_ats_check.txt 2>/dev/null; then
  if grep -q "true" /tmp/lifeos_ats_check.txt; then
    echo "ATS is weakened: NSAllowsArbitraryLoads=true"
    exit 1
  fi
fi
rm -f /tmp/lifeos_ats_check.txt

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
