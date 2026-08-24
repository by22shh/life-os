# LIFE OS — Cross-Document Invariants (Canonical Reference)

**Version:** 0.5
**Date:** February 16, 2026
**Purpose:** Single canonical source for all invariants that MUST remain consistent across every spec, prompt, screen, and test in the Life OS documentation set. If any document contradicts this file, treat it as a bug and fix the document.

**Referenced by:** `README.md` "Sources of truth" section.

---

## 1) Recovery Zones (4-Bucket Model)

| Zone | Range | Icon | Light Color | Dark Color | Label |
|------|-------|------|-------------|------------|-------|
| **Optimal** | 75–100 | ✓ | `#0072B2` | `#56B4E9` | "Ready for anything" |
| **Ready** | 50–74 | ↗ | `#009E73` | `#009E73` | "Good to go" |
| **Caution** | 25–49 | ⚠ | `#9A6800`¹ | `#F0E442` | "Take it easy" |
| **Critical** | 0–24 | ✕ | `#D55E00` | `#D55E00` | "Rest required" |

> ¹ Darkened from Okabe-Ito `#E69F00` for WCAG AA ≥4.5:1 contrast on warm neutral `#FFF7F0`.

**Rules:**
- Palette: Okabe-Ito (color-blind safe). Colors are **never** the sole status indicator — always pair with icon + text.
- Boundaries are inclusive on the low end and exclusive on the high end (e.g., Caution = score ≥ 25 AND score < 50), except Optimal which includes 100.
- Zone names in code/API: `optimal`, `ready`, `caution`, `critical` (lowercase).

---

## 2) Confidence & Low-Confidence Behavior

- **Low-confidence threshold:** `< 0.65`
- When confidence is below threshold:
  - AI outputs are tagged `needs_review = true`
  - No risky one-tap actions (e.g., no auto-logging meals from photo)
  - UI shows a review gate before saving
  - Insights display a "Low Confidence" badge
- Confidence values are stored with every AI-generated output (`confidence` field, 0.0–1.0).
- OCR-specific threshold: `0.85` for auto-accept (higher than general threshold because OCR data can directly affect health decisions).

---

## 3) Notifications

- **Hard cap:** `≤ 6 notifications per day` (never exceeded regardless of triggers).
- **Quiet hours:** User-defined window (default 22:00–07:00 local time). No notifications during quiet hours.
- **Morning Brief exception:** Morning Brief is a scheduled digest, not a push notification. It respects quiet hours but is delivered at the first post-quiet-hours window.
- **Priority ordering:** When cap is near, highest-priority notifications are kept, lowest are dropped. Priority: critical health > supplement reminders > insights > general.
- **Same-category deduplication cooldown:** `≥ 2 hours` between notifications of the same category (e.g., two `SUPPLEMENT_REMINDER` pushes must be ≥2h apart). This prevents notification clustering even when the daily cap is not reached.
- **Notification channel:** APNs (iOS), routed through Supabase Edge Functions.

---

## 4) Control Model

| Level | Behavior | Requirements |
|-------|----------|--------------|
| **Advisory** | Suggestions only; user controls all actions | Default level; no special entitlements |
| **Protective** | Active nudges + friction on risky behaviors | User opt-in required |
| **Guardian** | Can restrict app access via Focus Control | Requires `FamilyControls` + `ManagedSettings` entitlements |

**Rules:**
- If `critical_only = true`, force control level to **Advisory** AND set `focus_control_enabled = false`.
- Guardian level cannot be silently enabled — explicit user consent required.
- Control model is stored per-user in `notification_settings.control_level`.

---

## 5) AI / OpenRouter Gateway (LOCKED)

- **All LLM calls go through OpenRouter** via Supabase Edge Functions. No exceptions.
- **No API keys on client.** iOS and watchOS never hold OpenRouter keys.
- **Model references in docs** use OpenRouter slug format: e.g., `openai/gpt-4o`, `openai/text-embedding-3-small`.
- **Prompt source of truth:** `life_os_gpt_prompts.md`.
- **Vector store:** Pinecone (server-only; no client access).
- **AI output storage:** Always includes `confidence`, `inputs_used`, `version`/prompt ID.
- **Medical guardrail:** AI never provides diagnoses. All health-related outputs are phrased as hypotheses with "consult your clinician" bounds.

---

## 6) Offline-First Sync

- **Architecture:** Local write → Outbox → replay with idempotency (no lost input).
- **Client-generated IDs:** UUIDs for all offline-capable entities.
- **Idempotency:** Every mutation carries `Idempotency-Key` (outbox event UUID) + `X-Device-Id`.
- **Conflict resolution:** Server-authoritative last-write-wins on `updated_at`.
- **Dead-letter:** Failed events after max retries (default 10, exponential backoff) move to `failed_permanent` status.
- **Sync source of truth:** `life_os_sync_engine_spec.md`.

---

## 7) watchOS (V2)

- **No direct backend calls.** Watch never holds Supabase or OpenRouter keys.
- **Data flow:** iPhone fetches `GET /api/watch/snapshot` → syncs to watch via WatchConnectivity.
- **Safe actions only:** One-taps on watch are routed to iPhone host for execution.
- **watchOS source of truth:** `life_os_watchos_spec.md`.

---

## 8) Privacy & Data Classification

- **Posture:** Data minimization + local-first where possible + explicit retention & deletion flows.
- **Menstrual data:** On-device only by default (never synced to server without explicit opt-in).
- **Vector embeddings:** Opt-in, derived-only (no raw PII in vectors).
- **GDPR/CCPA:** Full export + deletion endpoints. Export is async (`POST` to initiate, `GET` to poll).
- **Restricted data:** `health_diagnoses`, `medical_scans` — highest protection level.
- **Privacy source of truth:** `life_os_privacy_architecture.md`.

---

## 9) Accessibility

- **Baseline:** WCAG 2.2 AA + Apple HIG.
- **Touch targets:** ≥ 44×44 pt.
- **List row minimum height:** 56 pt (recommended).
- **Status encoding:** Color + Icon + Text (never color-only).
- **Dynamic Type:** All text styles must support Dynamic Type scaling.
- **Accessibility source of truth:** `life_os_accessibility_guidelines.md`.

---

## 10) Copy & Localization

- **Copy source of truth:** `life_os_copy_catalog.md`.
- **Every user-visible string** must have a copy ID and exist in the catalog.
- **CIS edge cases:** `life_os_cis_edge_cases.md` for localization pitfalls.
- **Tone:** Supportive, never blaming. No diagnostic language in AI outputs.

---

## 11) Rate Limiting

- **Standard tier:** 120 requests / minute per user (all authenticated endpoints).
- **Write-heavy tier:** 30 requests / minute (food/workout/supplement log endpoints).
- **AI / Vision tier:** 10 requests / minute (photo analysis, lab scans, insight generation).
- **Auth tier:** 5 requests / minute.
- Rate limiting is per-user (JWT `sub`), not per-IP.
- Offline sync replay is exempt from write-heavy limits when `X-Outbox-Replay: true` header is set, capped at 300 / 5 min.
- Exceeded limit returns `HTTP 429` with `retry_after_seconds`.
- **Rate limiting source of truth:** `life_os_api_specification.md` § Rate Limiting.

---

## 12) Push Notifications

- **Payload format:** APNs with `aps.alert` + `data.type` + `data.deep_link`.
- **Categories:** `MORNING_BRIEF`, `SUPPLEMENT_REMINDER`, `MEAL_REMINDER`, `RECOVERY_ALERT`, `INSIGHT`, `CELEBRATION`, `EXPERIMENT`.
- **Interruption levels:** passive (celebrations), active (reminders), time-sensitive (recovery alerts). Never use `critical`.
- **Sending rules:** All sends go through the `send-notification` Edge Function which enforces daily caps, per-category caps, quiet hours, and `critical_only` mode.
- **Push notification source of truth:** `life_os_api_specification.md` § Push Notification Payload Spec.

---

## 13) Dynamic Weight

- All weight-dependent calculations use `getEffectiveWeight()` — never read `users.weight_kg` directly.
- **Fallback chain:** (1) Rolling 7-day avg from `body_composition` → (2) Latest single measurement (< 30 days) → (3) Static `users.weight_kg`.
- When divergence from profile > 2kg, notify user to update.
- **Source of truth:** `life_os_recovery_algorithms.md` § 27.

---

## 14) Force Update / Minimum Version

- Server responses include the `X-Min-App-Version` header (semver, e.g. `1.2.0`).
- Server may also include `X-Soft-Update-Version` — a non-blocking update suggestion.
- Client compares its own build version against these headers on every authenticated API response.
- If `client_version < X-Min-App-Version` **and** the grace period has elapsed:
  - Show a **blocking** full-screen "Update Required" overlay with a direct App Store link.
  - All local functionality continues (offline-first is preserved), but Outbox push is paused until updated.
- If `client_version < X-Min-App-Version` but within the grace period, OR if `client_version < X-Soft-Update-Version`: show a **non-blocking** banner "Update available" once per session.
- **Grace period:** after a new minimum version is set server-side, enforce the blocking overlay only after **48 hours** to allow organic App Store propagation. During the grace window, show a soft update banner instead.
- Optional `X-App-Store-URL` header overrides the default App Store link and should point to a direct product page, not App Store search.

---

## 15) Deep Link Registry

All supported `lifeos://` deep link schemes. Any unrecognized deep link opens the Home screen.

| Scheme | Target | Source |
|--------|--------|--------|
| `lifeos://home` | Home tab | Internal navigation |
| `lifeos://recovery` | Recovery detail (today) | Widget, watchOS, notification |
| `lifeos://nutrition?date=YYYY-MM-DD` | Nutrition day view | Widget, notification |
| `lifeos://nutrition/log?method={photo\|barcode\|voice\|manual}` | Food log flow with pre-selected method | Notification, shortcut |
| `lifeos://supplements?date=YYYY-MM-DD` | Supplement day view | Widget, notification |
| `lifeos://supplements/log?date=YYYY-MM-DD` | Supplement log flow | Notification |
| `lifeos://workout?date=YYYY-MM-DD` | Workout day view | Widget |
| `lifeos://workout/log` | Start workout logging | Notification |
| `lifeos://diary?date=YYYY-MM-DD` | Unified diary day view | watchOS, notification |
| `lifeos://sleep?date=YYYY-MM-DD` | Sleep day view | Widget, notification |
| `lifeos://hydration?date=YYYY-MM-DD` | Hydration day view | Widget, notification |
| `lifeos://wellness?date=YYYY-MM-DD` | Wellness check day view | Notification |
| `lifeos://body-composition` | Body composition screen | Notification |
| `lifeos://insights/{id}` | Insight detail | Notification |
| `lifeos://experiments/{id}` | Experiment detail | Notification |
| `lifeos://settings/sync` | Sync status screen | Sync health banner |
| `lifeos://settings/notifications` | Notification settings | Notification |
| `lifeos://settings/privacy` | Privacy settings | Settings |
| `lifeos://labs/{id}` | Lab scan detail | Notification |
| `lifeos://auth/callback` | OAuth callback handler | Auth flow |

**Backward-compatible aliases** (not for new use):
- `lifeos://food/log` → same as `lifeos://nutrition/log`
- `lifeos://achievements` → redirects to Insights tab

**Fallback:** Unrecognized schemes → navigate to Home tab. Log the unrecognized scheme as `analytics.deeplink_fallback`.

---

## 16) API Conventions

- **HTTP methods:** `POST` for creates, `PATCH` for updates, `DELETE` for deletes. `PUT` is only used where full-replace semantics apply (rare).
- **Timestamps:** `TIMESTAMPTZ` in DB, ISO 8601 in API responses.
- **IDs:** `snake_case` in SQL, `camelCase` in JSON, Swift `lowerCamelCase`.
- **Local dates:** Client always sends `*_date` in user's timezone + `*_timezone` + `*_utc_offset_minutes`.
- **API source of truth:** `life_os_api_specification.md`.

---

## 17) Body Weight Source of Truth

Any feature that needs "current weight" (recovery algorithms, TDEE, nutrition targets) must use the `current_weight()` rule:

```
current_weight(user_id) →
  1. Latest `body_composition.weight_kg` WHERE age < 30 days
     → if found: use it
  2. ELSE: fallback to `users.weight_kg` (onboarding value)
```

**Rules:**
- If `body_composition` has multiple recent entries, use the **rolling 7-day average** (not just latest) for stability.
- `divergenceFromProfile`: if `current_weight()` diverges > 5% from `users.weight_kg`, surface a prompt: "Your weight has changed significantly. Update your profile?" (copy id: `profile.weight_divergence_prompt`).
- Recovery algorithms must call `current_weight()` — never read `users.weight_kg` directly.
- Weight unit conversion (imperial ↔ metric) happens at the API boundary; all storage is in kg.

---

## Changelog

| Version | Date | Change |
|---------|------|--------|
| 0.5 | 2026-02-16 | Added: same-category notification dedup cooldown §3, Force Update / Minimum Version §14, Deep Link Registry §15. Renumbered API Conventions to §16. |
| 0.4 | 2026-02-16 | Aligned dead-letter max retries to 10 (was 5) to match `life_os_sync_engine_spec.md` §8.2. |
| 0.3 | 2026-02-12 | Added invariants: Rate Limiting (§11), Push Notifications (§12), Dynamic Weight (§13). Renumbered API Conventions to §14. |
| 0.2 | 2026-02-09 | Fix control-level storage reference to match API schema |
| 0.1 | 2026-02-09 | Initial creation — consolidated from README and all spec documents |
