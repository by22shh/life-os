# LIFE OS — V2 Spec Freeze & Change Control

**Version:** 0.3  
**Date:** February 16, 2026  
**Purpose:** Stop churn, prevent spec drift, and make the documentation set “one-shot implementable” by locking V2 as a baseline with an explicit change-control process.

---

## 0) What “Frozen” Means

When a spec is **frozen**:
- It is treated as **contract** for implementation.
- Any change MUST be made as a **Change Request** (CR) with impact analysis.
- Any accepted change MUST:
  - bump the document header version
  - update the relevant changelog (if present)
  - update `README.md` “Document versions” table
  - update “Aligns with” references where applicable
  - update E2E/QA coverage if behavior changes

---

## 1) V2 Scope (Frozen)

V2 is defined as the union of these shipped surfaces and contracts:
- **Unified Daily Diary (V2):** day + calendar surfaces.
- **Sleep Diary (V2):** day + calendar surfaces (sleep-focused UX and APIs).
- **Nutrition V2 surfaces:** templates management + batch/meal-prep library improvements.
- **Supplements calendar:** month grid endpoint + UX.
- **Insights & Experiments:** insights list/detail + experiments create/log.
- **Notifications/control model:** advisory/protective/guardian + caps/quiet hours.
- **watchOS companion (V2):** complication + glance + safe one-taps routed to iPhone host (no direct backend calls).
- **Offline-first sync engine:** outbox + pull strategy + idempotency + client-generated IDs.
- **AI via OpenRouter (LOCKED):** Edge Functions only; prompts/policies are source of truth.

Out of scope for V2 (explicitly **not** included in the frozen baseline):
- watchOS “Full View” / complex workflows on watch
- Android/Web
- HealthKit writes (read-only in V1/V2)
- any “auto-actions” that can alter user health decisions without review when confidence is low
- Hydration logging UI (API reserved for future surface)
- Body composition UI (API reserved for future surface)
- Weekly strategy report UI (API reserved for future surface)
- Standalone recommendations feed UI (recommendations may be used indirectly, no dedicated surface in V2)

---

## 2) Frozen Baseline Versions (Source of Truth)

These versions define the **V2 frozen baseline**. If we implement V2, we implement **this set**.

| Document | Version | Role |
|---|---:|---|
| `life_os_prd_v7_ultimate.md` | 7.13 | product vision + constraints |
| `life_os_ux_screens.md` | 0.12 | UX screens + flows (V1/V2) |
| `life_os_design_system.md` | 2.24 | UI tokens/components/states |
| `life_os_api_specification.md` | 2.3 | DB schema + `/api/*` contracts + offline rules |
| `life_os_technical_architecture.md` | 0.8 | system architecture + locked tech decisions |
| `life_os_engineering_blueprint.md` | 0.6 | repo layout + delivery/testing/CI guidance |
| `life_os_sync_engine_spec.md` | 0.6 | outbox/pull sync engine spec |
| `life_os_error_handling.md` | 2.1 | error taxonomy + retry/offline UX |
| `life_os_privacy_architecture.md` | 1.7 | privacy posture + retention + processors |
| `life_os_gpt_prompts.md` | 1.6 | prompt library + OpenRouter gateway rules |
| `life_os_healthkit_spec.md` | 1.2 | HealthKit read + sync rules |
| `life_os_watchos_spec.md` | 0.3 | watchOS companion contract |
| `life_os_copy_catalog.md` | 1.14 | copy source of truth |
| `life_os_e2e_test_checklists.md` | 0.4 | E2E scenarios (incl. V2 diary/sleep/watch) |
| `life_os_qa_master_pack.md` | 0.3 | QA gates + acceptance harness |
| `life_os_invariants.md` | 0.5 | cross-document invariants (canonical) |
| `life_os_recovery_algorithms.md` | 3.5 | recovery algorithms + validation |
| `life_os_health_ecosystem_spec.md` | 1.5 | nutrition/training/supplements/labs spec |
| `life_os_food_data_strategy.md` | 1.0 | food data sourcing + OCR fallback |
| `life_os_accessibility_guidelines.md` | 1.4 | accessibility baseline + tests |
| `life_os_data_lineage_matrix.md` | 0.3 | scenario → tables/views/fields mapping |
| `life_os_onboarding_backend.md` | 0.1 | onboarding flow backend contract |
| `life_os_analytics_catalog.md` | 0.1 | analytics events catalog |
| `life_os_widget_spec.md` | 0.2 | iOS widget specifications |

---

## 2.1) Reference Docs (Non-Frozen, Informative)

These documents are informative only and may drift unless explicitly promoted into the frozen baseline:

- `life_os_health_ecosystem_expansion.md` v1.1
- `life_os_functional_matrix.md` v0.3
- `life_os_cis_edge_cases.md` v0.1
- `life_os_ux_benchmarks.md` v0.1
- `life_os_build_backlog.md` v0.5
- `life_os_e2e_master_matrix.md` v0.2
- `life_os_acceptance_checklists.md` v0.2

---

## 3) Non-Negotiable Invariants (Must Stay True)

If a CR violates any invariant, it is automatically **rejected** unless it explicitly proposes to bump the invariant (which is a major product decision).

- Recovery zones: `critical 0–24`, `caution 25–49`, `ready 50–74`, `optimal 75–100`
- Low-confidence threshold: `< 0.65` triggers review-required behavior
- Notifications: hard cap `<= 6/day` + quiet hours
- Control model: `advisory | protective | guardian` (Guardian requires Focus Control; `critical_only=true` forces Advisory)
- watchOS (V2): no direct backend calls; safe actions route to iPhone host
- AI (LOCKED): OpenRouter gateway only (Edge Functions); no client-side keys

---

## 4) Change Policy (To Avoid “Infinite Iterations”)

### 4.1 Severity Levels

- **P0 — Safety/Data Loss:** fixes for crashes, data loss, security/privacy violations, idempotency holes, or anything that can harm users.
  - Allowed during freeze, must update specs immediately.
- **P1 — Spec Correctness:** contradictions across docs, missing required request fields, unclear contract that blocks implementation.
  - Allowed during freeze, must update specs immediately.
- **P2 — UX/Feature Improvement:** changes that improve UX but are not required to safely ship.
  - Not applied to frozen baseline. Goes into backlog as “V2.x” or “V3”.
- **P3 — Nice-to-have:** cosmetic/optional improvements.
  - Not applied to frozen baseline.

### 4.2 What We Do With Improvements

To avoid getting stuck:
- **Only P0/P1 changes can modify frozen docs.**
- All P2/P3 are captured in `life_os_build_backlog.md` with labels:
  - `v2.x` (post-ship refinement) or `v3` (next major)

---

## 5) Change Request (CR) Template (Required)

Create a CR (in a new markdown file or as a clearly marked section in the target doc) using this template:

1. **Title:** short, specific
2. **Motivation (User Problem):** what breaks today, for whom, how often
3. **Proposal:** the exact change (contracts/UX/DB/API)
4. **Affected Docs:** list files + sections
5. **Behavioral Impact:** what changes in user flows and system outputs
6. **Offline + Idempotency Impact:** does it change client IDs, replay, merge rules, or outbox ordering
7. **Privacy/Security Impact:** data classification changes, retention, processors/subprocessors
8. **watchOS Impact:** snapshot payload changes, routing changes, any safety gates
9. **Tests to Update:** which E2E/QA items must change
10. **Migration Plan:** data migrations, backward compatibility, deprecations (if any)
11. **Acceptance Criteria:** pass/fail bullets

**Rule:** CR must state whether it is P0/P1/P2/P3 and why.

---

## 6) Post-Change Checklist (If CR Is Accepted)

1. Update the target spec(s) with the change.
2. Bump the version header(s).
3. Update `README.md` “Document versions” table.
4. Update any “Aligns with:” references that mention versions.
5. Update E2E/QA docs if behavior changed:
   - `life_os_e2e_test_checklists.md`
   - `life_os_qa_master_pack.md`
6. Re-run the “Stop-check” invariants scan (manual):
   - low confidence `< 0.65`
   - zones 4-bucket
   - notifications cap `<= 6/day`
   - control model rules
   - OpenRouter-only AI rule
   - watchOS no direct backend calls
