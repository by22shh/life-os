# LIFE OS — Technical Architecture & Tech Stack

**Version:** 0.8  
**Date:** February 9, 2026  
**Purpose:** Lock an implementation-ready technical blueprint (client + server + AI + watch) that matches the existing PRD/UX/API specs and supports a one-shot build without hidden architectural gaps.

**Aligns with:**
- PRD: `life_os_prd_v7_ultimate.md` (v7.11)
- UX: `life_os_ux_screens.md` (v0.11)
- Design System: `life_os_design_system.md` (v2.24)
- API: `life_os_api_specification.md` (v2.2)
- HealthKit: `life_os_healthkit_spec.md` (v1.1)
- watchOS: `life_os_watchos_spec.md` (v0.3)
- Copy: `life_os_copy_catalog.md` (v1.14)
- Error handling: `life_os_error_handling.md` (v2.0)
- Sync engine: `life_os_sync_engine_spec.md` (v0.4)

---

## 0) Non-Negotiables (System Invariants)

- Recovery zones are fixed: `critical 0–24`, `caution 25–49`, `ready 50–74`, `optimal 75–100`.
- Low-confidence threshold is fixed: `< 0.65` requires review; avoid risky one-tap actions when below.
- Notifications hard cap is fixed: `<= 6/day` with quiet hours enforcement.
- Control model is fixed: `advisory | protective | guardian`.
- Vector store is fixed: `Pinecone` (server-side only).
- Guardian requires Focus Control permission; if not granted, fall back to Protective.
- If `critical_only=true`, force control level to Advisory AND `focus_control_enabled=false`.
- HealthKit is read-only (no writes) in V1 and V2.
- watchOS is a companion in V2: no core workflows, no direct backend calls.

---

## 1) Recommended Tech Stack (Default)

### 1.1 iOS App (V1/V2)

- Language/UI: Swift + SwiftUI
- Concurrency: Swift Concurrency (`async/await`, `actors`)
- State management (recommended): TCA (The Composable Architecture)
- Local persistence (offline-first): SQLite + GRDB
- Networking: `URLSession` + typed `APIClient` + strict request/response models
- Background work: BackgroundTasks (`BGAppRefreshTask`, `BGProcessingTask`)
- Notifications: UserNotifications (`UNUserNotificationCenter`) + APNs
- HealthKit: anchored queries + background delivery (per `life_os_healthkit_spec.md`)
- Focus Control (Guardian): FamilyControls + ManagedSettings

### 1.2 watchOS Companion (V2)

- UI: SwiftUI
- Complications: WidgetKit
- Sync: WatchConnectivity (host-prepared snapshot only)
- Storage: encrypted snapshot cache (minimal payload)

### 1.3 Backend

- Platform: Supabase (Auth + Postgres + RLS)
- Server logic: Supabase Edge Functions (Deno + TypeScript)
- Storage: Supabase Storage for media (food photos, label scans) with retention rules
- Async processing: job-like pattern via tables + functions + polling (already used for Labs OCR)

### 1.4 AI / Intelligence Layer

- Invocation: only via Edge Functions (keys and policies never ship to the client)
- Provider gateway (LOCKED): OpenRouter (OpenAI-compatible API surface)
- RAG/Memory: opt-in embeddings; derived-only; no raw sensitive docs in vectors (per privacy spec)
- Determinism: AI outputs must be stored with `confidence` and surfaced with review rules

---

## 2) High-Level Architecture

### 2.1 Layering (Client)

1. Presentation
- SwiftUI views
- Navigation + UI state

2. Domain
- Use-cases (log meal, mark supplement taken, resolve workout conflict, compute next action)
- Policies (guardian rules, low-confidence safety, notification caps)

3. Data
- LocalStore (GRDB) for cached reads + offline writes
- RemoteStore (Supabase REST/Edge Functions) for canonical sync
- SyncEngine (outbox + retries + dedupe + conflict rules)

### 2.2 Server-Side Derivation

The server should own derived, deterministic aggregates whenever possible:
- `/api/recovery/daily`
- `/api/sleep/daily`
- `/api/diary/daily` (Unified Daily Diary V2)
- calendar range endpoints (max 62 days)

Reason: fast client rendering, fewer fan-out calls, consistent behavior across devices.

---

## 3) Offline-First Sync Model (Outbox)

> Source of truth: `life_os_sync_engine_spec.md`.  
> This section stays high-level; the Sync Engine spec defines the local schema, replay ordering, and backoff rules.

### 3.1 Core Idea

- All user write actions create a local Outbox item first.
- Outbox items are replayed to the server when connectivity is available.
- Server responses are merged back into local tables (with stable IDs).

### 3.2 Local Tables (Conceptual)

- `outbox_events`
- `local_cache_*` tables for diary payloads and module day payloads
- `sync_state` table (last sync timestamps, anchors, cursors)

### 3.3 Idempotency and Deduplication

- Every write request must carry an `idempotency_key` (UUID) stored in the Outbox.
- Server stores and rejects duplicates safely (or returns the original result).
- HealthKit imports dedupe by HealthKit identifiers as per `life_os_healthkit_spec.md`.

### 3.4 Conflict Resolution Principles

- User edits override AI fields (e.g., `user_corrected=true`).
- Imported vs manual conflicts must prompt the user (never silent).
- Soft delete + undo windows must be stable across offline sync.

---

## 4) Data Flow (Event-Driven Intelligence)

### 4.1 Triggering Events (Examples)

- HealthKit ingest completed (sleep/HRV/RHR/workouts)
- Meal logged/edited/undone
- Supplement marked taken
- Labs OCR completed + reviewed
- Daily wellbeing check answered

### 4.2 Pipeline (Server)

1. Persist the fact (authoritative table)
2. Update derived daily aggregates (deterministic)
3. Generate insights/recommendations (only when safe and data is sufficient)
4. Notification candidate creation (respect caps, quiet hours, confidence)
5. Write `next_best_action` back into day payload or recommendations store

### 4.3 Safety Gates

- If any input confidence is `< 0.65`, avoid strong recommendations and prefer:
  - review prompts
  - neutral insights
  - routing to iPhone for confirmation (especially from watch)

---

## 5) Notifications Architecture (Recommended: Hybrid)

### 5.1 Why Hybrid

- iOS local notifications are more precise for quiet hours and delivery windows.
- Server is best for computing priority, eligibility, and daily caps based on global context.

### 5.2 Split of Responsibilities

Server:
- compute candidates and priorities
- enforce global hard cap and quiet-hours constraints in the decision logic

Client:
- schedule local notifications for the next window
- coalesce and cancel obsolete notifications on state changes

Hard rule: never exceed 6/day, regardless of where the schedule is decided.

---

## 6) watchOS (V2) Architecture

### 6.1 Networking Rule

- watchOS app never calls backend directly in V2.
- iPhone host fetches `/api/watch/snapshot` and syncs via WatchConnectivity.

### 6.2 Snapshot Cache

- store last snapshot encrypted on watch
- show `watch.last_updated` and disable actions when phone unreachable

### 6.3 Allowed One-Tap Actions

- supplement taken (host performs `POST /api/supplements/log`)
- insight acknowledge (host performs `POST /api/insights/{id}/acknowledge`)

Everything else routes via `global.open_on_iphone`.

---

## 7) Security & Privacy Implementation Notes

- Supabase RLS must be enabled for all user tables.
- Media retention and storage mode must follow `life_os_privacy_architecture.md`.
- Secrets (AI keys, provider tokens) must live only in Edge Functions env vars.
- Local encrypted storage:
  - tokens
  - any locally cached sensitive snapshot
  - local-only preferences like Focus Control selected apps

---

## 8) Observability (Non-Optional)

Client:
- structured logs for sync (outbox enqueue, replay result, conflicts)
- crash reporting (opt-in if needed)
- performance metrics for critical screens (diary load, logging flows)

Server:
- request logs + latency histograms for SLO endpoints
- AI cost accounting + rate-limit alerts
- background job success rates (labs OCR, insights generation)

---

## 9) Release Architecture Boundaries (V1 vs V2)

### 9.1 V1 (iOS MVP)

- module diaries (nutrition/training/supplements)
- HealthKit ingest + recovery aggregates
- labs OCR flow
- notifications settings + control levels + Focus Control (guardian)

### 9.2 V2

- Unified Daily Diary endpoints + UI
- Sleep diary + dedicated sleep surfaces
- Templates management
- Insights & Experiments surfaces
- watchOS companion (snapshot + complications + glance + safe one-taps)

---

## 9A) Force Update / Minimum Version Strategy

- Server includes `X-Min-App-Version` header (semver) in all authenticated API responses.
- Client compares its build version against `X-Min-App-Version` on every response.
- **Blocking update:** If `client_version < X-Min-App-Version`, show full-screen "Update Required" overlay with direct App Store link. Outbox push is paused until updated. Offline reading of local data remains available.
- **Soft nudge:** If client is within one minor version of minimum, show non-blocking "Update available" banner once per session.
- **Grace period:** 48 hours after server-side minimum version change before enforcement, to allow App Store propagation.
- **Canonical invariant:** `life_os_invariants.md` §14.

---

## 9B) Background Task Budget Management

iOS limits background execution. Life OS registers multiple `BGTaskRequest` types. When the system grants limited budget, prioritize in this order:

| Priority | Task | Identifier | Frequency |
|----------|------|------------|-----------|
| 1 (highest) | **Outbox push** | `app.lifeos.sync.push` | On connectivity change + every 15 min |
| 2 | **HealthKit incremental sync** | `app.lifeos.healthkit.sync` | Every 1 hour |
| 3 | **Pull sync** (server → local) | `app.lifeos.sync.pull` | Every 30 min |
| 4 | **Widget snapshot refresh** | `app.lifeos.widget.refresh` | Every 30 min |
| 5 | **watchOS snapshot push** | `app.lifeos.watch.push` | Every 1 hour |
| 6 (lowest) | **SQLite backup** | `app.lifeos.db.backup` | Daily |

**Fallback behavior:**
- If iOS defers a task, it will run at the next available window. No data loss occurs because the Outbox preserves writes.
- If a background task is killed mid-execution, it must be idempotent and resume cleanly on next invocation.
- Use `BGProcessingTask` for SQLite backup (long-running); use `BGAppRefreshTask` for all others.

---

## 9C) Feature Flags / Kill Switches

**Implementation:** Remote configuration via Supabase Edge Function (`GET /api/config/feature-flags`).

**Default flags (V2 launch):**

| Flag | Default | Purpose |
|------|---------|---------|
| `ai_food_photo_enabled` | `true` | Kill switch for AI photo analysis |
| `ai_voice_logging_enabled` | `true` | Kill switch for AI voice parsing |
| `ai_lab_ocr_enabled` | `true` | Kill switch for lab OCR |
| `ai_insights_enabled` | `true` | Kill switch for AI-generated insights |
| `openrouter_available` | `true` | Global kill switch for all OpenRouter calls |
| `guardian_mode_enabled` | `true` | Kill switch for Focus Control features |
| `batch_recipes_enabled` | `true` | Gradual rollout for meal prep |

**Rules:**
- Client fetches flags on app launch and caches them locally (TTL: 1 hour).
- If the fetch fails, use cached values. If no cache exists, use hardcoded defaults (all `true`).
- When a kill switch is `false`, the affected feature gracefully degrades to manual entry / cached data.
- **OpenRouter kill switch:** When `openrouter_available = false`, all AI-dependent features show: "AI features are temporarily unavailable. You can log manually."

---

## 9D) Server-Side Monitoring & Alerting

| Metric | Source | Warning Threshold | Critical Threshold |
|--------|--------|-------------------|--------------------|
| Edge Function p95 latency | Supabase dashboard | > 2s | > 5s |
| Edge Function error rate (5xx) | Supabase logs | > 2% | > 10% |
| OpenRouter API latency (p95) | Custom telemetry | > 3s | > 8s |
| OpenRouter API error rate | Custom telemetry | > 5% | > 15% (auto-enable kill switch) |
| Database connection pool | Supabase metrics | > 70% utilization | > 90% utilization |
| Auth failure rate | Supabase Auth logs | > 5% of attempts | > 20% of attempts |
| Outbox replay server-side failure rate | Custom telemetry | > 5% in 1 hour | > 15% in 1 hour |
| APNs delivery failure rate | Apple developer dashboard | > 3% | > 10% |

**Alerting:**
- Warning → Slack channel notification.
- Critical → Slack + email to on-call + automatic OpenRouter kill switch if AI error rate exceeds critical threshold.
- All alerts include: metric name, current value, threshold, time window, and suggested action.

---

## 9E) Cost Management

### OpenRouter API Budget
- **Per-user monthly budget:** Soft cap at $0.50/user/month for AI calls.
- **Tracking:** Edge Functions log `model`, `prompt_tokens`, `completion_tokens`, `cost_usd` per call.
- **Overage protection:** If a single user exceeds 3x the per-user budget in a rolling 24h window, throttle their AI calls to 1 per 5 minutes.
- **Dashboard:** Weekly cost report aggregated by model, feature, and user cohort.

### Storage
- **Food photos:** Resized to max 1024px before upload. JPEG quality 80%. Estimated 200KB/photo.
- **Lab scan PDFs:** Stored as-is. Average 2MB/scan.
- **Retention:** Food photos deleted after 90 days (privacy spec). Lab scans retained per user preference.
- **Projected cost:** ~$0.02/user/month for storage at 50 photos + 1 scan/month.

### Supabase Tier Planning
- **MVP → 1k users:** Free tier is sufficient.
- **1k → 10k users:** Pro tier ($25/month). Monitor Edge Function invocations.
- **10k+ users:** Team tier. See §14 (Supabase Scalability Monitoring) in the Engineering Blueprint.

---

## 10) LOCKED Decisions (Do Not Re-Open Without Version Bump)

These decisions are **locked** to prevent churn and enable one-shot implementation quality.

1. Platforms: Apple-only (near-term)
- iOS 17+ is the primary platform.
- watchOS 9+ ships only as a V2 companion (no core workflows).
- No Android/web targets until after a stable V2 is shipped.

2. iOS architecture: SwiftUI + TCA
- Use SwiftUI for UI.
- Use TCA for state management on complex flows (Diary, logging, sync, settings/control, insights).
- Use Swift Concurrency as the default execution model.

3. Offline posture: full offline-first with Outbox
- All user writes enqueue locally first and replay to server (idempotent).
- Local cache is authoritative for offline reads; server becomes authoritative after sync.

4. Local persistence: SQLite + GRDB
- GRDB is the default for migrations, queries, and building the Outbox reliably.

5. Backend: Supabase (Postgres + RLS) + Edge Functions
- Auth via Supabase Auth (JWT).
- Data via Postgres with RLS enabled on all user-owned tables.
- All secret-bearing logic (providers, AI keys, policies) lives in Edge Functions.

6. AI execution: cloud-only via Edge Functions (V1/V2)
- No on-device LLM in V1/V2.
- All AI calls go through Edge Functions and must persist confidence + “why”.
- RAG/embeddings remain opt-in and derived-only (privacy posture enforced).

6A. AI gateway: OpenRouter (LOCKED)
- All LLM/VLM requests are sent from Edge Functions to OpenRouter (never from clients).
- Treat OpenRouter as the single outbound AI gateway (provider routing is a config concern).
- Secrets:
  - store `OPENROUTER_API_KEY` only in Edge Functions environment variables
  - optionally store `OPENROUTER_BASE_URL` (defaults to OpenRouter OpenAI-compatible base URL)
  - never log prompts/responses containing sensitive data
- API compatibility:
  - use an OpenAI-compatible request/response contract to simplify swapping models
  - model IDs must be expressed as OpenRouter model slugs (implementation config)

6B. Model routing policy (LOCKED)
- Source of truth for per-feature primary/fallback models: `life_os_gpt_prompts.md` → `AI_CONFIGS`.
- Defaults (can be changed only via version bump + drift check):
  - primary for critical analyses: `openai/gpt-4o`
  - first fallback: `openai/gpt-4-turbo`
  - last-resort degraded mode: local fallback where defined (Core ML / templates / manual entry)

7. Notifications: hybrid scheduling (server candidates, client scheduling)
- Server computes candidate notifications and priorities, respecting caps/quiet hours rules.
- Client schedules local notifications for precision and cancels/coalesces on state changes.
- Hard cap `<= 6/day` is absolute.

8. watchOS V2: host-only networking + snapshot-driven UI
- watchOS never calls the backend directly in V2.
- iPhone host fetches `GET /api/watch/snapshot?date=...` and syncs it via WatchConnectivity.
- Only safe one-tap actions on watch:
  - supplement taken → host `POST /api/supplements/log`
  - insight acknowledge → host `POST /api/insights/{id}/acknowledge`
- All other actions route via `global.open_on_iphone`.

### Change Control (When We *Do* Re-Open)

If we must change any locked decision:
1. Bump `life_os_technical_architecture.md` version.
2. Update affected specs:
   - `life_os_api_specification.md` (sync semantics, endpoints, auth flows)
   - `life_os_error_handling.md` (offline/error states)
   - `life_os_e2e_test_checklists.md` (offline and multi-device expectations)
   - `life_os_watchos_spec.md` (if watch behavior changes)
3. Run a drift check:
   - recovery zones, confidence threshold, notification caps, control model
