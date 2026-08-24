# LIFE OS — Master Implementation Spec (One‑Prompt Ready)

**Version:** 2.0
**Date:** February 16, 2026
**Purpose:** Single, consolidated spec for one‑shot implementation. This document summarizes the frozen baseline, invariants, and end‑to‑end behavior. It does **not** replace source docs; it references them for details.

---

## 0) Frozen Baseline (Authoritative)

Use these versions as source of truth:
- `life_os_prd_v7_ultimate.md` v7.13
- `life_os_ux_screens.md` v0.12
- `life_os_design_system.md` v2.24
- `life_os_api_specification.md` v2.3
- `life_os_technical_architecture.md` v0.8
- `life_os_engineering_blueprint.md` v0.6
- `life_os_sync_engine_spec.md` v0.6
- `life_os_error_handling.md` v2.1
- `life_os_privacy_architecture.md` v1.7
- `life_os_gpt_prompts.md` v1.6
- `life_os_healthkit_spec.md` v1.2
- `life_os_watchos_spec.md` v0.3
- `life_os_copy_catalog.md` v1.14
- `life_os_e2e_test_checklists.md` v0.4
- `life_os_qa_master_pack.md` v0.3
- `life_os_invariants.md` v0.5
- `life_os_recovery_algorithms.md` v3.5
- `life_os_health_ecosystem_spec.md` v1.5
- `life_os_food_data_strategy.md` v1.0
- `life_os_accessibility_guidelines.md` v1.4
- `life_os_data_lineage_matrix.md` v0.3
- `life_os_onboarding_backend.md` v0.1
- `life_os_analytics_catalog.md` v0.1
- `life_os_widget_spec.md` v0.2
- `life_os_spec_freeze_v2.md` v0.3

**Reference docs (non-frozen, informative):**
- `life_os_health_ecosystem_expansion.md` v1.1
- `life_os_functional_matrix.md` v0.3
- `life_os_ux_benchmarks.md` v0.1
- `life_os_cis_edge_cases.md` v0.1
- `life_os_build_backlog.md` v0.5
- `life_os_e2e_master_matrix.md` v0.2
- `life_os_acceptance_checklists.md` v0.2

---

## 1) Non‑Negotiable Invariants

- Recovery zones: `critical 0–24`, `caution 25–49`, `ready 50–74`, `optimal 75–100`.
- Low‑confidence threshold: `< 0.65` requires review before save.
- Notifications cap: `<= 6/day`, quiet hours enforced.
- Control levels: `advisory | protective | guardian` with Focus Control guardrails.
- watchOS is companion‑only; no direct backend calls.
- AI via OpenRouter only; no client keys.
- Copy must map to `life_os_copy_catalog.md`.
- IDs: `snake_case` in SQL, `camelCase` in JSON.

---

## 2) V2 Scope (Shipped)

- Onboarding with 6 required steps + optional supplements/labs.
- Home screen with recovery card, Next Best Action, quick logs.
- Nutrition diary + logging (photo, barcode + label OCR fallback, voice, search, meal prep, templates).
- Training diary + manual logging + conflicts with import.
- Supplements diary + month grid + one‑tap taken.
- Sleep diary (detail + month grid).
- Unified daily diary (V2) with calendar.
- Labs import (photo/PDF → OCR → review → save).
- Insights + experiments list/detail + daily logging.
- Notifications & control model.
- Offline‑first sync engine.
- watchOS companion (complications + glance + safe actions).

---

## 3) Out of Scope for V2 UI

These have API support but no V2 UI surfaces:
- Hydration logging
- Body composition
- Weekly strategy report
- Standalone recommendations feed

---

## 4) Architecture (High Level)

- iOS client (SwiftUI) + LocalStore (GRDB) + Outbox.
- Supabase Postgres + Edge Functions for `/api/*`.
- OpenRouter for LLMs via Edge Functions only.
- Pinecone as server‑only vector store.
- watchOS receives snapshots from iPhone via WatchConnectivity.

---

## 5) Offline‑First Sync (Contract)

- Local write → Outbox → replay with idempotency.
- Client‑generated UUIDs for all offline‑capable entities.
- Every mutation includes `Idempotency-Key` and `X-Device-Id`.
- Pull by `updated_at` watermarks with `>=` and dedupe.
- Dead‑letter after max retries; surface review/fix UI.

---

## 6) Home + Next Best Action

- Home uses `/api/recovery/latest`, `/api/diary/daily`, `/api/insights?unread=true`, `/api/experiments`, `/api/supplements/daily`.
- `next_best_action` is deterministic (see API spec). Priority:
  - Needs review → open diary (review).
  - Supplement due soon → mark taken.
  - Nutrition under target → log meal.
  - Sleep permission missing → open sleep.
  - Unread insights → acknowledge.
  - Fallback → open diary.
- If `confidence_score < 0.65`, never return risky one‑tap actions.

---

## 7) Core User Flows (Summary)

Onboarding:
- Silent auth → HealthKit permission → profile → optional supplements/labs → first insight → notifications.

Nutrition:
- Method picker → photo/barcode/voice/search → Review Meal → Save.
- Barcode fallback: label OCR → Review Product → create catalog item.
- Meal prep: batch recipes with quick or precise mode.

Training:
- Manual strength logging + exercise picker.
- Import from HealthKit, conflict resolution (merge/keep/undo).
- Training load computed via TRIMP.

Supplements:
- Manage stack → daily schedule → one‑tap taken.

Sleep:
- Detail view + manual entry (if needed).
- Calendar view for month grid.

Labs:
- Capture → OCR → review normalization → save.

Insights & Experiments:
- Insights list/detail → start experiment → daily log → results.

Notifications & Control:
- Advisory/Protective/Guardian.
- Focus Control required for Guardian.
- Hard cap and quiet hours enforced.

watchOS:
- Complications + glance view.
- Safe actions only (supplement taken, insight acknowledge).

---

## 8) HealthKit (Key Rules)

- Read‑only. Import sleep, HRV, RHR, workouts, steps, active energy.
- Compute daily aggregates by local date with timezone history.
- Training load uses TRIMP with HR zone minutes when HR samples exist.
- HR zones are derived from workout HR samples using per‑workout peak HR.

---

## 9) Privacy & GDPR

- Local‑first, explicit retention policies.
- Menstrual data on‑device by default.
- GDPR export and delete endpoints required (async export).
- Pinecone vectors deleted before SQL on account deletion.

---

## 10) Testing Gates

- E2E checklists cover core flows.
- QA master pack is the release gate.
- Accessibility baseline: WCAG 2.2 AA + Apple HIG.

---

## 11) Implementation Notes

- UI strings must reference copy IDs.
- No direct watch backend calls.
- Use warm surfaces + Okabe‑Ito for semantic colors.

