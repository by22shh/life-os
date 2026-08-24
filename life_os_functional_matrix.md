# LIFE OS — Functional Matrix (User Journey Coverage)

**Version:** 0.6
**Date:** July 30, 2026
**Purpose:** Map user‑requested functionality to specs, attach an audited repository snapshot, and keep only real open items in the readiness backlog.

**Legend:**
- **описано** — детально прописано в документации
- **пробел** — отсутствует в спеках
- **требуются решения** — частично описано, нужен выбор или детализация

**Важно:** колонка `Статус` ниже по‑прежнему отражает полноту спецификаций, а не готовность релиза сама по себе. Сверка с реальным кодом на **May 28, 2026** вынесена в примечания строк и в итоговый audited snapshot ниже. Финальная readiness‑оценка должна опираться на код, сборку и QA‑gate’ы, а не на один документ.

| Область | Пользовательская потребность | Где описано | Статус | Примечания и задачи |
|---|---|---|---|---|
| Онбординг | Визуально приятный минималистичный старт, максимум 6 шагов | `life_os_ux_screens.md`, `life_os_prd_v7_ultimate.md`, `life_os_design_system.md` | описано | Тайминг зафиксирован: Step 1–6 ≤ 2 минуты; измеряется аналитикой `onboarding_completion_time` |
| Auth | Безболезненный вход без “стены аккаунта” | `life_os_api_specification.md` (anonymous auth), `life_os_ux_screens.md` (Silent auth) | описано | В репо реализовано: silent anonymous auth, local fallback/recovery и upgrade/link Apple/email из Settings без потери локального профиля |
| Онбординг | Сбор базовых параметров (возраст/рост/вес/цель/активность) | `life_os_prd_v7_ultimate.md`, `life_os_api_specification.md` (`users`), `life_os_ux_screens.md` (Step 4) | описано | Финализировать UX‑валидации и единицы (metric/imperial) |
| Онбординг | Опционально: добавить БАДы и импортировать анализы (без увеличения обязательных шагов) | `life_os_ux_screens.md` (Step 4A/4B), `life_os_copy_catalog.md` | описано | Доступно также из профиля после онбординга |
| Онбординг | Импорт Apple Health (HealthKit) | `life_os_healthkit_spec.md`, `life_os_ux_screens.md` (Step 3), `life_os_api_specification.md` | описано | В репо реализовано: auth request, anchors, hourly background delivery, 14-day backfill, source precedence, confidence degradation (`HealthKitManager`, `HealthSyncManager`, `SleepDetailSupport`) |
| Данные | Корректная группировка “по дням” при путешествиях | `life_os_api_specification.md` (local date + timezone fields), `life_os_healthkit_spec.md` | описано | В репо реализовано: timezone history на клиенте для HealthKit и manual-entry путей, плюс сохранение `*_timezone` и `*_utc_offset_minutes` для display/persistence correctness |
| Дневник | Единый дневник дня (еда + тренировки + БАДы + сон) | `life_os_ux_screens.md` (Unified Diary), `life_os_design_system.md` | описано | Рекомендуемый “один экран на день” |
| Питание | Быстрый выбор метода лога (Photo/Barcode/Voice/Search) | `life_os_ux_screens.md` (3.9), `life_os_design_system.md` | описано | В репо реализовано: method picker + modal flows для photo/barcode/voice/search, плюс templates, batch recipes и calendar |
| Питание | Фото‑лог: съемка → AI → Review Meal | `life_os_ux_screens.md` (3.10 + 3.8), `life_os_api_specification.md` (`analyze-food-image`), `life_os_gpt_prompts.md` | описано | В репо реализовано: image analysis, OCR/barcode hints, review gate, а также локальный save-for-later с возобновлением, удалением и privacy-erasure cleanup |
| Питание | Штрихкод: скан → lookup → порция → add (+ label OCR fallback) | `life_os_ux_screens.md` (3.11–3.11A), `life_os_api_specification.md` (foods/barcode + create), `life_os_food_data_strategy.md`, `life_os_error_handling.md` | описано | В репо реализовано: barcode scan, remote/local lookup, OCR fallback и create-from-label path; провайдер Open Food Facts + CIS fallback зашит в код и edge functions |
| Питание | Поиск еды + избранное/недавнее + кастомная еда | `life_os_ux_screens.md` (3.13), `life_os_api_specification.md` (foods/search, `user_foods`, `user_food_favorites`) | описано | В репо реализовано: search, local fallback, custom food create, cached barcode/search reuse и полный favorites list/add/remove с local-first outbox; ranking hardening остаётся quality-улучшением |
| Питание | Голосовой ввод: transcript → parse → 0–2 уточнения → review | `life_os_ux_screens.md` (3.12), `life_os_api_specification.md` (`parse-food-text`) | описано | В репо реализовано: voice input, интерактивные ответы на 0–2 backend-уточнения, повторный parse с ответами и review fallback без обязательного ответа |
| Питание | Редактор порций (граммы/порции) | `life_os_ux_screens.md` (3.14), `life_os_design_system.md` | описано | Валидация: grams > 0, soft cap |
| Питание | Шаблоны/Quick Add/Repeat last | `life_os_ux_screens.md` (3.15), `life_os_api_specification.md` (`meal_templates` + templates endpoints), `life_os_copy_catalog.md` | описано | В репо реализовано: templates library, apply template, remote list/detail, local storage и repeat-style flows |
| Питание | Рецепты/батч‑готовка (meal prep) | `life_os_ux_screens.md` (3.16), `life_os_api_specification.md` (`batch_recipes` + endpoints), `life_os_design_system.md`, `life_os_health_ecosystem_spec.md` | описано | В репо реализовано: batch recipe library, precise/quick create flows, portion logging, archive/duplicate и sync support |
| Питание | Дневник питания с календарем (месяц/неделя/день) | `life_os_ux_screens.md` (3.x), `life_os_design_system.md`, `life_os_api_specification.md` (`/api/nutrition/calendar`) | описано | В репо реализовано: nutrition calendar surface на iOS; диапазонный API сохранён как backend contract |
| Тренировки | Ручной лог (сеты/репы/вес) | `life_os_api_specification.md` (`workout_*`, exercises API), `life_os_prd_v7_ultimate.md`, `life_os_ux_screens.md` (4.8–4.11), `life_os_design_system.md`, `life_os_copy_catalog.md` | описано | В репо реализовано: workout log, sets/reps/weight, rest timer и guardrails для неполных сетов |
| Тренировки | Импорт тренировок из Apple Health | `life_os_healthkit_spec.md`, `life_os_api_specification.md` (`import_provider`, `import_source_id`) | описано | В репо реализовано: HealthKit workout import через `HealthSyncManager`/`HealthKitManager`, включая `import_source_id`-based reconciliation |
| Тренировки | Конфликты manual vs import (merge/keep + undo) | `life_os_ux_screens.md` (4.6), `life_os_design_system.md`, `life_os_error_handling.md`, `life_os_copy_catalog.md` | описано | В репо реализовано: merge/keep imported/keep manual и undo delete path |
| Тренировки | План тренировок + адаптация | `life_os_health_ecosystem_spec.md`, `life_os_api_specification.md`, `life_os_prd_v7_ultimate.md` | описано | В репо реализовано: generate/update/adjust/manage surfaces и route client support |
| Тренировки | Дневник тренировок с календарем | `life_os_ux_screens.md` (4.x), `life_os_design_system.md`, `life_os_api_specification.md` (`/api/workouts/calendar`) | описано | В репо реализовано: week/month day-surface, remote `api-workouts-calendar` client call и local fallback; planned + logged агрегируются в одном дне |
| БАДы | Стек, расписание, быстрый лог приема | `life_os_health_ecosystem_spec.md`, `life_os_api_specification.md`, `life_os_design_system.md` | описано | One-tap Taken в дневнике + напоминания |
| Лабораторные анализы | Импорт фото/PDF + OCR + Review | `life_os_ux_screens.md` (6), `life_os_api_specification.md`, `life_os_design_system.md`, `life_os_copy_catalog.md` | описано | Low-confidence OCR нельзя сохранить без review |
| Сон | Анализ сна (метрики, стадии, рекомендации) | `life_os_healthkit_spec.md`, `life_os_recovery_algorithms.md`, `life_os_ux_screens.md` (Sleep Detail), `life_os_design_system.md`, `life_os_copy_catalog.md` | описано | В репо реализовано: sleep detail экран со стадиями, 7-day trends, factors, recommendations, diary link и month calendar; timeline стадий остаётся on-device из HealthKit |
| Стресс / ментальное здоровье | Утренний чек‑ин + бережные рекомендации | `life_os_api_specification.md` (`wellness_checks`), `life_os_recovery_algorithms.md`, `life_os_health_ecosystem_spec.md` | описано | PSS‑4 + стресс‑шкала; ресурсы показываются при устойчиво высоком стрессе |
| Менструальный цикл | Цикл‑aware корректировки (opt‑in) | `life_os_healthkit_spec.md`, `life_os_privacy_architecture.md`, `life_os_recovery_algorithms.md` | описано | Данные чувствительные, on‑device по умолчанию; облачная синхронизация отключена |
| AI‑инсайты | Кросс‑доменный анализ + объяснимость | `life_os_health_ecosystem_spec.md`, `life_os_gpt_prompts.md`, `life_os_ux_screens.md` | описано | UX шаблон “Почему так?” закреплён |
| AI‑инсайты | Лента инсайтов + карточки детализации | `life_os_ux_screens.md`, `life_os_copy_catalog.md` | описано | Включить фильтры по доменам |
| Эксперименты | Список и детальная карточка эксперимента | `life_os_ux_screens.md`, `life_os_api_specification.md` | описано | В репо реализовано: отдельная библиотека с All/Active/Finished, remote refresh через sync и переходом в детальную карточку; лог ежедневных измерений < 20 секунд |
| Данные | Privacy, retention, delete/export, офлайн очередь | `life_os_privacy_architecture.md`, `life_os_error_handling.md`, `life_os_api_specification.md` | описано | Зафиксировано: local-first; облако — только при opt-in (user_health_flags, scans, vectors) |
| Offline/Sync | Логирование без сети + детерминированная синхронизация | `life_os_sync_engine_spec.md`, `life_os_api_specification.md` | описано | Outbox + cursor pull + last-write-wins; dead-letter обработка описана в QA |
| Дизайн | Теплая минималистичная тема + Okabe‑Ito для статусов | `life_os_design_system.md`, `life_os_accessibility_guidelines.md` | описано | Контраст WCAG 2.2 AA закреплён; проверки в a11y чеклистах |
| Уведомления | Настройки и лимиты уведомлений | `life_os_prd_v7_ultimate.md`, `life_os_api_specification.md`, `life_os_ux_screens.md` | описано | Макс 6 в день, приоритетная очередь |
| Контроль | Уровень контроля (Advisory/Protective/Guardian) | `life_os_prd_v7_ultimate.md`, `life_os_api_specification.md`, `life_os_ux_screens.md` | описано | Guardian требует Focus Control |
| Уведомления | Планировщик уведомлений + дедупликация | `life_os_api_specification.md`, `life_os_prd_v7_ultimate.md` | описано | Дедуп: не чаще 1 раз в 2 часа |
| watchOS | Glance, complications, one‑tap actions | `life_os_watchos_spec.md`, `life_os_ux_screens.md` | описано | Host‑only networking; офлайн‑кеш; unsafe actions → iPhone |

---

## Сверка с кодом (аудит на May 28, 2026)

Уже реализовано в репозитории и больше **не должно** висеть в открытом backlog этого документа:

1. HealthKit import: authorization, anchors, background delivery, 14-day backfill, source precedence, confidence-aware sync.
2. Nutrition logging: method picker, photo, barcode, OCR label fallback, voice, search, portion editing, templates, batch recipes, nutrition calendar.
3. `foods` API и client integration: search, barcode lookup, custom food create, barcode create-from-review.
4. Meal Templates / Quick Add: storage, remote list/detail, apply flow.
5. Batch recipes / meal prep: library, create, review, duplicate, archive, portion logging.
6. Workout session logging: sets/reps/weight, rest timer, HealthKit import, conflict resolution, undo.
7. Sleep detail: stages, trends, recommendations, diary link, sleep calendar.
8. Training calendar/range surface: week/month UI, `api-workouts-calendar` client call, local fallback.

## Audited Snapshot (May 28, 2026)

Проверено по коду и локальным gate-прогонам:

1. `deno fmt --check`, `deno lint`, `deno check` и `deno test -A supabase/functions/tests` проходят.
2. `LifeOS` и `LifeOSWatch` собираются локально через `xcodebuild` с `-skipMacroValidation`.
3. Travel-correct persistence для manual nutrition, batch/template nutrition, workouts, hydration и supplements закрыт через client timezone history и normalized local day context.
4. Account upgrade/link flows для anonymous профиля доведены до release-ready поведения: cloud bootstrap перед Apple/email linking и корректное разделение local-only vs reconnect/bootstrap states.
5. Локальные Supabase edge scripts теперь fail-fast проверяют Docker вместо зависания на мёртвой среде.

## Открытые P1 блокеры после сверки

На **May 28, 2026** открытых P1-блокеров в audited snapshot этого документа не осталось.

## Оставшееся non-blocking сопровождение

1. Поддерживать этот документ как audited snapshot: после крупных feature landings обновлять матрицу и удалять закрытые пункты из backlog сразу, а не перед релизом.

---

## Решения (зафиксированы)

1. Теплая визуальная тема: warm surfaces зафиксированы в дизайн‑системе, Okabe‑Ito остается для семантики и статусов.
2. Онбординг: опциональные шаги “БАДы” и “Импорт анализов” открываются из шага профиля (не увеличивают обязательные шаги).
3. Дневники: поддерживаются месяц + неделя + день.
4. Тренировки: план и факт отображаются вместе, переключаются фильтром.
5. Auth: silent anonymous auth по умолчанию; апгрейд/линковка Apple/email доступны из Settings без потери локальных данных.
6. Time zones: `*_date` авторитетен для группировки; дополнительно сохраняем `*_timezone` + `*_utc_offset_minutes` для корректного отображения при путешествиях.
7. Voice logging: максимум 2 уточняющих вопроса; дальше — best-effort + Review Meal.
8. Food DB: провайдер и fallback зафиксированы в `life_os_food_data_strategy.md` (Open Food Facts + label OCR + user overrides).
