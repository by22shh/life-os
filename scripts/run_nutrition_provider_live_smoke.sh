#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

require_env() {
  local key="$1"
  if [[ -z "${!key:-}" ]]; then
    echo "Missing required env: ${key}" >&2
    exit 2
  fi
}

FUNCTIONS_BASE_URL="${SUPABASE_FUNCTIONS_BASE_URL:-${SUPABASE_URL:-}}"
if [[ -n "${FUNCTIONS_BASE_URL}" ]]; then
  FUNCTIONS_BASE_URL="${FUNCTIONS_BASE_URL%/}"
fi

require_env FUNCTIONS_BASE_URL
require_env SUPABASE_ANON_KEY
require_env SUPABASE_ACCESS_TOKEN

SEARCH_QUERY="${LIFEOS_SMOKE_QUERY:-banana}"
BARCODE="${LIFEOS_SMOKE_BARCODE:-3017620422003}"
LOCALE="${LIFEOS_SMOKE_LOCALE:-en-US}"

if [[ "${FUNCTIONS_BASE_URL}" != *"/functions/v1" ]]; then
  FUNCTIONS_BASE_URL="${FUNCTIONS_BASE_URL}/functions/v1"
fi

search_url="${FUNCTIONS_BASE_URL}/api-foods/search?q=${SEARCH_QUERY}&limit=5"
barcode_url="${FUNCTIONS_BASE_URL}/api-foods/barcode/${BARCODE}"

common_headers=(
  -H "apikey: ${SUPABASE_ANON_KEY}"
  -H "Authorization: Bearer ${SUPABASE_ACCESS_TOKEN}"
  -H "Accept-Language: ${LOCALE}"
)

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/lifeos-nutrition-smoke.XXXXXX")"
trap 'rm -rf "${tmp_dir}"' EXIT

search_body="${tmp_dir}/search.json"
barcode_body="${tmp_dir}/barcode.json"

echo "== Search smoke =="
curl --fail --silent --show-error \
  "${common_headers[@]}" \
  "${search_url}" >"${search_body}"

python3 - "${search_body}" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as handle:
    payload = json.load(handle)

results = payload.get("results")
if not isinstance(results, list) or not results:
    raise SystemExit("Search smoke failed: empty results")

first = results[0]
name = first.get("name") or "<missing>"
ref_type = first.get("ref_type") or "<missing>"
print(f"search.ok name={name} ref_type={ref_type} count={len(results)}")
PY

echo "== Barcode smoke =="
curl --fail --silent --show-error \
  "${common_headers[@]}" \
  "${barcode_url}" >"${barcode_body}"

python3 - "${barcode_body}" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as handle:
    payload = json.load(handle)

required = ["name", "calories_per_100g", "protein_per_100g", "fat_per_100g", "carbs_per_100g"]
missing = [key for key in required if payload.get(key) is None]
if missing:
    raise SystemExit(f"Barcode smoke failed: missing fields {missing}")

print(
    "barcode.ok"
    f" name={payload.get('name')}"
    f" provider={payload.get('provider')}"
    f" calories={payload.get('calories_per_100g')}"
)
PY

echo "Nutrition provider live smoke passed."
