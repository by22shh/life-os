---
phase: system-audit-2026-09-12-backend
reviewed: 2026-09-12T14:33:02Z
depth: deep
files_reviewed: 57
files_reviewed_list:
  - supabase/config.toml
  - supabase/functions/_shared/supabase.ts
  - supabase/functions/_shared/user_context.ts
  - supabase/functions/_shared/rate_limit.ts
  - supabase/functions/_shared/ai_consent.ts
  - supabase/functions/_shared/account_deletion.ts
  - supabase/functions/_shared/medical_scan_privacy.ts
  - supabase/functions/_shared/vector_memory.ts
  - supabase/functions/_shared/export_builder.ts
  - supabase/functions/_shared/date_range.ts
  - supabase/functions/_shared/supplements.ts
  - supabase/functions/api/account/delete/index.ts
  - supabase/functions/api/account/delete_cancel/index.ts
  - supabase/functions/api/account/delete_worker/index.ts
  - supabase/functions/api/settings/privacy/index.ts
  - supabase/functions/api/training/plan/index.ts
  - supabase/functions/api/nutrition/batches/index.ts
  - supabase/functions/api/nutrition/templates/index.ts
  - supabase/functions/api/food/log/index.ts
  - supabase/functions/api/labs/index.ts
  - supabase/functions/api/experiments/index.ts
  - supabase/functions/api/experiments/analysis.ts
  - supabase/functions/api/workouts/index.ts
  - supabase/functions/api/sleep/log/index.ts
  - supabase/functions/api/vector_memory/worker/index.ts
  - supabase/functions/api/supplements/daily/index.ts
  - supabase/functions/api/analytics/batch/index.ts
  - supabase/functions/api/recommendations/index.ts
  - supabase/functions/api/notifications/register_device/index.ts
  - supabase/functions/api/notifications/unregister_device/index.ts
  - supabase/functions/send-notification/index.ts
  - supabase/functions/ai/openrouter-gateway/index.ts
  - supabase/migrations/20260216000001_api_schema.sql
  - supabase/migrations/20260315000001_medical_scans_storage.sql
  - supabase/migrations/20260316000001_account_deletion_storage_cleanup.sql
  - supabase/migrations/20260316000002_onboarding_step_flow.sql
  - supabase/migrations/20260317000001_medical_scan_retention_worker.sql
  - supabase/migrations/20260318000001_physiological_states_local_timezone.sql
  - supabase/migrations/20260318000002_seed_exercise_catalog.sql
  - supabase/migrations/20260318000003_wellness_body_comp_local_days.sql
  - supabase/migrations/20260319000001_medical_scans_api_parity.sql
  - supabase/migrations/20260320000001_db_rls_policy_hardening.sql
  - supabase/migrations/20260730000001_public_table_grants.sql
  - supabase/migrations/20260824000001_catalog_rls_ops_hardening.sql
  - supabase/migrations/20260825000001_security_hardening.sql
  - supabase/migrations/20260826000001_export_artifact_hygiene.sql
  - supabase/migrations/20260826000002_users_deletion_column_guard.sql
  - supabase/migrations/20260826000003_ai_processing_consent.sql
  - supabase/migrations/20260909000001_integrity_transactions.sql
  - supabase/migrations/20260909000002_vector_memory_lifecycle.sql
  - supabase/migrations/20260909000003_deletion_receipts.sql
  - supabase/migrations/20260909000004_sleep_canonical.sql
  - supabase/migrations/20260911000001_audit_hardening.sql
  - supabase/migrations/20260911000002_atomic_mutations_and_guards.sql
  - supabase/migrations/20260911000003_batch_atomic_upsert.sql
  - supabase/functions/tests/_edge_runtime_harness.ts
  - supabase/functions/tests/_mock_supabase_service.ts
findings:
  critical: 8
  warning: 0
  info: 0
  total: 8
status: issues_found
---

# Life OS: серверная часть, миграции и целостность данных

## Narrative Findings (AI reviewer)

Проверено текущее рабочее дерево, включая незакоммиченные изменения и новую миграцию `20260911000003_batch_atomic_upsert.sql`. Старые сообщения аудита 8 сентября использованы только как контекст; перечисленные ниже дефекты подтверждены заново. Исходники не изменялись, коммиты не создавались.

**Вывод:** выпуск с реальными пользовательскими данными блокируется. Наиболее серьёзная находка позволяет аутентифицированному клиенту направить внутреннее задание удаления на чужую Auth-учётную запись. Также подтверждены невозможность удалить собственный аккаунт с каталогом, ложное подтверждение отмены и потеря задания удаления при временном сбое.

`BLOCKER` означает обязательное исправление до выпуска соответствующей функции. Приоритет P0/P1/P2 отдельно показывает очередность. Подтверждённая уязвимость в исходниках не является утверждением о том, что кто-то уже воспользовался ею в production.

## Critical Issues

### CR-01: BLOCKER / P0 — клиент может направить удаление на чужой Auth ID

**Файлы:** `supabase/migrations/20260216000001_api_schema.sql:3223`, `:3992`, `:4002`, `:4092`; `supabase/migrations/20260730000001_public_table_grants.sql:53`; `supabase/functions/api/account/delete_worker/index.ts:374`, `:275`.

**Сценарий:** пользователь A вставляет в свою строку `account_deletion_jobs` чужой `auth_user_id=B`, `mode=scheduled`, `state=scheduled` и наступившую дату. RLS проверяет принадлежность только `user_id`. Worker получает реального владельца A, но выбирает `job.auth_user_id ?? userRow.auth_id`, затем вызывает Admin Auth deletion для B.

**Причина:** старую разрешающую политику `account_deletion_jobs_user_isolation FOR ALL` миграция пытается заменить, удаляя другое имя — `account_deletion_jobs_user_access`. Кроме неё общий цикл создаёт разрешающие `user_insert_own/user_update_own`. Запреты `adj_no_update/adj_no_delete` также permissive и не отменяют разрешающие политики. Поправить только опечатку недостаточно: клиентский INSERT с произвольными служебными полями тоже должен исчезнуть.

**Влияние:** удаление Auth и каскадно данных B при известном UUID его Auth-учётной записи; возможность подделывать состояние задания и `storage_cleanup_completed`. Это нарушение границы между пользователями. Знание UUID не должно давать такое полномочие.

**Подтверждение:** основной агент выполнил `evidence/probes/deletion-job-authorization.sql` на чистой локальной БД с миграциями: INSERT чужого Auth ID и UPDATE worker state прошли под `SET LOCAL ROLE authenticated`; `worker_identity_mismatch=true`. Лог: `evidence/deletion-job-authorization.log`. Worker/Auth deletion не вызывался; транзакция откатилась. Маршрутизация до Admin API подтверждена чтением точного обработчика.

**Исправление:** forward-only миграцией отозвать клиентские INSERT/UPDATE/DELETE на operational queue; удалить все разрешающие write policies, оставить только ограниченный SELECT при необходимости. Создавать задания только через аутентифицированный Edge/RPC, связывающий public ID и Auth ID. На worker требовать совпадение сохранённой и фактической идентичности до любых действий. Добавить негативные SQL/RLS проверки под реальной ролью authenticated, включая произвольные state/auth ID/cleanup flags.

**Уверенность:** высокая, реальная PostgreSQL-проба + полная цепочка вызовов.

### CR-02: BLOCKER / P1 — собственный продукт или упражнение блокирует удаление аккаунта

**Файлы:** `supabase/migrations/20260911000001_audit_hardening.sql:15`; `supabase/migrations/20260911000003_batch_atomic_upsert.sql:295`; `supabase/migrations/20260216000001_api_schema.sql:463`, `:1241`, `:2519`.

**Сценарий:** пользователь создал OCR/manual продукт в `food_catalog_items` либо собственное упражнение с `created_by`, затем удаляет аккаунт. `delete_user_account` удаляет строку users; FK пытается выполнить `ON DELETE SET NULL` для автора каталога. Новая защита неизменности владельца запрещает именно это изменение и выдаёт `catalog_owner_immutable`.

**Влияние:** SQL-удаление откатывается. При обычном полном workflow к этому моменту Storage и внешние векторы уже могли быть удалены: пользователь остаётся с частично разрушенным аккаунтом и неисполнимым запросом удаления. Это новая регрессия сентябрьских hardening migrations.

**Подтверждение:** `evidence/probes/catalog-account-deletion.sql` воспроизвёл оба случая на реальной локальной БД, с отдельными временными пользователями. Лог: `evidence/catalog-account-deletion.log`; оба `catalog_owner_immutable`, внешний ROLLBACK.

**Исправление:** согласовать модель удаления и неизменность владельца. Например, удалить приватные catalog rows в той же транзакции до удаления users и корректно обработать ссылки на них; не превращать приватный продукт в общедоступный NULL-owner элемент. Сохранить запрет обычной смены владельца. Добавить сценарии erasure после создания еды и упражнений в настоящий DB gate.

**Уверенность:** высокая, реальная SQL-проба.

### CR-03: BLOCKER / P1 — отмена удаления возвращает успех, хотя worker продолжает удалять

**Файлы:** `supabase/functions/api/account/delete_cancel/index.ts:73`, `:94`, `:120`, `:131`; `supabase/functions/_shared/account_deletion.ts:302`.

**Сценарий:** cancel читает `deletion_in_progress=false`; worker начинает удаление между этим чтением и отменой задания. Cancel отдельно очищает users flags, проигрывает state compare-and-swap и подавляет конфликт через `continue`. Возвращается HTTP 200 `{cancelled:true,deletion_state:"cancelled"}`, хотя реальное состояние уже `data_deleting`. Возможен и пустой результат job lookup после перехода worker.

**Влияние:** необратимое удаление после явного подтверждения пользователю, что оно отменено. Если job lookup/update просто упал после очистки users flags, повтор отмены отклоняется `deletion_not_scheduled`, хотя задание осталось активным.

**Подтверждение:** точный handler запущен с перехваченным transport в `evidence/probes/deletion-handler-behavior.test.ts`, тест `cancellation reports success after losing worker state race`. Наблюдение: 200/cancelled=true при сохранённом `data_deleting`. Никакие реальные пользователи не затрагивались.

**Исправление:** одна SQL-транзакция отмены, блокирующая пользователя и активные задания в том же порядке, что claim worker. Очищать users flags только после успешной отмены. При уже начатой обработке возвращать конфликт и фактическое состояние. Проверять interleaving и отказ каждого write step.

**Уверенность:** высокая, воспроизведение реальным обработчиком.

### CR-04: BLOCKER / P1 — временный сбой навсегда исключает удаление из очереди

**Файлы:** `supabase/functions/api/account/delete_worker/index.ts:109`, `:129`, `:168`, `:205`; `supabase/functions/_shared/account_deletion.ts:428`, `:470`.

**Сценарий:** worker успешно переводит задание в `data_deleting`, затем запрос манифеста medical_scans/Storage выбрасывает исключение. Исключение доходит до общего catch и даёт HTTP 500. Следующие worker-запуски выбирают только `scheduled` и `retry_scheduled`, поэтому потерянное задание никогда не возобновляется. Аналогична остановка процесса после claim.

**Влияние:** удаление зависает навсегда даже после восстановления БД/Storage. Ретрай cron сам по себе ничего не исправляет. Статус пользователя может оставаться «удаляется».

**Подтверждение:** второй тест `evidence/probes/deletion-handler-behavior.test.ts` выполняет handler дважды: первый ответ 500 после зафиксированного `data_deleting`; второй ответ 200 `{processed:0,results:[]}`; state остаётся прежним. Пробы проходят как characterization tests, то есть подтверждают дефект, а не желаемое поведение.

**Исправление:** lease/claim timestamp и возобновляемые стадии, подбор просроченных in-progress jobs. Локальные исключения оформлять как retry state; обеспечить восстановление и после process termination, когда catch не выполняется. После удаления public.users хранить operational job так, чтобы Auth/storage cleanup можно было продолжить независимо от user cascade.

**Уверенность:** высокая, точный handler и повторный worker-запуск.

### CR-05: BLOCKER / P1 — чужой план тренировок принимает подставные дочерние сессии

**Файлы:** `supabase/migrations/20260216000001_api_schema.sql:1430`, `:3992`; `supabase/functions/api/training/plan/index.ts:235`, `:354`.

**Сценарий:** A создаёт `training_plan_sessions` с собственным `user_id=A`, но `training_plan_id` плана B. FK проверяет существование плана; user-scoped RLS — принадлежность дочерней строки. Совпадение владельцев не проверяется. Edge GET active/sessions сначала находит план B, затем читает детей service_role только по plan ID, без `user_id`.

**Влияние:** внедрение сессий/названий в чужой план, искажение расписания и возможное блокирование настоящей вставки через UNIQUE(plan,date,type). Требуется знание plan UUID; это всё равно нарушение tenant isolation.

**Подтверждение:** исправленный fixture `evidence/probes/training-plan-child-ownership.sql` выполнен основным агентом на реальной БД. `foreign_user_row_returned=true`; лог `evidence/training-plan-child-ownership.log`, ROLLBACK. Первый запуск упал на отсутствующем обязательном `plan_json` до проверяемого действия; он не считался подтверждением.

**Исправление:** составной FK (training_plan_id,user_id) на UNIQUE(id,user_id), либо эквивалентный trigger/policy, сохраняющий принадлежность на всех прямых PostgREST write путях. Дополнительно фильтровать service-role чтения по user_id. Проверить аналогичные parent/child таблицы с отдельным user_id.

**Уверенность:** высокая, реальная RLS-проба и чтение consumer.

### CR-06: BLOCKER / P1 — «AI-план» и адаптация не дают заявленного содержания тренировки

**Файлы:** `supabase/functions/api/training/plan/index.ts:117`, `:143`, `:157`, `:180`, `:509`, `:522`; `ios/LifeOS/Modules/Training/TrainingPlanService.swift:226`; `ios/LifeOS/Modules/Training/TrainingDayView.swift:343`, `:1279`, `:2686`.

**Сценарий:** пользователь указывает цель, опыт, оборудование, травмы и создаёт план; затем выбирает «снизить объём на 30%» или пропустить занятие. Backend циклически выдаёт типы strength/cardio/mobility/recovery по индексу дня. `planned_exercises` — только title/week; ограничений, упражнений, sets/reps/weights нет. При этом `ai_generated=true`. Adjust только записывает словарь `adaptive_rules` и timestamp, затем возвращает `adjusted:true`; сами сессии остаются прежними.

**Влияние:** функция создания персонализированной тренировки и её адаптации реализована лишь частично, несмотря на подтверждение успеха. У пользователя нет подготовленной тренировки, а изменение объёма фактически не происходит.

**Проверка клиента:** feature reviewer подтвердил, что plannedSessionCard передаёт в WorkoutLogView только дату, тип и plan ID; exercises начинается пустым; локального применения adaptive_rules нет. Клиент лишь вызывает backend и делает sync. Следовательно, отсутствующее поведение не реализовано на другом слое.

**Исправление:** реализовать содержательный генератор с валидируемыми ограничениями, наполнением упражнений и фактическим применением коррекции к будущим сессиям; передавать этот план в workout editor. До этого показывать честную функцию создания календаря и отключить обещание применённой адаптации. Тест должен проверять итоговый граф сессий/упражнений и изменение нагрузки, а не только HTTP 200/plan ID.

**Уверенность:** высокая, cross-file/cross-layer tracing.

### CR-07: BLOCKER / P1 — отключение облачного хранения оставляет uploads без строки medical_scans

**Файлы:** `supabase/functions/_shared/medical_scan_privacy.ts:128`, `:145`, `:180`; `supabase/functions/api/settings/privacy/index.ts:277`; для сравнения полный erasure manifest — `supabase/functions/_shared/account_deletion.ts:440`.

**Сценарий:** файл уже загрузился в owned Storage prefix, но приложение/сеть упало до сохранения ссылки в medical_scans. Пользователь отключает cloud backup или включает local-only. Privacy cleanup собирает manifest исключительно из image_url/original_image_url в SQL. При отсутствии ссылок функция сразу успешно заканчивает удаление; объект без SQL-строки остаётся в Storage. Создание нового объекта после отзыва согласия ограничено RLS, но существующий orphan этим не удаляется.

**Влияние:** приватный исходный документ остаётся в облаке после успешного переключения настройки. Retention worker также опирается на строки scans; orphan не получает обычный scheduled deletion timestamp.

**Подтверждение:** статическая цепочка вызовов; отдельный Storage integration probe не выполнялся. Полное удаление аккаунта уже использует enumeration и исправлено в этом отношении; здесь речь о другой цепочке — отзыве backup/local-only, а не повторении старой исправленной находки.

**Исправление:** использовать полное перечисление owned prefix при принудительной очистке облачных originals, включая вложенные каталоги и orphan uploads. Сначала зафиксировать запрет новых записей, затем удалить и проверить пустой prefix; cleanup obligation сохранять для повторов. Добавить тест «успешный upload → ошибка записи scan → privacy revoke».

**Уверенность:** высокая по исходникам; внешняя Storage-проверка остаётся отдельным пробелом.

### CR-08: BLOCKER / P2 — атомарность сохранения анализа не включает сам документ

**Файлы:** `supabase/functions/api/labs/index.ts:310`, `:351`, `:364`, `:425`, `:433`; `supabase/migrations/20260911000002_atomic_mutations_and_guards.sql:311`.

**Сценарий:** metadata/processed_data/markers_extracted уже upsert-нуты, после чего lookup существующих измерений или `save_scan_measurements_atomic` падает. RPC откатывает только health_measurements; новая версия medical_scans остаётся. Вариант API: отправить `processed_data:{markers:[]}`; существующие измерения вообще не запрашиваются, p_delete_ids=[], и старые маркеры сохраняются при markers_extracted=0.

**Влияние:** карточка документа и история маркеров расходятся после неуспешного сохранения; API может вернуть успех для пустой замены, которая не удалила предыдущие показатели. iOS сейчас не разрешает сохранить пустой список, поэтому этот частный вариант относится к API, а не заявляется как воспроизведённый UI дефект.

**Подтверждение:** транзакционные границы и payload прослежены в исходниках; отдельный runtime probe этого сценария не выполнялся. Это оставшийся gap после миграции atomic measurements, которая действительно обеспечивает атомарность внутри списка маркеров.

**Исправление:** один SQL RPC должен сохранить parent и полностью заменить markers в общей транзакции. При явной замене обработать ноль элементов как очистку; при отсутствии поля — сохранить прежние маркеры. Проверить failures после parent write, unique collision и замену последнего маркера.

**Уверенность:** высокая по исходникам; current UI trigger для пустого списка исключён.

## Проверка и ограничения

Основной агент централизованно запускал DB, Edge E2E, security gate и общие Deno-тесты. Этот reviewer не запускал/останавливал Docker и не менял БД самостоятельно. Три SQL-пробы выполнены основным агентом на свежем локальном Supabase, результаты приведены выше. Самостоятельно выполнены два полностью изолированных Deno handler characterization tests: **2 passed, 0 failed**. Их успех означает воспроизведение неправильного поведения. Production-провайдеры и реальное удаление чужой учётной записи не вызывались.

Общий security gate при этом также проходит (основной агент сообщил 42 успешных теста). Следовательно, он не покрывает найденные права PostgREST, каскадные FK side effects и interleaving deletion worker/cancel. Успешные существующие gates нельзя считать доказательством отсутствия этих дефектов.

В списке files_reviewed сохранены файлы, непосредственно прочитанные при проверке цепочек; у крупных baseline/CRUD-файлов анализировались релевантные участки и их связи. Это глубокий аудит перечисленных путей, **не утверждение о построчной проверке каждого backend файла или каждого достижимого состояния**. Код AI-рекомендаций и product/UX-полнота параллельно проверялись основным и feature-агентами; выводы об их качестве входят в общий отчёт. Auth/storage/provider production config, доставка APNs, актуальность моделей OpenRouter, реальный Pinecone lifecycle и результат на физическом устройстве здесь не подтверждались.

Нет локального AGENTS.md, .codex/skills или .agents/skills в репозитории; применены переданные глобальные предпочтения и инструкции deep GSD code review. Отдельные Read/Write tools в текущем наборе отсутствовали: чтение выполнялось через exec, создание только артефактов review/probes — через apply_patch. Исходники приложения не изменены.

_Reviewer: gsd-code-reviewer, backend subsystem. No commit._
