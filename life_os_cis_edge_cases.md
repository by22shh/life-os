# LIFE OS — CIS Edge Cases & Localization Pitfalls

**Version:** 0.1  
**Date:** February 4, 2026  
**Purpose:** Enumerate CIS‑specific edge cases that must be handled to avoid broken UX in Russia + neighboring countries.

---

## 1) Nutrition Labels (Cyrillic Variants)

1. **Б/Ж/У abbreviations** are common without full words.  
   - Must map to protein/fat/carbs.
2. **ккал vs кДж only**:
   - Convert kJ → kcal when kcal missing.
3. **Salt only (соль)**:
   - Derive sodium via `sodium_mg = salt_g * 1000 * 0.393`.
4. **Per 100g only** (no serving size):
   - Accept per‑100g and keep serving null.
5. **Per serving only** without grams:
   - Must request serving grams; do not infer.
6. **Comma decimals** (e.g., 2,5):
   - Parse correctly as 2.5.
7. **Mixed languages** (RU + EN):
   - Keep original label, map normalized.

---

## 2) Product Naming / Search

1. Mixed query: “кефир danone” should still return relevant items.
2. Cyrillic + translit (optional V1+): “kefir” should match “кефир”.
3. Abbrev: “БЖУ”, “ккал”, “гр” used in search text.
4. Brand-first items: “Снежок Простоквашино” — must not reorder incorrectly.

---

## 3) Barcode Reality in CIS

1. Many products lack database coverage.  
   - Must show “Scan label” fallback immediately.
2. Printed barcodes may be low contrast.  
   - Provide manual “Type code” fallback.
3. Multiple packaging sizes with same product name.  
   - User override must be allowed to correct macros.

---

## 4) Units & User Expectations

1. Metric only by default (grams, kg, cm).
2. Avoid “oz / cups” defaults unless user explicitly chooses.
3. Decimal commas displayed for RU locale.

---

## 5) Labs (CIS Specific)

1. Cyrillic marker names (e.g., “ТТГ”, “ЛПНП”).
2. Units like “мкМЕ/мл”, “ммоль/л”.
3. Reference ranges sometimes use “—” instead of explicit min/max.

---

## 6) Date/Time Formatting

1. 24‑hour time is the default (e.g., 21:30).
2. Week starts on Monday in RU locale.
3. Month names localized correctly (e.g., “Февраль”).

---

## 7) Legal/Attribution

1. Open Food Facts attribution must be visible in Settings.
2. “Community data” label must not imply medical accuracy.

