# iOS data-flow integration audit — 2026-09-08

## Scope and method

Read-only audit of the current working tree: Auth/Onboarding, GRDB/SyncEngine, Privacy/backup, Nutrition, Training, Labs, unified Diary. No source edits. HealthKit/recovery/notifications/watch/widgets and comprehensive backend audit belong to other audit workers. No repeated Xcode/Deno suite runs; parent owns them. Project `.codex/skills` and `.agents/skills` are absent. No `.planning` phase summaries or requirement IDs were available: mappings below use concrete acceptance checklist section/item identifiers and master-spec sections, not invented REQ IDs.

Evidence is end-to-end source tracing unless explicitly marked runtime. One standalone Swift harness extracted the actual `LabsMarkerCatalog` and `ExtractedLabMarker` from the current source and executed them unchanged. This is not a mocked substitute for the parser. Runtime iOS UI, device backup extraction, real auth, transport and cross-device reproduction remain unverified here.

## Verdict

The local storage/write paths are substantial and useful, but the system cannot currently be certified reliable for health history, privacy or offline/cloud convergence. Core ordinary flows can discard local-only records, overwrite queued edits, and misparse laboratory values. Independent unit-test success would not demonstrate that these paths compose safely.

## Confirmed findings

### IOS-DATA-01 — P1 / BLOCKER: lab OCR corrupts decimal-comma values and assigns mismatched units/reference ranges

**Files:** `ios/LifeOS/Modules/Labs/LabsView.swift:1184`, `:1204`, `:1217`, `:1277`, `:652`, `:808`.

Capture → Vision text → `LabsMarkerCatalog.extractMarkers` splits each line on **every comma before parsing**. The regex permits only ASCII marker names. Missing units are replaced with fixed English catalog units/ranges; explicit units do not cause range conversion. The result feeds the review UI and `HealthMeasurement` persistence. Confidence is a fixed 0.88 for any nonempty image extraction / 0.84 for PDF, not OCR or normalization quality.

**Exact runtime reproduction (standalone extracted Swift parser):**

```
Glucose 5,6 mmol/L => Glucose=5 mg/dL ref=70.0-100.0 normal=false
Glucose 5.6 mmol/L => Glucose=5.6 mmol/L ref=70.0-100.0 normal=false
Глюкоза 5,6 ммоль/л => []
Ferritin 85,5 ng/mL => Ferritin=85 ng/mL ref=30.0-400.0 normal=true
```

The second example proves catalog ranges are reused across unit systems; the first loses both the fractional value and real unit. This is a deterministic data-integrity defect, not a clinical interpretation claim. User review is present but does not repair the erroneous extraction automatically. Existing `LabsViewCoverageTests.swift:26` tests English dotted values, missing these cases.

**Requirements:** master §7 Labs normalization; acceptance §8.2, CIS/localization data correctness.

### IOS-DATA-02 — P1 / BLOCKER: opening detail overwrites pending local edits with stale server data

**Files:** `NutritionLogViewModel.swift:393`; `NutritionService.swift:896`, `:1664`, `:1701`, `:1738`; `TrainingDayView.swift:1477`; `TrainingService.swift:367`, `:628`, `:664`, `:724` (all under `ios/LifeOS/Modules/`).

Meal/workout detail UI requests remote whenever runtime and cloud session exist. Service reads local first but then fetches and unconditionally caches remote parent and replaces all children. There is no pending-outbox or local timestamp guard in these detail paths. In contrast, template/batch loaders have dedicated pending-mutation checks.

**Reproduction trace:** sync an entity → change its portion/sets offline → local DB and PATCH outbox contain new values → reconnect/open detail before replay or while replay is retrying → GET returns previous server values → cache overwrites local parent/items/sets → editor displays old values. Saving another change from this stale screen then queues old values over the first correction. Even without a second save, local display temporarily regresses. Cache additionally stamps remote objects with `Date()` instead of server timestamp; `SyncEngine.hasNewerLocalEdit` can reject subsequent authoritative pulls as older.

**Requirements:** master §5; acceptance §2.5, §3.7–8, §6.3/6.

### IOS-DATA-03 — P1 / BLOCKER: ordinary authenticated logout destroys local-only health history and unsent outbox

**Files:** `ios/LifeOS/Modules/Settings/SettingsAccountDestinationViews.swift:516–537`; `ios/LifeOS/Modules/Shared/Network/AuthManager.swift:693`, `:798`; `ios/LifeOS/Modules/Shared/Privacy/LocalPrivacyOperations.swift:5–27`.

Authenticated Sign Out calls `AuthManager.signOut` immediately; confirmation is only used for anonymous/reset/recovered-local cases. After remote signout, all user-scoped tables, users, outbox and sync state are purged. No pending-write check, flush, preservation by identity, or warning about local-only records is performed. This includes default-local-only menstrual logs and lab scans/measurements even for fully authenticated cloud accounts.

**Reproduction:** authenticated user imports a lab PDF with default local-only privacy → logs out → logs into the same account → GRDB records were deleted and no remote copies ever existed. Unsent nutrition/training mutations are likewise erased. Physical raw scan files can remain (next finding), but the user has lost their indexed history.

`try? await clearLocalUserState()` also hides purge errors and proceeds to signedOut, so failed cleanup is not observable to the user.

**Requirements:** master §5/9 local-first data control; acceptance §1.6 data continuity (related), §8.4.

### IOS-DATA-04 — P1 / BLOCKER: local erasure reports completion while backups and raw scans remain

**Files:** `ios/LifeOS/Modules/Shared/Privacy/LocalPrivacyOperations.swift:138–147`, `:377–465`; `ios/LifeOS/Modules/Shared/Database/DatabaseBackupManager.swift:44–77`, `:139–147`; `ios/LifeOS/Modules/Labs/LabScanDetailView.swift:1083–1104`.

Local erasure deletes exported JSON, nutrition photo drafts, DB rows and field key. It does not delete `LifeOS/MedicalScans` or daily full-database backups. Nevertheless the audit entry sets `storageDeleted: true` and later `compliance_verified = 1`, returning `deletionState: completed`. Backups contain many unencrypted model columns as well as encrypted fields; deleting the field key does not erase plaintext history. Retention keeps three copies until enough future backups replace them, not an immediate deletion guarantee.

**Reproduction:** create lab asset + run daily backup → execute local account erasure → observe completed state while MedicalScans file and pre-erasure SQLite snapshot remain. Lab orphan maintenance may delete the unreferenced file on a later maintenance run; it is not part of deletion completion. Backup erasure has no corresponding hook at all.

**Requirements:** acceptance §10.6; master §9.

### IOS-DATA-05 — P1 / BLOCKER: revoking menstrual sync consent does not stop queued upload

**Files:** `ios/LifeOS/Modules/Shared/Database/MenstrualStore.swift:15–22`, `:166–178`; `ios/LifeOS/Modules/Settings/SettingsDestinationViews.swift:2555–2568`; `ios/LifeOS/Modules/Shared/Database/SyncEngine.swift:599–612`; `supabase/functions/api/menstrual/sync/index.ts:69–173`.

Menstrual save checks opt-in when creating `api-menstrual-sync` event. Settings' revocation policy cancels medical and user-health-flags events but not menstrual events. Push rechecks medical/health/vector permission, again not menstrual. Backend authenticates and upserts via service role without reading `menstrual_local_only`.

**Reproduction:** disable local-only → save cycle log offline → enable local-only before reconnect → pending event remains → next push sends it → backend saves it. This breaks an explicit, current privacy choice even though the ordinary default-enqueue path is gated correctly.

**Requirements:** privacy architecture line 81; master §9; menstrual opt-in contract.

### IOS-DATA-06 — P1 / WARNING: parallel pull violates parent-child foreign-key ordering

**Files:** `ios/LifeOS/Modules/Shared/Database/SyncEngine.swift:143–173`, `:373`, `:104–107`; `NutritionSyncHandler.swift:17–25`; `TrainingSyncHandler.swift:16–22`; `Migrations.swift:271–275`, `:516–537`; `DatabaseManager.swift:193–195` (module handlers/migrations under Shared/Database or owning module).

`pullAll` adds one task for each table to a single throwing task group. Parents and children are not staged: food_logs/food_items, workout_sessions/workout_exercises/workout_sets, training_plans/training_plan_sessions, batch_recipes/ingredients. SQLite foreign keys are enabled, and each arriving page saves immediately in its own transaction.

**Reproduction trace:** empty local tables + remote meal with items → child response finishes before parent response → `food_items.save` raises FK violation → task group throws → full `runSyncLoop` stops before outbox push. Retry may recover after parent rows happen to persist, so this is intermittent rather than a guaranteed permanent break. It remains a confirmed possible execution ordering; transport-delay runtime reproduction was not run in this audit.

**Requirements:** master §5; acceptance §2.5 / §6.5 and restoring multi-table history.

### IOS-DATA-07 — P1 / BLOCKER: export misses local-only records for cloud users; local export omits workout exercises

**Files:** `ios/LifeOS/Modules/Shared/Privacy/PrivacyGateway.swift:42–88`, `:120–151`; `LocalPrivacyOperations.swift:225–297`; `ios/LifeOS/Modules/Shared/Database/Migrations.swift:516–537`.

Two confirmed export gaps:

1. For runtime-configured cloud users, requestExport sends only `export_id` to the server, and download returns that archive unchanged. Local-only lab/cycle/flags records are not uploaded or merged into this export. Thus the default local-only data cannot appear in the generated cloud archive.
2. Local export selects only tables with user_id/auth_id or four device tables. `workout_exercises` has only `session_id` and is excluded; workout_sets is included with dangling exercise_entry_id. The workout tree cannot be reconstructed from the export. Encrypted local values are serialized directly as ciphertext strings without decrypting for portability (separate warning), and no key is exported.

**Reproduction:** cloud account stores local-only lab → export → lab absent by construction. For local runtime, export workout with one exercise/set → tables has workout_sessions/workout_sets but lacks workout_exercises.

**Requirements:** acceptance §10.5; privacy architecture comprehensive export.

### IOS-DATA-08 — P2 / BLOCKER: lab date and duplicate workflows are absent in local capture

**Files:** `ios/LifeOS/Modules/Labs/LabsView.swift:616–625`, `:746`, `:805–807`, `:833`, `:881–887`, `:1044–1178`.

Save always allocates a fresh scan UUID and uses `Date()` as scan and measured date. Review model has only marker name/value/unit/range/normal status; it has no document date. `source_file_sha256` is stored but never checked on this local save path. No same-day marker overlap query or conflict choice precedes insert. Backend duplicate logic, if present, cannot cover default local-only imports.

**Reproduction:** import an older lab PDF → review → save → historical results are assigned today's date. Import it again → second local scan and measurement set are inserted without duplicate warning. This affects chronological usefulness and trend data.

**Requirements:** acceptance §8.3 (same-day marker overlap ≥60%); Labs import/normalization workflow.

### IOS-DATA-09 — P1 / WARNING: primary store and raw scans are not excluded from OS backup

**Files:** `ios/LifeOS/Modules/Shared/Database/DatabaseManager.swift:278–290`; `ios/LifeOS/Modules/Labs/LabScanDetailView.swift:1083–1104`; compare explicit exclusions at `DatabaseBackupManager.swift:167–178` and `NutritionDayView.swift:282`.

Primary `Application Support/LifeOS/lifeos.db` and `MedicalScans` are created without `isExcludedFromBackup`. Only the separate database backup directory and nutrition drafts set this property. Consequently application-level local-only/cloud-backup consent does not cover the ordinary OS backup channel. File protection/field encryption does not itself exclude a file from backup.

Verified: missing exclusion on the primary store and raw assets, independent of app privacy flags. Actual iCloud/Finder backup extraction was not run; platform behavior must be confirmed on a physical release build. Avoid stating a real user's data has already leaked.

**Requirements:** acceptance §8.4/§10.4; master §9 local-first privacy.

### IOS-DATA-10 — P2 / BLOCKER: unified diary calendar and daily status contract are not wired

**Files:** `ios/LifeOS/Modules/Diary/DiaryView.swift:45–52`; `DiaryViewModel.swift:75–123`, `:551`.

Unified diary renders a compact DatePicker and independently queries local module summaries. It has no unified month status grid nor `/api/diary/daily` or `/api/diary/calendar` consumer. A review queue exists separately, so review navigation is not wholly absent; however unified day-level needs_review/status aggregation and deterministic next_best_action are not part of this view model. Changing date is usable, but selecting a date is not the specified month completeness calendar. Labs summary ignores requested day and always chooses latest scan.

**Requirements:** acceptance §6.5.1–5; master §2 Unified daily diary with calendar. Local-first reads are valid architecture; absence of an HTTP call alone is not the defect—the missing unified status/calendar behavior is.

### IOS-DATA-11 — P2 / BLOCKER: automatic backups have no production restoration consumer

**Files:** `ios/LifeOS/Modules/Shared/Database/DatabaseManager.swift:215–239`; `DatabaseBackupManager.swift:88–103`.

Startup catches DB/migration error and returns unavailable. `newestValidBackupURL` is declared and tested but never called from production recovery. No integrity_check/backup restoration chain is wired. This deliberately avoids overwriting damaged data, which is preferable to silent loss, but does not fulfill the promised automatic recovery workflow.

**Requirements:** `life_os_error_handling.md:1599–1625` (try each backup, integrity check, then server rebuild / support). Existing tests of backup selection/copy do not prove startup uses them.

## Working connections actually traced

| Connection | Status / scope | Evidence |
|---|---|---|
| Auth bootstrap → local identity → shell/onboarding state | WIRED, source trace | AuthManager bootstrap/applySessionState/synchronizeLocalIdentityState/refreshPostAuthState; UserIdentityReconciler canonicalizes IDs and rewrites scoped references/outbox |
| Onboarding transition/completion → GRDB + outbox | WIRED, source trace | OnboardingFeature uses performOptimisticMutation at 953/1177; completion also writes onboarding state event in transaction |
| Manual nutrition save/edit/delete/undo → local DB + dependency outbox | WIRED for persistence; detail refresh BROKEN | NutritionService persistNewMeal/updateMeal/deleteMeal/undoDeleteMeal; snapshot children + dependsOn; 24-hour undo guard |
| Manual workout save/edit/delete/undo → exercises/sets + outbox | WIRED for persistence; detail refresh BROKEN | TrainingService createManualWorkout/updateWorkout/deleteWorkout/undoDeleteWorkout; plan linkage and 24-hour undo |
| Local log → selected-day diary summary | WIRED for common local data | DiaryViewModel user-scoped SQL and local-date grouping |
| Lab image/PDF → OCR → editable review → persistent scan/markers | BROKEN for integrity; path exists | LabsScanCaptureView processImage/processPDF/handleReviewSave/persistMarkers; IOS-DATA-01/08 |
| Medical local-only → no ordinary lab enqueue/pull | WIRED default gate | persistMarkers storageMode test; SyncEngine shouldPullRestrictedMedicalData; raw assets remain local on ordinary request path |
| Medical/vector consent revoke → queued-event gate | WIRED for examined paths | Settings policy + SyncEngine medical/vector checks; menstrual separately BROKEN |
| Local changes → ordered dependency replay → reconcile | BROKEN for full resilience | Outbox dependencies/headers/retry exist; IOS-DATA-02/06 |
| Data deletion → every local artifact removed | BROKEN | IOS-DATA-04 |
| Every core data type → portable complete export | BROKEN | IOS-DATA-07 |
| Persistent DB failure → backup restore → resumed app | BROKEN | IOS-DATA-11 |

## Requirements integration map

| Requirement reference | Path | Status | Finding |
|---|---|---|---|
| AC §1.1/§1.5 onboarding/basic auth | bootstrap → local identity → onboarding → shell | WIRED by trace; real auth unverified | Parent owns Apple capability defect |
| AC §1.6 linking retains data | AuthManager → identity reconciler → rekey local scope/outbox | WIRED by trace for linking | Ordinary logout is a separate destructive path, IOS-DATA-03 |
| AC §2.4 grouping by logged_date | local log → DiaryViewModel loadSummary | WIRED | — |
| AC §2.5 offline logging | local transaction → outbox → replay/pull → detail | BROKEN | 02, 03, 06 |
| AC §3.6–9 nutrition persistence/edit/delete | service → DB/items → edge outbox → UI reload | BROKEN across refresh | 02 |
| AC §3.5 templates / §5 batches | service transaction → dedicated mutation routes → guarded cache | WIRED by inspected paths | No real backend round trip performed |
| AC §6.3/5–7 training | editor → exercise/set snapshot → outbox → detail | BROKEN across refresh | 02, 06 |
| AC §6.5 unified calendar/status | diary UI → summary/status grid/action | BROKEN | 10 |
| AC §8.2 review / normalized OCR | capture → extraction → review → measurement | BROKEN | 01 |
| AC §8.3 duplicates | local capture → overlap detection → review choice | BROKEN | 08 |
| AC §8.4–5 privacy | capture settings → gated enqueue/pull; local lifecycle | BROKEN across logout/deletion/OS backup | 03, 04, 09 |
| AC §10.5 export | local + remote domain data → portable archive | BROKEN | 07 |
| AC §10.6 deletion | erasure request → DB/files/backups removed | BROKEN locally | 04 |
| Master §5 offline sync | local mutation → parent/child pull → push → reconcile | BROKEN for specified edge paths | 02, 06 |
| Privacy architecture menstrual opt-in | settings → queued mutations → server | BROKEN | 05 |
| Error handling crash recovery ladder | backup writer → startup restore | BROKEN | 11 |

Requirements without cross-phase wiring: local UI details such as gram labels, calendar icon+text styling and rest-timer interaction were not the scope of this data-flow audit. No named REQ-ID inventory exists in the checked working tree; do not interpret this as all product requirements being covered.

## Verification limits and test gaps

- Runtime evidence: exact laboratory parser reproduction succeeded; main test suites are managed by parent.
- Sync FK race is established by concurrent task scheduling + real FK constraints; deterministic delay transport test was not executed here.
- Existing tests cover happy-path remote detail caching, CRUD, privacy failure probes, retention and identity reconciliation. They do not establish lifecycle tests for pending-edit→remote-detail overwrite, opt-in→queued-menstrual→revoke→replay, logout→login preservation of default-local-only data, complete export graph, erasure→backup/raw-file cleanup, or real OS backups.
- Lab OCR capture state uses view @State and only persists at Save; leaving during extraction/pending review does not produce a resumable background OCR job. AC §8.1 background leave/return behavior requires dedicated UI/lifecycle validation.
- Sensitive records serialized from raw local rows remain encrypted strings; practical portable export use needs a test that decrypts and inspects expected values after export.
- Auth/session/network and Settings mutations contain additional non-atomic save/enqueue boundaries; these are potential crash windows, not escalated here without a concrete injected-failure run.
- Do not equate WIRED-by-trace with passing physical-device or production service tests.
