# Life OS: аудит всей системы

Дата: 8 сентября 2026. База: `088bdaf` **плюс текущие незакоммиченные изменения**, включая новый `SupabaseSessionKeychainStorage.swift`. Это аудит фактического рабочего дерева, а не только последнего коммита.

## Вердикт

**Нет, весь заявленный функционал не завершён. Нет, текущую версию нельзя считать полностью рабочей. Для хранения единственного экземпляра личной истории и для доверия рекомендациям она сейчас не готова.**

Это не пустой макет: есть настоящие дневники, локальная база, очередь синхронизации, серверные обработчики, AI-вызовы, распознавание анализов, Watch-приложение и существенная тестовая база. Но границы между этими частями содержат ошибки: текущий iOS-код не компилируется, чистая миграция БД падает, отдельные операции теряют данные, нарушают пользовательские настройки приватности и изоляцию записей.

**Потенциальная практическая польза — в едином журнале питания, тренировок, самочувствия, сна и приёма добавок.** Возможность безопасно получать эту пользу ежедневно не подтверждена. Польза восстановления, прогнозов и экспериментов отдельно требует проверки качества: наличие формул и AI API не доказывает правильность рекомендаций или улучшение самочувствия.

Июньский `LIFE_OS_PRODUCTION_READINESS_REPORT.md` больше не описывает текущую версию. Его утверждение «остались только внешние proof-gaps» опровергнуто свежими локальными проверками.

## Что проверялось и насколько можно доверять выводам

- Сверка с `life_os_master_spec.md`, PRD, функциональной матрицей, acceptance checklists, privacy, recovery и sync спецификациями. GSD `.planning` и формальных фаз в проекте нет: фазы и проценты выполнения не выдумывались.
- Инвентаризация 128 Swift-файлов основного приложения, 120 TypeScript-файлов серверной части, 16 SQL-миграций, тестов и release-скриптов; углублённые трассировки основных путей. Инвентаризация не означает построчную формальную верификацию каждого файла.
- Реальные запуски Deno, Xcode, PostgreSQL/Supabase; независимые проверки межмодульных связей backend и iOS.
- Отдельные воспроизведения дефектов: реальные Edge handlers с моделью PostgREST; извлечённые без изменения алгоритма Swift-парсеры/расчёты.
- Для прохода за первым блокером использованы **временные диагностические копии**. Их результаты не превращают исходное дерево в PASS. Изменения компиляции зафиксированы в `evidence/diagnostic-compile-only.patch`.
- Исходники приложения, существующие правки пользователя, production-инфраструктура и реальные аккаунты не менялись. Добавлены только материалы этого аудита. Случайное изменение версии CLI в `supabase/.temp/cli-latest` восстановлено.

Обозначения: **воспроизведено** — выполнена конкретная проверка; **трассировка кода** — доказан путь по исходникам, но не полный сценарий на устройстве; **не проверено** — нет оснований заявлять PASS или фактический инцидент.

## Свежие проверки

| Проверка | Результат | Что именно доказано |
|---|---|---|
| `deno fmt --check supabase/functions` | PASS, 120 файлов | Форматирование |
| `deno lint supabase/functions` | PASS, 120 файлов | Проверки lint |
| `deno check` всех TS-файлов | PASS | Типизация серверного кода |
| `deno test -A supabase/functions/tests` | PASS, 236 тестов, 46 шагов | Unit/handler suite; не реальная схема БД |
| `check_ios_release_config.sh` | PASS | Статические source config/privacy checks; не App Store artifact |
| iOS `xcodebuild test`, исходное дерево | **FAIL до тестов**, exit 65 | Пять ошибок Keychain; приложение не собрано |
| Изолированная диагностика после Keychain | **FAIL до тестов** | Дополнительные ошибки HealthKit и захватов Swift 6 |
| Watch `xcodebuild test`, исходный Watch-код | PASS, 6 тестов | Watch и complications собираются; тесты проходят |
| `run_supabase_edge_e2e.sh`, исходное дерево | **FAIL на миграции** | Реальная БД не достигает конечной схемы |
| Копия БД с единственной правкой UUID → TEXT | Миграции прошли, **grant gate FAIL** | Следующий блокер: policy/grant для `batch_recipe_ingredients` |
| Та же копия с отдельно пропущенным grant gate | **56 сценариев OK, затем E2E FAIL: 403 вместо 200** | Сценарий `parse-food-text` не учитывает AI consent; полный PASS отсутствует |
| `run_preprod_security_pass.sh` | **FAIL на secret scan** | Ложное срабатывание на пример `OPENROUTER_API_KEY="sk-or-..."` в DEPLOYMENT.md:63; утечка секрета этим не доказана |
| 2 audit handler probes | 2 воспроизведения успешны | Присвоение чужой записи и потеря ингредиентов при ошибке PATCH |
| Swift Labs parser probe | Дефекты воспроизведены | Десятичная запятая, русские названия, единицы/референсы |
| Swift recovery probe | Расхождения воспроизведены | HRV влияет при отсутствии guard; REM не влияет в рабочей ветке; сон без стадий занижается |

Сжатые и очищенные от локальных ключей логи находятся в `evidence/`. Полные Xcode-логи и `.xcresult` — `/tmp/lifeos-audit-20260908/`. Дополнительные итоги диагностического iOS-прогона приведены в `evidence/verification-final.md`.

## Ошибки, которые необходимо устранить до реальных пользовательских данных

### F01. iOS-приложение сейчас не компилируется — P1, воспроизведено

`SupabaseSessionKeychainStorage.swift:28,35,45,64,72` вызывает instance-методы через `Self`. После устранения только этих вызовов в копии компилятор обнаруживает:

- `HealthKitManager.swift:1344`: нет импорта для `OSAllocatedUnfairLock`.
- `HealthKitManager.swift:1381`: обработчик `HKObserverQuery` должен принимать три аргумента, передан один; затем объект query ошибочно вызывается как completion.
- `HealthSyncManager.swift:354`: несоответствующий Sendable-захват `persist`.
- `DiaryViewModel.swift:79–114`: восемь захватов `dbQueue` в closures без явного `self`.

Это несколько проблем в текущих изменениях, а не только недоступные сертификаты или физический iPhone. Результат исходного iOS unit/UI suite — **не выполнен из-за сборки**, а не «тесты прошли».

### F02. Чистая установка/обновление backend останавливается — P1, воспроизведено

`20260216000001_api_schema.sql:3680` создаёт `export_artifacts.download_token UUID`; `20260825000001_security_hardening.sql:289` применяет `NOT LIKE` и записывает текст. PostgreSQL: `operator does not exist: uuid !~~ unknown`. Ни одна миграция не переводит колонку в TEXT, хотя Edge уже пишет 64-символьный SHA-256.

Нужно исправить полный SQL/Edge-контракт, затем выполнить все миграции с нуля и upgrade с прежнего состояния. Простого cast в WHERE недостаточно. Подробности: B-01 в backend-отчёте.

### F03. Присвоение чужих записей через привилегированный upsert — P1, handler reproduction + трассировка

`api/user-supplements/index.ts:159`, `api/body-composition/index.ts:185`, `api/labs/index.ts:274,362` принимают пользовательский ID и выполняют service-role upsert по глобальному ключу. Проверка владельца существующей записи отсутствует либо не защищает последующий upsert. RLS не исправляет привилегированную операцию.

Для supplements реальный handler в stateful probe переназначает запись B пользователю A и возвращает оставшееся приватное `notes`. Предпосылка — знание ID записи; угадываемость UUID и фактическая атака не утверждаются. Все эти endpoints требуют проверки `существует → принадлежит текущему пользователю` и multi-user regression tests. См. B-02 и `backend-regression-probes.test.ts`.

### F04. Неудачное редактирование может уничтожить старое содержимое — P1, handler reproduction

`api/food/log/index.ts:474–506` обновляет totals, удаляет все items и только затем вставляет новые, без общей транзакции. Ошибка FK на последнем шаге возвращает 500, но старых ингредиентов уже нет. Проба: было 300 kcal и один item; после ошибки — 500 kcal и ноль items. Аналогичная последовательность есть у workouts/exercises/sets (`api/workouts/index.ts:629–695`).

Нужна атомарная операция изменения родителя и детей. Не достаточно улучшить текст ошибки или сделать retry. См. B-04.

### F05. Открытие карточки может затереть несинхронизированную локальную правку — P1, трассировка

`NutritionService.swift:896,1664` и `TrainingService.swift:367,628` при облачной сессии получают detail с сервера и сохраняют parent/children без проверки pending outbox. Сценарий: edit offline → reconnect → открыть detail до replay → старый ответ сервера заменяет новую локальную запись. Следующее сохранение с этого экрана может закрепить старые значения. Кроме того, кэш ставит `updatedAt=Date()`, выдавая старое содержимое за новое.

Общий LWW guard в `SyncEngine` не защищает эти отдельные detail-загрузчики. См. IOS-DATA-02.

### F06. Обычный выход из аккаунта стирает local-only историю и outbox — P1, трассировка

`SettingsAccountDestinationViews.swift:516` → `AuthManager.swift:693,798` → local purge удаляет все user-scoped записи и очередь. Для authenticated аккаунта это обычный Sign Out без проверки несинхронизированных изменений и local-only данных. Анализы/цикл, которым пользователь не разрешал облако, невозможно вернуть простым повторным входом.

Нужен явный жизненный цикл локальных данных при смене аккаунта, сохранение по идентичности либо отдельная осознанная операция удаления. См. IOS-DATA-03.

### F07. Удаление и отзыв согласия не соблюдают текущий выбор пользователя — P1, трассировка

- `LocalPrivacyOperations.swift:377–465` сообщает completed / storageDeleted, не удалив `MedicalScans` и SQLite backups. Удаление ключа зашифрованных полей не удаляет оставшиеся незашифрованные данные из полной копии БД. См. IOS-DATA-04.
- Menstrual consent проверяется при enqueue, но не отменяет уже queued upload. После перехода обратно в local-only Settings и push не отсеивают `api-menstrual-sync`; сервер также не проверяет этот consent. См. IOS-DATA-05.
- У primary DB и raw scans не найдена настройка исключения из OS backup; это отдельный неподтверждённый на физическом устройстве канал резервного копирования, а не доказанная утечка. См. IOS-DATA-09.

### F08. Экспорт не восстанавливает полную историю — P1, SQL/code contract

Три независимые проблемы помимо UUID-токена:

1. Backend запрашивает `workout_sets.exercise_id`, хотя схема содержит `exercise_entry_id`. Пользователь с непустой силовой тренировкой получает failed export. `export_builder.ts:408`.
2. Облачный экспорт не добавляет local-only записи из телефона. `PrivacyGateway.swift:42–88,120–151` возвращает серверный архив без merge локальных анализов/цикла.
3. Локальный exporter пропускает `workout_exercises`, потому что таблица не содержит прямой `user_id`; sets экспортируются с висячими ссылками. `LocalPrivacyOperations.swift:225–297`.

Нужен round-trip тест архива с непустыми вложенными сущностями и локальными данными. См. B-03, IOS-DATA-07.

### F09. Распознавание анализов искажает числа, единицы и даты — P1, Swift reproduction

`LabsView.swift:1184–1277` разбивает строку по запятой до разбора числа, использует ASCII-названия и не согласует референс с найденной единицей.

| Вход | Фактический результат парсера |
|---|---|
| `Glucose 5,6 mmol/L` | `5 mg/dL`, reference `70–100` |
| `Glucose 5.6 mmol/L` | `5.6 mmol/L`, но reference всё ещё `70–100` |
| `Глюкоза 5,6 ммоль/л` | Ни одного маркера |
| `Ferritin 85,5 ng/mL` | `85 ng/mL` |

Непустой результат получает фиксированную confidence 0.88/0.84; это не измеренная точность. Экран review есть, но пользователь должен сам заметить и исправить повреждение. Сохранение относит старый документ к сегодняшней дате; локальная проверка повторного импорта/перекрытия маркеров отсутствует. См. IOS-DATA-01/08.

### F10. Read-доступ HealthKit определяется через write-статус — P1, код + контракт Apple

`HealthKitManager.swift:122–124,1100–1112,1135–1146` считает `.sharingAuthorized`, хотя запрос `:1229` использует `toShare: []`. Apple не раскрывает статус разрешения читать HealthKit таким способом: этот статус относится к записи. Следствие при fresh read-only доступе — ложный отказ, пропуск включения background delivery и 14-дневного backfill в `OnboardingFeature.swift:542–556`.

Это следует из кода и [официального контракта HealthKit](https://developer.apple.com/documentation/healthkit/hkauthorizationstatus), а не из успешно пройденного физического onboarding. Потребуются корректная модель состояния разрешений и real-device regression.

### F11. App Store-сборка рискует сама отключить ключевые возможности — P1, код + контракт Apple

`AppCapabilityAvailability.swift:250–259` получает entitlements только из DerivedData либо `embedded.mobileprovision`, иначе возвращает пустой словарь. На физическом устройстве остаётся только второй источник. [Apple TN3125](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles) указывает, что приложения, загруженные из App Store, не содержат embedded provisioning profile.

По этой цепочке приложение сочтёт недоступными Apple Sign In, HealthKit, remote push и Guardian даже при корректно подписанных entitlements. Это детерминированное противоречие формату дистрибуции; фактическая установленная App Store-версия здесь не тестировалась. Source config guard данную проблему не ловит.

### F12. Рабочий расчёт восстановления обходит медицинские ограничения и другой алгоритм сна — P1, трассировка + pure Swift reproduction

`HealthSyncManager.swift:141` вызывает raw overload `RecoveryEngine.computeScore` (`:332`), который не принимает и не читает health flags. Проверка `disableHrv` есть только в DB overload `RecoveryEngine.swift:62–66`, не вызываемом основным импортом.

Извлечённый production raw code при одинаковых остальных данных даёт **56 с HRV против 90 при его исключении**. Значит, отмеченный cardiac/pacemaker flag не обеспечивает обещанный guard на реально используемом пути.

Та же ветка использует `SleepData.qualityScore` вместо `SleepScorer`: веса 40/30/30, без отдельного REM/continuity/возраста/sleep debt. В probe замена 120 минут REM на 0 не меняет 100 баллов; 8 часов сна без стадий и in-bed дают 40. Отсутствие измерения превращается в штраф, вместо согласованной обработки отсутствующих компонент.

Также `hideCalories` сохраняется и показывается в health settings, но не применяется в Nutrition/Home/widgets: численные калории выводятся без этого guard (`NutritionDayView.swift:510,1510`; `UserModels.swift:201`). Это невыполненное обещание настройки, не медицинская рекомендация аудитора.

### F13. Главный экран может показывать старое восстановление как актуальное — P2, трассировка

`HomeViewModel.swift:920–934` выбирает последнюю запись без фильтра текущего дня/возраста. `HomeView.swift:103` показывает score/zone без даты этой записи. После нескольких дней без новых данных пользователь видит прежнее состояние без понятной метки давности. Complication также ставит `date: Date()` поверх cached score (`ComplicationEntry.swift:65–84`) и не декодирует timestamp источника.

Требуются freshness semantics, дата измерения и явное состояние «нет сегодняшних данных» на всех поверхностях.

### F14. Watch собирается отдельно, но не встроен в iOS-продукт — P1 для companion-релиза, build configuration

В `ios/project.yml:59–74` зависимости LifeOS содержат Guardian/Widgets, но не LifeOSWatch. В `project.pbxproj:1389–1401` нет Watch embed/copy phase. Наличие Watch в build-схеме собирает соседний продукт, но не помещает его внутрь iOS bundle. Apple [описывает embedding Watch app как отдельный шаг](https://developer.apple.com/documentation/technotes/tn3157-updating-your-watchos-project-for-swiftui-and-widgetkit).

Шесть прошедших Watch-тестов подтверждают работоспособность компонента, но не установку companion вместе с iPhone-приложением и не задержку реальных WatchConnectivity actions.

## Завершённость функций

«Есть код» ниже не означает «готово к релизу». Общие F01/F02 ограничивают полный end-to-end запуск всех соответствующих областей.

| Область | Что действительно существует | Готовность / конкретный пробел |
|---|---|---|
| Anonymous/local auth, onboarding | Реальные reducers, local profile, bootstrap, 6 шагов | Частично; HealthKit onboarding F10, сборка F01 |
| Apple/email upgrade | Cloud bootstrap/linking и настройки | Код есть; App Store capability F11; live linking не проверен |
| Profile/health flags | CRUD, производные flags, настройки | Частично; guards не доходят до части функций F12 |
| Home/next action | Реальные DB reads, deterministic NBA, quick logs | Частично; stale recovery F13, flags F12 |
| Manual nutrition | Поиск, portion editor, local write/outbox, review | Реализовано с дефектами remote edit/cache F04/F05 |
| Photo/voice/barcode/label | Capture, speech/Vision, реальные Edge/OpenRouter вызовы | Не заглушки; live accuracy/providers и полный flow не подтверждены |
| Foods/favorites/recents | Local cache, custom food, provider routes | Реализовано по коду; полнота базы СНГ и поиск на реальных продуктах не измерены |
| Templates/batch cooking | Create/apply/archive/duplicate/portion flows | Основные пути есть; grant gate и sync ordering требуют исправления |
| Nutrition calendar | День/диапазон/календарь и локальные данные | Реализовано по коду; full UI run исходной версии блокирован |
| Training log | Exercise picker, sets/reps/weight, timer, delete/undo | Реализовано с рисками F04/F05 и неполным export |
| Training import/conflicts | Import IDs, merge/keep/undo и reconciliation | Реальные пути; HealthKit/compile и sync integrity ограничивают готовность |
| Training plan/load | Plans/adjustment и расчёты нагрузки | Есть; точность персональных рекомендаций не валидирована |
| Sleep | HealthKit, summary/stages, detail/trends/calendar | Частично; две формулы сна расходятся, F10/F12; manual-entry promise не подтверждён |
| Supplements | Stack/schedule/taken/adherence/calendar | Есть; tenant ownership F03 |
| Unified diary | Секции дня, date picker, локальные данные | Нет обещанного общего month status grid / единой day-status логики; IOS-DATA-10 |
| Wellness/PSS-4/hydration/body composition | Models, формы/записи, endpoints | Основные записи есть; body composition ownership F03 |
| Menstrual diary | Local storage/encryption, optional sync | Есть; consent revoke F07, signout/export F06/F08 |
| Labs image/PDF | Vision capture, review, local assets, measurements | Ненадёжно: F09, dates/duplicates, privacy/export |
| Insights/recommendations | Реальные rule-based daily producers + local display | Частично; не доказательство работающей долгосрочной AI memory |
| Predictions/simulation | Historical context, OpenRouter, marked fallback | Реализовано технически; accuracy/calibration не проверены |
| Experiments | Create/list/detail/daily log/lifecycle | Результаты — first/last delta; нет полноценного baseline/intervention анализа и подтверждённого reminder scheduler; B-06 |
| Pinecone/vector memory | Схемы, настройки, флаги | Producer/retrieval/external deletion lifecycle отсутствуют; B-05 |
| Notifications | Настройки, cap/dedup/quiet hours, local/APNs paths | Реализация есть; real APNs не проверен, capability F11 |
| Guardian | FamilyControls/ManagedSettings и extension | Реальные механизмы; entitlement/device approval и F11 блокируют уверенный релиз |
| Offline sync | Outbox, retries, LWW, quarantine, replay | Частично; F05/F06/F07; parallel parent-child pull допускает FK failure (IOS-DATA-06) |
| Local backups | Полная SQLite backup, retention, выбор последнего | Нет подключённого production restore; erase не удаляет копии |
| Export/delete | UI, local/server workflows и jobs | Сломано/неполно: F02/F07/F08 |
| Widgets/watch | Реальные extensions, snapshots, safe-action paths | Watch 6 tests PASS; packaging/freshness F13/F14, physical pair не проверена |
| Accessibility/localization | Design tokens, labels, xcstrings, UI audit suite | Наличие механизмов подтверждено; весь интерфейс текущей версии не прошёл runtime audit |
| StoreKit/subscriptions | Реализация не найдена | **Не дефект V2:** PRD явно откладывает monetization до V3+ |

API-only функции, вынесенные master spec за V2 UI, не объявлялись недоделкой только из-за отсутствия отдельного экрана. Аналогично placeholder previews WidgetKit не считаются заглушками production-функций.

## Можно ли ожидать пользу

### Что может приносить пользу после стабилизации

Ручной журнал питания и тренировок, история самочувствия, календарь приёма добавок, единое место для измерений. Их ценность понятна без предположения о «точном AI»: они помогают записывать и видеть собственную историю. Ключевое условие — надёжное сохранение, корректные значения, даты, единицы, экспорт и восстановление.

### Чего нельзя обещать по результатам этого аудита

- Что recovery score отражает реальную готовность конкретного пользователя: рабочий pipeline уже расходится с собственными guards и sleep specification.
- Что прогнозы заранее обнаруживают болезнь, предотвращают травмы или улучшают результат тренировки. В репозитории есть планы и целевые метрики валидации, но не найдены результаты проверки готового продукта на пользовательских исходах.
- Что эксперимент доказал причинную связь: сравнение первого и последнего значения не заменяет анализ baseline/intervention, соблюдения протокола и достаточности данных.
- Что AI memory учится на накопленной истории через Pinecone: соответствующая цепочка не реализована.

Это не утверждение, что приложение никогда не сможет быть полезным. Это разделение реализованного учёта данных, качества вычислений и доказанной продуктовой пользы. Процент «готовности» без весов сценариев и полного прохождения проверки здесь вводил бы в заблуждение.

## Порядок исправления и критерии повторной приёмки

1. **Восстановить воспроизводимую сборку и установку:** F01/F02; clean DB + upgrade DB; согласовать policy/grant и AI consent fixtures; исправить ложный secret scan. Все стандартные gates должны реально доходить до конца.
2. **Защитить историю и изоляцию:** F03–F08; owner checks на всех service-role mutations, SQL transactions для вложенных изменений, сохранение pending edits и local-only данных, отмена очереди при consent revoke, полное удаление всех копий.
3. **Согласовать медицинские данные и вычисления:** F09–F13; decimal comma/Cyrillic/unit conversion, исторические даты, duplicate review, единый recovery engine с flags и handling missing data, честная давность и confidence.
4. **Закрыть недостающие функции либо сузить обещания:** vector memory, analysis/reminders experiments, общий календарь статусов, restore, Watch embedding. Не оставлять отсутствующую функцию обозначенной как shipped.
5. **Провести реальные сценарии на release artifact:** fresh install → onboarding → HealthKit; create/edit offline → reconnect → second device; Sign Out/Sign In с local-only и pending данными; full export/restore; deletion с raw scans/backup; iPhone + Watch; APNs/Guardian; русский язык, Dynamic Type/VoiceOver.
6. **Проверить пользу на небольшом пилоте:** время типового лога и исправлений, сохранность после потери сети/перезапуска, точность распознанных чисел против оригинала, понятность рекомендаций, частота их исправления и фактическое продолжение использования. Размер/длительность пилота требуют отдельного плана; результаты сейчас не подменяются ожиданиями.

## Ограничения и материалы

- Production Supabase, Vault/cron, APNs, Apple linking, реальный iPhone/Watch, App Store artifact, живые nutrition/AI providers не были проверены. Их отсутствие — отдельные пробелы доказательств, а не объяснение уже найденных локальных дефектов.
- После подтверждения `PGRST_DB_SCHEMAS=public,graphql_public` в диагностической БД обнаружено несоответствие проверки account deletion через `storage.objects` стандартной exposed schema. Полный delete с реальными storage objects не выполнен; B-W01 остаётся ограниченным этим evidence.
- Дополнительная динамическая проверка privileged RPC была остановлена автоматической защитой инструмента с причиной possible cybersecurity risk. Этот пункт оставлен как статический риск B-W02, без заявления об успешной runtime-проверке и без попытки обхода ограничения.
- Нагрузочный soak, полная performance-профилировка и real-device accessibility не выполнены. При падающих исходных build/migrations они не могут подтвердить релизную готовность.

Подробные приложения:

- `backend-integration.md`: SQL/API/AI/experiments, маршруты и воспроизведения.
- `ios-data-flows.md`: local data, sync, privacy, labs, diary, backup.
- `backend-regression-probes.test.ts`: выполняемые воспроизведения двух серверных дефектов. PASS в них означает **дефект воспроизведён**.
- `evidence/`: очищенные логи, Swift probes, точный diff только диагностической копии и итоговая ведомость запусков.
