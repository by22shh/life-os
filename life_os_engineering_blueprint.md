# LIFE OS — Engineering Blueprint (Tech Stack, Architecture, Delivery)

**Version:** 0.6
**Date:** February 16, 2026
**Purpose:** A practical, implementation-facing blueprint that answers “what do we build, with what technologies, and how do we ship it safely” — optimized for one-shot code generation and fast team onboarding.

**Aligns with:**
- PRD: `life_os_prd_v7_ultimate.md` (v7.11)
- UX: `life_os_ux_screens.md` (v0.11)
- Design System: `life_os_design_system.md` (v2.24)
- API: `life_os_api_specification.md` (v2.3)
- Error handling: `life_os_error_handling.md` (v2.0)
- Sync engine: `life_os_sync_engine_spec.md` (v0.4)
- AI prompts: `life_os_gpt_prompts.md` (v1.5)
- Technical architecture: `life_os_technical_architecture.md` (v0.6)
- HealthKit: `life_os_healthkit_spec.md` (v1.1)
- watchOS: `life_os_watchos_spec.md` (v0.3)
- Privacy: `life_os_privacy_architecture.md` (v1.5)

---

## 0) Hard Constraints (Locked)

1. **Offline-first.** Local write → Outbox → replay with idempotency (no lost input).
2. **AI gateway (LOCKED): OpenRouter only.** Keys/policies never ship to client. All LLM calls run via Edge Functions.
3. **Vector store (LOCKED): Pinecone.** Vector memory is server-only; no client access.
4. **Apple-only near term.** iOS is primary; watchOS is a V2 companion (no direct backend calls).
5. **Safety invariants are non-negotiable:**
   - Recovery zones: critical 0–24, caution 25–49, ready 50–74, optimal 75–100
   - Low confidence: `< 0.65` → review-required behavior
   - Notifications: `<= 6/day` hard cap + quiet hours
   - Control model: `advisory | protective | guardian` (Guardian requires Focus Control)

---

## 1) Repository Layout (Recommended)

This repo currently contains docs only. When creating the real codebase, use a structure that mirrors system boundaries:

```
life-os/
  ios/
    LifeOS.xcodeproj (or .xcworkspace)
  ios/
    LifeOS.xcodeproj (or .xcworkspace)
    LifeOS/
      AppShell/
      LifeOSApp.swift
      Modules/
        AppShell/
      Diary/
      Nutrition/
      Training/
      Supplements/
      Sleep/
      Labs/
      Insights/
      Settings/
      Shared/
    LifeOSTests/
  watch/
    LifeOSWatchApp/
    LifeOSComplications/
  supabase/
    migrations/
    functions/
      api/ (Edge Functions for /api/*)
      ai/  (OpenRouter gateway wrappers)
  tools/
    scripts/
```

**Rule of thumb:** a “module” maps to a user mental model surface (Nutrition, Training…).
*Note: In V1, core models and database logic are centralized in `Shared/Models` and `Shared/Database` to simplify dependency management.*

---

## 2) iOS App Architecture (Implementation-Ready)

### 2.1 Stack

- Swift + SwiftUI
- Swift Concurrency (`async/await`, `Task`, actors)
- TCA (recommended default for complex flows)
- GRDB + SQLite (LocalStore)
- URLSession + typed API client (RemoteStore)
- BackgroundTasks (`BGAppRefreshTask`, `BGProcessingTask`)
- UserNotifications + APNs
- HealthKit (read-only)
- Focus Control (Guardian): FamilyControls + ManagedSettings

### 2.2 App Layers

1. **Presentation (SwiftUI)**
- Views render `ViewState` only.
- No business logic in views; side effects via TCA effects.

2. **Domain**
- Use cases: log meal, log workout, mark supplement taken, resolve conflicts, generate next-best-action.
- Policies: confidence gating, guardian rules, notification caps, time-zone/local-date rules.

3. **Data**
- LocalStore (GRDB) is the single source of truth for UI reads.
- RemoteStore writes happen via the Outbox replay to `/api/*`.
- Pull is table-based (PostgREST) using `updated_at` watermarks.

### 2.3 Navigation & Deep Links

- One global router in AppShell.
- Deep links should target:
  - Diary day (date)
  - Meal detail (food_log_id)
  - Workout detail (session_id)
  - Sleep day
  - Batch detail (batch_id)
  - Labs scan review (scan_id)
  - Insight detail (insight_id)

### 2.4 Local Date Model (Do Not Deviate)

Client always sends `*_date` computed in the user’s timezone (see API spec “TIME ZONE + LOCAL DATE MODEL”):
- meals: `food_logs.logged_date`
- supplements: `supplement_logs.taken_date`
- workouts: `workout_sessions.session_date`

Also send `*_timezone` and `*_utc_offset_minutes` when available for travel-correct historical display.

---

## 3) Offline-First Sync (Outbox + Pull)

> Source of truth: `life_os_sync_engine_spec.md` + API “Offline-Safe Create Contract”.

### 3.1 Non-negotiable write flow

1. Apply write locally (optimistic UI).
2. Enqueue an Outbox event with:
- `Idempotency-Key` (Outbox event UUID)
- `X-Device-Id` (stable UUID stored in Keychain)
- Body includes **client-generated record IDs** for create events.
3. Replay when online.
4. Merge server authoritative fields back into LocalStore.

### 3.2 ID Strategy

- Client generates UUIDs for all offline-capable entities (meals, items, workouts, sets, templates, batches, experiment measurements, etc.).
- For create endpoints that create multiple rows, nested IDs are required (see API contract table).

### 3.3 Practical GRDB Notes

- Keep a table per “core entity” (food_logs, food_items…).
- Add `updated_at_server` columns locally to merge safely.
- Keep “derived” payload caches (e.g., daily diary response) separate so they can be dropped/rebuilt.

---

## 4) Backend Architecture (Supabase)

### 4.1 Components

- Supabase Auth (JWT)
- Postgres (RLS on all user tables)
- PostgREST for pull-sync reads (watermark queries on `updated_at`)
- Edge Functions (Deno/TS) for:
  - all writes (`/api/*`)
  - deterministic derived endpoints (diary/sleep/recovery aggregations)
  - AI invocations (OpenRouter gateway)
- Supabase Storage for media (food photos, label scans) under privacy retention rules

### 4.2 Idempotency Implementation (Server)

Minimum viable pattern:
- Every mutation endpoint reads `Idempotency-Key`.
- If request was already applied, return the original success response.
- For creates with client IDs: `INSERT ... ON CONFLICT (id) DO UPDATE` (or equivalent upsert).

---

## 5) AI / Intelligence Layer (OpenRouter-Only)

### 5.1 Gateway Rule

- iOS/watchOS clients never call OpenRouter directly.
- Edge Functions call OpenRouter using `OPENROUTER_API_KEY`.
- Model routing and prompt templates live in `life_os_gpt_prompts.md` (source of truth).

### 5.2 Output Storage Rules

- Store AI outputs with:
  - `confidence`
  - `inputs_used` (high-level, no raw sensitive documents)
  - `version` / prompt id for reproducibility
- Enforce low-confidence behavior globally (`< 0.65`).

### 5.3 Guardrails

- Medical-risky suggestions must be phrased as hypotheses + “ask your clinician” bounds per prompt library rules.
- Never use AI to silently mutate user-entered facts without a review step.

---

## 6) watchOS Companion (V2)

### 6.1 Data Flow

1. iPhone calls `GET /api/watch/snapshot`.
2. iPhone syncs snapshot to watch via WatchConnectivity.
3. watch renders:
  - complication
  - glance screen
  - safe one-taps (routed to phone)

### 6.2 No Direct Backend Calls

watchOS must not include Supabase/OpenRouter keys and must not call backend in V2.

---

## 7) Observability (Must-Have)

Client:
- structured logs for sync (enqueue/replay/result)
- performance metrics on diary payload load
- crash reporting (opt-in policy per privacy spec)

Server:
- endpoint latency histograms for SLO endpoints
- AI cost telemetry (tokens, model, latency, error rate)
- async job success tracking (labs OCR, insight generation)

---

## 8) Testing Strategy (One-Shot Ready)

### 8.1 Unit Tests

**Coverage targets:**

| Module | Target | Rationale |
|--------|--------|----------|
| Recovery algorithms (scoring, EWMA, ACWR) | ≥ 95% | Safety-critical; boundary conditions must be exhaustively tested |
| Confidence scoring + gates | ≥ 95% | Determines risky one-tap behavior |
| Notification policy (caps, quiet hours, priority) | ≥ 90% | User-facing, cap enforcement |
| Local date / timezone mapping | ≥ 90% | Correctness-critical for travel users |
| Sync engine (outbox ordering, retry, backoff) | ≥ 90% | Data integrity |
| HealthKit aggregation (sleep, HRV, RHR) | ≥ 85% | Deterministic output requirement |
| Food data normalization (kJ→kcal, salt→sodium) | ≥ 85% | CIS-critical |
| AI output parsing + validation | ≥ 80% | Prompt injection defense |
| UI ViewModels / Reducers | ≥ 70% | Logic-heavy reducers only |

**Property-based tests (required):**
- Recovery score: all inputs in valid ranges → output always [0, 100]
- ACWR cold-start: with < 21 days of data → uses padded TRIMP floor, never divides by zero
- Confidence scoring: adding more data sources never decreases confidence
- Notification cap: no combination of triggers produces > 6 notifications/day

**Mock strategies:**
- HealthKit: use `HealthKitMock` protocol for injecting deterministic sample sets
- Network: use `URLProtocol` subclass for offline/error simulation
- AI/OpenRouter: use stub responses from versioned JSON fixtures
- Time/Date: inject `Clock` protocol for deterministic date testing

### 8.2 Snapshot Tests

- Recovery score card (all 4 zones × light/dark × default/AX5 Dynamic Type)
- Nutrition diary day view (empty, partial, full)
- Supplement schedule (pending, taken, missed)
- Error/low-confidence banners

### 8.3 Integration Tests

- Sync engine outbox ordering + retry/backoff
- Idempotent replay (send same event twice; ensure no duplicates)

### 8.4 UI Tests

- Onboarding happy path
- "Log meal from photo" review gate
- Batch log flow
- Watch snapshot render + "open on iPhone" routing

### 8.5 Spec-Driven E2E

- Use `life_os_e2e_test_checklists.md` as a required acceptance harness.

---

## 9) CI/CD (Recommended Baseline)

- iOS: Xcode Cloud or GitHub Actions
  - build + unit tests on PR
  - UI smoke tests nightly
  - TestFlight deploy on main tag
- Supabase:
  - migrations folder is the source of truth
  - Edge Functions deployed from `supabase/functions/`
  - separate staging vs production projects

---

## 10) Migration Strategy

### 10.1 Database Migrations (Supabase)

All schema changes are managed as sequential, idempotent SQL migration files.

**Directory:** `supabase/migrations/`

**Naming convention:**
```
YYYYMMDDHHMMSS_description.sql
e.g., 20260212120000_add_hydration_logs.sql
```

**Rules:**
1. **Forward-only.** Never modify a migration file after it has been applied to staging. Create a new migration instead.
2. **Idempotent where possible.** Use `CREATE TABLE IF NOT EXISTS`, `CREATE INDEX IF NOT EXISTS`, and `DO $$ ... $$` blocks for conditional logic.
3. **No destructive operations in V1.** Column drops, table drops, and data deletions require a 2-step process:
   - Migration 1: Mark as deprecated (add comment, rename with `_deprecated` suffix)
   - Migration 2 (after 30 days): Drop (only after confirming no production reads)
4. **Data migrations** (backfills, transforms) are separate files suffixed `_data_backfill.sql` and must be wrapped in a transaction with a `SAVEPOINT`.
5. **RLS policies** must be included in the same migration as the table they protect — never create a table without RLS.

### 10.2 Local Schema (GRDB / iOS)

**Directory:** `ios/LifeOSModules/Shared/Database/Migrations/`

**Naming:** Swift enum cases, e.g., `v1_addHydrationLogs`.

**Rules:**
1. GRDB migrations run on first app launch or app update.
2. Each migration is a `DatabaseMigrator.registerMigration` block.
3. Destructive local migrations (drop table, drop column) are allowed only when the data can be re-pulled from the server.
4. Keep a `SchemaVersion` table locally with the last applied migration name for debugging.
5. **Outbox safety:** If a migration changes the schema of a table with pending outbox events, the migration must first drain/replay all pending events for that table before altering the schema. If drain fails (offline), defer the migration to next launch.
6. **Failure handling:** Wrap each migration in a transaction. If a migration fails mid-flight, GRDB rolls back the transaction automatically (SQLite WAL). The app retries on next launch. If retry fails 3 times, show a "Data repair needed" screen with option to reset local database and re-pull from server.
7. **No partial state:** Never allow a migration to leave the database in a partially-migrated state. Either the full migration succeeds or it rolls back entirely.

### 10.3 Migration Testing

- Every migration must be testable against a fresh database AND against the previous state.
- CI runs: `supabase db reset && supabase db push` on every PR to validate migration chain.
- Staging environment mirrors production schema; migrations are applied to staging first and soaked for 48h before production.

### 10.4 Rollback Strategy

- Supabase does not support native rollback. For every migration, maintain a companion `_rollback.sql` file (not auto-applied; manual use only).
- Rollback files reverse the migration's effects (drop added tables, re-add dropped columns, restore old constraints).
- Keep rollback files in `supabase/migrations/rollbacks/` — same timestamp prefix.

---

## 11) Build Sequence (Low-Risk Order)

1. LocalStore schema + migrations + basic screens rendering from local data
2. Auth + read-only pulls (PostgREST) for core tables
3. Outbox + idempotent write endpoints (`/api/food/log`, `/api/workouts/log`, `/api/supplements/log`)
4. Derived daily endpoints (diary/day, sleep/day)
5. Labs scan pipeline (local-only default) + review UI
6. Notification policy engine + scheduling
7. watch snapshot endpoint + WatchConnectivity + complications

---

## 12) Performance Budgets

| Metric | Target | Measurement Method |
|--------|--------|-------------------|
| **App cold launch** → Home screen | ≤ 2.0 seconds | Instruments, `os_signpost` |
| **App warm launch** → Home screen | ≤ 0.5 seconds | Instruments |
| **Time to first recovery score** (after HealthKit backfill) | ≤ 15 seconds | E2E test timer |
| **Diary day load** (local) | ≤ 200ms | `os_signpost` |
| **Food photo analysis** (end-to-end) | ≤ 8 seconds (p95) | Server telemetry |
| **Lab scan OCR** (end-to-end) | ≤ 20 seconds (p95) | Server telemetry |
| **Edge Function cold start** | ≤ 1.5 seconds | Supabase dashboard |
| **API response time** (PostgREST reads) | ≤ 300ms (p95) | Server telemetry |
| **API response time** (write endpoints) | ≤ 500ms (p95) | Server telemetry |
| **Outbox replay** (single event) | ≤ 2 seconds | Client telemetry |
| **HealthKit incremental sync** | ≤ 5 seconds | Client telemetry |
| **Local DB query** (any single query) | ≤ 50ms | GRDB statistics |

> [!WARNING]
> If Edge Function cold start exceeds 1.5 seconds consistently for AI endpoints (food photo, lab scan), consider migrating those endpoints to a dedicated server (Fly.io / Railway) with persistent warm instances.

---

## 13) TCA Adoption Guidelines

The Composable Architecture (TCA) is the recommended state management framework for complex flows. To mitigate adoption risk:

**Use TCA for:**
- Onboarding wizard (multi-step, stateful)
- Food logging wizard (method picker → photo/barcode/voice → review → save)
- Workout logging (sets, exercises, timer, save)
- Lab scan pipeline (capture → OCR → review → save)
- Settings screens with interdependent state

**Use plain SwiftUI + `@Observable` for:**
- Simple read-only screens (trends, charts, recovery card)
- Static information screens (about, privacy policy)
- Simple forms with independent fields

**Risk mitigation:**
- Pin TCA dependency to a specific minor version (e.g., `1.9.x`).
- Avoid TCA's advanced features (SharedState, PersistenceKey) until stable.
- Keep a "migration escape hatch": domain logic in the `Domain` layer (not in Reducers) so it can survive a TCA swap.

**Learning curve guidance:**
- Estimated ramp-up time for a developer new to TCA: **2–4 weeks** to productive, 6–8 weeks to fluent.
- Recommended onboarding path: (1) read TCA README + Tutorial, (2) implement a simple screen (Settings), (3) implement a complex screen (Food Logger) with pairing.
- Assign TCA-experienced developer as reviewer for first 2–3 PRs per team member.

**CI-specific considerations:**
- TCA `TestStore` tests are CPU-intensive. Allocate CI runners with ≥ 4 cores for unit test jobs.
- Snapshot tests for TCA-driven views: run nightly (not per-PR) to reduce CI time.
- Monitor TCA compile times: if module compile time exceeds 15s, extract sub-features into separate modules.

---

## 14) Supabase Scalability Monitoring

**Near-term (MVP → 10k users):** Supabase is fully adequate.

**Mid-term (10k → 100k users) — monitor these signals:**

| Signal | Threshold | Action |
|--------|-----------|--------|
| Edge Function p95 latency (AI endpoints) | > 3 seconds | Consider dedicated API server for AI |
| Edge Function cold starts / hour | > 50 | Enable concurrency reservations |
| Database connection pool exhaustion | > 80% utilization | Upgrade Supabase plan or add read replica |
| Storage egress (food photos) | > 100GB/month | Add CDN layer or reduce photo retention |
| Edge Function execution time limit hits | Any | Split long-running AI chains into async jobs |

**Long-term (100k+ users):** Re-evaluate whether to migrate AI-heavy endpoints to a dedicated server with persistent connections and GPU access.

---

## 15) App Store Review Strategy

### FamilyControls Entitlement (Guardian Mode)

**Risk:** Apple requires a specific entitlement (`com.apple.developer.family-controls`) for apps that use `FamilyControls` / `ManagedSettings` frameworks. They strictly reject apps that appear to "lock down" a device arbitrarily or act as unauthorized parental controls.

**Strategy (The "Trojan Release" & Positioning):**
1. **Positioning (CRITICAL):** In all App Store review notes and user-facing copy, **never** use terms like "lock down," "parental control," or "device restriction." Always use terms like: *Digital Wellbeing*, *Focus Mode*, *Self-Regulation*, and *Recovery Shield*. We must position this alongside apps like Opal or Forest as a self-initiated productivity/health tool.
2. **The "Escape Hatch" (Mandatory Architectural Pattern):** Apple will reject the app if the user cannot turn off the restrictions. The UI MUST have an "Emergency Override" button. To preserve the psychological friction of Guardian mode, this override must not be a simple tap. It requires **cognitive friction**: for example, holding the button for 15 seconds, solving a complex math problem, or waiting for a 5-minute dismiss timer.
3. **Initial V2 Submission (The Trojan):** Submit V2 **without** Guardian mode enabled. Use feature flag `guardian_mode_enabled = false` server-side. The app will only use Advisory and Protective levels (push notifications and nudges, no system blocking).
4. **Entitlement Application:** While V2 is live, apply for the `FamilyControls` entitlement via the Apple Developer portal. Provide:
   - Use case: user-initiated screen time reduction for sleep and health recovery.
   - Proof of Escape Hatch: "The user is always in control and can explicitly disable the shield via the Emergency Override."
5. **Post-Approval Flip:** Once the entitlement is granted, release a minor update or simply flip `guardian_mode_enabled = true` on the server.
6. **Fallback:** If entitlement is completely denied, Guardian mode gracefully degrades to Protective (strong UX nudges, full-screen covers within our app, but no OS-level app blocking).

**Review documentation to prepare:**
- Demo video showing Guardian mode opt-in flow AND the Escape Hatch procedure.
- Screenshots of all Focus Control permission dialogs.
- List of all restricted actions and their time-bounds.
- Privacy policy section explicitly covering data used for screen time regulation.

### General Review Tips
- Include a demo account in App Review notes (with pre-seeded data for 7+ days)
- Document all health-related claims and their non-medical positioning
- Ensure HealthKit usage description strings are specific and non-generic

---

## 16) Load Testing Strategy

**Tooling:** k6 (JavaScript-based, open-source) for API load testing. Run against a staging Supabase project.

### SLO Validation Tests

| Endpoint Category | Target p95 | Target Throughput | Test Duration |
|------------------|-----------|-------------------|---------------|
| Sync push (`POST /api/food/log`, etc.) | < 400ms | 100 req/s | 10 min |
| Sync pull (`GET /api/food-logs?updated_at>...`) | < 300ms | 200 req/s | 10 min |
| AI photo analysis (`POST /api/nutrition/analyze-photo`) | < 5s | 20 req/s | 5 min |
| Lab OCR (`POST /api/labs/analyze`) | < 30s (async) | 5 req/s | 5 min |
| Auth flow (`POST /api/auth/sign-in`) | < 500ms | 50 req/s | 5 min |

### Sync Engine Stress Scenarios

1. **Burst sync after 24h offline:** 50 concurrent users each replaying 100 Outbox events simultaneously.
2. **Large pull:** User with 365 days of data does initial pull (all tables, no watermark).
3. **Concurrent multi-device:** 2 devices per user, both pushing simultaneously for 100 users.

### Run cadence
- Before every major release
- After any Supabase plan change
- After any Edge Function refactor

---

## 17) Security Testing

### RLS Policy Audit

**Requirement:** Before launch, every Supabase table with user data must pass the following RLS tests:

```sql
-- Test: User A cannot read User B's food logs
SET request.jwt.claims = '{"sub": "user-a-uuid"}';
SELECT * FROM food_logs WHERE user_id = 'user-b-uuid';
-- Expected: 0 rows returned
```

**Tables to audit:** `food_logs`, `food_items`, `workout_sessions`, `workout_sets`, `user_supplements`, `supplement_logs`, `medical_scans`, `lab_markers`, `experiments`, `experiment_measurements`, `hydration_logs`, `wellness_checks`, `body_composition`, `physiological_states`, `insights`, `recommendations`.

### JWT Validation
- Verify Edge Functions reject expired JWTs (401)
- Verify Edge Functions reject JWTs with wrong audience
- Verify Edge Functions reject requests with missing `Authorization` header
- Verify `Idempotency-Key` is validated as UUID format

### API Abuse Rate-Limit Testing
- Verify 429 response after exceeding each tier's limit
- Verify `retry_after_seconds` header is present in 429 responses
- Verify `X-Outbox-Replay: true` grants exemption up to 300/5min
- Verify per-user (not per-IP) enforcement

---

## 18) Accessibility Testing Automation

### XCTest Accessibility Audit (CI)

**Implementation:** Add `XCUIApplication.performAccessibilityAudit()` to the UI test suite (requires Xcode 15+ / iOS 17+).

**Audit categories to enable:**
- `.dynamicType` — verifies all text respects Dynamic Type
- `.contrast` — verifies color contrast meets WCAG AA (4.5:1 for text)
- `.hitRegion` — verifies touch targets ≥ 44×44 pt
- `.sufficientElementDescription` — verifies interactive elements have accessibility labels

**Run in CI:** Every PR must pass accessibility audit with zero critical findings.

### VoiceOver Smoke Tests

**Manual test script (pre-release):**
1. Navigate Home → Recovery card → Nutrition tab → Log meal (photo) with VoiceOver enabled
2. Verify all interactive elements are reachable and have meaningful labels
3. Verify zone colors are announced as text (e.g., "Recovery: Optimal, 78 percent")
4. Verify charts/graphs have `accessibilityValue` summaries

### Dynamic Type Snapshot Tests

**Implementation:** Use `swift-snapshot-testing` to capture screenshots at:
- `.body` (default)
- `.extraExtraExtraLarge` (largest standard)
- `.accessibilityExtraExtraExtraLarge` (largest accessibility)

**Screens to snapshot:** Recovery card, Nutrition diary, Workout log, Settings, Onboarding (all 8 screens).

**Rule:** No text truncation allowed at `.extraExtraExtraLarge`. Truncation at accessibility sizes is acceptable only with a "See more" affordance.

---

## 19) Notification Scheduler Architecture

> [!IMPORTANT]
> This section closes the gap between PRD notification rules (≤6/day, quiet hours, priority dropping, dedup cooldown) and the engineering implementation.

### 19.1 Architecture

The notification scheduler is a **client-side Swift actor** (`NotificationScheduler`) that runs on the iPhone. It is not a server-side cron job — this avoids server-to-APNs latency and ensures offline-created notifications still work.

```swift
actor NotificationScheduler {
    // Evaluate candidates on: app launch, foreground, morning refresh, significant data change
    func evaluatePendingNotifications() async -> [ScheduledNotification]
    
    // Called by each module to register a notification candidate
    func propose(_ candidate: NotificationCandidate) async
    
    // Returns whether a notification can be sent (checks cap, dedup, quiet hours)
    func canDeliver(_ candidate: NotificationCandidate) async -> Bool
}
```

### 19.2 Evaluation Triggers

| Trigger | When | Purpose |
|---------|------|---------|
| App launch / foreground | Every time | Re-evaluate pending queue in case context changed |
| Morning recovery refresh | 06:00–10:00 window | Schedule daily recovery notification |
| Data change (food log, workout, supplement due) | On mutation | Propose context-aware reminder |
| Background task (BGAppRefreshTask) | ~every 2-4 hours | Catch scheduled reminders (supplement, meal) |

### 19.3 Delivery Pipeline

```
Module proposes candidate
    → NotificationScheduler.propose(candidate)
    → Check quiet hours (reject if inside)
    → Check dedup cooldown (reject if same category < cooldown window)
    → Check daily cap (reject if ≥ 6 today)
    → Priority sort remaining candidates (drop lowest if over cap)
    → Schedule via UNUserNotificationCenter
```

### 19.4 Invariant Enforcement

| Rule | Source | Implementation |
|------|--------|---------------|
| ≤ 6 notifications/day | PRD, Invariants §3 | Counter persisted in UserDefaults, reset at midnight local time |
| Quiet hours | PRD, Invariants §3 | Check `notification_settings.quiet_start/end` before scheduling |
| Same-category dedup | Invariants §3 | Track `{category: lastSentAt}` in memory; cooldown = 2 hours |
| Priority dropping | PRD | Each candidate has priority (1=highest to 5=lowest); drop lowest first when at cap |

### 19.5 Push vs Local

- **Local notifications** (UNUserNotificationCenter): used for supplement reminders, meal reminders, experiment check-ins. Scheduled by the client.
- **Push notifications** (APNs via Supabase): used for server-side events: weekly reports, insight generated, experiment complete. The server calls the APNs endpoint; the client-side scheduler does NOT control these but does count them toward the daily cap by incrementing the counter when a push is received.
- **Cap coordination**: `application(_:didReceiveRemoteNotification:)` increments the local daily counter so that subsequent local notifications respect the combined cap.

---

## 20) Push Notification Backend

> Source of truth for payload format: `life_os_invariants.md` §12.

### 20.1 Architecture

```
Supabase Edge Function: send-notification
    → Reads device tokens from `device_tokens` table
    → Constructs APNs payload per invariants §12 format
    → Sends via APNs HTTP/2 (p8 key auth)
    → Logs delivery status to `notification_delivery_log`
```

### 20.2 Device Token Management

```sql
CREATE TABLE device_tokens (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token TEXT NOT NULL,
    platform TEXT NOT NULL CHECK (platform IN ('ios', 'watchos')),
    app_version TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_used_at TIMESTAMPTZ,
    is_valid BOOLEAN DEFAULT TRUE,
    UNIQUE(user_id, token)
);

ALTER TABLE device_tokens ENABLE ROW LEVEL SECURITY;
CREATE POLICY device_tokens_policy ON device_tokens
    USING (user_id = auth.uid())
    WITH CHECK (user_id = auth.uid());
```

### 20.3 Delivery Retry

| APNs Response | Action |
|---------------|--------|
| `200` Success | Mark delivered in log |
| `410` Unregistered | Set `is_valid = false` on token; don't retry |
| `429` Too many requests | Retry with exponential backoff (max 3 attempts) |
| `500/503` Server error | Retry with exponential backoff (max 3 attempts) |
| Network error | Retry once after 5s; log for monitoring |

### 20.4 Server-Initiated Push Events

| Event | Trigger | Priority |
|-------|---------|----------|
| Weekly strategy report ready | Edge Function cron (Sunday 09:00 local) | Normal |
| AI insight generated | After `generate-insights` Edge Function completes | Normal |
| Experiment checkpoint | Experiment midpoint or completion | Normal |
| Account deletion scheduled | After `POST /api/account/delete` | High |
| Force update available | Admin-triggered | Critical |

---

## 21) Edge Function Cold Start Mitigation

### Problem

Deno-based Supabase Edge Functions have cold start latency of 500ms–2s, which can impact p99 latency for critical endpoints.

### Strategy

| Approach | Application | Expected Impact |
|----------|-------------|----------------|
| **Cron warm-up** | Schedule pings every 5 min for critical functions (recovery, food-log) via Supabase cron | Keeps 1 warm instance; p99 drops ~60% |
| **Lightweight probes** | `GET /health` endpoint per function; returns instantly | Validates function is alive without business logic |
| **Code splitting** | Keep critical functions small (<500 LOC); extract shared utils to `_shared/` | Reduces bundle parse time |
| **Supabase Pro concurrency** | Reserve 2 concurrent instances for `calculate-recovery-score` | Eliminates cold starts for primary user flow |

### Migration Criteria to Dedicated Server

If any of these persist for > 1 week:
- Recovery endpoint p99 > 1.5s despite warm-up
- Food analysis p99 > 8s (current SLO: 5s)
- Edge Function error rate > 1% (non-AI endpoints)

Migration target: Fly.io or Railway with Deno Deploy.

---

## 22) V1→V2 Data Migration Strategy

### Schema Migrations

All V2 schema changes are backward-compatible additions (new tables, new columns with defaults). No destructive migrations.

| Change Type | V1 Impact | Migration Approach |
|-------------|-----------|-------------------|
| New tables (`sleep_logs`, `training_templates`) | None | Standard `CREATE TABLE` migration |
| New columns on `users` | None (nullable, defaults) | `ALTER TABLE ADD COLUMN` |
| New columns on `physiological_states` | None (nullable) | `ALTER TABLE ADD COLUMN` |
| New RLS policies | None (additive) | Policy creation is idempotent |

### Feature Flag Rollout

```typescript
const V2_FEATURES = {
  sleep_diary: 'v2_sleep_diary',       // Sleep logging UI
  training_templates: 'v2_templates',  // Template management
  unified_diary: 'v2_diary',           // Daily diary view
  watchos_companion: 'v2_watchos',     // watchOS app
} as const;

// Server-side: Supabase `feature_flags` table
// Client-side: check flag on app launch, cache for session
```

### Backward Compatibility

- V1 clients continue to work for **minimum 90 days** after V2 launch.
- V1 API endpoints remain stable; V2 endpoints use new paths (e.g., `/api/sleep/log` is V2-only).
- Local GRDB schema migrations are additive; V1 tables are not modified.
- Force update only triggered if V1 client cannot safely coexist (see `life_os_invariants.md` §16).

---

## 23) Customer Support Tooling

### Tier 1: Self-Service

- In-app FAQ (compiled from help center, offline-available)
- Data export (GDPR `POST /api/account/export`, async — see `life_os_api_specification.md` §DATA EXPORT)
- Account deletion (self-serve via Settings → Account → Delete)

### Tier 2: Support Investigation

| Tool | Purpose | Access |
|------|---------|--------|
| Supabase Dashboard | View user data, run ad-hoc queries | Admin team |
| Edge Function logs (Supabase) | Debug server-side errors | Dev team |
| Client debug bundle | Collect local logs + sync state + device info | User-initiated via Settings → Help → Send Debug Info |

### Client Debug Bundle

Triggered from Settings → Help → Send Debug Info:

```
Contents:
- Last 500 structured log lines (no PII; user IDs hashed)
- Outbox queue state (pending events count, oldest event age)
- Device info (model, OS version, app version, storage remaining)
- HealthKit permission status (per data type)
- Last sync timestamp + sync error log
- Recovery algorithm version + active feature flags
```

Bundle is uploaded to Supabase Storage (`support-bundles/{user_id}/{timestamp}.json`), auto-deleted after 30 days.

### Escalation Process

1. User submits debug bundle + description via in-app form
2. Creates entry in `support_tickets` table (admin-only, no RLS for user)
3. Dev reviews in Supabase Dashboard → investigates → resolves or escalates to GitHub issue
4. Hotfix path: Edge Function patch → deploy → verify → close ticket

---

## 24) Internationalization (i18n) Pipeline

### V2 Scope

Two languages: **English** (primary) and **Russian** (secondary).

### String Management

| Tool | Purpose |
|------|---------|
| **Xcode String Catalog** (`.xcstrings`) | Source of truth for localized strings |
| **Copy Catalog** (`life_os_copy_catalog.md`) | Canonical copy IDs and English text |
| Manual translation | Russian translations by native speaker (no machine translation for V2) |

### Pipeline

```
1. Developer writes String Catalog entry with copy ID
2. English text pulled from life_os_copy_catalog.md
3. Russian translation added to .xcstrings by translator
4. CI validates: all copy IDs have both en + ru entries
5. Missing translations → build warning (not error) in dev, build error in release
```

### Scaling Plan (V3+)

When adding 3+ languages:
- Migrate to **Lokalise** or **Crowdin** for collaborative translation
- Export: Lokalise → `.xcstrings` via CI integration
- Review: native speaker review before merge
- RTL support: deferred until Arabic/Hebrew market entry (requires layout audit)

### Rules

1. No hardcoded strings in SwiftUI views — all via `String(localized:)`
2. Plurals use `.stringsdict` or `inflect: true`
3. Date/number formatting uses locale-aware formatters (see PRD §Localization)
4. CIS-specific edge cases documented in `life_os_cis_edge_cases.md`
