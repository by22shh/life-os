# Backend исправления — 2026-09-09

## Завершённый блок integrity

- F02/B01: `download_token` переведён UUID → TEXT до invalidation в старой миграции (чистая установка), и повторно в `20260909000001_integrity_transactions.sql` для существующих установок. Валидные SHA-256 digest сохраняются.
- F03/B02: supplements/body-composition/labs отвергают чужие ID до записи; labs проверяет все переданные measurement IDs до изменения scan. SQL trigger запрещает переназначение `user_id` в таблицах с обязательным владельцем, включая service-role upsert и гонки между lookup/upsert. Nullable anonymization columns исключены, чтобы не ломать удаление аккаунта.
- F04/B04: food/workout PATCH вызывают единственный SQL RPC для parent+children. SQL row lock сериализует конкурентные edits; любая FK/constraint ошибка откатывает весь parent+children. RPC доступны только service_role; HTTP authentication/rate limit сохранены. Food references на user_foods/batch_recipes и training_plan проверяются по владельцу.
- F08/B03: экспорт workout_sets выбирает `exercise_entry_id`; регрессионный export fixture теперь содержит реальную цепочку session → exercise → set.
- Menstrual privacy: Edge требует явный `menstrual_local_only=false`; SQL trigger проверяет согласие под блокировкой privacy row; revoke удаляет cloud rows и последующий replay отвергается. Удаление записей разрешено без согласия на загрузку.
- B-W01/03: account deletion объединяет сохранённый manifest, scan URLs и рекурсивный пагинированный Storage listing собственного auth prefix. Это включает orphan uploads. При закрытой storage schema/PGRST106 применяется проверка Storage API; поиск surviving object тоже пагинирован.
- B-W02: feature flags RPC использует `auth.uid()` (включая JSON JWT claims) и реальную session role вместо SECURITY DEFINER `current_user`.
- Grant gate не требует DELETE grant для deny-all DELETE policy. E2E fixtures явно включают AI/cloud consent только в проверяемых сценариях.

## Проверки

- `deno test --allow-env --allow-read --allow-net supabase/functions/tests/`: **244 passed, 46 steps, 0 failed** после основных правок (до добавления одного дополнительного теста storage fallback).
- Новый `backend_integrity.test.ts`: отказ supplements/body/labs чужому owner, единый atomic RPC path/failure для food и workouts, menstrual consent/replay, recursive orphan listing/pagination и проверка surviving object на второй странице.
- `scripts/check_backend_integrity.sql`: реальная SQL проверка service-role owner collision, FK rollback meal, workout rollback при ошибке второго set, отказ wrong-owner RPC, successful replacement, consent revoke/replay, SHA256 token persistence, authenticated JSON-JWT flags isolation и RPC grants. Все fixtures под BEGIN/ROLLBACK. **Передан основному агенту для централизованного запуска; Docker из этого блока не запускался.**

## Ограничения

- Итог миграции на настоящей БД/полного Edge E2E фиксирует основной агент после централизованного gate.
- Производственные credentials, внешние storage и deployed Supabase не проверялись.
- Historical audit probes оставлены неизменными; PASS в них по-прежнему означает воспроизведение старой уязвимости, новые регрессии находятся в `supabase/functions/tests`.
- B05 vector-memory lifecycle завершён; описание находится ниже.

## Дополнительные завершённые изменения

- B05: server-side OpenRouter embeddings / Pinecone upsert/query/delete + derived-only allowlist, user namespaces, privacy consent, operation leases, resumable cleanup and internal worker. Predictive context consumes retrieved memory. Missing configuration is an explicit error.
- Account erasure: scoped expiring receipt permits confirmation after auth deletion, hashes only server-side, issued/reused before destructive work. Status endpoint supports receipt-only access without treating unauthorized responses as completion.
- Fresh Deno suite after vector/receipt changes: **267 passed, 46 steps, 0 failed** (worker run). Central clean Supabase migrations and Edge E2E with vector/receipt schema passed (`backend-e2e-final.log`). **Correction:** the SQL integrity script was silently skipped by the runner because the background process lost redirected stdin; its earlier PASS attribution was invalid. The parent fixed stdin forwarding; actual SQL assertions subsequently passed, as recorded below. Sleep-schema integration is tracked separately.
- Provider network calls remain mocked; no production account/data was sent to external AI/Pinecone.

## Нагрузка и дополнительные регрессии

- Первый централизованный default load (120 food requests, concurrency 16) обнаружил 90 ответов HTTP 202 и 30 HTTP 401, p95 3309 ms. Исходный resolver ошибочно преобразовывал **все** Auth errors в 401 и не сохранял причину; конкретный upstream bottleneck по этому логу не доказан.
- `resolveUserContext` теперь различает недействительный/отозванный токен (401) и Auth overload/transport/5xx (503 + Retry-After). Structured logs содержат только status/code/name, без JWT и upstream payload.
- `verifyBearerUser` использует явный `getUser(jwt)` и объединяет исключительно одновременно выполняющиеся проверки идентичного bearer. Завершённые результаты не кешируются; следующий запрос повторно проверяет Auth, включая отзыв сессии. Карта ограничена 256 in-flight записями; разные bearer не разделяют результат. Каждый авторизованный HTTP запрос отдельно проходит прежние database lookup и rate limit.
- Load harness сохраняет JSON report до проверки threshold и включает безопасные machine-readable error counts. Concurrency, лимиты latency, error budget и expected statuses не ослаблены. Повторный централизованный load нужен для подтверждения эффекта на latency.
- Полный Deno suite после auth changes: **273 passed, 46 steps, 0 failed** (`/tmp/lifeos-auth-regression.log`). Новые auth tests проверяют concurrency, следующий revoked request, отдельные бюджеты, изоляцию токенов и upstream 429/500/502/503.
- Дополнительный targeted запуск vector/receipt: **15 passed**. Проверены удаление hard-deleted sources, разбиение upsert с 4096-dimensional embeddings ниже Pinecone 2 MB, клиентский prepared receipt replay и запрет rebinding к другому deletion job.
- Второй централизованный default load подтвердил улучшение food endpoint: **120/120 HTTP 202, 0% errors, p95 123.8 ms** (исходно 3309.1 ms и 25% ошибок). Notifications дал 90/90 HTTP 200, но p95 3477.5 ms превышал 800 ms. Проверка handler обнаружила отдельный старый Auth flow, который не использовал исправленный resolver. Notifications переведён на тот же `resolveUserContext`; standard rate-limit и отсутствие outbox exemption сохранены.
- Notification regression: 16 concurrent PATCH делят одну in-flight Auth проверку, выполняют все 16 writes и отдельно расходуют все 16 standard budgets; critical-only всё ещё принудительно отключает guardian/focus. Endpoint suite: **2 passed, 11 steps**, lint/fmt PASS. Для подтверждения notification latency передан третий централизованный load.
- Bounded follow-up audit нашёл ещё 19 `index.ts` Auth duplicates: food-image/food-label/batch-recipe analyzers, send-notification, OpenRouter gateway, analytics, device registration/unregistration, account deletion/cancel/status, watch snapshot, export/create/status/download, insight acknowledge, menstrual sync, privacy и consent. Общий supplement handler имел тот же дефект. Добавлен auth-only `resolveAuthenticatedUser` и заменены только старые Auth blocks на прежнем месте; специфические user lookups, validation order, AI/privacy checks, rate tiers/exemptions и receipt-only status path сохранены.
- Production `auth.getUser` теперь существует только в `verifyBearerUser` и всегда получает явный JWT. Общая классификация исключает превращение Auth overload в logout. Полный suite после миграции: **277 passed, 46 steps, 0 failed** (`/tmp/lifeos-all-auth-regression.log`). Дополнительный route matrix: **1 passed, 19 steps**; каждый маршрут проверен с Auth 401/429/503, без последующих database/provider calls. Full lint и fmt: **131 files PASS**. Готово к финальным централизованным Deno/E2E/load gates.
- Финальный централизованный default load: **food 120/120 HTTP 202, p95 108.3 ms; notifications 90/90 HTTP 200, p95 57.5 ms; оба 0% errors**. Concurrency 16 и исходные thresholds 1200/800 ms сохранены. Последний полный Deno результат основного агента: **280 tests, 65 steps PASS**.
- Первый реальный SQL integrity запуск выявил ошибку теста: mutation RPC и чтение его результата были в разных операндах одного IF/OR expression. PostgreSQL не гарантирует порядок вычисления подвыражений; scalar subquery может читать прежнее состояние. Mutation и assertions разделены на отдельные PL/pgSQL statements; RPC не менялся. Проверка результата усилена на owner/parent/new item values. См. [PostgreSQL expression evaluation rules](https://www.postgresql.org/docs/current/sql-expressions.html#SYNTAX-EXPRESS-EVAL).
- **Фактически выполненные SQL проверки PASS:** `check_backend_integrity.sql` (`/tmp/lifeos-sql-integrity-real.log`), `check_backend_upgrade.sh` (`/tmp/lifeos-sql-upgrade-real.log`), `check_sleep_canonical.sql` (`/tmp/lifeos-sql-sleep-real.log`). Запущены напрямую через `docker exec -i ... psql`/upgrade wrapper на retained локальной БД, созданной основным агентом. Каждый лог содержит выполненные DO blocks, ROLLBACK и success sentinel; upgrade/sleep process exit 0. Во время этих проверок не было start/stop/reset, fixtures и schema replay откатились.
