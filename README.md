# Life OS — Documentation Index

This repository contains the Life OS application source code and accompanying product/engineering documentation.

## What to read (by role)

**Product / UX**
1. `life_os_prd_v7_ultimate.md` — product vision, IA, onboarding, notifications, constraints.
2. `life_os_design_system.md` — UI tokens, components, states, motion/haptics, screen specs.
3. `life_os_accessibility_guidelines.md` — WCAG/Apple accessibility requirements + test checklist.
4. `life_os_health_ecosystem_spec.md` — detailed spec for nutrition, training, supplements, labs.
5. `life_os_functional_matrix.md` — functional coverage matrix with spec coverage, repository snapshot, and audited readiness snapshot (updated May 28, 2026).
6. `life_os_ux_screens.md` — UX screen specs for onboarding + V1/V2 surfaces.
7. `life_os_watchos_spec.md` — watchOS companion spec (V2): complications, glance, lightweight actions, sync contract.
8. `life_os_copy_catalog.md` — UX copy source of truth (core app flows).
9. `life_os_build_backlog.md` — prioritized implementation backlog (MVP → V2).
10. `life_os_ux_benchmarks.md` — market UX patterns adopted/rejected + CIS-specific decisions (implementation-facing).
11. `life_os_e2e_test_checklists.md` — end-to-end test checklists for the highest-impact flows (incl. V2 diary/sleep/watch).
12. `life_os_e2e_master_matrix.md` — scenario → UX screen → API → error codes → copy IDs.
13. `life_os_acceptance_checklists.md` — subsystem-level acceptance criteria (pass/fail).
14. `life_os_data_lineage_matrix.md` — scenario → tables/views/fields mapping.
15. `life_os_cis_edge_cases.md` — CIS localization pitfalls and edge cases.
16. `life_os_qa_master_pack.md` — unified QA pack (E2E + acceptance + matrix + CIS edge + lineage).
17. `life_os_spec_freeze_v2.md` — V2 spec freeze baseline + change-control process (prevents endless iteration).

**Backend / Data**
1. `life_os_api_specification.md` — database schema, RLS, edge functions, client APIs, offline sync.
2. `life_os_healthkit_spec.md` — HealthKit identifiers, units, aggregation windows, source precedence, sync strategy.
3. `life_os_food_data_strategy.md` — food barcode/search provider strategy (CIS-optimized), caching, attribution, OCR fallback.
4. `life_os_privacy_architecture.md` — data classification, encryption, retention, GDPR/CCPA/HIPAA posture.
5. `life_os_error_handling.md` — error taxonomy, codes, retry, offline behavior, UI patterns.
6. `life_os_technical_architecture.md` — implementation architecture + tech stack (client/server/AI/watch), offline sync model.
7. `life_os_engineering_blueprint.md` — engineering blueprint: repo layout, module boundaries, CI/CD, testing, delivery order.
8. `life_os_sync_engine_spec.md` — offline-first sync engine spec (outbox, reconciliation, retries, background).

**Science / Algorithms**
1. `life_os_recovery_algorithms.md` — recovery score algorithms + validation methodology.

**AI / Prompts**
1. `life_os_gpt_prompts.md` — prompt library, fallbacks, testing, RAG evaluation, medical bounds validation.

**Roadmap / Expansion**
1. `life_os_health_ecosystem_expansion.md` — planned ecosystem expansion (nutrition/workouts/supplements).

**Cross-Cutting**
1. `life_os_master_spec.md` — consolidated “one‑prompt” implementation spec (frozen baseline summary).
2. `life_os_invariants.md` — canonical reference for all cross-document invariants (zones, thresholds, caps, AI rules, privacy posture).

## Readiness truth

- September 2026: see the [system audit](audits/system-audit-2026-09-08/REPORT.md) and [repair/verification record](audits/system-audit-2026-09-08/REMEDIATION.md). Earlier readiness reports describe historical snapshots.
- External release evidence (hosted project, real devices, APNs, providers, App Store artifact, pilot) is tracked in [PRODUCTION_EXTERNAL_CHECKS.md](PRODUCTION_EXTERNAL_CHECKS.md).
- No single document is the final release truth.
- Use the repository code, `xcodebuild`/CI release gates, `life_os_functional_matrix.md`, and the QA pack together.
- `life_os_functional_matrix.md` is now an audited implementation snapshot, not just a spec-gap list.
- If the code and docs diverge, treat the docs as stale and update them before using them for readiness decisions.

## Sources of truth (cross-document invariants)

> **Canonical reference:** `life_os_invariants.md` contains the full, detailed invariants with exact values, colors, and rules. The summary below is for quick reference.

These rules MUST be consistent across all documents and implementations:
- **Recovery Zones:** 4-zone model — `optimal`, `ready`, `caution`, `critical`.
- **Status encoding:** **Color + Icon + Text** (never color-only).
- **Low-confidence threshold:** `< 0.65` requires review; avoid risky one-tap actions when below.
- **Notifications:** hard cap `<= 6/day` (quiet hours enforced).
- **Control model:** `advisory | protective | guardian` (Guardian requires Focus Control; critical-only forces Advisory).
- **Accessibility baseline:** WCAG 2.2 AA + Apple HIG; touch targets ≥ 44×44pt.
- **Privacy posture:** data minimization + local-first where possible + explicit retention & deletion flows.
- **Sensitive data:** menstrual data is on-device only by default; vector embeddings are opt-in and derived-only.
- **Copy source of truth:** `life_os_copy_catalog.md` for core app flows.

If any document conflicts with this section, treat it as a bug and fix the document before coding.

## Document versions (as declared in headers)

| File | Version | Date |
|------|---------|------|
| `life_os_prd_v7_ultimate.md` | 7.13 (Monetization & Distribution) | February 16, 2026 |
| `life_os_master_spec.md` | 2.0 | February 16, 2026 |
| `life_os_spec_freeze_v2.md` | 0.3 | February 16, 2026 |
| `life_os_invariants.md` | 0.5 | February 16, 2026 |
| `life_os_design_system.md` | 2.24 | February 9, 2026 |
| `life_os_api_specification.md` | 2.3 | February 16, 2026 |
| `life_os_technical_architecture.md` | 0.8 | February 9, 2026 |
| `life_os_engineering_blueprint.md` | 0.6 | February 16, 2026 |
| `life_os_sync_engine_spec.md` | 0.6 | February 16, 2026 |
| `life_os_error_handling.md` | 2.1 | February 16, 2026 |
| `life_os_privacy_architecture.md` | 1.7 (GDPR Export Format) | February 16, 2026 |
| `life_os_healthkit_spec.md` | 1.2 | February 16, 2026 |
| `life_os_recovery_algorithms.md` | 3.5 | February 9, 2026 |
| `life_os_health_ecosystem_spec.md` | 1.5 | February 16, 2026 |
| `life_os_health_ecosystem_expansion.md` | 1.1 | February 3, 2026 |
| `life_os_accessibility_guidelines.md` | 1.4 | February 16, 2026 |
| `life_os_gpt_prompts.md` | 1.6 | February 16, 2026 |
| `life_os_ux_screens.md` | 0.12 | February 16, 2026 |
| `life_os_copy_catalog.md` | 1.14 | February 9, 2026 |
| `life_os_food_data_strategy.md` | 1.0 | February 4, 2026 |
| `life_os_watchos_spec.md` | 0.3 | February 4, 2026 |
| `life_os_widget_spec.md` | 0.2 | February 16, 2026 |
| `life_os_onboarding_backend.md` | 0.1 | February 16, 2026 |
| `life_os_analytics_catalog.md` | 0.1 | February 16, 2026 |
| `life_os_functional_matrix.md` | 0.5 | May 28, 2026 |
| `life_os_data_lineage_matrix.md` | 0.3 | February 9, 2026 |
| `life_os_build_backlog.md` | 0.5 | February 4, 2026 |
| `life_os_e2e_test_checklists.md` | 0.4 | February 4, 2026 |
| `life_os_e2e_master_matrix.md` | 0.2 | February 4, 2026 |
| `life_os_qa_master_pack.md` | 0.3 | February 4, 2026 |
| `life_os_acceptance_checklists.md` | 0.2 | February 4, 2026 |
| `life_os_ux_benchmarks.md` | 0.1 | February 4, 2026 |
| `life_os_cis_edge_cases.md` | 0.1 | February 4, 2026 |
| `life_os_doc_audit_verified.md` | — | February 6, 2026 |

## Naming conventions (recommended)

- **IDs:** snake_case in SQL, camelCase in JSON, Swift lowerCamelCase.
- **Units:** always store *normalized* value + unit; preserve original value/unit when extracted from documents.
- **Timestamps:** `TIMESTAMPTZ` on the server; ISO 8601 in APIs.

## Runtime configuration

- The iOS app expects `SUPABASE_URL` and `SUPABASE_ANON_KEY` through build settings / environment / `Info.plist` expansion.
- Checked-in placeholder values intentionally keep secrets out of the repo.
- When those values are not provided, the app now stays in explicit offline-local mode:
  - local database features continue working
  - auth bootstrap does not attempt cloud sign-in
  - sync / PostgREST / Edge calls short-circuit instead of hitting `localhost.invalid`
- Cloud auth, sync, exports, and AI edge routes require a real Supabase project configuration.

## Release gate

- CI workflow: `.github/workflows/release-gate.yml`
- Local all-in-one gate: `bash scripts/run_release_gate_local.sh`
- Local release/profiling scripts now default to a temporary artifact root outside the repo.
  - Override with `LIFEOS_ARTIFACTS_DIR=/absolute/path` if you want to keep artifacts.
- iOS sync contract gate (registry + fixtures contracts + sync perf bench): `bash scripts/run_ios_sync_contract_gate.sh`
- Refresh sync contract fixtures from live API snapshots:
  - `SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... python3 scripts/refresh_sync_contract_fixtures.py --user-id <uuid>`
  - The refresh script now fails fast if `health_measurement.json` drifts back to legacy keys instead of the canonical server contract.
- Supabase edge e2e only: `bash scripts/run_supabase_edge_e2e.sh`
- Supabase edge load only: `bash scripts/run_supabase_edge_load.sh`
- Supabase edge soak only: `bash scripts/run_supabase_edge_soak.sh`
- iOS performance hard-gates only (startup/memory/sync latency): `bash scripts/run_ios_performance_hard_gates.sh`
- Pre-prod security pass (keys/transport/rate-limit/abuse): `bash scripts/run_preprod_security_pass.sh`
- Production configuration preflight (env completeness + key/URL format, no secret printing): `bash scripts/check_production_config.sh` (add `--strict` to also fail on missing optional integrations)
- Include soak phase in full local gate: `RUN_EDGE_SOAK=1 bash scripts/run_release_gate_local.sh`
- iOS pre-prod real-device smoke (APNs/HealthKit/background prechecks): `bash scripts/run_ios_preprod_real_device_smoke.sh`
- iOS profiling guide (Settings/Sync): `ios/PROFILING.md`
