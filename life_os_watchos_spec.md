# LIFE OS — watchOS COMPANION SPEC (V2)

**Version:** 0.3  
**Date:** February 4, 2026  
**Platforms:** watchOS 9+ (companion) + iOS 17+ (host)  
**Purpose:** Implementation-ready specification for the watchOS companion experience: complications, glance view, lightweight actions, and sync contracts.

> [!IMPORTANT]
> watchOS in Life OS is a **companion**, not a second full app.  
> V2 adds watch surfaces that **reduce friction** and **increase adherence**, without introducing new core workflows.

> [!NOTE]
> **Related specs:** iOS widget surfaces (`life_os_widget_spec.md`) use a separate `WidgetSnapshot` schema with richer nutrition/supplement data for Home Screen display. Widget and watch analytics events are defined in `life_os_analytics_catalog.md`.

---

## 0) Non‑Negotiables

1. **No new core workflows on watch.** Logging is lightweight only (e.g., “Taken”), and anything complex routes to iPhone.
2. **No HealthKit writes in V2.** Life OS remains read-only to HealthKit; the iPhone aggregates watch-derived HealthKit data.
3. **No extra notification stream.** Watch shows the same notification schedule as iPhone (hard cap, quiet hours).
4. **Minimal data on watch.** Store only a small encrypted “snapshot” for offline viewing.
5. **Accessibility first.** Large tap targets, VoiceOver labels, and non-color status encoding.

---

## 1) Watch Surfaces (What Ships in V2)

### 1.1 Complications (Primary)

**Goal:** recovery at a glance.

Supported:
- Circular
- Rectangular
- Corner

Content:
- Recovery % (or score)
- Zone icon + label (never color-only)

Source of truth for visuals: `life_os_design_system.md` → “watchOS DESIGN (PHASE 2)”.

### 1.2 Watch App — Glance View (Primary Screen)

**Goal:** show “what to do now” in < 3 seconds.

Blocks (top → bottom):
- Recovery score + zone (big)
- One “Next Best Action” (single CTA)
- Optional: “Due soon” pill (supplement / sleep prep) if relevant — `watch.due_soon`

### 1.3 Lightweight Actions (Allowed)

Allowed actions in V2:
- **Mark supplement as taken** (for the next due slot)
- **Acknowledge** an insight (“Got it”) when it is low-risk

Disallowed actions in V2:
- Editing meals, workouts, lab values
- Starting training plans
- Any “block apps” enforcement from watch

Routing:
- If an action requires context or review, show `global.open_on_iphone`.
- Any `next_best_action.type` other than `supplement_taken` / `insight_acknowledge` must route to iPhone (no on-watch logging/editing in V2).

---

## 2) Data Contract: Watch Snapshot

The watch UI is driven by a single snapshot payload prepared on iPhone.

```ts
type WatchNextAction =
  | { type: 'open_diary'; label_copy_id: 'diary.view_day'; payload?: { date?: string } }
  | { type: 'open_sleep'; label_copy_id: 'sleep.title'; payload?: { date?: string } }
  | { type: 'log_meal'; label_copy_id: string; payload?: any }
  | { type: 'supplement_taken'; label_copy_id: 'supplements.log_primary'; payload: { supplement_name: string; scheduled_time: string } }
  | { type: 'insight_acknowledge'; label_copy_id: 'insights.acknowledge'; payload: { insight_id: string } }
  | { type: 'open_on_iphone'; label_copy_id: 'global.open_on_iphone'; payload?: { deep_link?: string } };

interface WatchSnapshot {
  date: string; // local date (YYYY-MM-DD)
  last_updated_at: string; // ISO timestamp
  recovery_score: number;
  recovery_zone: 'critical' | 'caution' | 'ready' | 'optimal';
  confidence_score: number; // 0-1
  next_best_action: WatchNextAction;

  // Optional lightweight context (safe, minimal)
  sleep_duration_hours?: number | null;
  sleep_quality_percent?: number | null;
  nutrition_adherence_percent?: number | null; // 0-100 (calories + protein targets)
  supplements_due_soon?: { time: string; count: number } | null;
}
```

**Rules:**
- Never include raw health samples or medical documents.
- **Hard limit: 4 KB maximum.** If the serialized snapshot exceeds 4 KB, fields are dropped in this order (lowest priority first):
  1. `nutrition_adherence_percent` (drop first)
  2. `sleep_quality_percent`
  3. `supplements_due_soon`
  4. `sleep_duration_hours`
  5. Core fields (`recovery_score`, `recovery_zone`, `confidence_score`, `next_best_action`, `date`, `last_updated_at`) are **never** dropped.
- The iPhone client must validate snapshot size before sending via `WCSession.transferUserInfo()`. If truncation occurs, set `snapshot.was_truncated = true` so the watch UI can show a "View full details on iPhone" link.

---

## 3) Sync Strategy (iPhone → Watch)

### 3.1 When to Sync

The iPhone updates the watch snapshot:
- After morning recovery refresh completes (06:00–10:00 window)
- When recovery zone changes
- When a “Next Best Action” changes meaningfully
- When the user marks a supplement as taken (state feedback)

### 3.2 Offline Behavior

If the watch cannot reach the phone:
- Show last snapshot with `watch.last_updated`
- Disable actions and show `global.open_on_iphone` fallback

---

## 4) Complication / Widget Refresh

- Use WidgetKit timeline updates; assume limited refresh budget.
- Prefer iPhone-driven snapshot updates after meaningful changes (recovery refresh, next-best-action change).
- Do not schedule high-frequency refreshes; target a small number of updates per day.
- Always display last updated time to prevent stale-data confusion.

---

## 5) API (Host App Only)

The watch app does not call the backend directly. The iPhone may call:
- `GET /api/watch/snapshot?date=...` (server-prepared minimal payload), OR
- build the snapshot locally from `GET /api/diary/daily` (fallback).

---

## 6) QA (V2)

Must pass:
1. Complication shows correct recovery score + zone label.
2. Snapshot updates after recovery refresh.
3. Offline watch shows cached snapshot and disables actions safely.
4. “Taken” action updates state on watch within 5 seconds when phone is reachable.

---

## 7) Copy IDs (V2)

Watch-only:
- `watch.due_soon`
- `watch.last_updated`

Shared (reused from iOS):
- `global.open_on_iphone`
- `diary.view_day`
- `sleep.title`
- `supplements.log_primary`
- `insights.acknowledge`

---

## CHANGELOG

### v0.3 (February 4, 2026)
- Clarified that all non-safe actions must route to iPhone (no on-watch logging/editing in V2)

### v0.2 (February 4, 2026)
- Added explicit copy IDs for watch surfaces and routing
- Expanded `WatchNextAction` allowlist to cover insight acknowledge + iPhone routing
