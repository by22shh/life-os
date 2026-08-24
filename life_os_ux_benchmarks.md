# LIFE OS — UX Benchmarks & Pattern Decisions (Market-Informed)

**Version:** 0.1  
**Date:** February 4, 2026  
**Purpose:** Explicitly document the **market UX patterns** we are adopting (and rejecting) so the product stays consistent, “modern”, and implementation-ready—especially for **Russia + CIS**.

> [!NOTE]
> This doc is intentionally practical: it translates common best-in-class patterns into concrete Life OS decisions and cross-links to our specs.

---

## 1) Onboarding (Activation in < 2 Minutes)

**Common market pattern (best apps):**
- Immediate value preview before permission asks.
- Progressive disclosure: ask only what’s needed now.
- “Skip” is safe; user can finish onboarding without being blocked.
- Trust-building microcopy around privacy/permissions.

**Life OS decisions (locked):**
- **Silent auth** (anonymous) on first launch; account upgrade later.  
  Source: `life_os_ux_screens.md` (2.0) + `life_os_api_specification.md` (Auth).
- **6-step max** onboarding with a “demo quick win” before any permissions.  
  Source: `life_os_ux_screens.md` (2.x).
- HealthKit permission only after value (Step 3), notifications only after first insight (Step 6).  
  Source: `life_os_ux_screens.md` (2.3, 2.6).

**What we avoid:**
- Account wall before first insight.
- Permission spam on launch.
- Long questionnaires and guilt-driven “you must complete” flows.

---

## 2) Nutrition Diary & Logging (Fast + Trustworthy)

**Common market pattern:**
- Calendar day view + week strip + month grid (fast navigation).
- “Recent / Favorites” dominate search ranking.
- Multi-item meal assembly tray (power-user flow).
- Barcode as “lowest friction” for packaged foods.

**Life OS decisions (locked):**
- Day view default, week strip always visible, month grid as sheet.  
  Source: `life_os_ux_screens.md` (3.1–3.7) + `life_os_design_system.md` (Nutrition screens).
- Multi-method entry via one sheet (Photo/Barcode/Voice/Search/Quick Add/Recipe).  
  Source: `life_os_ux_screens.md` (3.9).
- **Review gate** for AI/low-confidence results (photo, voice parse, label OCR).  
  Source: `life_os_ux_screens.md` (3.8, 3.10, 3.12, 3.11A) + `life_os_error_handling.md`.
- **CIS-critical barcode miss recovery:** Scan nutrition label → OCR → Review Product → Save reusable barcode product.  
  Source: `life_os_ux_screens.md` (3.11A), `life_os_food_data_strategy.md`, `life_os_api_specification.md` (foods + analyze-food-label).
- **Meal prep (batch recipes):** cook once, log portions by grams with remaining tracking.  
  Source: `life_os_ux_screens.md` (3.16) + `life_os_api_specification.md` (batches) + `life_os_design_system.md`.

**What we avoid:**
- Saving OCR/AI results without showing editable review (trust break).
- “Barcode not found” dead ends (catastrophic for CIS).

---

## 3) Barcode & Food DB Strategy (Stability for Russia + CIS)

**Common market problem:**
- Commercial barcode databases have uneven CIS coverage and can be operationally fragile by region.

**Life OS decisions (locked):**
- Primary provider: **Open Food Facts** (cache + attribution).  
- Fallback: **Label OCR catalog** + mandatory review.  
- User override always wins (custom food with barcode).  
Source of truth: `life_os_food_data_strategy.md`.

---

## 4) Training Diary & Strength Logging (Gym Apps Best Practices)

**Common market pattern:**
- Set-based logging with very fast numeric entry.
- Rest timer is optional but a major usability win.
- Templates + “start planned” reduce friction.

**Life OS decisions (locked):**
- Calendar training diary (month/week/day) + planned vs logged.  
  Source: `life_os_ux_screens.md` (4.x).
- Strength session UI: exercise cards + set rows + optional rest timer.  
  Source: `life_os_ux_screens.md` (4.9) + `life_os_design_system.md`.
- Import/manual conflict resolution must be explicit with undo.  
  Source: `life_os_ux_screens.md` (4.6), `life_os_api_specification.md` (workout_sessions soft delete), `life_os_error_handling.md`.

**What we avoid:**
- Silent overwrite of imported/manual sessions.
- Workflows that require scrolling huge exercise libraries (search-first picker is required).

---

## 5) Sleep (Clarity Over Complexity)

**Common market pattern:**
- One clear score + 2–3 drivers (“why”) + 1–2 actions (“try tonight”).
- Trends are more motivating than raw numbers.

**Life OS decisions (locked):**
- Sleep detail is read-first with stages + 7-day trend + gentle actions.  
  Source: `life_os_ux_screens.md` (Sleep Detail) + `life_os_design_system.md` (Sleep screens).
- Stages timeline can remain on-device (HealthKit), server stores daily aggregates.  
  Source: `life_os_healthkit_spec.md`.

---

## 6) Labs Import (Trust + Normalization)

**Common market pattern:**
- OCR must be async and skippable (don’t trap user).
- Review is mandatory for low confidence.
- Duplicate detection avoids data pollution.

**Life OS decisions (locked):**
- Async scan states + return-later UX + privacy toggles (local-only default).  
  Source: `life_os_ux_screens.md` (6.x) + `life_os_privacy_architecture.md`.

---

## 7) Supplements (Adherence Without Medical Claims)

**Common market pattern:**
- One-tap “Taken”, schedule-driven reminders, adherence feedback.
- Avoid dosing recommendations (legal + safety risk).

**Life OS decisions (locked):**
- Dose is user-entered only; app can suggest timing tips, not dosing.  
  Source: `life_os_health_ecosystem_spec.md` + `life_os_design_system.md` + `life_os_copy_catalog.md`.

---

## 8) CIS-Specific UX Notes (Non-Negotiables)

1. Cyrillic-first search behavior and mixed-language queries (e.g., “кефир danone”).  
   Source: `life_os_food_data_strategy.md`.
2. Barcode misses are normal: label scan flow must be first-class, not hidden.  
   Source: `life_os_ux_screens.md` (3.11A).
3. Metric units by default; avoid unit confusion in onboarding and portion editors.  
   Source: `life_os_prd_v7_ultimate.md`, `life_os_api_specification.md`.

---

## 9) Notifications & Control (Safety by Design)

**Common market pattern:**
- Aggressive notification spam and guilt‑based copy.

**Life OS decisions (locked):**
- Hard cap: max 6 notifications/day with priority queue.
- Control levels: Advisory / Protective / Guardian.
- Guardian requires explicit consent and Focus Control permission.

Source: `life_os_prd_v7_ultimate.md`, `life_os_api_specification.md`, `life_os_ux_screens.md`.
