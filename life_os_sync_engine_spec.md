# LIFE OS — Offline-First Sync Engine Spec (Outbox + Pull)

**Version:** 0.6  
**Date:** February 16, 2026  
**Purpose:** Implementation-ready specification for the iOS sync engine that guarantees offline-first logging, deterministic reconciliation, and minimal user friction.

**Aligns with:**
- Technical architecture: `life_os_technical_architecture.md` (v0.6)
- API spec (offline strategy): `life_os_api_specification.md` (v2.3)
- Error handling: `life_os_error_handling.md` (v2.0)
- E2E offline scenarios: `life_os_e2e_test_checklists.md` (v0.4)

---

## 0) Non-Negotiables

- **Never lose user input.** Any write performed offline must be safely queued until synced or explicitly cancelled by the user.
- **Idempotent replay.** Re-sending the same offline mutation must not create duplicates.
- **Server time is authoritative.** `updated_at` is server-set; clients never trust device clocks for conflict resolution.
- **Soft delete only where specified.** Undoable deletions are tombstones (`deleted_at`), never hard deletes from client.
- **Privacy-first logs.** Sync diagnostics must not store raw photos, documents, or sensitive prompt content.

---

## 1) Terminology

- **LocalStore:** SQLite database on-device (GRDB).
- **RemoteStore:** Supabase Postgres (RLS) + `/api/*` Edge endpoints.
- **Outbox:** local queue of pending mutations (write intents).
- **Pull:** fetching server-side changes into LocalStore.
- **Reconcile:** merging server changes + server-computed fields back into local records.

---

## 2) Core Strategy (Locked)

Life OS uses a **hybrid sync**:

1. **Push:** all writes are executed via `/api/*` endpoints (Edge Functions) for validation + business rules.
2. **Pull:** server changes are fetched per-table via PostgREST (RLS) using `updated_at` watermarks.

This keeps client logic simple (queue + replay) while keeping server as the authority for derived fields and invariants.

---

## 3) Client-Generated IDs (Idempotency Without Extra Server Tables)

### 3.1 Rule

For any user-created entity that must work offline, the client MUST generate stable UUIDs **before** enqueueing the Outbox event.

**Reason:** If the same create request is replayed multiple times, the server can safely upsert by the same IDs (no duplicates).

### 3.2 Entities With Client-Generated IDs (Required)

- Nutrition:
  - `food_logs.id`
  - `food_items.id`
  - `user_foods.id`
  - `user_food_favorites.id`
  - `batch_recipes.id`, `batch_recipe_ingredients.id`
  - `meal_templates.id`
- Training:
  - `workout_sessions.id`
  - `workout_exercises.id`
  - `workout_sets.id`
  - `exercise_catalog.id` (custom exercises)
  - `training_templates.id` — V2 training templates
- Sleep:
  - `sleep_logs.id` — V2 sleep diary logs
- Body Composition:
  - `body_composition.id` — body composition measurements
- Hydration:
  - `hydration_logs.id` — hydration logs
- Supplements:
  - `supplement_logs.id`
- Labs:
  - `medical_scans.id` (if client initiates an offline scan placeholder)
  - `health_measurements.id` (only for manual entry flows; OCR-derived entries may be server-generated)
- Experiments:
  - `experiments.id` (if created from client)
  - `experiment_measurements.id` (if logged offline)

### 3.3 Entities With Server-Generated IDs

- `insights.*`
- `recommendations.*`
- any server-only background artifacts

---

## 4) LocalStore Schema (GRDB) — Required Tables

> This section is conceptual. Exact GRDB migrations may differ, but fields and semantics are required.

### 4.1 `local_meta`

- `device_id` (UUID, stable, stored in Keychain and mirrored here)
- `schema_version` (int)

### 4.2 `sync_state`

Per-table pull cursor.

- `table_name` (text, PK)
- `last_pulled_at_server` (TIMESTAMPTZ nullable) — last server `updated_at` watermark applied
- `last_pull_attempt_at` (TIMESTAMPTZ)
- `last_pull_success_at` (TIMESTAMPTZ)
- `last_error_code` (text nullable)

### 4.3 `outbox_events`

Queue of write intents.

Required fields:
- `id` (UUID, PK) — also used as the default `Idempotency-Key`
- `created_at_local` (TIMESTAMPTZ)
- `updated_at_local` (TIMESTAMPTZ)
- `status` (text): `pending | in_flight | succeeded | failed_retryable | failed_permanent | cancelled`
- `priority` (int): lower = earlier; default 100; safety/undo may be higher priority
- `depends_on` (UUID nullable) — enforce ordering when required (e.g., items depend on log)

Request envelope:
- `http_method` (text): `POST | PUT | PATCH | DELETE`
- `path` (text): e.g., `/api/food/log`
- `headers_json` (JSON) — must include `Idempotency-Key` (default = `id`) and `X-Outbox-Replay: true` (signals server that this is a replay from the offline Outbox; grants rate-limit exemption per `life_os_invariants.md` §11, capped at 300 requests / 5 min)
- `body_json` (JSON) — must include client-generated IDs for create operations

Tracking:
- `attempt_count` (int)
- `next_attempt_at` (TIMESTAMPTZ nullable)
- `last_attempt_at` (TIMESTAMPTZ nullable)
- `last_error_category` (text nullable): `network | auth | validation | server | unknown`
- `last_error_code` (text nullable)
- `last_error_message` (text nullable, truncated)

Optional (recommended for UX):
- `user_visible_blocker` (bool): whether this failure should block the relevant screen with “Fix & retry”
- `ui_hint_json` (JSON): deep link target + copy_id for banners

---

## 5) Outbox Enqueue Rules

1. **Write local first.** Apply the user action immediately to LocalStore so UI updates instantly.
2. **Enqueue second.** Create an Outbox event that represents the remote mutation needed to persist the change.
3. **No dead ends.** If an event fails permanently (validation), keep local state but mark the relevant record `needs_review=true` and surface a repair path.

---

## 6) Sync Loop (Deterministic Order)

When sync is triggered (app launch, foreground, network regained, background task):

1. **Pull phase** (per-table)
2. **Push phase** (Outbox replay)
3. **Reconcile phase** (optional second pull for derived fields if push endpoints do not return full authoritative records)

### 6.1 Pull Phase (Per-Table, Paginated & Windowed)

> [!IMPORTANT]
> To prevent massive payloads, timeouts, and memory exhaustion on devices with years of history, the Pull phase MUST implement **Pagination**, a **Sync Window**, and **HTTP Compression**.

#### 6.1.1 HTTP Compression (Mandatory)
- All PostgREST requests MUST include the header `Accept-Encoding: gzip, br`.
- Supabase Edge/CDN handles compression automatically, reducing JSON payload size by 70-85%.

#### 6.1.2 Cursor-Based Pagination
Instead of a single massive request per table, the client MUST fetch data in chunks:
- Query: `GET /table?updated_at=gte.{watermark}&order=updated_at.asc&limit=1000`
- The client processes the chunk, updates its local `sync_state.last_pulled_at_server` to the maximum `updated_at` in that chunk, and repeats until the returned row count is `< 1000`.
- **Important:** use `gte` (`>=`) rather than `gt` (`>`) to avoid missing same-timestamp updates; the client MUST deduplicate rows on insertion based on ID.
- **Benefit:** If the network drops during a massive initial sync, progress is saved.

#### 6.1.3 Sync Window (Active Depth)
Granular data (e.g., `food_items`, `workout_sets`, `hrv_readings`) grows unbounded. The local database MUST NOT download the entire history by default.

- **Active Window:** The client automatically pulls granular rows where `updated_at >= watermark` AND `*_date >= (today - 90 days)`.
- **Historical Aggregates:** For data older than 90 days, the client pulls **only derived aggregates** (e.g., `daily_recovery_scores`, `daily_nutrition_summary`).
  - **Benefit:** Fast UI rendering for historical Trend charts without downloading 10,000 strings of salad ingredients.

#### 6.1.4 On-Demand (Lazy) Loading
- If the user scrolls the Diary view beyond the 90-day active window (e.g., looking at a meal from a year ago), the client makes an on-demand `GET` request specifically for that date (`/api/diary/day?date=YYYY-MM-DD`).
- Render the data and cache it locally with a TTL (e.g., 7 days) or use an LRU eviction policy to prevent perpetual local storage bloat.

#### 6.1.5 Syncable Tables & Direction

**Sync direction:**
- **Bidirectional (client ↔ server):** `food_logs`, `food_items`, `user_foods`, `user_food_favorites`, `meal_templates`, `batch_recipes`, `batch_recipe_ingredients`, `workout_sessions`, `workout_exercises`, `workout_sets`, `training_plans`, `training_plan_sessions`, `sleep_logs`, `training_templates`, `user_supplements`, `supplement_logs`, `medical_scans`, `health_measurements`, `experiments`, `experiment_measurements`, `wellness_checks`, `body_composition`, `hydration_logs`, `weekly_strategy_reports`, `notification_settings`, `onboarding_state`, `user_baselines`, `privacy_settings`.
- **Pull-only (server → client):** `insights`, `recommendations`, `health_diagnoses`, `daily_nutrition_targets`. These are server-generated and never written by the client directly.
- **Push-only (client → server):** `analytics_events`. Handled by a dedicated `POST /api/analytics/batch` endpoint.

**Server‑side async sync (not part of client outbox):**
- `food_logs` → vector embeddings in Pinecone (server cron upserts embeddings and flips `synced_to_vector_db=true`).

### 6.2 Push Phase (Replay Outbox)

Replay ordering:
- primary sort: `priority` ascending
- secondary: `created_at_local` ascending

Rules:
- Mark event `in_flight` before sending.
- Always include:
  - `Idempotency-Key` header (use Outbox `id`)
  - `X-Device-Id` header (from `local_meta.device_id`)
- If request succeeds:
  - mark `succeeded`
  - merge any returned authoritative fields into LocalStore (recommended)
- If request fails:
  - classify failure (network/auth/validation/server)
  - decide retry strategy (see §8)

### 6.3 Reconcile Phase (When Needed)

If a push endpoint returns only `{ ok: true }` but server computed fields changed (totals, derived flags):
- either immediately call the relevant GET endpoint, OR
- run a targeted pull for affected tables

Goal: local store converges to server authoritative state within the same sync cycle when possible.

---

## 7) Applying Server Changes (Merge Rules)

General rule: **server wins** if `server.updated_at >= local.updated_at_server`.

Implementation notes:
- Maintain `updated_at_server` in LocalStore for each synced row (the last seen server `updated_at`).
- Local-only fields (not present on server) must not be overwritten.

Safe merge exceptions (optional, can be added later):
- For pure client-only annotation fields, keep local.

Conflict UX:
- If local has unsynced edits to the same entity and server also changed it:
  - keep local optimistic UI state
  - mark entity `needs_review=true`
  - enqueue a “repair” event or require user to resolve (screen-level)

### 7.1 Parent-Child Atomic Merge (food_logs ↔ food_items)

> [!IMPORTANT]
> When a parent row has children (e.g., `food_logs` → `food_items`, `workout_sessions` → `workout_exercises` → `workout_sets`, `batch_recipes` → `batch_recipe_ingredients`), the merge must be **atomic** — the parent and all its children are treated as one unit.

**Problem:** If user edits the same meal on two devices simultaneously, a naïve last-write-wins on each row could produce a state where `food_items` come from device A but the parent `food_logs` totals come from device B.

**Rules:**

1. **Atomic unit** = parent row + all child rows with matching `parent_id`.
2. **Winner selection**: the device whose parent row has the later `updated_at` wins the entire unit (parent + children).
3. **Loser handling**: the losing device's changes are discarded from server state but preserved in the dead letter queue for potential recovery.
4. **Totals re-derivation**: after merge, `food_logs.total_*` fields are **always re-derived** from the winning `food_items` set. Never trust pre-computed totals across device boundaries.
5. **Conflict UX**: if both devices have unsynced edits to the same parent entity:
   - Show a "Meal edited on another device" banner on the conflicting food log.
   - Present a diff view: "Your version" vs "Other device version".
   - Let the user choose: Keep mine / Keep other / Merge manually.
   - Default (if user ignores for 24h): server version wins.

**Applies to these parent-child pairs:**

| Parent | Children | Totals to re-derive |
|--------|----------|-------------------|
| `food_logs` | `food_items` | `total_calories`, `total_protein_g`, `total_fat_g`, `total_carbs_g` |
| `workout_sessions` | `workout_exercises` → `workout_sets` | `total_volume_kg`, `total_sets` |
| `batch_recipes` | `batch_recipe_ingredients` | `total_*` per 100g |

---

## 8) Retry & Backoff Strategy

### 8.1 Error Classification

- Network:
  - no connection, timeout, DNS
  - action: retry with exponential backoff + jitter
- Auth:
  - token expired/revoked
  - action: re-auth, then retry
- Validation:
  - server rejected payload (e.g., missing required fields)
  - action: mark `failed_permanent`, surface “Fix” UI
- Server:
  - 5xx or gateway errors
  - action: retry with backoff, cap attempts

### 8.2 Backoff

- base: 10s
- multiplier: ×2
- max: 30 minutes
- jitter: ±20%
- attempt cap: 10 (after which mark `failed_permanent` and require manual retry)

### 8.3 Dead‑Letter Handling

- If an outbox event exceeds `attempt cap`, move it to a dead‑letter state (`failed_permanent`).
- Surface a non‑blocking banner: “Sync needs attention”.
- Provide actions: **Retry**, **Edit**, **Discard**.
- Dead‑letter items must not block the rest of the queue.

---

## 9) Media & Large Payloads (Offline)

### 9.1 Photos (Food / Label / Labs)

- Store local file paths and metadata in LocalStore.
- Upload to Supabase Storage only when needed and allowed by privacy policy.
- Use a dedicated Outbox event for upload:
  1. upload blob
  2. receive remote URL
  3. update the owning record with URL (as a second Outbox event)

### 9.2 Privacy Defaults

- Food photos: may sync to cloud (retention rules apply).
- Label photos: ephemeral by default; upload only for immediate analysis, then delete per policy.
- Medical scans: local-only by default; derived markers can sync only if allowed.

---

## 10) Background Execution (iOS)

### 10.1 When to Schedule

- If Outbox has pending items:
  - schedule `BGProcessingTask` (requires power/network; best effort)
- Always schedule a lightweight daily `BGAppRefreshTask` for pull + recovery refresh windows

### 10.2 Hard Truth

iOS background scheduling is not deterministic. The app must never rely on background execution for safety-critical enforcement.

---

## 12) Multi-Device Sync (V2 Considerations)

> [!NOTE]
> V1 is single-device (iPhone only). This section documents the design for V2 multi-device support (iPhone + iPad).

### 12.1 Conflict Scenarios

When two devices make conflicting edits offline:
- **Same entity, same field:** Server-authoritative last-write-wins (existing rule). The device that syncs second has its local state overwritten on next pull.
- **Same entity, different fields:** Merge at field level where possible (e.g., device A updates `notes`, device B updates `rpe` → both fields saved). If field-level merge is not feasible, fall back to last-write-wins.
- **Concurrent creates with same UUID:** Impossible if UUIDs are generated correctly (device-local). If collision occurs (UUIDv4 collision is negligible), treat as duplicate and merge.

### 12.2 Device Identity

- Each device generates a unique `device_id` (persisted in Keychain).
- All outbox events include `X-Device-Id` header.
- Server tracks `last_device_id` per entity for audit and conflict resolution.

### 12.3 Outbox Deduplication Across Devices

- Idempotency keys are device-specific (outbox UUID × device_id).
- Server-side: `UNIQUE(idempotency_key, device_id)` — same idempotency key from different devices is allowed (they represent different user actions).
- Pull sync uses per-device watermarks to avoid re-processing.

### 12.4 UX on Conflict

- Silent merge for non-conflicting changes (no user notification).
- If a user sees a stale value replaced after pull: show a subtle "Updated from another device" toast (not blocking).
- No manual conflict resolution UI in V2 — server-wins policy is sufficient for health data.

### 12.5 Multi-Device Conflict Scenarios (Detailed)

The following scenarios clarify how LWW (last-write-wins) applies in practice:

**Scenario 1: Same food log edited on two devices**
- Device A edits `food_log.items[0].portion_g = 200` at `updated_at = T1`
- Device B edits `food_log.items[0].portion_g = 150` at `updated_at = T2` (T2 > T1)
- **Resolution:** Entity-level LWW. Device B's entire food_log wins. Device A's pending edit (if still in Outbox) is reconciled: server response with `updated_at = T2` overwrites local.
- **UX:** Device A sees "Updated from another device" toast after next pull.

**Scenario 2: Batch recipe with ingredients edited concurrently**
- Device A adds an ingredient to `batch_recipe_ingredients` at T1
- Device B changes `batch_recipe.total_weight_g` at T2
- **Resolution:** These are separate entities (different tables). Both writes succeed independently via normal Outbox replay. Server recomputes per-100g macros using the latest ingredient list + latest total weight.
- **No conflict.** Each table has its own `updated_at` watermark.

**Scenario 3: Create + delete race**
- Device A creates `food_log` (client ID = X) at T1 while offline
- Device B creates and then deletes the same log on another device (server `deleted_at = T3`)
- Device A comes online and replays the create
- **Resolution:** Server upsert (`ON CONFLICT (id) DO UPDATE`) restores the row. Since Device A's create has no `deleted_at`, the row is un-deleted. If this is undesirable, the server must check `deleted_at IS NOT NULL AND deleted_at > incoming.updated_at` and reject the replay as a no-op.
- **Rule:** For V2, the simpler approach (upsert always wins) is acceptable. Undo is always available client-side.

**Field-Level vs Entity-Level LWW:**
- V2 uses **entity-level LWW** (entire row `updated_at`). Field-level merge (CRDTs) is out of scope.
- This means if two devices edit different fields of the same row concurrently, the later write overwrites all fields — including unchanged ones.
- **Mitigation:** Since health logs are primarily additive (create-heavy, edit-rare), this is an acceptable trade-off for V2.

---

## 13) Sync Health Monitoring

### 13.1 Client-Side Metrics

| Metric | Description | Alert Threshold |
|--------|-------------|----------------|
| `sync.outbox.pending_count` | Events waiting to sync | > 50 events |
| `sync.outbox.oldest_age_hours` | Age of the oldest pending event | > 24 hours |
| `sync.outbox.failed_permanent_count` | Dead-lettered events | > 0 |
| `sync.last_pull_at` | Timestamp of last successful pull | > 12 hours ago |
| `sync.last_push_at` | Timestamp of last successful push | > 12 hours ago |

### 13.2 Server-Side Metrics

| Metric | Description | Alert Threshold |
|--------|-------------|----------------|
| `sync.replay.success_rate` | Proportion of successful replays | < 95% |
| `sync.replay.p95_latency_ms` | 95th percentile replay latency | > 2000ms |
| `sync.idempotency.duplicate_rate` | Rate of idempotent re-submissions | > 10% (indicates client retries) |

### 13.3 User-Facing Sync Status

- Settings → Sync Status: show last sync time, pending events count, and any permanent failures.
- If `outbox.pending_count > 50`: show non-blocking banner "Syncing data..." on Home.
- If `outbox.oldest_age_hours > 168` (7 days): show blocking "Fix sync" screen per existing QA requirement.

---

## 14) QA Requirements (Sync)

Must pass (in addition to existing E2E checklists):

1. Offline create → online sync produces **no duplicates** (same IDs on server).
2. Timeout retry (unknown server state) does not duplicate entities.
3. Soft delete + undo sync correctly across two devices.
4. Travel/timezone does not shift `*_date` grouping after sync.
5. Outbox stuck >24h shows non-blocking banner; >7 days shows a blocking “Fix sync” screen (per API spec guidance).

---

## 15) Implementation Checklist

- [ ] Generate and persist `device_id` (Keychain) on first launch.
- [ ] Implement GRDB migrations for `local_meta`, `sync_state`, `outbox_events`.
- [ ] Ensure all offline create flows generate stable UUIDs for entities.
- [ ] Ensure all mutation requests include `Idempotency-Key` and `X-Device-Id`.
- [ ] Implement deterministic pull with `updated_at >= watermark`.
- [ ] Implement replay loop with backoff + classification.
- [ ] Ensure UI surfaces repair paths for `failed_permanent` events.
- [ ] Implement sync health metrics (client-side; see §13).
