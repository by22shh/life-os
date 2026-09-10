# Финальная ведомость проверок

2026-09-08; рабочее дерево `088bdaf` + имеющиеся изменения. Xcode 26.6 (17F113), iOS/watchOS Simulator 26.5. Supabase CLI 2.115.0. Никаких утверждений о прошедшей проверке production.

## Исходное дерево

| Команда | Итог |
|---|---|
| `deno fmt --check supabase/functions` | exit 0, 120 файлов |
| `deno lint supabase/functions` | exit 0, 120 файлов |
| `find supabase/functions -type f -name '*.ts' -print0 \| xargs -0 deno check` | exit 0 |
| `deno test -A supabase/functions/tests` | exit 0, 236 passed, 46 steps, 0 failed |
| `bash scripts/check_ios_release_config.sh` | exit 0; source-only guard |
| `SECURITY_PASS_SKIP_EDGE_E2E=1 bash scripts/run_preprod_security_pass.sh` | exit 1; пример ключа в DEPLOYMENT.md:63 принят за secret; до abuse tests не дошёл |
| `bash scripts/run_supabase_edge_e2e.sh` | exit 1; migration 20260825000001, UUID NOT LIKE |
| `xcodebuild test ... -scheme LifeOS -only-testing:LifeOSTests -only-testing:LifeOSWidgetsTests` | exit 65; compilation failure; 0 выполненных iOS/widget unit tests |
| `xcodebuild test ... -scheme LifeOSWatch -only-testing:LifeOSWatchTests` | exit 0; 6 tests, 0 failures |

Использованные параметры Xcode: `-skipMacroValidation -skipPackagePluginValidation -project ios/LifeOS.xcodeproj`, destination `platform=iOS Simulator,name=iPhone 17 Pro` либо `platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)`, DerivedData `/tmp/lifeos-audit-20260908/derived`. Результаты исходного дерева: `unit.xcresult`, `watch.xcresult` в `/tmp/lifeos-audit-20260908/`.

## Диагностические копии — НЕ исправленный продукт

Backend: `/tmp/lifeos-audit-20260908/backend-probe`. Скопированы functions/migrations/scripts; отдельный `project_id=lifeos-audit-probe`.

1. Перед падающим UPDATE добавлен **только в копию** `ALTER TABLE public.export_artifacts ALTER COLUMN download_token TYPE TEXT USING download_token::TEXT`. Миграции проходят. Следующая проверка падает: `authenticated lacks DELETE required by policy on public.batch_recipe_ingredients`.
2. В скрипте **копии** отдельно пропущен уже зафиксированный grant gate. 56 последовательных endpoint-сценариев дают `:: OK`; следующий `parse-food-text` останавливает suite: 403 вместо ожидаемого 200 (`edge_local_e2e.ts:2913`). Полного E2E PASS нет. Consent guard нового backend требует согласия, которого сценарий не подготовил.
3. Config inspection в этой локальной среде: `PGRST_DB_SCHEMAS=public,graphql_public`; `resolve_feature_flags_for_user` имеет SECURITY DEFINER, owner postgres. Это read-only наблюдения, не runtime exploit verification.
4. Скрипты выполнили cleanup. Контейнеров `supabase_*_life-os`/`supabase_*_lifeos-audit-probe` в финальном списке нет. Чужие контейнеры не останавливались.

iOS: `/tmp/lifeos-audit-20260908/ios-probe`. Изменения ограничены попытками пройти компиляцию; точный совокупный diff в `diagnostic-compile-only.patch`.

1. Исправление пяти `Self.query/baseQuery` выявило ошибки OS lock import, observer callback signature и Sendable closure.
2. После их минимального устранения выявлены восемь explicit-self ошибок в DiaryViewModel.
3. После explicit-self compiler всё ещё отклоняет передачу completion callback в Task: `sending 'completion' risks causing data races`. Попытка `@preconcurrency import HealthKit` это не устранила.
4. Диагностическая iOS-копия **тоже не дошла до тестов и запуска интерфейса**. Дальнейшие правки не выполнялись: аудит не подменяет отдельную задачу исправления приложения. Протокол не заявляет 776/1000+ пройденных iOS tests на текущей версии.

## Исполняемые воспроизведения

- `deno test --allow-env --allow-read --allow-net audits/system-audit-2026-09-08/backend-regression-probes.test.ts`: 2 passed. Реальные handlers, синтетические пользователи, stateful PostgREST model. **PASS означает, что плохое поведение произошло.** Это не полноценная live DB E2E и не операция над чужими аккаунтами.
- `swift audits/system-audit-2026-09-08/evidence/labs-parser-probe.swift`: выполнен исходный извлечённый parser; decimal comma, Cyrillic и reference-unit дефекты подтверждены. Вывод в `labs-parser.log`.
- `swift audits/system-audit-2026-09-08/evidence/recovery-probe.swift`: извлечённые чистые production function bodies; `RecoveryZone` заменён неиспользуемым carrier stub, zone не тестируется. Score: 56 с HRV, 90 без HRV; unspecified 8h sleep: 40; REM=120/0 при фиксированных остальных условиях: 100/100. Это проверка алгоритма, а не биомедицинская валидация.

## Не выполнено

- UI walkthrough, весь XCTest UI/accessibility suite, iOS performance/analyze: блокированы сборкой исходной версии.
- Полный live edge E2E/load/soak: блокированы миграцией; диагностический запуск тоже неполный.
- Physical iPhone+Watch, production signing/App Store bundle, Apple linking, APNs, Guardian, реальный HealthKit permission flow, реальные AI/nutrition providers и clinical/product outcome studies.
- Дополнительный dynamic privileged-RPC probe не выполнен: отдельный вызов агента отклонён автоматической защитой как possible cybersecurity risk. Статическое замечание B-W02 не выдаётся за проверенный runtime-дефект.

Логи Supabase в этом каталоге отредактированы: локальные JWT, publishable/secret keys и S3 credentials заменены метками. Полные временные логи не публикуются.
