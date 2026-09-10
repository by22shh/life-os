# iOS data-flow repairs — 2026-09-09

Scope: F05–F08; IOS-DATA-02–07,09,11; calorie-visibility safety propagation. Parser, lab dates/duplicates, unified diary and HealthKit/recovery are owned by other workers.

## Implemented

- **Detail refresh:** NutritionService/TrainingService recheck unsent, in-flight and failed mutations inside the same write transaction as cache replacement. They preserve a newer local parent, retain pending child edits, and return the actual persisted snapshot. Parent/child timestamps come from server `created_at`/`updated_at`; missing versions use a conservative distant-past value rather than fabrication with the current clock.
- **Logout:** ordinary logout retains the health database, encrypted fields, and outbox. A persisted owner lock prevents anonymous bootstrap or another account from accessing/rebinding the retained vault. The original identity can reopen it. Confirmed local-profile removal and anonymous reset explicitly use complete local erasure. Widgets and Watch snapshots are cleared on logout.
- **Erasure:** deletes local exports, nutrition drafts, MedicalScans, recovery quarantines, temporary downloaded archives, and daily backups. The backup actor blocks new snapshots after erasure starts. Database freed pages/WAL are scrubbed before compliance is set; any artifact/key/SQL failure prevents a successful result. Following server acceptance, local health history is erased immediately; only the minimal deletion request, user stub and audit remain. Normal pull/reconcile/push stop while erasure is pending, avoiding rehydration of the deleted local history. A device-only Keychain receipt supports status polling after the auth identity has been deleted. A 401 is never treated as proof of deletion.
- **Menstrual consent:** revocation cancels menstrual outbox paths, and replay independently rechecks the current local consent before dispatch.
- **Pull dependencies:** pulls catalogs and users first, then module parents and children in foreign-key order, including experiments before measurements. Removed per-table parallel races.
- **Export:** includes indirect-owned workout exercises and batch ingredients, readable decrypted fields, normalized UUIDs, and both cloud and local snapshots in one portable JSON download. Local-only data is bundled on-device and is never uploaded for export. Both snapshots are preserved explicitly when unsent local changes conflict with cloud data.
- **Backups/recovery:** SQLite online backup replaces unsafe copying of live DB/WAL files. Candidate backups must pass integrity and foreign-key checks. Startup attempts recovery only on confirmed corruption, validates the staged copy, and preserves damaged originals in a protected quarantine. Permission, disk-space and migration failures do not overwrite the original database.
- **OS backups:** the entire primary LifeOS data directory is excluded from OS backup; the Labs worker additionally applies protection/exclusion at asset creation.
- **Calorie visibility:** shared NutritionSafetyPolicy hides calorie labels/inputs in food search, meal/template/batch detail and editing, capture review, onboarding quick-win and imported-training summaries. Home/NBA suppress calorie targets for eating-disorder/pregnancy flags. Generic dynamic nutrition target hints are disabled for those flags. Widget payloads omit nutrition when hidden, Watch outgoing server/local snapshots remove nutrition adherence and calorie-derived actions. Health-flag saves refresh both surfaces immediately.

## Regression coverage added or strengthened

- DatabaseBackupManagerTests: real SQLite integrity selection, corrupt-newest fallback, restoration retaining damaged evidence.
- NutritionServiceTests / TrainingServiceTests: server-version cache behavior and a queued edit surviving subsequent detail fetch.
- LocalPrivacyOperationsTests: full workout graph, decrypted local biomarker export, artifact cleanup failure does not certify deletion.
- PrivacyGatewayTests: cloud/local export bundle contains both snapshots.
- AuthManagerOnboardingFlowTests: logout retains local-only measurements/outbox and rejects another identity while permitting the original identity.
- SyncEngineControlFlowTests: queued menstrual upload is cancelled after consent revocation without invoking transport.
- WidgetSnapshotCoordinatorTests: eating-disorder safety overrides widget opt-in; pregnancy suppresses generic targets without hiding food history.

Production PrivacySettings decoding also now defaults absent consent fields to false instead of failing on legacy payloads. This repaired a runtime contract failure discovered by the parent test run.

## Verification and operational limits

Static Swift parsing passed during implementation. The parent runs the integrated iOS build/unit suite and owns final runtime evidence; do not interpret this file as a claim that physical-device flows, OS backup extraction, Watch delivery while disconnected, or production cloud deployment have been verified. Receipt endpoints and detail timestamp fields require the coordinated backend changes from this repair set. Calorie formula effectiveness is not medically validated; the repair suppresses generic advice for the existing safety flags rather than inventing clinical targets.
