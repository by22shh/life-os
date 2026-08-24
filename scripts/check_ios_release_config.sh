#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PLACEHOLDER_URL="https://localhost.invalid"
PLACEHOLDER_ANON_KEY="development-missing-anon-key"
SOURCE_GUARD_URL="https://source-guard.lifeos.invalid"
SOURCE_GUARD_ANON_KEY="source-guard-anon-key"

fail() {
  echo "error: $*" >&2
  exit 1
}

read_build_setting() {
  local settings="$1"
  local key="$2"
  awk -F'= ' -v key="$key" '$1 ~ "^[[:space:]]*" key "[[:space:]]*$" { print $2; exit }' <<<"$settings"
}

reject_placeholder_value() {
  local label="$1"
  local value="$2"

  if [[ -z "$value" ]]; then
    fail "$label is empty"
  fi
  if [[ "$value" == "$PLACEHOLDER_URL" || "$value" == "$PLACEHOLDER_ANON_KEY" ]]; then
    fail "$label still uses the development placeholder"
  fi
  if [[ "$value" == *'$('* || "$value" == *'LIFEOS_SUPABASE_'* ]]; then
    fail "$label was not resolved from Release build settings"
  fi
}

echo "== iOS release source config guard =="
source_settings="$(
  LIFEOS_SUPABASE_URL="$SOURCE_GUARD_URL" \
  LIFEOS_SUPABASE_ANON_KEY="$SOURCE_GUARD_ANON_KEY" \
    xcodebuild -project ios/LifeOS.xcodeproj \
      -target LifeOS \
      -configuration Release \
      -showBuildSettings 2>/dev/null
)"

resolved_source_url="$(read_build_setting "$source_settings" "SUPABASE_URL")"
resolved_source_key="$(read_build_setting "$source_settings" "SUPABASE_ANON_KEY")"

[[ "$resolved_source_url" == "$SOURCE_GUARD_URL" ]] || fail "Release SUPABASE_URL must resolve from LIFEOS_SUPABASE_URL"
[[ "$resolved_source_key" == "$SOURCE_GUARD_ANON_KEY" ]] || fail "Release SUPABASE_ANON_KEY must resolve from LIFEOS_SUPABASE_ANON_KEY"

echo "== Privacy manifest source guard =="
expected_manifests=(
  "ios/LifeOS/App/PrivacyInfo.xcprivacy"
  "ios/LifeOSWidgets/PrivacyInfo.xcprivacy"
  "ios/GuardianMonitorExtension/PrivacyInfo.xcprivacy"
  "watch/LifeOSWatchApp/PrivacyInfo.xcprivacy"
  "watch/LifeOSComplications/PrivacyInfo.xcprivacy"
)

for manifest in "${expected_manifests[@]}"; do
  [[ -f "$manifest" ]] || fail "missing $manifest"
  plutil -lint "$manifest" >/dev/null
done

if [[ "$(grep -c 'PrivacyInfo.xcprivacy in Resources' ios/LifeOS.xcodeproj/project.pbxproj)" -lt 5 ]]; then
  fail "not all PrivacyInfo.xcprivacy files are wired into Xcode resource build phases"
fi

if [[ "${LIFEOS_REQUIRE_RESOLVED_RELEASE_CONFIG:-0}" == "1" ]]; then
  echo "== iOS release resolved config guard =="
  resolved_settings="$(
    xcodebuild -project ios/LifeOS.xcodeproj \
      -target LifeOS \
      -configuration Release \
      -showBuildSettings 2>/dev/null
  )"

  resolved_url="$(read_build_setting "$resolved_settings" "SUPABASE_URL")"
  resolved_key="$(read_build_setting "$resolved_settings" "SUPABASE_ANON_KEY")"
  reject_placeholder_value "Release SUPABASE_URL" "$resolved_url"
  reject_placeholder_value "Release SUPABASE_ANON_KEY" "$resolved_key"
  [[ "$resolved_url" == https://* ]] || fail "Release SUPABASE_URL must be https"
fi

if [[ -n "${LIFEOS_BUILT_APP_PATH:-}" ]]; then
  echo "== Built app config guard =="
  app_path="$LIFEOS_BUILT_APP_PATH"
  [[ -d "$app_path" ]] || fail "LIFEOS_BUILT_APP_PATH does not point to an app bundle: $app_path"
  [[ -f "$app_path/PrivacyInfo.xcprivacy" ]] || fail "built app is missing PrivacyInfo.xcprivacy"

  built_url="$(/usr/libexec/PlistBuddy -c 'Print :SUPABASE_URL' "$app_path/Info.plist")"
  built_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPABASE_ANON_KEY' "$app_path/Info.plist")"
  reject_placeholder_value "Built app SUPABASE_URL" "$built_url"
  reject_placeholder_value "Built app SUPABASE_ANON_KEY" "$built_key"
  [[ "$built_url" == https://* ]] || fail "Built app SUPABASE_URL must be https"
fi

echo "iOS release config guard passed."
