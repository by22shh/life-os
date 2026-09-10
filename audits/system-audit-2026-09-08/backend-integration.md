# Backend integration audit — 2026-09-08

Аудит текущего working tree. Исходники не менялись. Проверены контракты SQL ↔ Edge ↔ iOS для identity, mutations, privacy, export/delete, AI и experiments; сверка с `life_os_master_spec.md`, `life_os_acceptance_checklists.md`, уточнениями API specification. `.planning`, `.codex/skills`, `.agents/skills` отсутствуют, поэтому фазовый граф GSD и формальные REQ-ID недоступны. Ниже используются идентификаторы разделов acceptance checklist, а не вымышленные REQ-ID.

**Вердикт: backend нельзя считать готовым к работе с реальными личными данными.** Есть воспроизведённый stop на миграциях, обход tenant isolation через service-role upsert, потеря состава блюда при неудачном редактировании и два независимых дефекта экспорта. AI-анализ изображений действительно реализован; долговременная AI memory и научная обработка результатов экспериментов не доведены до заявленного контракта.

## Evidence и ограничения

- Основной агент запустил `scripts/run_supabase_edge_e2e.sh`: миграция `20260825000001_security_hardening.sql` упала с `operator does not exist: uuid !~~ unknown`; endpoint E2E проверки до старта не дошли. Лог: `/tmp/lifeos-audit-20260908/edge-e2e.log`. Полный лог не копируется: в dev-логах могут быть ключи.
- В этом аудите исполнены два отдельных stateful handler probes: `deno test --allow-env --allow-read --allow-net audits/system-audit-2026-09-08/backend-regression-probes.test.ts`: **2 passed**. В этих пробах PASS означает воспроизведение дефекта, не исправность системы. Они исполняют реальные Edge handlers и моделируют PostgREST/storage state; это не live PostgreSQL тест.
- Общий Deno suite выполняет основной агент; повторный прогон здесь не выполнялся. Внешние OpenRouter/Pinecone/APNs аккаунты, production secrets, cron/jobs и опубликованное окружение не проверялись.

## Подтверждённые находки

### B-01 — BLOCKER / P1: чистая установка БД ломается; SHA-256 export token несовместим с UUID-колонкой

**Места:** `supabase/migrations/20260216000001_api_schema.sql:3680`; `supabase/migrations/20260825000001_security_hardening.sql:289`; `supabase/functions/_shared/export_builder.ts:125`, `:170`, `:229`.

`export_artifacts.download_token` создаётся как UUID. Следующая миграция применяет `NOT LIKE 'invalidated-legacy-plaintext-%'` и присваивает текстовый префикс, но ни одна миграция не меняет тип на TEXT. Оператор `NOT LIKE` для UUID не определён, что воспроизведено основным агентом на настоящей БД. Простой cast в WHERE не исправляет весь контракт: Edge пишет и ищет 64-символьный hex SHA-256, который также не является UUID.

**Последствие:** стандартная установка/обновление не достигает конечной схемы. Даже после обхода падающего выражения export creation/download остаётся сломанным без исправления типа. **Требования:** Master §4/§9/§10; AC §10.5. **Статус:** BROKEN.

### B-02 — BLOCKER / P1: чужую запись можно присвоить и получить оставшиеся поля через service-role upsert

**Места:** `supabase/functions/api/user-supplements/index.ts:159`; `supabase/functions/api/body-composition/index.ts:123`, `:185`; `supabase/functions/api/labs/index.ts:153`, `:274`, `:362`; общий service role: `supabase/functions/_shared/user_context.ts:62`.

POST supplements берёт пользовательский `payload.id`, затем выполняет `service.upsert({id, user_id: authenticatedUser, ...payload}, {onConflict:'id'})` без проверки владельца существующей записи. RLS не защищает service-role запрос. На конфликте чужой UUID обновляется, owner становится вызывающим, `.select('*')` возвращает также непереданные поля прежнего владельца. Это подтверждено stateful probe реального handler: прежнее `notes: 'B private note'` вернулось пользователю A.

**Минимальный сценарий:** B имеет `user_supplements.id = S` с notes. A, зная S, вызывает `POST /functions/v1/api-user-supplements` с `{"id":"S","custom_name":"Replacement","frequency":"daily"}`. Ожидается 403/409, фактически handler посылает privileged upsert и возвращает 200 с переназначенной записью. UUID не является самостоятельной границей авторизации; угадывание UUID для атаки не утверждается.

Та же ошибка доказуема статически в body-composition: POST с `id=S`, `measured_at`, `weight_kg` обновляет чужую запись, а `.select('*')` может вернуть её непереданные показатели. В labs предварительный lookup включает `user_id=A`, поэтому чужой scan выглядит отсутствующим; последующий upsert по глобальному `scan_id` всё равно перезаписывает его. Переданный `measurement_id` аналогично применяется к health_measurements без owner check.

**Последствие:** нарушение изоляции пользователей, потеря/переназначение медицинских данных; частичное раскрытие оставшихся полей в supplements/body-composition. **Требования:** AC §8/§9/§10; Master §9. **Статус:** BROKEN.

### B-03 — BLOCKER / P1: export перестаёт работать после появления упражнений силовой тренировки

**Места:** `supabase/functions/_shared/export_builder.ts:408`; `supabase/migrations/20260216000001_api_schema.sql:1383`; status consumer: `supabase/functions/api/user/export_status/index.ts:121`.

`buildExportPayload` сначала получает workout_exercises, затем запрашивает workout_sets по колонке **exercise_id**. В SQL единственная связь sets → exercise — **exercise_entry_id**. При пустом списке упражнений helper пропускает запрос; после первого упражнения он выполняется и завершается undefined-column error. Error выбрасывается из `fetchAllPaged`, job становится failed, download не создаётся.

**Сценарий после исправления B-01:** создать strength session с упражнением/подходами → POST export → GET export-status. Ошибка возникает до создания export artifact. Исправление token type не устраняет B-03. **Требования:** AC §6.3/§6.5 → §10.5. **Статус:** BROKEN.

### B-04 — BLOCKER / P1: ошибочный PATCH блюда/тренировки уничтожает старые дочерние данные

**Места:** `supabase/functions/api/food/log/index.ts:474`, `:493`, `:506`; аналогичный путь `supabase/functions/api/workouts/index.ts:629`, `:645`, `:658`, `:684`.

Meal PATCH коммитит новые totals, удаляет все прежние food_items, затем вставляет новые. Это три независимых HTTP/SQL операции без транзакции и восстановления. Проверяется формат user_food_id, но не существование ссылочной записи до удаления. Новая вставка может законно упасть по FK, уникальности, numeric overflow или временной ошибке.

**Исполненный probe:** старый meal=300 kcal с одним item. PATCH содержит новый item 500 kcal, `user_food_id` — валидный UUID отсутствующей записи. Handler доходит до insert, моделируемая БД отвечает FK 23503. Получаем 500 `food_items_insert_failed`, при этом сохранено 500 kcal и **ноль прежних items**. Probe проверяет и порядок запросов, и финальное состояние, а не только status code. Полный payload — в `backend-regression-probes.test.ts`.

Workouts используют такой же destructive replacement: DELETE exercises каскадно удаляет sets, затем новые exercises/sets вставляются по одному. Ошибка на втором элементе оставляет частичную тренировку. Здесь аналог подтверждён статически; отдельный live workout fault-injection не выполнялся.

**Последствие:** ошибка сохранения имеет необратимый side effect; повтор/интерфейс не может восстановить старую версию с сервера. **Требования:** AC §3.8/§6.3/§6.5; Master §5. **Статус:** BROKEN.

### B-05 — BLOCKER / P1: векторная AI memory отсутствует, удаление Pinecone подменено проверкой SQL

**Места:** заявленный worker — комментарий `supabase/migrations/20260216000001_api_schema.sql:344`; opt-in UI `ios/LifeOS/Modules/Settings/SettingsDestinationViews.swift:999`; `supabase/functions/api/account/delete/index.ts:361`, `:374`; `supabase/functions/_shared/account_deletion.ts:137`; `supabase/migrations/20260216000001_api_schema.sql:2505`.

Полный поиск runtime Edge кода на `Pinecone`, `embeddings`, `vector_memory` нашёл только SQL-count в export и deletion. Нет создания embeddings, upsert/query/delete внешних vectors, нет объявленного daily vector sync entrypoint/cron. Переключатель AI memory сохраняет preference, а iOS только условно читает SQL vector_memory.

Account deletion сначала удаляет users (каскад SQL), затем считает оставшиеся SQL vector_memory и маркирует `vectorsDeleted=true`. Это никак не проверяет внешний Pinecone. **Факт:** интеграция памяти и внешнего удаления отсутствует. **Условный impact:** если в Pinecone существуют записи из внешнего/старого процесса, этот код оставит их и всё равно подтвердит очистку; наличие таких production записей не проверялось и не утверждается.

**Требования:** Master §4 и §9, AC §10.6. **Статус:** BROKEN. Рекомендация: реализовать внешний lifecycle либо убрать неработающее обещание AI memory и честно зафиксировать отсутствие внешнего хранилища.

### B-06 — BLOCKER / P2: финал эксперимента не анализирует baseline/intervention; напоминает о фиктивном scheduling

**Места:** `supabase/functions/api/experiments/index.ts:618`, `:657`; SQL result fields `supabase/migrations/20260216000001_api_schema.sql:1498`; UI `ios/LifeOS/Modules/Insights/InsightDetailView.swift:687`, `:724`, `:729`; `supabase/functions/api/experiments/index.ts:322`, `:342`.

Сервер по истечении дат меняет только status на completed. Поля baseline_mean, intervention_mean, effect_size, p_value, confidence interval и ai_interpretation не имеют runtime producer. iOS results берёт самое раннее и самое позднее измерение, не группируя их по measurement_phase или metric_name, и окрашивает любой рост как положительный. Например, baseline [1,100], intervention [100,2] показывает +100% по endpoints, хотя среднее baseline=50.5 и intervention=51. Это не заявленный N-of-1 анализ.

Дополнительно create response возвращает `reminders_scheduled: true`, но обработчик только сохраняет `reminder_time`. Поиск consumers reminder_time/experiment scheduling в runtime Edge и iOS не выявил постановки experiment reminders; присутствуют только notification category definitions. Наличие внешнего неизвестного планировщика не подтверждено.

**Последствие:** дневной журнал измерений полезен, но результаты нельзя считать проверкой гипотезы; обещание reminder не обеспечено. **Требования:** Master §7 «daily log → results», API experiments/result schema. **Статус:** BROKEN для заявленного анализа; create/log/lifecycle wiring существует.

## Дополнительные риски с явно ограниченным evidence

### B-W01 — WARNING / P1 при штатном закрытом storage schema: account deletion не имеет fallback проверки удалённых файлов

`supabase/functions/_shared/account_deletion.ts:491` после Storage API remove вызывает PostgREST `.schema('storage').from('objects')`. Любая ошибка превращается в deletion failure. В `supabase/config.toml` нет декларации exposed storage schema. В соседнем `medical_scan_privacy.ts:198` **уже есть** fallback на Storage API list при unavailable schema, но в account_deletion его нет. Таким образом, на окружении, где storage не открыт через PostgREST, аккаунт с облачными scans застрянет после удаления файлов. В диагностическом локальном Supabase основной агент подтвердил `PGRST_DB_SCHEMAS=public,graphql_public`. Это подтверждённое несоответствие конфигурации; полный runtime delete с cloud scans не запускался. Утверждение о конфигурации неизвестного production не делается.

### B-W02 — WARNING / P2: SECURITY DEFINER RPC проверяет владельца функции вместо вызывающего

`supabase/migrations/20260825000001_security_hardening.sql:48`, `:59`, `:73` — `resolve_feature_flags_for_user` помечен SECURITY DEFINER; доверие вычисляется через `current_user`, что внутри такой функции означает её владельца (обычно postgres). `v_caller_role` объявлена, но не используется. JWT sub берётся из legacy `request.jwt.claim.sub`, без чтения `request.jwt.claims`/auth.uid(). Если доступны только JSON claims, effective user отсутствует и любой authenticated caller получает право передать чужой user_id. Возможное раскрытие flags/AB assignments, не всего health data. Требуется live PostgREST probe; из-за падающей миграции этот вариант функции на штатной чистой базе сейчас не устанавливается.

### B-W03 — WARNING: deletion manifest не перечисляет orphan uploads

`supabase/functions/_shared/account_deletion.ts:438` строит manifest только из medical_scans.image_url/original_image_url; каталог storage по auth-id не перечисляется. Объект, загруженный успешно перед неудачным сохранением scan metadata, в manifest не попадёт. Это подтверждённое ограничение алгоритма; частота таких orphan uploads и результат auth deletion при их наличии требуют отдельного live сценария.

## Что действительно соединено

- **JWT → собственный user context:** `resolveUserContext` проверяет auth.getUser, получает users.id по auth_id; food/workout GET фильтруют и parent, и user-owned child rows. Наличие правильного auth layer не отменяет B-02 в privileged mutations.
- **Privacy → OpenRouter gate:** все шесть AI entrypoints (food image, label, batch image, text parser, predict, generic gateway) вызывают `enforceAIProcessingConsent` до внешнего запроса. Отсутствующее/false consent → 403; lookup failure → 503. Настройка представлена в Swift model, local migration и privacy payload. В текущем clean deployment цепочка ограничена B-01, поэтому это static wiring verdict, не production E2E PASS.
- **Изображение → OpenRouter → проверенный draft:** image/label/batch endpoints содержат реальные OpenRouter fetch, timeout и response parsing. Это не пустые заглушки. Живая точность распознавания/стоимость/доступность модели не измерялись.
- **Daily insights:** Home/Insights используют DailyInsightsService; он вызывает api-insights-daily, backend читает physiological_states, food_logs, workout_sessions, nutrition targets и сохраняет insights/recommendations. Это полезные детерминированные правила, не работающая векторная память. Predict отдельно использует до 56 дней истории и допускает помеченный deterministic fallback.
- **Experiments create → local outbox → Edge → measurements → local display:** основные элементы существуют и вызываются. Нарушение относится к owner isolation в соседних mutations, scientific results и reminders, а не к полному отсутствию журнала экспериментов.
- **Export authentication/token hashing:** download требует auth owner + digest; это правильный дизайн на уровне вызовов, но его DB contract нарушен B-01/B-03.

## Requirements Integration Map

| Requirement | Integration path | Статус | Issue |
|---|---|---|---|
| Master §4/§10 | migrations → конечная схема → Edge runtime | BROKEN | B-01, clean DB не поднимается |
| AC §9 / Master §9 | auth → supplements mutation → DB owner → response | BROKEN | B-02, privileged ID takeover |
| AC §8 / Master §9 | labs review → scan/marker upsert → tenant storage | BROKEN | B-02, чужие scan_id/measurement_id |
| AC §3.8 | meal edit → parent totals → items → reload | BROKEN | B-04, partial commit и потеря items |
| AC §6.3/§6.5 | workout edit → exercises → sets → reload | BROKEN | B-04, destructive replace без transaction |
| AC §10.5 | export request → SQL graph → artifact → download | BROKEN | B-01, B-03 |
| AC §10.6 / Master §9 | delete → external vectors → SQL → auth | BROKEN | B-05; storage дополнительно B-W01/B-W03 |
| Master §4 AI memory | opt-in → embeddings → Pinecone → retrieval | BROKEN | B-05, producer/consumer отсутствуют |
| Master §7 experiments results | baseline/intervention measurements → analysis → results | BROKEN | B-06 |
| AI consent (privacy extension) | Settings → privacy row → consent guard → OpenRouter | WIRED (static) | Runtime verification ограничен B-01 |
| AC §3 photo/label draft | input → OpenRouter → parsed review payload | WIRED (static) | Живой провайдер/точность не проверялись |
| AC §11 list/detail / daily insight producer | state + nutrition + training → insight persistence → Home/Insights | WIRED (static) | Детерминированные правила; не доказательство персональных научных выводов |

Требования без cross-phase wiring: formal phases/REQ-ID отсутствуют; self-contained helpers/локальные UI checklist пункты в этом backend отчёте не объявляются пройденными. Hydration/body composition/weekly strategy/recommendations API помечены master spec как out-of-scope V2 UI: само отсутствие UI для них не считается дефектом.

## Почему существующие тесты пропустили это

`supabase/functions/tests/_mock_supabase_service.ts:43` записывает запросы и возвращает resolver result; mock не знает SQL column types, FK, RLS, ownership и transaction boundaries. `export_builder.test.ts:109` правильно проверяет 64 hex символа, но именно поэтому нужен реальный SQL contract test: рабочая БД ожидает UUID. Проверка покрытия entrypoints (`edge_entrypoint_coverage.test.ts:3`) доказывает только упоминание пути в e2e source, а не успешное выполнение. Большое количество unit/branch coverage нельзя превращать в утверждение «вся система работает».

Минимальные release gates: clean migrations; multi-user ID collision probes на каждой service-role upsert; export с непустыми workouts/sets/labs/experiments; fault injection между parent/child writes; delete с облачными и orphan scans; проверка реальной lifecycle внешних subprocessors; baseline/intervention analysis fixture с известным ожидаемым результатом.
