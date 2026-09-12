---
phase: system-audit-2026-09-12
reviewed: 2026-09-12T14:28:29Z
depth: deep
files_reviewed: 32
files_reviewed_list:
  - ios/LifeOS/Modules/Shared/Network/AuthManager.swift
  - ios/LifeOS/Modules/Shared/Network/APIClient.swift
  - ios/LifeOS/Modules/Shared/Network/CloudUserBootstrapper.swift
  - ios/LifeOS/Modules/Shared/Network/BackgroundSyncManager.swift
  - ios/LifeOS/Modules/Shared/Network/SupabaseSessionKeychainStorage.swift
  - ios/LifeOS/Modules/Shared/Database/DatabaseManager.swift
  - ios/LifeOS/Modules/Shared/Database/Migrations.swift
  - ios/LifeOS/Modules/Shared/Database/GRDBRecords.swift
  - ios/LifeOS/Modules/Shared/Database/UserIdentityReconciler.swift
  - ios/LifeOS/Modules/Shared/Database/SyncEngine.swift
  - ios/LifeOS/Modules/Shared/Database/DatabaseBackupManager.swift
  - ios/LifeOS/Modules/Shared/Privacy/LocalPrivacyOperations.swift
  - ios/LifeOS/Modules/Shared/Privacy/PrivacyGateway.swift
  - ios/LifeOS/Modules/Shared/Privacy/PrivacyRetentionManager.swift
  - ios/LifeOS/Modules/Shared/Privacy/FieldEncryption.swift
  - ios/LifeOS/Modules/Shared/HealthKit/HealthSyncManager.swift
  - ios/LifeOS/Modules/Shared/HealthKit/HealthKitManager.swift
  - ios/LifeOS/Modules/Shared/Watch/WatchSyncManager.swift
  - ios/LifeOS/Modules/Shared/Widgets/WidgetSnapshotCoordinator.swift
  - ios/LifeOS/Modules/Shared/Notifications/PushNotificationManager.swift
  - ios/LifeOS/Modules/Shared/Notifications/NotificationEngine.swift
  - ios/LifeOS/App/LifeOSApp.swift
  - ios/LifeOS/Modules/Auth/AuthView.swift
  - ios/LifeOS/Modules/Auth/AuthFeature.swift
  - ios/LifeOS/Modules/Auth/BiometricAuthManager.swift
  - ios/LifeOS/Modules/Settings/SettingsAccountDestinationViews.swift
  - ios/LifeOS/Modules/Settings/SettingsDestinationViews.swift
  - ios/LifeOS/Modules/Settings/SettingsView.swift
  - ios/LifeOS/Modules/Shared/Guardian/GuardianManager.swift
  - ios/GuardianMonitorExtension/GuardianActivityMonitorExtension.swift
  - watch/LifeOSWatchApp/WatchSnapshotStore.swift
  - ios/LifeOSTests/LocalPrivacyOperationsTests.swift
findings:
  critical: 10
  warning: 1
  info: 0
  total: 11
status: issues_found
---

# Аудит целостности данных и native-интеграций

## Narrative Findings (AI reviewer)

Проверены критические цепочки auth → владелец локальной базы → outbox → API; экспорт/импорт и стирание; импорт HealthKit; действия Watch; уведомления и резервные копии. Дополнительно прослежены вызывающие пути в `LifeOSApp.swift`, `AuthView.swift`, `SettingsAccountDestinationViews.swift`, `SettingsDestinationViews.swift`, `watch/LifeOSWatchApp/WatchSnapshotStore.swift`, `GuardianManager.swift` и extension Guardian. Список выше включает основной и вспомогательный исследованный код, а не заявление, что все строки всех этих крупных файлов покрыты одинаково.

Исходный код не изменялся. Существующие незакоммиченные правки учитывались как текущее состояние. Симулятор и Xcode-тесты в этой ветке аудита не запускались: ими владеет основной аудитор. Выполнен изолированный SQLite probe ниже. Остальные findings основаны на трассировке исходников; для HealthKit/APNs/Watch отдельно обозначен внешний триггер. Старые отчёты не использовались как доказательство актуального бага.

## Critical Issues

### CR-DI-01: Reconnect принимает другой аккаунт и оставляет очередь предыдущего владельца

**Classification:** BLOCKER
**File:** `/Users/Bayramov_N/Desktop/Other/life-os/ios/LifeOS/Modules/Shared/Network/AuthManager.swift:814-827`
**Related:** `AuthManager.swift:1017-1035`; `SettingsAccountDestinationViews.swift:339-343`; `SyncEngine.swift:1789-1827`; `WatchSyncManager.swift:1207-1228`.

**Trigger:** пользователь A имеет неотправленные записи; восстановление сессии не удалось, включился local fallback; через «Переподключить» он проходит OTP/Apple-вход в B.

**Issue:** ограничение владельца проверяет только `signed_out_vault_owner`, который записывается при явном sign-out. Fallback сохраняет A, но этот ключ не устанавливает. Поэтому B принимается, а общая база, sync watermarks и outbox A остаются. `pendingEvents()` не фильтрует владельца, сам outbox не содержит owner. Edge-запросы без `user_id`, например `api-supplements-log`, исполняются в новой сессии B. Данные A могут оказаться в B; запросы с явным `user_id=A` как минимум получают RLS-ошибки. Это именно пропущенный переход состояния; нормальный explicit sign-out имеет отдельную защиту.

**Evidence:** source-confirmed end-to-end client chain. Отдельный реальный OTP→backend replay в этом аудите не выполнялся.

**Fix:** хранить владельца vault независимо от текущей auth-state и сравнивать его на каждом переходе; разрешать offline→cloud перенос только как явно определённый merge. Привязать outbox и watermarks к владельцу. Перед replay сверять owner события, активный локальный identity и фактический JWT subject. При отказе от нового аккаунта также откатывать уже заменённую сессию SDK.

### CR-DI-02: Импорт lower-case UUID создаёт дубликаты и скрытые от приложения записи

**Classification:** BLOCKER
**File:** `/Users/Bayramov_N/Desktop/Other/life-os/ios/LifeOS/Modules/Shared/Privacy/LocalPrivacyOperations.swift:819-833`
**Related:** `LocalPrivacyOperations.swift:402-406`; `DatabaseManager.swift:456-458`; `Migrations.swift:67-70`; `WidgetSnapshotCoordinator.swift:146-158`.

**Trigger:** импортировать штатный экспорт в существующий профиль либо в пустую базу с тем же UUID.

**Issue:** экспорт переводит `id` и `*_id` в lower case. Импорт вставляет строки без нормализации. Обычная запись GRDB сохраняет `UUID.uuidString` в upper case, а TEXT PK/FK в схеме case-sensitive. `INSERT OR IGNORE` не считает upper/lower варианты одной записью: появляются два пользователя и две версии одной сущности. При восстановлении в пустую БД lower-case строки также не совпадают с многочисленными обычными запросами `user_id = userId.uuidString`. Импорт может сообщить успех, но восстановленные данные не видны в экранах/виджетах. Связи через `created_by` дополнительно сохраняют иной регистр, поскольку экспорт нормализует только `id`/`*_id`.

**Evidence:** schema-equivalent SQLite probe ниже воспроизвёл 2 users + 2 food_logs вместо 1; штатный upper-case query не видит импортированную версию. Это воспроизведение поведения SQL, не запуск приложения.

**Fix:** при импорте канонизировать все UUID PK/FK/ownership поля в формат текущего local store; сопоставлять существующие строки по UUID, а не исходному TEXT. Добавить round-trip тест в уже инициализированную БД: повторный импорт не увеличивает количество строк, новые записи доступны через реальные repository queries.

### CR-DI-03: Импорт сохраняет расшифрованные медицинские данные без полевого шифрования

**Classification:** BLOCKER
**File:** `/Users/Bayramov_N/Desktop/Other/life-os/ios/LifeOS/Modules/Shared/Privacy/LocalPrivacyOperations.swift:811-833`
**Related:** `LocalPrivacyOperations.swift:423-429`; `GRDBRecords.swift:585-588,758-770`; `Migrations.swift:1779-1783,1826-1830`.

**Trigger:** импортировать экспорт с `health_measurements`, `menstrual_logs`, GPS food log либо URL medical scan.

**Issue:** штатный экспорт правильно расшифровывает `enc:v1:` для переносимого архива. Однако importer выполняет raw SQL и не вызывает `GRDBSensitiveEncoder`/`aroundSave`. Расшифрованные значения медицинских показателей, flow/pain, координаты и URL остаются plaintext в SQLite и последующих SQLite backup. Миграция шифрования уже применена и повторно после импорта не запускается. Это обход заявленного field-level encryption, даже при сохранении общего iOS file protection.

**Evidence:** source-confirmed exporter→importer→GRDB persistence chain. Не утверждается, что данные отправлены наружу.

**Fix:** восстанавливать чувствительные таблицы через типизированные PersistableRecord с prepared encryption context либо иметь проверенную таблицу column→encryption policy для raw importer. Тестировать сырые значения SQLite после импорта: все защищённые поля должны иметь envelope, UI должен получать исходные значения.

### CR-DI-04: Архив локального профиля нельзя восстановить после переустановки/на новом устройстве

**Classification:** BLOCKER
**File:** `/Users/Bayramov_N/Desktop/Other/life-os/ios/LifeOS/Modules/Shared/Privacy/LocalPrivacyOperations.swift:756-768,868-891`
**Related:** `AuthManager.swift:1100-1111`; `PrivacyGateway.swift:252-275`; `SettingsDestinationViews.swift:1631-1645`.

**Trigger:** экспортировать данные local-only профиля, переустановить приложение или открыть новый local-only профиль, затем выбрать сохранённый архив.

**Issue:** новое приложение создаёт другой случайный local auth/user UUID. Importer принимает только строки, чей user/auth UUID уже совпадает с текущим. Metadata архива не используется для восстановления identity или контролируемого переноса. Все пользовательские строки отсеиваются до счётчика skipped, и UI может показать «Импортировано записей: 0, пропущено: 0». Стандартный пользовательский сценарий восстановления локального архива не работает. Это отличается от CR-DI-02: даже правильный регистр UUID не решит несовпадение identity.

**Evidence:** source-confirmed validation flow; явная UI-обещанная операция — «Восстановите данные из ранее экспортированного архива Life OS».

**Fix:** реализовать явно подтверждаемый restore-local-profile либо безопасное переназначение владельца и всех зависимых PK/FK на текущий локальный профиль. Иной cloud account не объединять автоматически. Несовпадение владельца должно выдавать объяснимую ошибку и корректное количество пропущенных строк, а не успешный нулевой импорт.

### CR-DI-05: Отзыв HealthKit read permission превращается в удаление истории тренировок

**Classification:** BLOCKER
**File:** `/Users/Bayramov_N/Desktop/Other/life-os/ios/LifeOS/Modules/Shared/HealthKit/HealthSyncManager.swift:445-453`
**Related:** `HealthSyncManager.swift:254-275,309-312`; `HealthKitManager.swift:290-298,386-405`.

**Trigger:** импортировать тренировку, отозвать доступ к чтению workouts в Apple Health и запустить очередную синхронизацию этого дня. Аналогичный риск — новое устройство, где HealthKit-выборка ещё не полная.

**Issue:** пустая выборка трактуется как доказательство удаления: все прежние импортированные тренировки дня получают `deletedAt` и отправляются в cloud. Но отсутствие read permission даёт пустую выборку без отдельной ошибки. После возвращения разрешения `upsertImportedWorkout` прекращает работу для существующего tombstone, поэтому тренировки сами не восстанавливаются. Cloud tombstone также распространяет ошибку на другие устройства.

**Evidence:** source-confirmed deletion chain; внешний permission-trigger соответствует [Apple Platform Security: Protecting access to user’s health data](https://support.apple.com/guide/security/protecting-access-to-users-health-data-sec88be9900f/1/web/1). Физическое устройство не использовалось.

**Fix:** использовать явные `HKDeletedObject` из anchored query для подтверждённых удалений; отсутствие выборки не считать tombstone. Различать user-deleted и source-deleted записи, чтобы разрешённая повторная загрузка не блокировалась навсегда.

### CR-DI-06: Удаление импортированных тренировок не атомарно с outbox

**Classification:** BLOCKER
**File:** `/Users/Bayramov_N/Desktop/Other/life-os/ios/LifeOS/Modules/Shared/HealthKit/HealthSyncManager.swift:424-476`.

**Trigger:** процесс останавливается или запись outbox падает после commit локальных `deletedAt`, но до записи всех соответствующих событий.

**Issue:** первая транзакция помечает все удалённые тренировки и завершается на строке 459. Только затем отдельными транзакциями вставляется outbox. Следующая reconciliation выбирает лишь `deleted_at IS NULL`, поэтому уже помеченные строки больше никогда не породят потерянное событие. Локальная и серверная история расходятся; на другом устройстве тренировка остаётся активной.

**Evidence:** source-confirmed crash/failure boundary; fault injection не выполнялся.

**Fix:** в одной DB transaction сохранять tombstone и prepared outbox каждой удаляемой записи. Использовать ту же атомарную mutation-path, что уже применена к create/update workout.

### CR-DI-07: Отложенное действие Watch записывается на дату доставки и текущему владельцу

**Classification:** BLOCKER
**File:** `/Users/Bayramov_N/Desktop/Other/life-os/watch/LifeOSWatchApp/WatchSnapshotStore.swift:247-254`
**Related:** `WatchSnapshotStore.swift:233-244`; `WatchSyncManager.swift:1151-1158,1175-1200`.

**Trigger:** отметить добавку на Watch вечером без соединения с телефоном; доставка `transferUserInfo` произойдёт на следующий день. Либо локальный профиль на телефоне сменился до доставки.

**Issue:** message содержит action ID/name/scheduled time, но не фактическое время действия, local day/timezone или owner. Получатель назначает `Date()`, текущий timezone и текущего user. В результате вчерашний приём засчитывается за сегодня, а при смене пользователя запись попадает в другой профиль. iPhone `clearSnapshot()` отменяет только исходящие transfers iPhone, не уже поставленные Watch→iPhone действия.

**Evidence:** source-confirmed payload/consumer mismatch; поведение очереди на физической паре устройств не запускалось.

**Fix:** передавать неизменяемый envelope с owner/session generation, action ID, occurredAt, локальной датой/timezone и stable supplement ID. Отвергать чужое поколение профиля; для даты журнала использовать время нажатия. Добавить replay across-midnight и replay after-profile-reset тесты.

### CR-DI-08: Sign-out не выполняет серверную отписку от push до удаления сессии

**Classification:** BLOCKER
**File:** `/Users/Bayramov_N/Desktop/Other/life-os/ios/LifeOS/Modules/Shared/Network/AuthManager.swift:700-714`
**Related:** `PushNotificationManager.swift:255-278`; `SyncEngine.swift:565-570,768-771`.

**Trigger:** устройство зарегистрировано для APNs; пользователь выходит из аккаунта в момент, когда другой sync не отправляет новую очередь.

**Issue:** `unregisterCurrentDevice()` только добавляет outbox, хотя вызывающий код ждёт метод перед sign-out. Затем SDK session удаляется и `activeHasCloudSession=false`; replay этой отписки запрещён. Серверная регистрация остаётся активна, пока не случится дополнительное действие извне. Это сохраняет возможность уведомлений прежнего аккаунта на уже вышедшем устройстве. Наличие и точное содержимое отправляемых сервером сообщений проверяет отдельная backend-ветка аудита.

**Evidence:** source-confirmed deterministic client flow, без live APNs delivery.

**Fix:** выполнить подтверждённую server unregister до отзыва credentials; для offline sign-out предусмотреть серверный механизм инвалидирования регистрации без повторного входа в старый аккаунт. Не считать постановку в очередь подтверждённой отпиской.

### CR-DI-09: Подтверждённое стирание не удаляет системные локальные уведомления

**Classification:** BLOCKER
**File:** `/Users/Bayramov_N/Desktop/Other/life-os/ios/LifeOS/Modules/Shared/Privacy/LocalPrivacyOperations.swift:521-540`
**Related:** `LocalPrivacyOperations.swift:5-25,188-218`; `NotificationEngine.swift:715-721,1040-1086`; `PushNotificationManager.swift:199-220`.

**Trigger:** локальное напоминание о добавке/эксперименте запланировано через UNUserNotificationCenter; пользователь удаляет данные или начинает новый профиль.

**Issue:** executor удаляет `notification_log`, но не системные pending/delivered notifications. Последующий scheduler восстанавливает ID для отмены из уже пустой таблицы, поэтому отменять нечего. Предыдущие уведомления с пользовательским содержимым продолжают храниться/доставляться после успешного erasure. Обычный sign-out без удаления имеет отдельную scheduler cleanup и этим finding не объявляется сломанным.

**Evidence:** source-confirmed OS-scheduling→DB-purge→cleanup chain; реальные уведомления устройства в этой ветке не создавались.

**Fix:** до удаления идентификаторов отменить все принадлежащие приложению pending и delivered notifications через UNUserNotificationCenter и проверить пустоту; включить это в erasure dependencies. Заблокировать повторное планирование до завершения удаления.

### CR-DI-10: HealthKit автоматически возвращает историю после erasure

**Classification:** BLOCKER
**File:** `/Users/Bayramov_N/Desktop/Other/life-os/ios/LifeOS/App/LifeOSApp.swift:202-205`
**Related:** `LocalPrivacyOperations.swift:521-529`; `PrivacyGateway.swift:279-290,305-308`; `SyncEngine.swift:852-874`; `HealthSyncManager.swift:114-199,250-275`.

**Trigger:** завершить local erasure или подтверждённую cloud-deletion очистку, затем получить HealthKit observer callback/следующий lifecycle daily sync при сохранённом доступе к HealthKit.

**Issue:** erasure создаёт fresh user stub с прежним ID; `authManager.userId` остаётся. HK handler проверяет только наличие userId и без проверки deletion state заново импортирует последние три дня сна, физиологии и тренировок. Проверка `deletion_in_progress` есть в cloud SyncEngine, но не блокирует local HealthSyncManager writes. Для completed receipt `erasureStatus()` сразу возвращает completed, не стирая повторно созданную историю. Пользователь получает подтверждение удаления, после которого приватные данные снова появляются локально.

**Evidence:** source-confirmed writer/deletion-state mismatch; callback после erasure на физическом устройстве не воспроизводился.

**Fix:** ввести единый persisted deletion/session generation fence перед каждым user-data write; остановить observers, отменить/дождаться in-flight native/import/snapshot tasks, затем очищать. Для нового профиля HealthKit ingestion включать только после явного нового onboarding/consent.

## Warnings

### WR-DI-01: Попытка erasure навсегда отключает backup actor до перезапуска процесса

**Classification:** WARNING
**File:** `/Users/Bayramov_N/Desktop/Other/life-os/ios/LifeOS/Modules/Shared/Database/DatabaseBackupManager.swift:163-169`
**Related:** `DatabaseBackupManager.swift:26,45-46`; `SettingsAccountDestinationViews.swift:555-561`.

**Trigger:** сбой cleanup в середине удаления либо «начать заново» и дальнейшая работа в том же процессе.

**Issue:** `erasureInProgress=true` устанавливается перед потенциально падающим удалением каталога, но нигде не сбрасывается. Все последующие `performBackupIfDue()` молча выходят даже после ошибки или создания нового профиля. Это снижает устойчивость нового/сохранившегося профиля к последующей порче БД.

**Evidence:** exhaustive symbol-reference search: единственная запись true и guard, нет reset/completion API.

**Fix:** добавить явное завершение/отмену erasure-generation и управлять паузой backup только пока writers действительно заморожены. Не просто снимать флаг слишком рано: новый backup должен быть разрешён лишь после завершения очистки.

## Воспроизводимое SQL-доказательство CR-DI-02

Это **schema-equivalent probe**, не приложение/GRDB runtime: сохранены значимые TEXT PK/FK без NOCASE и точный INSERT OR IGNORE importer. Выполнено в памяти, source/database приложения не затронуты.

```python
import sqlite3

db = sqlite3.connect(":memory:")
db.execute("PRAGMA foreign_keys=ON")
db.execute("CREATE TABLE users(id TEXT PRIMARY KEY, auth_id TEXT NOT NULL)")
db.execute(
    "CREATE TABLE food_logs("
    "id TEXT PRIMARY KEY, user_id TEXT REFERENCES users(id), calories INTEGER)"
)

user_id = "AAAAAAAA-1111-4111-8111-AAAAAAAAAAAA"
log_id = "BBBBBBBB-2222-4222-8222-BBBBBBBBBBBB"

# Обычная локальная запись: UUID.uuidString.
db.execute("INSERT INTO users VALUES (?,?)", (user_id, user_id))
db.execute("INSERT INTO food_logs VALUES (?,?,?)", (log_id, user_id, 777))

# Стандартный экспорт приводит UUID к lower-case.
# Импортер вставляет их без канонизации.
db.execute(
    "INSERT OR IGNORE INTO users VALUES (?,?)",
    (user_id.lower(), user_id.lower()),
)
db.execute(
    "INSERT OR IGNORE INTO food_logs VALUES (?,?,?)",
    (log_id.lower(), user_id.lower(), 300),
)

print("users_after_import", db.execute("SELECT count(*) FROM users").fetchone()[0])
print("food_logs_after_import", db.execute("SELECT count(*) FROM food_logs").fetchone()[0])
print(
    "normal_uppercase_user_lookup",
    db.execute("SELECT SUM(calories) FROM food_logs WHERE user_id=?", (user_id,)).fetchone()[0],
)
print("actual_rows", db.execute("SELECT id,user_id,calories FROM food_logs").fetchall())
```

Реальный вывод:

```text
users_after_import 2
food_logs_after_import 2
normal_uppercase_user_lookup 777
actual_rows [
  ('BBBBBBBB-2222-4222-8222-BBBBBBBBBBBB', 'AAAAAAAA-1111-4111-8111-AAAAAAAAAAAA', 777),
  ('bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb', 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa', 300)
]
```

## Границы доказательств

- Положительные изменения действительно есть: SQLite online backup и проверка integrity; отказ от silent in-memory fallback при повреждении persistent store; Keychain device-only session/key; атомарные create/update imported workouts; exporter decrypts portable values; отдельная защита vault после explicit sign-out; реальные HK observers. Они не устраняют перечисленные переходные сценарии.
- Не объявляю APNs, FamilyControls, WatchConnectivity, HealthKit background delivery или provisioning рабочими по наличию исходников. Нужны подписанная сборка и физические устройства с проверкой entitlement/configuration.
- Не проводились destructive live-account deletion, чужой OTP-login, внешние отправки или испытания HealthKit permission на устройстве.
- Не покрыты равномерно все 40k+ строк назначенных модулей. Основной объём глубокой проверки направлен на ownership, переносимость и сохранность данных, replay и erasure. Полная матрица пользовательских функций и runtime результаты находятся в основном отчёте.
