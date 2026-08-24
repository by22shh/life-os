# LIFE OS — FOOD DATA STRATEGY (BARCODES + SEARCH) — CIS-Optimized

**Version:** 1.0  
**Date:** February 4, 2026  
**Purpose:** A single, implementation-ready decision record and contract for food barcode lookup + food search that works reliably for **Russia + CIS** at scale.

---

## 0) Executive Summary (Decisions Locked In)

**Primary provider (barcode + search):** **Open Food Facts** (`open_food_facts`)  
**Strategic fallback for CIS coverage:** **Life OS Label OCR Catalog** (`lifeos_label_ocr`)  
**User-level override:** `user_foods` with optional `barcode` (personal corrections and custom items)  
**Offline resilience:** local recents/favorites + cached catalog items; no barcode flow is blocked by provider outages.

This combination is the most stable long-term because:
- It avoids vendor lock-in and sanction/region risk (open data baseline).
- It provides a deterministic fallback path when coverage is missing (very common in CIS).
- It keeps the user in flow (log in seconds even when databases fail).

---

## 1) Product Principles (Psychology + UX)

1. **Never punish missing coverage.** “Not found” must feel normal, not like a failure.
2. **Always offer a “still log in seconds” path.** For barcodes: Search / Photo / Manual / Label Scan.
3. **Trust-building through review.** Any OCR-derived product must be reviewed once before it becomes reusable.
4. **Default to fast repeat behavior.** Recents/favorites/templates must dominate search ranking.
5. **Minimize cognitive load.** The app chooses the best source automatically; users only intervene when needed.

---

## 2) Provider Strategy (What We Use and Why)

### 2.1 Open Food Facts (Primary)

**Use for:**
- Barcode lookup (packaged foods)
- Search discovery (brand products)

**Why:**
- Open community dataset, global, strong in Europe, usable in CIS.
- Low operational risk compared to commercial vendors.
- Works well with an internal cache (`food_catalog_items`).

**Constraints we accept:**
- Coverage gaps in CIS (especially smaller brands).
- Occasional incorrect nutrition labels (community input).

We handle these via:
- User overrides (`user_foods`)
- Label OCR fallback (`lifeos_label_ocr`)

### 2.2 Life OS Label OCR Catalog (Fallback for CIS)

When a barcode is not found in the primary provider, Life OS offers:
- “Scan nutrition label” → OCR → **Review** → Save as a reusable product for barcode.

**Important posture:**
- Store **extracted nutrition values** as structured data.
- Do **not** require storing the original packaging photo to keep storage + copyright risk low.

This is the decisive feature for CIS usability: users can “bootstrap” coverage naturally while meal logging.

### 2.3 User-Level Overrides (Always Available)

If the user thinks a product’s macros are wrong:
- They can “Create custom” (or “Fix macros”) and we store it in `user_foods` with the same `barcode`.
- Future scans prefer `user_foods` for that barcode (personal truth).

---

## 3) Data Model Contract (How This Maps to DB)

### 3.1 Global Catalog Cache: `food_catalog_items`

Stores normalized products used by many users:
- `provider = open_food_facts` (cached provider result, TTL-based)
- `provider = lifeos_label_ocr` (OCR-created product, no TTL by default)

Key fields:
- `barcode` (digits only)
- per-100g macros (canonical)
- optional serving size grams
- cache timestamps

### 3.2 User Custom Foods: `user_foods`

Stores user-owned foods, including personal barcode overrides:
- optional `barcode` for “override this product on scan”
- per-100g macros are canonical

### 3.3 Favorites: `user_food_favorites`

Favorites refer to either:
- catalog item (`ref_type = catalog`)
- custom item (`ref_type = custom`)

---

## 4) Deterministic Lookup Order (Barcode)

Barcode lookup MUST follow this precedence (first match wins):

1. `user_foods` where `barcode = scanned_code` (user override)
2. `food_catalog_items` where `provider = open_food_facts` and `barcode = scanned_code` and not expired
3. Provider fetch (Open Food Facts) → cache to `food_catalog_items`
4. `food_catalog_items` where `provider = lifeos_label_ocr` and `barcode = scanned_code` (community fallback)
5. Not found → present “Scan label / Search / Photo / Manual”

This rule is mandatory for consistent UX and user trust.

---

## 5) Search Strategy (CIS-Friendly)

### 5.1 Ranking Order (What the user sees first)

Search results must be merged and ranked:
1. Favorites (exact / strong match)
2. Recents (strong match)
3. User custom foods (strong match)
4. Cached catalog items (strong match)
5. Provider search results (Open Food Facts), cached on-demand

### 5.2 Language + Typing Behavior

Search must handle CIS realities:
- Cyrillic product names
- Mixed-language queries (e.g., “кефир danone”)
- Common abbreviations (“БЖУ”, “ккал”, “гр”)
- Transliteration tolerance (optional V1+)

### 5.3 Country Bias (Default)

When the user’s locale is RU/UA/KZ/etc:
- Prefer items with Russian/CIS-friendly naming and brands (if provider supports country tags).
- Prefer results previously used by users in those locales (future improvement).

---

## 6) Nutrition Normalization Rules (Label-Specific)

### 6.1 Canonical Storage

Always store macros per **100g** in the catalog and in custom foods.

### 6.2 Calories vs kJ

If label provides only kJ:
- Convert: `kcal = kJ / 4.184`
- Store rounded to 1 decimal max for per-100g values

### 6.3 Salt vs Sodium

If label provides salt (NaCl) but not sodium:
- Convert sodium mg: `sodium_mg = salt_g * 1000 * 0.393`

If label provides sodium but not salt:
- Optional display-only: `salt_g = sodium_mg / 1000 / 0.393`

### 6.4 Fiber and Sugar

- If fiber is missing, keep NULL (do not invent for packaged foods).
- Sugar may be missing; keep NULL.

### 6.5 Consistency Check (Sanity)

For any product:
- Reject if any macro < 0
- Reject if calories per 100g is implausible (> 900)
- If calories and macros disagree beyond tolerance:
  - keep macros; compute calories using 4/4/9/7 (protein/carbs/fat/alcohol) and flag “needs review”

---

## 7) Label OCR Flow (When Barcode Not Found)

### 7.1 Input

User provides:
- barcode (from scanner)
- 1–2 photos: nutrition panel (required), front pack (optional)
- language hint (from locale)

### 7.2 Output

The system must produce:
- product name (best effort)
- brand (best effort)
- serving size grams (if present)
- per-100g macros
- confidence + warnings

### 7.3 Mandatory UX Gate

Before saving a new barcode product, the user must see a **Review Product** screen:
- editable values
- unit checks
- confidence badges

After confirm:
- create/update `food_catalog_items` with `provider = lifeos_label_ocr` and `barcode`

---

## 8) Attribution + Legal/Store Readiness

### 8.1 Open Food Facts Attribution

App must include a “Data Sources” section (Settings) with:
- “Product data from Open Food Facts”
- License note: ODbL
- Link to Open Food Facts website

### 8.2 User-Submitted Data

For `lifeos_label_ocr` items:
- treat as “community sourced / user submitted”
- display a small badge when logging:
  - “Community data — review if unsure”

---

## 9) Reliability + Caching

### 9.1 TTL Rules

- `open_food_facts` items: TTL 30 days (`expires_at = fetched_at + 30d`)
- `lifeos_label_ocr` items: no TTL by default (expires_at NULL)

### 9.2 Offline Mode

If offline:
- barcode lookup shows cached results only
- if not in cache: allow label scan (barcode optional; stored locally) OR manual entry

### 9.3 Vector Embeddings (Opt‑In)

If the user opts in to AI memory features:
- A server-side cron job scans `food_logs` where `synced_to_vector_db = false`.
- It generates embeddings (OpenRouter (`openai/text-embedding-3-small`)), upserts into Pinecone
  namespace `user_{id}`, then stores `vector_id` and flips `synced_to_vector_db = true`.
- Embeddings are derived summaries only (no raw photos, no PII).

---

## 10) Monitoring (Quality Flywheel)

Track (aggregated, non-identifying):
- Barcode not-found rate by locale
- % of logs that use label OCR fallback
- Provider latency/error rate
- “User override created” rate (signals data quality problems)

---

## 11) Acceptance Criteria

1. In RU locale, a barcode miss never blocks logging: user can still log within 15 seconds.
2. Barcode lookup is deterministic: same barcode returns the same result given same user overrides.
3. Label OCR requires review before saving; no silent insertion.
4. Offline behavior is graceful: cached lookup works, uncached falls back to manual without errors.
