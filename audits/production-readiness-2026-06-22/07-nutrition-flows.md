# Phase 8 - Nutrition Flows

Date: 2026-06-23

## Verdict

Status: PASS.

Nutrition's photo, barcode, label OCR, voice parse, search, custom food, templates, batch recipes, portions, and calendar paths were reviewed against the current local/iOS and Supabase contracts. The mandatory iOS and Edge gates pass, and I added targeted follow-up xcodebuild runs for batch/calendar/review-gate support so this phase is not relying on broad green tests alone.

No production Swift, Supabase, Edge, or UI code changes were required in this phase.

## Mandatory Commands

| Command | Result | Evidence |
| --- | --- | --- |
| Targeted nutrition `xcodebuild test` for `NutritionServiceTests`, `NutritionTargetEngineTests`, `TrainingCalendarSupportTests`, and `EndToEndScenariosUITests` | PASS | `phase-8-logs/ios-nutrition-gate-final.log`: 45 unit/model tests plus 8 UI tests, 0 failures; `** TEST SUCCEEDED **`; `exit=0`. |
| `deno test -A supabase/functions/tests/food_image_analysis.test.ts supabase/functions/tests/foods_provider.test.ts supabase/functions/tests/parse_food_text_edge.test.ts supabase/functions/tests/ai_entrypoints_success.test.ts` | PASS | `phase-8-logs/deno-food-ai-tests.log`: `ok | 36 passed (18 steps) | 0 failed`; `exit=0` by command completion. |

Retry context:

- `phase-8-logs/ios-nutrition-gate.log`: invalid first wrapper attempt caused an empty `-derivedDataPath` argument to swallow the first `-only-testing` selector. This was a command-harness error, not app evidence.
- `phase-8-logs/ios-nutrition-gate-final.log`: reran the mandatory command with explicit `/tmp/lifeos-ios-gate` DerivedData and exited 0.

## Additional Targeted Proof

| Command | Result | Evidence |
| --- | --- | --- |
| Extra nutrition flow `xcodebuild test` for `CoverageFinalPushTests` nutrition calendar, batch library, template, draft resolver, photo, barcode, and rendered input coverage | PASS | `phase-8-logs/ios-nutrition-extra-flow-tests.log`: 7 tests, 0 failures; `** TEST SUCCEEDED **`; `exit=0`. |
| `xcodebuild test -only-testing:LifeOSTests/LowCoverageUtilitiesTests` | PASS | `phase-8-logs/ios-lowcoverage-nutrition-support.log`: 9 tests, 0 failures, including `testNutritionReviewGateBranches`; `** TEST SUCCEEDED **`; `exit=0`. |
| Batch functional `xcodebuild test` for `FinalCoverageContinuationTests` batch recipe identity tests | PASS | `phase-8-logs/ios-batch-functional-tests.log`: 2 tests, 0 failures; verifies successful batch create with resolved database user id and failure without resolved user id; `** TEST SUCCEEDED **`; `exit=0`. |

Selector note: I first addressed the two batch functional tests as `LowCoverageUtilitiesTests` because they live in the same file; Xcode correctly ran 0 matching methods for that class. The follow-up used the actual class, `FinalCoverageContinuationTests`, and both tests passed.

## Nutrition Flow Matrix

| Flow | Status | Evidence |
| --- | --- | --- |
| Photo log | PASS | `NutritionLogViewModel` blocks save until review for unknown/low photo confidence, allows only an explicitly reviewed photo placeholder, stamps local timezone/UTC offset, applies `FoodLog.applyReviewGate()`, and queues local persistence through `MealDraftManaging`/`NutritionService`. `CoverageFinalPushTests.testNutritionDraftResolverPublicVoiceAndPhotoCoverage`, `testNutritionPhotoAndBarcodeActionMethodCoverage`, and Edge `analyze-food-image` tests pass. |
| Barcode scan | PASS | `NutritionCatalogService.lookupBarcode` calls `api-foods/barcode/{code}`, caches remote results, and falls back to local custom override, fresh Open Food Facts cache, label OCR catalog cache, then generic catalog. `NutritionServiceTests` cover remote/cache/local miss paths; `foods_provider.test.ts` covers normalization, unavailable provider behavior, OCR fallback, enrichment flags, malformed payloads, and custom overrides. |
| Label OCR / reviewed food | PASS | `createReviewedFood` routes barcode-backed label review into catalog creation and non-barcode review into user custom food. `foods_provider.test.ts` and `ai_entrypoints_success.test.ts` cover `lifeos_label_ocr`, label payload normalization, guardrails, and failure responses. |
| Voice parse | PASS | `NutritionSpeechRecognizer`/draft resolver path feeds structured text into `parse-food-text`; the Edge handler returns meals, inferred meal types, warnings, clarification flags, and estimated confidence. `parse_food_text_edge.test.ts` covers parsing, empty input, unit conversions, repository failures, and guardrails. |
| Search and custom food | PASS | Search skips blank remote calls, ranks favorites/recent/custom/cache results, falls back to local cache on Edge failure, and surfaces empty/failure state through the search UI. `EndToEndScenariosUITests.testNutritionManualSearchScenario` adds a manual searched food and verifies the meal row count increases. |
| Templates | PASS | Template create/update/apply/archive paths persist locally and queue `api-nutrition-templates` outbox work with dependent food item events. Mandatory `NutritionServiceTests` and extra `testNutritionTemplateAndBatchActionHelpersCoverage` / `testNutritionTemplateBatchAndSystemPickerInstanceCoverage` pass. |
| Batch recipes and portions | PASS | Batch recipe UI requires non-empty name, total weight, total portions, and at least one ingredient before save. Functional tests prove create uses the resolved database user id, stores ingredients/totals/per-100g macros, loads detail back, and refuses to pretend success when identity cannot resolve. Extra coverage tests prove library load/failure states and action helpers. |
| Calendar | PASS | `NutritionCalendarView` loads month-local logged days by `logged_date`; extra `testNutritionCalendarAndBatchLibraryLoaderCoverage` proves only the displayed month's nutrition days are surfaced. Phase 7 already verified nutrition local-day/timezone lineage. |

## Review Gate and One-Tap Safety

The low-confidence gate is fail-closed:

- `NutritionReviewGate.confidenceThreshold` is `0.65`.
- Unknown confidence on photo input requires explicit review; manual input with unknown confidence does not.
- `NutritionLogViewModel.canSave` requires `!requiresEditFirst || didReviewLowConfidence`.
- The save button is disabled when `viewModel.canSave` is false.
- `save()` itself re-checks `guard canSave else { return false }`, so UI bypass does not persist unsafe logs.
- Edge `api-food-log` validates `ai_confidence` in `[0, 1]` and sets `needs_review` when `ai_confidence < 0.65`.

The reviewed photo placeholder path is intentional save-for-later behavior, not unsafe one-tap save: it is allowed only for photo input after the user explicitly confirms review, when there is no existing meal, no items, no draft macro totals, and no persistable detected items. The persisted log gets `aiConfidence = 0.0`, `applyReviewGate()`, and remains review-marked.

## Local Fallback and Offline Save-for-Later

| Area | Status | Evidence |
| --- | --- | --- |
| Food search | PASS | Search falls back from Edge to local cache and rethrows only when the local fallback is empty. |
| Barcode lookup | PASS | Barcode lookup returns local custom override, fresh provider cache, label OCR cache, or generic catalog cache when remote lookup fails. |
| Manual/custom food | PASS | Custom foods are cached locally and can be used as `userFoodId` references; reviewed barcode/catalog foods are cached for later lookup. |
| Meal log | PASS | Quick log and draft save paths insert local `food_logs`/`food_items` and queue `api-food-log` or dependent REST outbox events. |
| Templates | PASS | Template create/apply/archive paths queue local outbox events and dependent food item events. |
| Batch recipes | PASS | Batch create validates identity before local persistence/outbox. The batch functional tests prove success and failure boundaries. |
| Photo save-for-later | PASS | View-model tests prove low-confidence photo logs cannot save before explicit review and can persist an explicitly reviewed placeholder with `needsReview = true`. |

## Edge Contract Review

| Surface | Status | Evidence |
| --- | --- | --- |
| `api-food-log` create/update/delete/undo | PASS | Rejects body-level `user_id` spoofing, validates macro/nutrient ranges, validates timezone offset, sanitizes timezone, computes `needs_review` from AI confidence, and replaces food items transactionally on update. |
| `api-foods` and provider layer | PASS | Open Food Facts lookup/search uses timeouts, User-Agent, provider cache TTL, locale headers, custom-food preference, OCR fallback, and explicit provider error mapping. |
| AI entrypoints | PASS | `analyze-food-image`, `analyze-food-label`, `analyze-batch-recipe-image`, and OpenRouter gateway normalize upstream output, cap inputs/hints, and return guarded validation/config/auth/rate-limit failures. |
| Text parse | PASS | `parse-food-text` handles malformed JSON, empty/unsupported inputs, inferred meal types, warnings, confidence, and fallback suggestions. |

## UI Coverage

| UI path | Status | Evidence |
| --- | --- | --- |
| Golden manual nutrition flow | PASS | `testNutritionManualSearchScenario` opens a dated nutrition deeplink, adds Banana Bread through manual search, saves, and verifies two meal rows. |
| Nutrition modal/rendered states | PASS | Extra coverage tests instantiate direct input, calendar, template, batch, photo, barcode, and draft resolver surfaces. |
| Failure/empty states | PASS | Template and batch library failure/empty states, provider failure fallbacks, parse empty cases, label/image guardrails, and review-gated save disabled states are covered by the targeted iOS and Deno tests. |

No UI code changed, so no new screenshot artifact was required for this phase.

## Acceptance Criteria

| Criterion | Status |
| --- | --- |
| Photo, barcode, label OCR, voice parse, search, custom food, templates, batch recipes, portions, and calendar paths are code-reviewed against specs. | PASS |
| Nutrition service/model tests pass. | PASS |
| Edge tests for AI/food providers pass. | PASS |
| UI tests or simulator smoke cover golden nutrition flows and failure/empty states. | PASS |
| Low-confidence/review-gate behavior prevents unsafe one-tap saves. | PASS |
| Local fallback/offline save-for-later behavior is verified or explicitly filed as a blocker. | PASS |

## Notes

- Simulator logs about unpaired WatchConnectivity, Family Controls monitor authorization, and SwiftUI state access in non-installed test harness views were non-blocking and did not fail tests.
- The extra nutrition flow command contains a now-documented wrong-class selector for the two batch functional methods; the corrected `ios-batch-functional-tests.log` is the authoritative batch functional evidence.
