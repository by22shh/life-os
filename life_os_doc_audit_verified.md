# LIFE OS Documentation Audit (Verified)

Date: 2026-02-06
Scope: Markdown docs in /Users/Bayramov_N/Desktop/Other/life-os
Method: Targeted grep + line verification for each item in the provided list.

Legend:
Status = Confirmed | Partial | Not Found | Needs Clarification
Evidence = file:line (absolute path)
Fix = concrete, minimal change to resolve

---

## Critical Issues

1. API spec version mismatch (docs still reference v1.9 while API spec is v2.0).
Status: Confirmed
Evidence: /Users/Bayramov_N/Desktop/Other/life-os/life_os_api_specification.md:3, /Users/Bayramov_N/Desktop/Other/life-os/life_os_api_specification.md:4, /Users/Bayramov_N/Desktop/Other/life-os/life_os_ux_screens.md:5, /Users/Bayramov_N/Desktop/Other/life-os/life_os_sync_engine_spec.md:9, /Users/Bayramov_N/Desktop/Other/life-os/life_os_engineering_blueprint.md:11, /Users/Bayramov_N/Desktop/Other/life-os/life_os_technical_architecture.md:11
Fix: Update all cross-references to API spec v2.0 and verify any v2.0 deltas are propagated into dependent docs.

2. Missing critical API endpoints (wellness check, body composition CRUD, user supplements CRUD, user profile CRUD, recommendations read, media upload endpoints).
Status: Partial
Evidence (wellness): /Users/Bayramov_N/Desktop/Other/life-os/life_os_api_specification.md:4737 (only GET history listed)
Evidence (body composition table exists, no endpoints listed): /Users/Bayramov_N/Desktop/Other/life-os/life_os_api_specification.md:1011
Evidence (user supplements table exists, only supplement logs/schedule endpoints listed): /Users/Bayramov_N/Desktop/Other/life-os/life_os_api_specification.md:830, /Users/Bayramov_N/Desktop/Other/life-os/life_os_api_specification.md:4253, /Users/Bayramov_N/Desktop/Other/life-os/life_os_api_specification.md:4282
Evidence (only /api/user/health-flags endpoints, no /api/user/profile): /Users/Bayramov_N/Desktop/Other/life-os/life_os_api_specification.md:4759
Evidence (recommendations table exists, no /api/recommendations endpoint): /Users/Bayramov_N/Desktop/Other/life-os/life_os_api_specification.md:1612
Evidence (media analysis exists via Edge Functions, not /api upload): /Users/Bayramov_N/Desktop/Other/life-os/life_os_api_specification.md:2319, /Users/Bayramov_N/Desktop/Other/life-os/life_os_api_specification.md:3481
Fix: Add explicit /api endpoints for wellness checks, body composition, user supplements CRUD, user profile CRUD, and recommendations read. Decide whether image uploads are handled via /functions endpoints only or via a stable /api media upload contract; document the chosen approach.

3. Security: POST /api/account/delete accepts user_id from body (allows deleting other users).
Status: Confirmed
Evidence: /Users/Bayramov_N/Desktop/Other/life-os/life_os_api_specification.md:5253, /Users/Bayramov_N/Desktop/Other/life-os/life_os_api_specification.md:5268, /Users/Bayramov_N/Desktop/Other/life-os/life_os_api_specification.md:5277
Fix: Derive user from JWT (auth.uid) and ignore/forbid user_id in body. Log mismatches as security events.

4. Missing DB columns on users used by deletion flow.
Status: Confirmed
Evidence (users table lacks columns): /Users/Bayramov_N/Desktop/Other/life-os/life_os_api_specification.md:33, /Users/Bayramov_N/Desktop/Other/life-os/life_os_api_specification.md:67
Evidence (columns used): /Users/Bayramov_N/Desktop/Other/life-os/life_os_api_specification.md:5289, /Users/Bayramov_N/Desktop/Other/life-os/life_os_api_specification.md:5332
Fix: Add columns to users schema: deletion_scheduled_at, deletion_reason, deletion_in_progress, with types and indexes where needed.

5. calories type mismatch (NUMERIC in schema vs INTEGER in validation).
Status: Confirmed
Evidence: /Users/Bayramov_N/Desktop/Other/life-os/life_os_api_specification.md:358, /Users/Bayramov_N/Desktop/Other/life-os/life_os_api_specification.md:5702
Fix: Align validation to NUMERIC(8,2) or update schema to INTEGER everywhere. Prefer NUMERIC to preserve partial portions.

6. Outbox does not support PUT, but API uses PUT /api/settings/notifications.
Status: Confirmed
Evidence: /Users/Bayramov_N/Desktop/Other/life-os/life_os_sync_engine_spec.md:116, /Users/Bayramov_N/Desktop/Other/life-os/life_os_api_specification.md:2853
Fix: Add PUT to outbox http_method enum or change notifications endpoint to PATCH.

7. V2 tables sleep_logs and training_templates lack RLS and sync coverage.
Status: Confirmed
Evidence (tables exist): /Users/Bayramov_N/Desktop/Other/life-os/life_os_api_specification.md:4818, /Users/Bayramov_N/Desktop/Other/life-os/life_os_api_specification.md:4919
Evidence (RLS enable list missing both): /Users/Bayramov_N/Desktop/Other/life-os/life_os_api_specification.md:1991
Evidence (syncable tables list missing both): /Users/Bayramov_N/Desktop/Other/life-os/life_os_sync_engine_spec.md:161
Fix: Add RLS enable + policies for sleep_logs and training_templates and include them in syncable tables list.

---

## High Issues

8. No Home Screen spec in UX screens (only references, no dedicated section).
Status: Confirmed
Evidence: /Users/Bayramov_N/Desktop/Other/life-os/life_os_ux_screens.md:9, /Users/Bayramov_N/Desktop/Other/life-os/life_os_ux_screens.md:22
Fix: Add a Home Screen section with layout, states, and data contract.

9. Auth screens not specified (copy IDs exist but UX flow missing).
Status: Confirmed
Evidence (auth copy IDs): /Users/Bayramov_N/Desktop/Other/life-os/life_os_copy_catalog.md:132
Evidence (UX only says silent auth, no screens): /Users/Bayramov_N/Desktop/Other/life-os/life_os_ux_screens.md:38
Fix: Add explicit auth screen UX and flow (Apple, email OTP) or remove unused copy IDs if auth UI is out of scope.

10. Duplicate section numbering in UX screens (two 7s and two 8s).
Status: Confirmed
Evidence: /Users/Bayramov_N/Desktop/Other/life-os/life_os_ux_screens.md:1393, /Users/Bayramov_N/Desktop/Other/life-os/life_os_ux_screens.md:1406, /Users/Bayramov_N/Desktop/Other/life-os/life_os_ux_screens.md:1424, /Users/Bayramov_N/Desktop/Other/life-os/life_os_ux_screens.md:1509
Fix: Renumber sections to maintain a single ordered hierarchy.

11. Design System shows Insights as a tab, PRD says no dedicated tab.
Status: Confirmed
Evidence (PRD no tab): /Users/Bayramov_N/Desktop/Other/life-os/life_os_prd_v7_ultimate.md:928
Evidence (Design System tab hierarchy includes Insights): /Users/Bayramov_N/Desktop/Other/life-os/life_os_design_system.md:2207
Fix: Decide one source of truth and update the other (tab or no tab).

12. Experiment Results screen missing in UX screens (Design System nav references it).
Status: Confirmed
Evidence (Design System nav): /Users/Bayramov_N/Desktop/Other/life-os/life_os_design_system.md:2221
Evidence (UX screens list/detail only): /Users/Bayramov_N/Desktop/Other/life-os/life_os_ux_screens.md:1473
Fix: Add Experiment Results UX spec or remove it from Design System nav.

13. No changelog entry for UX screens v0.10.
Status: Confirmed
Evidence (version header): /Users/Bayramov_N/Desktop/Other/life-os/life_os_ux_screens.md:3
Evidence (latest changelog entry is v0.9): /Users/Bayramov_N/Desktop/Other/life-os/life_os_ux_screens.md:1651
Fix: Add v0.10 changelog entry summarizing deltas.

14. Caution zone color mismatch (Design System dark mode uses yellow, PRD says orange).
Status: Confirmed
Evidence (Design System): /Users/Bayramov_N/Desktop/Other/life-os/life_os_design_system.md:21
Evidence (PRD): /Users/Bayramov_N/Desktop/Other/life-os/life_os_prd_v7_ultimate.md:610
Fix: Align caution color token and update both docs.

15. Tab Bar and Settings use legacy neutral colors, conflicting with warm surface tokens.
Status: Confirmed
Evidence (warm surfaces rule): /Users/Bayramov_N/Desktop/Other/life-os/life_os_design_system.md:35
Evidence (tab bar colors): /Users/Bayramov_N/Desktop/Other/life-os/life_os_design_system.md:2130
Evidence (settings separators): /Users/Bayramov_N/Desktop/Other/life-os/life_os_design_system.md:2509
Fix: Replace legacy neutrals with warm surface tokens in component specs.

16. Pinecone appears in API spec but is not declared as a locked technology in architecture docs.
Status: Confirmed
Evidence (Pinecone in API spec): /Users/Bayramov_N/Desktop/Other/life-os/life_os_api_specification.md:5251
Evidence (locked tech list shows OpenRouter only): /Users/Bayramov_N/Desktop/Other/life-os/life_os_engineering_blueprint.md:24
Fix: Add Pinecone to locked technology decisions or replace it with declared vector store.

17. Auth flow mismatch: OTP/magic link listed, but example code uses signInWithPassword.
Status: Confirmed
Evidence (OTP/magic link): /Users/Bayramov_N/Desktop/Other/life-os/life_os_api_specification.md:2820
Evidence (password auth code): /Users/Bayramov_N/Desktop/Other/life-os/life_os_api_specification.md:5208
Fix: Pick one auth mode and remove the other, or document both with explicit UX guidance.

18. Deep nested RLS subqueries for food_items and workout_sets (performance risk).
Status: Confirmed
Evidence (food_items policy): /Users/Bayramov_N/Desktop/Other/life-os/life_os_api_specification.md:2032
Evidence (workout_sets policy): /Users/Bayramov_N/Desktop/Other/life-os/life_os_api_specification.md:2129
Fix: Denormalize user_id into child tables or use security definer views/functions.

19. Sleep logs missing from Offline-Safe Create Contract.
Status: Confirmed
Evidence (sleep log endpoint exists): /Users/Bayramov_N/Desktop/Other/life-os/life_os_api_specification.md:4874
Evidence (offline-safe list missing /api/sleep/log): /Users/Bayramov_N/Desktop/Other/life-os/life_os_api_specification.md:5583
Fix: Add /api/sleep/log (and ids) to offline-safe create contract.

20. Two different TRIMP formulas across docs (linear vs Banister exponential).
Status: Confirmed
Evidence (linear): /Users/Bayramov_N/Desktop/Other/life-os/life_os_health_ecosystem_spec.md:251
Evidence (exponential): /Users/Bayramov_N/Desktop/Other/life-os/life_os_recovery_algorithms.md:1285
Fix: Choose one TRIMP definition and align all docs.

21. TRIMP uses avgHeartRate but HealthKit mapping does not include HR avg.
Status: Confirmed
Evidence (TRIMP needs avgHeartRate): /Users/Bayramov_N/Desktop/Other/life-os/life_os_recovery_algorithms.md:1293
Evidence (workout mapping does not include HR avg; HR optional later): /Users/Bayramov_N/Desktop/Other/life-os/life_os_healthkit_spec.md:317
Fix: Add avgHeartRate derivation to HealthKit spec or use an alternate TRIMP variant.

22. Temperature is weighted at 15% but is optional; no fallback documented.
Status: Confirmed
Evidence (optional biomarker): /Users/Bayramov_N/Desktop/Other/life-os/life_os_healthkit_spec.md:125
Evidence (temperature weight 15%): /Users/Bayramov_N/Desktop/Other/life-os/life_os_recovery_algorithms.md:44
Fix: Define a fallback strategy (reweight missing components, or impute) and document it.

23. Confidence scoring mismatch (HealthKit spec uses 4 components, Recovery uses 7).
Status: Confirmed
Evidence (HealthKit components): /Users/Bayramov_N/Desktop/Other/life-os/life_os_healthkit_spec.md:401
Evidence (Recovery weights): /Users/Bayramov_N/Desktop/Other/life-os/life_os_recovery_algorithms.md:2277
Fix: Unify confidence model or explicitly scope each to a different layer with mapping.

24. Inline scientific citations missing from references list.
Status: Partial
Evidence (inline citations): /Users/Bayramov_N/Desktop/Other/life-os/life_os_recovery_algorithms.md:543, /Users/Bayramov_N/Desktop/Other/life-os/life_os_recovery_algorithms.md:836, /Users/Bayramov_N/Desktop/Other/life-os/life_os_recovery_algorithms.md:1008, /Users/Bayramov_N/Desktop/Other/life-os/life_os_recovery_algorithms.md:1026, /Users/Bayramov_N/Desktop/Other/life-os/life_os_recovery_algorithms.md:3266
Fix: Add missing references for Vandewalle, Bonnemeier, de Zambotti, Barron & Fehring, Kitamura in the references list.

25. E2E Master Matrix references BioimpedanceError for Labs OCR; Error spec defines HealthMarkersError.
Status: Confirmed
Evidence: /Users/Bayramov_N/Desktop/Other/life-os/life_os_e2e_master_matrix.md:35, /Users/Bayramov_N/Desktop/Other/life-os/life_os_error_handling.md:672
Fix: Update E2E master matrix to use HealthMarkersError.* for Labs OCR.

26. ValidationError and AIError used in E2E Master Matrix but not defined in error handling spec.
Status: Partial
Evidence (used): /Users/Bayramov_N/Desktop/Other/life-os/life_os_e2e_master_matrix.md:28, /Users/Bayramov_N/Desktop/Other/life-os/life_os_e2e_master_matrix.md:42
Fix: Define these errors in error handling spec or replace with existing enums.

27. Missing E2E tests for GDPR export/delete, consent management, insights/experiments.
Status: Partial
Evidence (E2E checklist lacks GDPR/consent terms; only insight ack appears in watch snapshot flow): /Users/Bayramov_N/Desktop/Other/life-os/life_os_e2e_test_checklists.md:875
Fix: Add explicit E2E scenarios for GDPR export/delete, consent management, insights list/detail, experiments logging/results.

28. Accessibility testing not included in Release Gate.
Status: Confirmed
Evidence: /Users/Bayramov_N/Desktop/Other/life-os/life_os_qa_master_pack.md:167
Fix: Add a11y checks to Release Gate (WCAG/VoiceOver checklists, dynamic type, contrast).

29. Privacy retention contradictions (Forever vs Account lifetime for the same data types).
Status: Confirmed
Evidence: /Users/Bayramov_N/Desktop/Other/life-os/life_os_privacy_architecture.md:28, /Users/Bayramov_N/Desktop/Other/life-os/life_os_privacy_architecture.md:206
Fix: Normalize retention policy per data type and update both tables.

---

## Medium Issues

30. Recovery zone naming mismatch (critical/caution/ready/optimal vs low/moderate/ready/optimal).
Status: Confirmed
Evidence (spec freeze): /Users/Bayramov_N/Desktop/Other/life-os/life_os_spec_freeze_v2.md:72
Evidence (scientific validation): [FILE REMOVED — god_prompt_scientific_validation.md no longer exists; validation content merged into life_os_recovery_algorithms.md]
Fix: Pick one naming set and align all docs and copy IDs.

31. ACWR zone naming mismatch (sweet_spot vs optimal vs OPTIMAL).
Status: Confirmed
Evidence (sweet_spot): /Users/Bayramov_N/Desktop/Other/life-os/life_os_health_ecosystem_expansion.md:420
Evidence (optimal): /Users/Bayramov_N/Desktop/Other/life-os/life_os_health_ecosystem_spec.md:279
Evidence (OPTIMAL enum): /Users/Bayramov_N/Desktop/Other/life-os/life_os_recovery_algorithms.md:1276
Fix: Normalize ACWR zone names and casing.

32. injury_risk vs danger vs INJURY_RISK naming mismatch.
Status: Confirmed
Evidence (injury_risk): /Users/Bayramov_N/Desktop/Other/life-os/life_os_health_ecosystem_spec.md:283
Evidence (danger): /Users/Bayramov_N/Desktop/Other/life-os/life_os_health_ecosystem_expansion.md:428
Evidence (INJURY_RISK): /Users/Bayramov_N/Desktop/Other/life-os/life_os_recovery_algorithms.md:1276
Fix: Standardize to one enum name.

33. trimp vs trimp_score field naming mismatch.
Status: Confirmed
Evidence (trimp): /Users/Bayramov_N/Desktop/Other/life-os/life_os_health_ecosystem_spec.md:238
Evidence (trimp_score): /Users/Bayramov_N/Desktop/Other/life-os/life_os_health_ecosystem_expansion.md:316
Fix: Pick one field name and apply consistently across docs and schema.

34. Tab label mismatch: "Supplements" vs "Supplements (includes Labs)".
Status: Confirmed
Evidence (PRD): /Users/Bayramov_N/Desktop/Other/life-os/life_os_prd_v7_ultimate.md:926
Evidence (Design System): /Users/Bayramov_N/Desktop/Other/life-os/life_os_design_system.md:2113
Fix: Decide label and update PRD/Design System/copy catalog.

35. "Protective" used for two concepts (control level and recovery zone behavior).
Status: Confirmed
Evidence (control model): /Users/Bayramov_N/Desktop/Other/life-os/life_os_technical_architecture.md:25
Evidence (recovery zone behavior): /Users/Bayramov_N/Desktop/Other/life-os/life_os_prd_v7_ultimate.md:216
Fix: Rename one concept or explicitly disambiguate in glossary.

36. TRIMP appears in wireframes without definition or formula nearby.
Status: Partial
Evidence: /Users/Bayramov_N/Desktop/Other/life-os/life_os_ux_screens.md:948, /Users/Bayramov_N/Desktop/Other/life-os/life_os_design_system.md:1403
Fix: Add a short TRIMP definition in UX/design system or link to the canonical formula.

37. Recovery algorithm weights inconsistent (headings show 20%/10%, formula shows 15%/15%).
Status: Confirmed
Evidence (formula): /Users/Bayramov_N/Desktop/Other/life-os/life_os_recovery_algorithms.md:40
Evidence (headings): /Users/Bayramov_N/Desktop/Other/life-os/life_os_recovery_algorithms.md:656, /Users/Bayramov_N/Desktop/Other/life-os/life_os_recovery_algorithms.md:715
Fix: Align headings to the actual weights or update the formula.

38. HRV plausibility thresholds mismatch (400 vs 300).
Status: Confirmed
Evidence (HealthKit spec > 400): /Users/Bayramov_N/Desktop/Other/life-os/life_os_healthkit_spec.md:278
Evidence (Recovery algorithms > 300): /Users/Bayramov_N/Desktop/Other/life-os/life_os_recovery_algorithms.md:115
Fix: Choose one threshold and align filters and validation.

39. ACWR trigger uses >1.4 while injury risk zone starts at >1.5.
Status: Confirmed
Evidence (trigger): /Users/Bayramov_N/Desktop/Other/life-os/life_os_health_ecosystem_spec.md:288
Evidence (zone): /Users/Bayramov_N/Desktop/Other/life-os/life_os_health_ecosystem_spec.md:283
Fix: Align trigger with zone boundary or justify the earlier trigger explicitly.

40. Protein target mismatch (1.6-2.2g/kg for all vs only athletes).
Status: Confirmed
Evidence (expansion: all): /Users/Bayramov_N/Desktop/Other/life-os/life_os_health_ecosystem_expansion.md:176
Evidence (recovery algorithms: strength athletes): /Users/Bayramov_N/Desktop/Other/life-os/life_os_recovery_algorithms.md:1481
Fix: Specify when 1.6-2.2 applies (athletes only vs general) and update both docs.

41. Recovery algorithms version header vs footer mismatch.
Status: Not Found
Evidence: No v3.1 string found in /Users/Bayramov_N/Desktop/Other/life-os/life_os_recovery_algorithms.md
Fix: If there is a footer elsewhere, point me to it; otherwise remove this item.

42. Notification category numbering out of order (1,2,5,3,4).
Status: Confirmed
Evidence: /Users/Bayramov_N/Desktop/Other/life-os/life_os_prd_v7_ultimate.md:330, /Users/Bayramov_N/Desktop/Other/life-os/life_os_prd_v7_ultimate.md:361, /Users/Bayramov_N/Desktop/Other/life-os/life_os_prd_v7_ultimate.md:379, /Users/Bayramov_N/Desktop/Other/life-os/life_os_prd_v7_ultimate.md:392
Fix: Renumber categories sequentially or remove numbers.

43. Copy/i18n section splits Design Principles list.
Status: Confirmed
Evidence: /Users/Bayramov_N/Desktop/Other/life-os/life_os_prd_v7_ultimate.md:141, /Users/Bayramov_N/Desktop/Other/life-os/life_os_prd_v7_ultimate.md:157, /Users/Bayramov_N/Desktop/Other/life-os/life_os_prd_v7_ultimate.md:181
Fix: Move copy/i18n to a separate section after all design principles.

44. Analytics Events section splits Success Metrics Phase 0 and Phase 1.
Status: Confirmed
Evidence: /Users/Bayramov_N/Desktop/Other/life-os/life_os_prd_v7_ultimate.md:1316, /Users/Bayramov_N/Desktop/Other/life-os/life_os_prd_v7_ultimate.md:1331, /Users/Bayramov_N/Desktop/Other/life-os/life_os_prd_v7_ultimate.md:1358
Fix: Move analytics section after all success metric phases or before Phase 0.

45. Design System "Needs Specification" vs "Specified" list contradiction.
Status: Not Found
Evidence: No matching sections found in /Users/Bayramov_N/Desktop/Other/life-os/life_os_design_system.md
Fix: Provide the exact location if this exists.

46. Design System language is mixed Russian/English while other docs are English.
Status: Confirmed
Evidence: /Users/Bayramov_N/Desktop/Other/life-os/life_os_design_system.md:2103
Fix: Translate to a single language or document a bilingual policy.

47. Sync engine missing in backlog.
Status: Partial
Evidence (backlog covers HealthKit sync but no offline outbox engine tasks): /Users/Bayramov_N/Desktop/Other/life-os/life_os_build_backlog.md:27
Fix: Add explicit backlog items for outbox/pull sync engine implementation.

48. Supplements calendar month grid in scope freeze but not in backlog.
Status: Confirmed
Evidence (scope freeze): /Users/Bayramov_N/Desktop/Other/life-os/life_os_spec_freeze_v2.md:29
Evidence (backlog only daily endpoint): /Users/Bayramov_N/Desktop/Other/life-os/life_os_build_backlog.md:107
Fix: Add backlog item for supplements month grid UX + API.

49. GDPR export/delete missing from backlog.
Status: Partial
Evidence: No GDPR/export/delete tasks found in /Users/Bayramov_N/Desktop/Other/life-os/life_os_build_backlog.md
Fix: Add backlog items for GDPR export and account deletion flows.

50. Bioimpedance prompts exist but are not in V2 scope or backlog.
Status: Confirmed
Evidence (prompts): /Users/Bayramov_N/Desktop/Other/life-os/life_os_gpt_prompts.md:1556
Evidence (scope freeze list does not include bioimpedance docs): /Users/Bayramov_N/Desktop/Other/life-os/life_os_spec_freeze_v2.md:48
Fix: Either add bioimpedance to scope/backlog or mark prompts as post-V2.

51. Several docs not listed in frozen baseline (drift risk): food_data_strategy, health_ecosystem_spec, accessibility_guidelines, functional_matrix, data_lineage_matrix, cis_edge_cases, ux_benchmarks, health_ecosystem_expansion. [NOTE: god_prompt_design_audit and god_prompt_scientific_validation no longer exist — content merged into life_os_recovery_algorithms.md and life_os_design_system.md]
Status: Confirmed
Evidence (frozen baseline list): /Users/Bayramov_N/Desktop/Other/life-os/life_os_spec_freeze_v2.md:48
Fix: Add these docs to frozen baseline or mark them as non-authoritative.

---

## Low Issues

52. UX screens reference Copy Catalog v1.10 while header says v1.11.
Status: Confirmed
Evidence: /Users/Bayramov_N/Desktop/Other/life-os/life_os_ux_screens.md:5, /Users/Bayramov_N/Desktop/Other/life-os/life_os_ux_screens.md:1395
Fix: Update internal reference to v1.11.

53. Missing copy IDs for recovery zone labels, home screen, health screening questions, insights empty state.
Status: Partial
Evidence (insights list has no empty state IDs): /Users/Bayramov_N/Desktop/Other/life-os/life_os_copy_catalog.md:82
Evidence (no home.* entries found in copy catalog): /Users/Bayramov_N/Desktop/Other/life-os/life_os_copy_catalog.md:1
Fix: Add explicit copy IDs for these surfaces or map to existing IDs.

54. Auth copy IDs defined but no auth screen UX uses them.
Status: Confirmed
Evidence (auth copy IDs): /Users/Bayramov_N/Desktop/Other/life-os/life_os_copy_catalog.md:132
Evidence (UX has silent auth only): /Users/Bayramov_N/Desktop/Other/life-os/life_os_ux_screens.md:38
Fix: Add auth screen specs or prune unused copy IDs.

55. Onboarding progress indicator shows 5 steps while spec says 6.
Status: Confirmed
Evidence (5 labels in wireframe): /Users/Bayramov_N/Desktop/Other/life-os/life_os_prd_v7_ultimate.md:738
Evidence (6 required steps): /Users/Bayramov_N/Desktop/Other/life-os/life_os_ux_screens.md:36
Fix: Update step labels or step count to match.

56. Label scan fallback is only defined for barcode-not-found, not voice/search not-found.
Status: Partial
Evidence (label scan as barcode fallback): /Users/Bayramov_N/Desktop/Other/life-os/life_os_ux_screens.md:537
Fix: Define fallback flow for voice/search not-found or declare it out of scope.

57. watchOS snapshot lacks sleep_quality and nutrition adherence fields.
Status: Confirmed
Evidence (watchOS snapshot interface): /Users/Bayramov_N/Desktop/Other/life-os/life_os_watchos_spec.md:80
Evidence (API snapshot example): /Users/Bayramov_N/Desktop/Other/life-os/life_os_api_specification.md:3129
Fix: Add fields if required by product, or document why they are excluded.

58. watchOS spec does not address WidgetKit/complication refresh constraints.
Status: Confirmed
Evidence: No WidgetKit/refresh guidance in /Users/Bayramov_N/Desktop/Other/life-os/life_os_watchos_spec.md
Fix: Add WidgetKit refresh budget and complication update rules.

59. GPT Prompt 7 includes specific supplement dosages (safety risk).
Status: Confirmed
Evidence: /Users/Bayramov_N/Desktop/Other/life-os/life_os_gpt_prompts.md:1378
Fix: Remove dosage recommendations or gate them behind clinician disclaimers and explicit scope.

60. GPT Prompt 2 uses raw hrv_ms while scientific validation expects lnRMSSD.
Status: Confirmed
Evidence (prompt): /Users/Bayramov_N/Desktop/Other/life-os/life_os_gpt_prompts.md:654
Evidence (validation): [FILE REMOVED — god_prompt_scientific_validation.md no longer exists; validation content merged into life_os_recovery_algorithms.md]
Fix: Normalize HRV input to lnRMSSD or update validation spec.

61. allostatic_load is used in prompts but missing from API/DB.
Status: Not Found
Evidence: allostatic_load exists in physiological_states schema: /Users/Bayramov_N/Desktop/Other/life-os/life_os_api_specification.md:247
Fix: Remove this item.

62. Food photo analysis latency mismatch (<3s vs p95 <5s).
Status: Confirmed
Evidence: /Users/Bayramov_N/Desktop/Other/life-os/life_os_health_ecosystem_expansion.md:80, /Users/Bayramov_N/Desktop/Other/life-os/life_os_health_ecosystem_spec.md:440
Fix: Align latency targets to one SLA.

63. experiments.deleted_reason lacks CHECK constraint.
Status: Confirmed
Evidence (no CHECK): /Users/Bayramov_N/Desktop/Other/life-os/life_os_api_specification.md:1497
Evidence (other tables have CHECK): /Users/Bayramov_N/Desktop/Other/life-os/life_os_api_specification.md:391
Fix: Add CHECK constraint for experiments.deleted_reason to match other soft-delete tables.

