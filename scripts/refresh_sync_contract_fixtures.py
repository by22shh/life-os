#!/usr/bin/env python3
"""Refresh Sync contract fixtures from Supabase REST API snapshots.

Usage:
  SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... \
  python3 scripts/refresh_sync_contract_fixtures.py --user-id <uuid>

The script fetches one row per table and writes it to:
  ios/LifeOSTests/Fixtures/SyncContracts/*.json
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlencode
from urllib.request import Request, urlopen


ROOT_DIR = Path(__file__).resolve().parents[1]
DEFAULT_OUT_DIR = ROOT_DIR / "ios" / "LifeOSTests" / "Fixtures" / "SyncContracts"


@dataclass(frozen=True)
class FixtureSpec:
    file_stem: str
    table: str
    user_scoped: bool


FIXTURE_SPECS: tuple[FixtureSpec, ...] = (
    FixtureSpec("user", "users", True),
    FixtureSpec("notification_settings", "notification_settings", True),
    FixtureSpec("user_health_flags", "user_health_flags", True),
    FixtureSpec("physiological_state", "physiological_states", True),
    FixtureSpec("training_load", "training_loads", True),
    FixtureSpec("food_log", "food_logs", True),
    FixtureSpec("food_item", "food_items", True),
    FixtureSpec("user_food", "user_foods", True),
    FixtureSpec("user_food_favorite", "user_food_favorites", True),
    FixtureSpec("meal_template", "meal_templates", True),
    FixtureSpec("batch_recipe", "batch_recipes", True),
    FixtureSpec("batch_recipe_ingredient", "batch_recipe_ingredients", True),
    FixtureSpec("daily_nutrition_target", "daily_nutrition_targets", True),
    FixtureSpec("food_catalog_item", "food_catalog_items", False),
    FixtureSpec("workout_session", "workout_sessions", True),
    FixtureSpec("workout_exercise", "workout_exercises", True),
    FixtureSpec("workout_set", "workout_sets", True),
    FixtureSpec("training_plan", "training_plans", True),
    FixtureSpec("training_plan_session", "training_plan_sessions", True),
    FixtureSpec("exercise_catalog", "exercise_catalog", False),
    FixtureSpec("training_template", "training_templates", True),
    FixtureSpec("user_supplement", "user_supplements", True),
    FixtureSpec("supplement_log", "supplement_logs", True),
    FixtureSpec("supplement_catalog", "supplement_catalog", False),
    FixtureSpec("sleep_log", "sleep_logs", True),
    FixtureSpec("menstrual_log", "menstrual_logs", True),
    FixtureSpec("wellness_check", "wellness_checks", True),
    FixtureSpec("body_composition", "body_composition", True),
    FixtureSpec("hydration_log", "hydration_logs", True),
    FixtureSpec("medical_scan", "medical_scans", True),
    FixtureSpec("health_measurement", "health_measurements", True),
    FixtureSpec("health_diagnosis", "health_diagnoses", True),
    FixtureSpec("health_marker_catalog", "health_marker_catalog", False),
    FixtureSpec("experiment", "experiments", True),
    FixtureSpec("experiment_measurement", "experiment_measurements", True),
    FixtureSpec("insight", "insights", True),
    FixtureSpec("recommendation", "recommendations", True),
    FixtureSpec("weekly_strategy_report", "weekly_strategy_reports", True),
    FixtureSpec("vector_memory", "vector_memory", True),
    FixtureSpec("onboarding_state", "onboarding_state", True),
    FixtureSpec("user_baseline", "user_baselines", True),
    FixtureSpec("privacy_settings", "privacy_settings", True),
)


ORDER_CANDIDATES: tuple[str | None, ...] = (
    "updated_at.desc.nullslast,id.asc",
    "created_at.desc.nullslast,id.asc",
    "id.asc",
    None,
)

HEALTH_MEASUREMENT_REQUIRED_KEYS = frozenset({
    "id",
    "user_id",
    "created_at",
    "updated_at",
    "marker_id",
    "value",
    "unit",
    "measured_at",
    "source_scan_id",
    "source_type",
    "confidence",
    "manually_verified",
})

HEALTH_MEASUREMENT_LEGACY_KEYS = frozenset({
    "medical_scan_id",
    "biomarker_name",
    "measured_date",
    "ai_confidence",
    "user_corrected",
})

HEALTH_MEASUREMENT_ALLOWED_STATUSES = frozenset({
    "critical_low",
    "low",
    "optimal",
    "high",
    "critical_high",
})

LOCAL_DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Refresh iOS sync contract JSON fixtures from Supabase REST snapshots."
    )
    parser.add_argument(
        "--supabase-url",
        default=os.getenv("SUPABASE_URL"),
        help="Supabase project URL (or full /rest/v1 URL). Defaults to SUPABASE_URL env.",
    )
    parser.add_argument(
        "--api-key",
        default=os.getenv("SUPABASE_SERVICE_ROLE_KEY") or os.getenv("SUPABASE_ANON_KEY"),
        help=(
            "Supabase API key. "
            "Defaults to SUPABASE_SERVICE_ROLE_KEY, then SUPABASE_ANON_KEY."
        ),
    )
    parser.add_argument(
        "--bearer-token",
        default=(
            os.getenv("SUPABASE_AUTH_TOKEN")
            or os.getenv("SUPABASE_JWT")
            or os.getenv("SUPABASE_SERVICE_ROLE_KEY")
            or os.getenv("SUPABASE_ANON_KEY")
        ),
        help="Authorization bearer token. Defaults to auth env vars, then API key.",
    )
    parser.add_argument(
        "--schema",
        default="public",
        help="PostgREST schema profile header. Default: public.",
    )
    parser.add_argument(
        "--user-id",
        default=os.getenv("SYNC_FIXTURE_USER_ID"),
        help=(
            "Optional user id filter. Applied to user-scoped fixtures "
            "(id=<user_id> for users, user_id=<user_id> for other user tables)."
        ),
    )
    parser.add_argument(
        "--out-dir",
        default=str(DEFAULT_OUT_DIR),
        help=f"Output fixtures directory. Default: {DEFAULT_OUT_DIR}",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=20,
        help="HTTP timeout in seconds. Default: 20.",
    )
    parser.add_argument(
        "--allow-missing",
        action="store_true",
        help="Do not fail if a table has no rows; keep existing fixture as-is.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Fetch and validate snapshots without writing files.",
    )
    return parser.parse_args()


def normalize_rest_url(url: str) -> str:
    normalized = url.strip().rstrip("/")
    if normalized.endswith("/rest/v1"):
        return normalized
    return f"{normalized}/rest/v1"


def build_headers(api_key: str, bearer_token: str, schema: str) -> dict[str, str]:
    return {
        "apikey": api_key,
        "Authorization": f"Bearer {bearer_token}",
        "Accept": "application/json",
        "Accept-Profile": schema,
    }


def read_json_response(request: Request, timeout: int) -> Any:
    with urlopen(request, timeout=timeout) as response:
        body = response.read()
        try:
            return json.loads(body.decode("utf-8"))
        except json.JSONDecodeError as exc:
            raise RuntimeError(f"Invalid JSON response from {request.full_url}: {exc}") from exc


def is_retryable_order_error(error_body: str) -> bool:
    lowered = error_body.lower()
    return "order" in lowered or "column" in lowered


def fetch_first_row(
    rest_url: str,
    headers: dict[str, str],
    spec: FixtureSpec,
    user_id: str | None,
    timeout: int,
) -> dict[str, Any] | None:
    last_error: Exception | None = None

    for order in ORDER_CANDIDATES:
        params: list[tuple[str, str]] = [("select", "*"), ("limit", "1")]
        if order is not None:
            params.append(("order", order))

        if user_id and spec.user_scoped:
            filter_column = "id" if spec.table == "users" else "user_id"
            params.append((filter_column, f"eq.{user_id}"))

        url = f"{rest_url}/{quote(spec.table)}?{urlencode(params)}"
        request = Request(url=url, headers=headers, method="GET")

        try:
            payload = read_json_response(request, timeout=timeout)
        except HTTPError as exc:
            body = exc.read().decode("utf-8", errors="replace")
            if exc.code == 400 and order is not None and is_retryable_order_error(body):
                last_error = RuntimeError(
                    f"Order '{order}' failed for table '{spec.table}': {body}"
                )
                continue
            raise RuntimeError(
                f"HTTP {exc.code} while fetching {spec.table}: {body}"
            ) from exc
        except URLError as exc:
            raise RuntimeError(f"Network error while fetching {spec.table}: {exc}") from exc

        if not isinstance(payload, list):
            raise RuntimeError(
                f"Expected list payload for table '{spec.table}', got: {type(payload).__name__}"
            )

        if not payload:
            return None

        first = payload[0]
        if not isinstance(first, dict):
            raise RuntimeError(
                f"Expected object row for table '{spec.table}', got: {type(first).__name__}"
            )
        return first

    if last_error is not None:
        raise RuntimeError(
            f"Failed to fetch table '{spec.table}' with all order fallbacks: {last_error}"
        ) from last_error
    raise RuntimeError(f"Failed to fetch table '{spec.table}'")


def write_fixture(path: Path, row: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        json.dump(row, handle, indent=2, sort_keys=True, ensure_ascii=False)
        handle.write("\n")


def validate_health_measurement_fixture(row: dict[str, Any]) -> None:
    missing = sorted(HEALTH_MEASUREMENT_REQUIRED_KEYS.difference(row))
    if missing:
        raise RuntimeError(
            "health_measurement fixture is missing canonical server keys: "
            + ", ".join(missing)
        )

    legacy_keys = sorted(HEALTH_MEASUREMENT_LEGACY_KEYS.intersection(row))
    if legacy_keys:
        raise RuntimeError(
            "health_measurement fixture still contains legacy keys: "
            + ", ".join(legacy_keys)
        )

    measured_at = row.get("measured_at")
    if not isinstance(measured_at, str) or not LOCAL_DATE_RE.fullmatch(measured_at):
        raise RuntimeError(
            "health_measurement fixture must use a date-only measured_at in YYYY-MM-DD format"
        )

    status = row.get("status")
    if status is not None and status not in HEALTH_MEASUREMENT_ALLOWED_STATUSES:
        raise RuntimeError(
            "health_measurement fixture has non-canonical status: "
            + repr(status)
        )


SLEEP_LOG_CANONICAL_KEYS = {
    "bed_time",
    "wake_time",
    "total_duration_minutes",
    "time_in_bed_minutes",
    "deep_sleep_minutes",
    "rem_sleep_minutes",
    "light_sleep_minutes",
    "awake_minutes",
    "number_of_awakenings",
    "sleep_efficiency",
    "sleep_quality_score",
    "device_name",
}


def validate_sleep_log_fixture(row: dict[str, Any]) -> None:
    missing = sorted(key for key in SLEEP_LOG_CANONICAL_KEYS if key not in row)
    if missing:
        raise RuntimeError(
            "sleep_log fixture is missing canonical columns: " + ", ".join(missing)
        )


def validate_fixture_shape(spec: FixtureSpec, row: dict[str, Any]) -> None:
    if spec.file_stem == "health_measurement":
        validate_health_measurement_fixture(row)
    elif spec.file_stem == "sleep_log":
        validate_sleep_log_fixture(row)


def main() -> int:
    args = parse_args()

    if not args.supabase_url:
        print("error: missing --supabase-url (or SUPABASE_URL env)", file=sys.stderr)
        return 2
    if not args.api_key:
        print(
            "error: missing --api-key (or SUPABASE_SERVICE_ROLE_KEY/SUPABASE_ANON_KEY env)",
            file=sys.stderr,
        )
        return 2
    if not args.bearer_token:
        print(
            "error: missing --bearer-token (or SUPABASE_AUTH_TOKEN/SUPABASE_JWT env)",
            file=sys.stderr,
        )
        return 2

    rest_url = normalize_rest_url(args.supabase_url)
    out_dir = Path(args.out_dir).resolve()
    headers = build_headers(args.api_key, args.bearer_token, args.schema)

    refreshed = 0
    skipped_missing = 0
    missing_tables: list[str] = []

    for spec in FIXTURE_SPECS:
        row = fetch_first_row(
            rest_url=rest_url,
            headers=headers,
            spec=spec,
            user_id=args.user_id,
            timeout=args.timeout,
        )

        if row is None:
            if args.allow_missing:
                skipped_missing += 1
                missing_tables.append(spec.table)
                print(f"skip: {spec.table} has no rows")
                continue
            raise RuntimeError(
                f"Table '{spec.table}' has no rows for fixture '{spec.file_stem}'. "
                "Use --allow-missing to skip."
            )

        validate_fixture_shape(spec, row)

        if args.dry_run:
            print(f"ok: {spec.table} -> {spec.file_stem}.json ({len(row)} fields)")
            refreshed += 1
            continue

        output_path = out_dir / f"{spec.file_stem}.json"
        write_fixture(output_path, row)
        refreshed += 1
        print(f"updated: {output_path}")

    print(
        f"done: refreshed={refreshed}, skipped_missing={skipped_missing}, output_dir={out_dir}"
    )
    if missing_tables:
        print("missing tables:", ", ".join(missing_tables))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(1)
