# Исправление аудита — 9 сентября 2026

Этот документ описывает исправления после аудита от 8 сентября. `REPORT.md` и первоначальные пробы сохранены как исторические свидетельства: их прежний FAIL не относится автоматически к исправленному дереву.

База: `088bdaf` вместе с исходными незакоммиченными изменениями пользователя. Они сохранены; коммиты и публикация не выполнялись.

Все перечисленные в исходном аудите дефекты получили исправления и проверки. Основные сценарии дневника, локального хранения, синхронизации и серверных операций проверены на симуляторах и настоящем локальном Supabase. Это подтверждает работоспособность проверенных сценариев, но не заменяет production-развёртывание, испытания на физических устройствах или оценку пользы рекомендаций в пилоте.

## Матрица исправлений

| Находки | Исправление | Подробности |
|---|---|---|
| F01 | Исправлены Keychain API, Swift 6 closures/Sendable и HealthKit observer completion | Итоговые Xcode проверки ниже |
| F02 / B-01 | UUID export token переводится в TEXT; старые открытые токены инвалидируются, SHA-256 сохраняются; forward migration и повторное применение | `backend-fixes.md`, `check_backend_upgrade.sh` |
| F03 / B-02 | Проверка владельца до privileged upsert плюс запрет смены владельца на уровне БД | `backend-fixes.md` |
| F04 / B-04 | Изменение блюда/тренировки и дочерних записей выполняется одной транзакцией | `backend-fixes.md` |
| F05 / IOS-DATA-02 | Refresh сохраняет pending local edits, проверяет реальные серверные версии внутри транзакции | `ios-data-fixes.md` |
| F06 / IOS-DATA-03 | Logout сохраняет историю и outbox; привязка хранилища не допускает доступ другого аккаунта | `ios-data-fixes.md` |
| F07 / IOS-DATA-04/05/09 | Полное локальное удаление сканов/архивов/копий; блокировка восстановления данных sync; отзыв menstrual consent останавливает очередь и очищает сервер | `ios-data-fixes.md`, `backend-fixes.md` |
| F08 / B-03 / IOS-DATA-07 | Полный граф тренировок и локальные несинхронизированные данные включаются в переносимый экспорт | `ios-data-fixes.md`, `backend-fixes.md` |
| F09 / IOS-DATA-01/08 | Десятичная запятая/кириллица, проверка единиц и референсов без выдуманных норм, явное подтверждение OCR, даты, дубликаты | `labs-fixes.md` |
| F10 | Успех запроса HealthKit не определяется разрешением на запись; корректное состояние запроса чтения | `HealthKitManager.swift`, `SleepDetailSupport.swift` |
| F11 | Build-generated capabilities берутся из тех же entitlements и доступны без embedded provisioning profile | `write_runtime_capabilities.py`, `AppCapabilityAvailability.swift` |
| F12 | Общий recovery/sleep pipeline учитывает flags и отсутствие стадий; hideCalories применяется на iPhone/widgets/Watch | `sleep-canonical-fixes.md`, `ios-data-fixes.md` |
| F13 | Home и Watch показывают только сегодняшние данные восстановления, иначе — отсутствие данных | `HomeViewModel.swift`, `ComplicationEntry.swift` |
| F14 | Watch companion встроен в iOS bundle; extension/watch SKIP_INSTALL настроены | `project.yml` |
| IOS-DATA-06 | Pull выполняется в порядке внешних ключей; sleep UUID и legacy payload согласованы | `ios-data-fixes.md`, `sleep-canonical-fixes.md` |
| IOS-DATA-10 | Общий месячный календарь дневника отмечает дни с записями по всем включённым модулям | `DiaryView.swift`, `DiaryViewModel.swift` |
| IOS-DATA-11 | SQLite online backup, integrity/FK-проверка, восстановление при повреждении с сохранением оригинала и уведомлением пользователя | `ios-data-fixes.md` |
| B-05 | Producer/retrieval/vector deletion lifecycle, consent gating, leases/retry, очистка внешнего namespace до завершения удаления | `backend-fixes.md` |
| B-06 | Baseline/intervention, достаточность и сопоставимость данных, описательный эффект, остановка и реальные local reminders | `experiments-fixes.md` |
| B-W01–03 | Storage API fallback и orphan enumeration; SECURITY DEFINER проверяет вызывающего; удаление имеет независимую проверяемую квитанцию | `backend-fixes.md` |

## Дополнительно найдено при повторной проверке

- Первый запуск требовал анонимный JWT, но Supabase запускался с отключённым anonymous sign-in. Конфигурация приведена к контракту приложения; live smoke теперь явно проверяет настройку и действительно получает свои переменные через XCTest runner.
- `api-sleep-log` был связан с GET-only endpoint. Добавлен настоящий writer, каноническая запись на день, сохранение ручной правки при HealthKit replay, совместимость со старым субъективным дневником и ручной ввод на iPhone.
- Эксперимент, начатый без сети, сохраняет исходную дату baseline при отложенной отправке, в том числе для старой очереди.
- Во время нагрузки Auth SDK порождал лишнюю работу, а временные ошибки маскировались под недействительную сессию. Проверка JWT объединяется только для одновременно выполняющихся запросов; завершённые ответы не кешируются. Каждый запрос сохраняет собственный rate limit. Временный сбой возвращает 503, недействительный токен — 401.
- Insights теперь целиком прокручивается; библиотека экспериментов получила явную accessibility-группировку. Область нажатия стрелок календаря и перехода к шаблонам увеличена до 44 pt. Исправлены контраст, переносы крупного текста и компоновка Nutrition, Training, Insights и Privacy; повторный системный accessibility audit всех четырёх экранов проходит без исключений для обнаруженных проблем.
- Исправлены release fixtures/grant gate и ложное срабатывание secret scan на документационный placeholder.
- Проверки SQL больше не теряют stdin при запуске под timeout в фоне. Их выполнение подтверждается явной отметкой после всех assertions и ROLLBACK. Необязательные Logflare/vector-log контейнеры исключены из API тестового стенда; Postgres/Auth/REST/Storage остаются настоящими.
- Переменные live smoke и performance hard gates передаются через `TEST_RUNNER_`, чтобы XCTest действительно получал режим проверки и абсолютный лимит памяти. Accessibility-тест продолжает обход после первой ошибки, собирая проблемы на всех целевых экранах.

## Проверка

| Проверка | Результат | Доказательство |
|---|---|---|
| iOS build + unit | PASS: 815 тестов, 5 skip, 0 failures | `ios-unit-final.xcresult` |
| Widgets | PASS: 4/4 | тот же Xcode прогон |
| Watch | PASS: 7/7 | `watch-second.xcresult` |
| Deno suite | PASS: 280 тестов, 65 steps, 0 failures | `deno-tests-final.log` |
| Deno fmt/lint/check | PASS, 131 TS-файл | `deno-*-final*.log` |
| Backend default load | PASS: 120 food + 90 notification writes, concurrency 16, 0% errors; p95 108.3/57.5 ms при лимитах 1200/800 ms | `backend-load-fourth.log` |
| Настоящий PostgreSQL | PASS: integrity, legacy UUID upgrade/digest replay, canonical sleep; assertions + ROLLBACK | `lifeos-sql-*-real.log`; повторено в E2E |
| Security source/handler checks | PASS: 42 теста, secret/HTTPS scan | `security-complete.log`; E2E выполнен отдельно |
| Полный Edge E2E после чистых миграций | PASS: clean DB, grants, все три SQL набора, все сценарии handlers | `backend-e2e-final3.log` |
| iPhone UI/accessibility | Основные E2E-сценарии PASS; после исправлений повтор Nutrition/Training/Insights/Privacy и сценария Experiments: 2/2 PASS. Home/Settings accessibility и ручное сохранение сна также PASS | `ios-ui-final.xcresult`, `ios-ui-recheck.xcresult`, `ios-a11y-final.xcresult`, `ios-a11y-recheck2.xcresult` |
| Supabase iOS config | PASS: 8 тестов, включая Debug live backend и HTTPS guard | `ios-a11y-final.xcresult` |
| Реальный iOS → local Supabase bootstrap | PASS: 1 UI тест, облачный Auth ID совпал с anonymous/public user; offline fallback отсутствует | `ios-live-backend.log`, `evidence/fix-live-cloud-proof.txt` |
| Performance hard gates | PASS: 6 unit + 1 startup UI; исходные лимиты startup 4000 ms, sync 2500 ms, resident memory 450 MB, growth 64 MB | `ios-performance-final.log`, `evidence/fix-performance.txt` |
| Xcode static analyze | PASS; два сообщения об отсутствии AppIntents metadata у targets без этой зависимости, без ошибок анализатора | `ios-analyze-final.log` |
| Release source config / privacy manifests | PASS: environment build settings и включение пяти manifests; production archive и реальные deployment credentials здесь не проверялись | `release-config-final.log` |

Полные логи и `.xcresult` находятся в `/tmp/lifeos-fix-20260909/`; вспомогательные SQL-журналы — `/tmp/lifeos-sql-*-real.log`. Секреты локального Supabase из служебного вывода CLI не копируются в репозиторий. Watch проверен на Apple Watch Series 11 (46mm), iOS — iPhone 17 Pro, Xcode 26.6 / iOS Simulator 26.5. Пять unit skip — smoke-набор, требующий физического iPhone; точный список сохранён в журнале.

UI-результат составлен из полного первоначального прогона и адресных повторов после исправлений: исходный accessibility FAIL сохранён в журнале, а окончательное исправление подтверждено `ios-a11y-recheck2`. Live UI, пропущенный в обычном прогоне, выполнен отдельно с поднятым сервером и не был пропущен. Проверка облачной записи дополнительно сопоставила идентификатор из настроек установленного приложения с `auth.users` и `public.users`, подтвердив отсутствие offline fallback.

Проверки скорости и памяти — воспроизводимые simulator gates на тестовых данных; они не характеризуют все объёмы истории и модели iPhone. Приведённые значения — верхние границы assertions, не измеренные значения каждого запуска. Полный серверный E2E, security pass и нагрузка выполнены отдельно, чтобы нагрузка не искажалась одновременными тестами.

После проверки локальный Supabase остановлен, временные стартовые ключи и отдельно созданный cloud-test симулятор удалены. Посторонние контейнеры и существовавшие симуляторы сохранены. `git diff --check` и проверка текстовых артефактов аудита на JWT/provider-key patterns прошли.

## Что требует внешней проверки

Физические HealthKit/WatchConnectivity, APNs, Guardian entitlement и установленная App Store-сборка; реальные AI/Pinecone credentials и production deployment; качество распознавания на пользовательских документах и полезность рекомендаций в пилоте. Эти результаты нельзя получить из unit-тестов или объявить подтверждёнными по наличию кода. Статистические результаты эксперимента являются описательными, без заявления причинности.
