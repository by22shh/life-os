---
phase: system-audit-2026-09-12-user-features
reviewed: 2026-09-12T14:32:04Z
depth: deep
status: issues_found
files_reviewed: 28
findings:
  critical: 12
  warning: 3
  info: 0
  total: 15
files_reviewed_list:
  - ios/LifeOS/Modules/Nutrition/NutritionLogViewModel.swift
  - ios/LifeOS/Modules/Nutrition/NutritionDayView.swift
  - ios/LifeOS/Modules/Nutrition/NutritionService.swift
  - ios/LifeOS/Modules/Nutrition/NutritionAIServices.swift
  - ios/LifeOS/Modules/Nutrition/NutritionCaptureViews.swift
  - ios/LifeOS/Modules/Nutrition/NutritionMealTemplateViews.swift
  - ios/LifeOS/Modules/Nutrition/NutritionCalendarView.swift
  - ios/LifeOS/Modules/Training/TrainingDayView.swift
  - ios/LifeOS/Modules/Training/TrainingService.swift
  - ios/LifeOS/Modules/Training/TrainingPlanService.swift
  - ios/LifeOS/Modules/Labs/LabsView.swift
  - ios/LifeOS/Modules/Labs/LabsFeature.swift
  - ios/LifeOS/Modules/Labs/LabScanDetailView.swift
  - ios/LifeOS/Modules/Labs/LabScanSyncSupport.swift
  - ios/LifeOS/Modules/Supplements/SupplementsDayView.swift
  - ios/LifeOS/Modules/Diary/DiaryView.swift
  - ios/LifeOS/Modules/Diary/DiaryViewModel.swift
  - ios/LifeOS/Modules/Insights/InsightDetailView.swift
  - ios/LifeOS/Modules/Insights/InsightsView.swift
  - ios/LifeOS/Modules/Shared/Models/HealthModels.swift
  - ios/LifeOS/Modules/Shared/Models/NutritionTargetEngine.swift
  - ios/LifeOS/Modules/Shared/Notifications/NotificationEngine.swift
  - ios/LifeOS/Modules/Sleep/SleepDetailSupport.swift
  - supabase/functions/_shared/supplements.ts
  - ios/LifeOSTests/NutritionServiceTests.swift
  - ios/LifeOSTests/TrainingServiceTests.swift
  - ios/LifeOSTests/CoverageFinalPushTests.swift
  - ios/LifeOSTests/ModelCoverageExpansionTests.swift
---

# Аудит пользовательских функций Life OS

## Narrative Findings (AI reviewer)

Проверена текущая рабочая копия, включая незакоммиченные исправления. Метод: трассировка пользовательского действия через view/view model, локальное сохранение, повторное открытие и связанные API-контракты; два изолированных Swift-прогона действующего кода. Это не полный построчный аудит всех 38 тысяч строк перечисленных модулей и не результат прогона приложения на устройстве. Основные write/read-пути прочитаны подробно; вспомогательные UI/coverage-разделы обследованы выборочно. Исходники не изменены.

Приложение содержит настоящие локальные журналы, редакторы, историю, OCR и очередь синхронизации. Однако утверждение «все функции реализованы и корректны» не подтверждается: при обычной коррекции еды теряются выбранная дата или позиции, длительность тренировки выдумывается по количеству сетов, расписание БАДов расходится между экраном, уведомлениями и сервером. Для использования как надежного персонального помощника эти ошибки существенны.

### Матрица реальной готовности

| Область | Что существует в текущем коде | Статус и предел полезности |
|---|---|---|
| Еда: ручной поиск, порция, дневник | Выбор еды, ручные позиции, сохранение FoodLog/FoodItem, повторное открытие, edit/delete/undo, локальная очередь | Частично пригодно. Исправление даты при создании теряется; изменение граммов сохраненного блюда не пересчитывает макросы. |
| Еда: фото и голос | Захват/распознавание, AI/fallback drafts, уточнения, экран review, сохранение | Частично. Результаты AI не становятся редактируемыми позициями; добавление ручной позиции заменяет весь набор. Точность живых провайдеров не проверялась. |
| Штрихкод и OCR этикетки | Lookup, fallback, Review Product и создание продукта | Частично. Локальный parser не различает «на порцию»/«на 100 г». Реальные камеры и каталог провайдера не проверены. |
| Шаблоны и batch recipes | Создание/редактирование/архивирование, повторное использование, порции; остаток вычисляется по не удаленным логам | Основные локальные пути существуют. Наличие путей не означает подтвержденный live round trip. Текущая защита detail-cache от pending edits имеется. |
| Тренировки вручную | Каталог/кастомные упражнения, подходы/вес/повторы, таймер, CRUD, импорт-конфликты | Для учета сетов полезно; данные о времени/нагрузке ненадежны из-за CR-F05. |
| План тренировок и адаптация | Composer, список запланированных дней, вызовы generate/adjust, статусные сообщения | Существенно неполно. Начало плановой тренировки открывает пустой ручной журнал; упражнений/подходов плана и локального исполнения адаптации нет. Серверный агент отдельно подтвердил placeholder generation и отсутствие изменения занятий при adjust. |
| Анализы | Локальные image/PDF OCR, ручной review полей, дата анализа, дубликаты, сохранение, оригинал, pin | Основной импорт существует; исправления даты/дубликатов из прошлого аудита присутствуют. Нет коррекции уже сохраненных значений/удаления отдельного анализа; remote refresh опасен для локальных изменений/оригинала. |
| БАДы | Создание элемента стека, переключение активности, scheduled/quick Taken, дневная история, месячная окраска | Нельзя считать надежным расписанием: weekly/as-needed показываются ежедневно, процент соблюдения неверен; нет отмены ошибочного приема. |
| Дневник | Навигация по дню, месячная сетка доменов, summaries, переходы в модули, review queue | Реальный UI присутствует, прежнее «нет месячной сетки» уже неверно. Наличие записи обозначается отдельно от полноты/достоверности данных. |
| Wellness | Пять оценок, симптомы, заметка, сохранение и повторное изменение check-in | Базовый опрос существует. PSS-4 не доступен; журнал ложно отмечает показ ресурсов помощи. |
| Эксперименты | Создание из insight, baseline/intervention schedule, локальные напоминания, ежедневный лог, stop, описательные средние | Частично. Список использует устаревшую фазу; повторное изменение дневного измерения стирает adherence/notes. Настройка протокола, единиц и историческая коррекция с UI отсутствуют. |
| Body composition | Ручной вес/body-fat/muscle, история, edit/delete | Поверхность существует, хотя master spec все еще относит ее к отсутствующим V2 UI. Подробная проверка физиологической валидации не выполнена. |

Ссылки для плана: `ios/LifeOS/Modules/Training/TrainingDayView.swift:343` передает только date/type/planId; `:1279` и `:1320` оставляют exercises пустыми; `:2686` отображает AI-adaptive label; `TrainingPlanService.swift:215`/`:257` только вызывает сервер и sync. Основная серверная находка в отчете backend-аудита, здесь повторно не считается.

## Critical Issues

### CR-F01 — BLOCKER: выбор даты и времени новой еды не сохраняется

**Файл:** `ios/LifeOS/Modules/Nutrition/NutritionLogViewModel.swift:490–497`; UI: `ios/LifeOS/Modules/Nutrition/NutritionDayView.swift:1500–1504`.

**Сценарий:** открыть новую еду → изменить DatePicker, например на вчерашний ужин → Save. Picker изменяет `viewModel.loggedAt`, но `createNewMeal` создает одноименную локальную переменную из `draft?.loggedAt ?? now`; день также берется из исходного draft. Изменение пользователя полностью игнорируется.

**Влияние:** запись попадает в другой день/время, искажаются дневные итоги и последующий анализ. Это обычный сценарий запоздалого внесения еды, не проблема неверного пользовательского ввода.

**Исправление:** сохранять редактируемый `self.loggedAt`, пересчитывать авторитетный local day/timezone для этого времени, не использовать устаревший `draft.loggedDate`. Добавить сценарий create → изменить дату → save → reopen, с проверкой реальной строки БД.

**Уверенность:** высокая, прямая трассировка binding → save.

### CR-F02 — BLOCKER: review фото/голоса не редактирует AI-позиции, а ручное дополнение удаляет их из лога

**Файл:** `ios/LifeOS/Modules/Nutrition/NutritionLogViewModel.swift:776–780`, `:534–566`; UI: `ios/LifeOS/Modules/Nutrition/NutritionDayView.swift:1464–1491`, `:1569–1581`.

**Сценарий:** AI распознал курицу и рис → пользователь хочет исправить количество или добавить масло. `prefilledMealItems` создает editable items только для `.manual`; photo/voice candidates выводятся read-only текстом. После `Add item` массив ручных `mealItems` становится непустым, и сохранение выбирает только его, исключая все AI candidates. В результате журнал содержит только масло.

**Влияние:** пользователь не может нормально исправить распознавание до сохранения; добавление одного продукта тихо теряет остальные и уменьшает дневные итоги.

**Исправление:** материализовать все распознанные кандидаты в единую редактируемую модель независимо от способа ввода; добавление должно дополнять массив. Неполные кандидаты нужно исправлять явно, не отбрасывать при переходе между ветками сохранения.

**Уверенность:** высокая, ветки UI и persistence совпадают по одному массиву.

### CR-F03 — BLOCKER: исправление граммов не пересчитывает пищевую ценность

**Файл:** `ios/LifeOS/Modules/Nutrition/NutritionDayView.swift:1636–1645`; persistence: `ios/LifeOS/Modules/Nutrition/NutritionService.swift:939–949`.

**Сценарий:** открыть сохраненный продукт 100 г / 200 ккал → исправить порцию на 200 г → Save. Поле граммов напрямую меняет `weightG`, тогда как calories/protein/fat/carbs остаются независимыми значениями. `updateMeal` суммирует прежние макросы, поэтому 200 г по-прежнему дают 200 ккал.

**Влияние:** обычная коррекция размера порции искажает рацион; при batch-item дополнительно меняется расход веса без соответствующего изменения потребленной пищевой ценности.

**Исправление:** хранить базовую пищевую ценность и масштабировать ее при изменении веса; прямое исправление макросов должно быть отдельным понятным режимом. Проверить удвоение и уменьшение порции, включая существующие batch items.

**Уверенность:** высокая, прямые bindings и сохранение без пересчета.

### CR-F04 — BLOCKER: offline OCR этикетки сохраняет значения «на порцию» как «на 100 г»

**Файл:** `ios/LifeOS/Modules/Nutrition/NutritionAIServices.swift:1198–1247`; вызывающий fallback: `:966–989`.

**Сценарий:** без cloud analysis распознать этикетку `Serving 30 g`, `kcal 150`, `Protein 10 g`. Parser извлекает serving=30, но возвращает caloriesPer100g=150 и proteinPer100g=10 без преобразования.

**Доказательство:** действующие Swift helpers извлечены в memory-only probe и выполнены через `swift -`; вывод: `Serving 30.0 kcalPer100g 150.0 proteinPer100g 10.0`. Для этих исходных единиц ожидается 500 ккал и ≈33.33 г белка на 100 г. Review экран может позволить ручную починку, но единицы уже подменены без специального предупреждения о basis.

**Влияние:** запись продукта 30 г дает 45 ккал вместо 150; ошибка затем повторяется при каждом lookup/использовании сохраненного продукта.

**Исправление:** определять basis таблицы и преобразовывать значения; при неоднозначной разметке не выдавать числа как per100g, потребовать выбор основы. Добавить реальные примеры per-serving/per100g и двухколоночных таблиц.

**Уверенность:** высокая, воспроизведено на текущей функции.

### CR-F05 — BLOCKER: длительность и нагрузка тренировки подменяются количеством сетов

**Файл:** `ios/LifeOS/Modules/Training/TrainingDayView.swift:2021–2041`; запись: `:1819–1842`, `:1868–1894`.

**Сценарий:** внести часовую тренировку с тремя подходами либо открыть существующую ручную/plan тренировку и изменить только заметку. `currentDurationMinutes` всегда выбирает `max(round(setCount*2.5),15)` прежде существующего duration; время окончания и TRIMP сохраняются заново на его основе. Редактор `workoutMetadataSection:695–738` не дает указать фактическую длительность или время.

**Влияние:** трехсетовая часовая тренировка становится 15-минутной; уже полученная при merge с HealthKit длительность снова теряется при последующем сохранении. Нагрузка/ACWR/рекомендации получают неверные исходные значения. Это не маркируется как приблизительная оценка на записи.

**Исправление:** дать ввод/таймер фактической длительности; при редактировании сохранять старое значение, если время не менялось. При неизвестной длительности хранить unknown либо явно отделенную оценку. Тест `ios/LifeOSTests/CoverageFinalPushTests.swift:10410–10411` сейчас утверждает 15 минут и TRIMP 18, закрепляя эвристику; заменить его проверкой пользовательского/загруженного времени.

**Уверенность:** высокая, код записи и существующие assertions.

### CR-F06 — BLOCKER: ежедневный список БАДов игнорирует расписание, а weekly-запись расходится с сервером

**Файл:** `ios/LifeOS/Modules/Supplements/SupplementsDayView.swift:609–680`, `:1647–1662`; связанные правила: `ios/LifeOS/Modules/Shared/Notifications/NotificationEngine.swift:1114–1142`, `supabase/functions/_shared/supplements.ts:136–160`.

**Сценарий:** добавить БАД с `weekly` или `as_needed`, открыть следующий день. Экран использует frequency только для подписи и создает scheduled item на каждый день. `days_of_week`, started_at и ended_at не участвуют в фильтре. Weekly composer вообще сохраняет `daysOfWeek:nil`: сервер считает такую запись незапланированной, локальные notifications выбирают weekday начала, дневной экран предлагает прием ежедневно.

**Влияние:** три поверхности показывают разные правила приема. Исторический день до начала стека также получает текущую схему.

**Исправление:** единый календарный resolver для дневника/уведомлений/server contracts; выбирать и сохранять weekday для weekly; исключать as-needed из плановых приемов и учитывать начало/окончание.

**Уверенность:** высокая, подтверждена независимым чтением backend helper.

### CR-F07 — BLOCKER: процент соблюдения БАДов считает названия вместо приемов и переписывает историю

**Файл:** `ios/LifeOS/Modules/Supplements/SupplementsDayView.swift:716–742`.

**Сценарий:** один БАД назначен утром и вечером; отмечен только утренний прием. `COUNT(DISTINCT user_supplement_id)` дает 1, знаменатель — число активных элементов стека, также 1; день считается полностью выполненным. Добавление нового БАДa сегодня увеличивает знаменатель для всех дней месяца; деактивация уменьшает его задним числом. As-needed и фактически незапланированные дни также попадают в знаменатель.

**Влияние:** adherence не отражает соблюдение расписания, старые достижения меняются без изменения исторических логов.

**Исправление:** вычислять для каждой даты ожидаемые slots из исторической схемы и сопоставлять taken по supplementId+slot. Использовать единые правила с API, сохранять историю изменения расписания либо явно определить ее семантику.

**Уверенность:** высокая, точный SQL и формирование знаменателя.

### CR-F08 — BLOCKER: обновление карточки анализа перезаписывает локальные изменения и ссылку на оригинал

**Файл:** `ios/LifeOS/Modules/Labs/LabScanDetailView.swift:658–663`, `:725–733`; удаление бесхозных файлов: `:1123–1167`.

**Сценарий:** для cloud-mode анализа поставить pin/подтвердить review, пока upload pending; затем Refresh возвращает более старую запись. `persistRemoteSnapshot` без проверки outbox/updatedAt сохраняет ее поверх локальной, а UI применяет remote snapshot напрямую. Вариант без гонки: разрешить cloud markers, оставить original локально (`storeOriginalInCloud=false`); remote запись не содержит локального file URL, и blind replace убирает единственную ссылку на него. Последующий `pruneStaleAssets` удалит файл как бесхозный.

**Влияние:** локально сохраненная проверка/pin откатывается; оригинал может стать недоступен и затем удалиться при maintenance. Здесь нет защиты, уже добавленной в meal/workout detail cache.

**Исправление:** recheck pending mutations и updatedAt в write transaction, merge device-local asset references отдельно от синхронизируемой записи, применять в UI итоговый local snapshot. Проверить metadata-only cloud round trip и refresh во время pending pin/review.

**Уверенность:** высокая для overwrite; удаление оригинала установлено по цепочке reference replacement → orphan cleanup, живой backend round trip не запускался.

### CR-F09 — BLOCKER: календарь питания показывает дни под неверными названиями недели

**Файл:** `ios/LifeOS/Modules/Nutrition/NutritionCalendarView.swift:60–63`, `:97–105`. Та же причина в `ios/LifeOS/Modules/Sleep/SleepDetailSupport.swift:1837–1844`, `:1908–1909`.

**Сценарий:** календарь с началом недели в понедельник, типичный для русского интерфейса. Leading spaces вычисляются относительно `calendar.firstWeekday`, а заголовки выводятся из массива Sunday-first без поворота.

**Доказательство:** Foundation Swift probe для ru_RU/firstWeekday=2 и 2026-09-01 вывел `grid column 1 header Пн actual weekday 3`: вторник попадает под понедельник.

**Влияние:** пользователь ориентируется по ошибочным дням недели и может открыть/заполнить не тот день. Число месяца само по себе верное.

**Исправление:** повернуть массив weekday symbols по firstWeekday, как уже сделано в TrainingCalendarSupport; проверять Sunday-first и Monday-first.

**Уверенность:** высокая, воспроизведено.

### CR-F10 — BLOCKER: завершенный эксперимент остается в активном списке с устаревшей фазой

**Файл:** `ios/LifeOS/Modules/Insights/InsightsView.swift:667–677`, `:724–731`, `:756–773`; detail: `ios/LifeOS/Modules/Insights/InsightDetailView.swift:745–761`.

**Сценарий:** начать эксперимент, затем открыть приложение после окончания его периода, не вызывая специализированный experiment API. Detail рассчитывает фазу по календарю и показывает completed; список фильтрует и подписывает сырой сохраненный status, обычно baseline/intervention. Обычный refresh использует sync pull таблицы, а не API lifecycle normalizer.

**Влияние:** законченный run не находится в Finished, остается Active; разные экраны противоречат друг другу. Backend-аудит подтвердил, что lifecycle обновляется при специализированных API-вызовах и отдельного cron для такого перехода нет.

**Исправление:** использовать `resolvedLifecycleStatus(forLocalDate:)` для list filter и badge; определить единый способ персистентного продвижения фаз. Проверить ситуацию без новых измерений после последнего дня.

**Уверенность:** высокая, межмодульная трассировка подтверждена backend агентом.

### CR-F11 — BLOCKER: correction дневного эксперимента стирает соблюдение протокола и заметку

**Файл:** `ios/LifeOS/Modules/Insights/InsightDetailView.swift:674–677`, `:763–765`, `:822–834`.

**Сценарий:** сохранить сегодняшнее измерение с «протокол не соблюден» и заметкой → закрыть карточку → открыть и исправить число. `load` устанавливает только `hasLoggedToday`, но не восстанавливает dailyValue/dailyNotes/adheredToday. Последний по умолчанию true; update заменяет notes пустотой и protocolFollowed=true.

**Влияние:** простая коррекция числа меняет смысл наблюдения. День, ранее исключенный из сравнения фаз, ошибочно включается в результаты.

**Исправление:** заполнять форму полным сегодняшним measurement при load, сохранять поля, которые пользователь не менял; показывать единицы. Добавить reopen → correction тест с false adherence и непустой заметкой.

**Уверенность:** высокая, прямые начальные значения/load/update.

### CR-F12 — BLOCKER: Wellness записывает показ помощи, которой пользователь не видел

**Файл:** `ios/LifeOS/Modules/Diary/DiaryView.swift:1059–1145`, `:1399–1410`.

**Сценарий:** заполнить check-in с итогом ниже 40. Save сохраняет `mentalHealthResourcesShown: true`, хотя ни одна ветка Wellness view не показывает ресурсы помощи и не выполняет длительный анализ стресса. PSS-4 поля всегда nil; во всем production UI не найден ввод четырех вопросов.

**Влияние:** в данных утверждается выполненное действие поддержки, которого не было; обещанный в PRD и functional matrix PSS-4/реакция на устойчивый стресс отсутствует. Низкий итог при соматических симптомах дополнительно не равнозначен длительному стрессу.

**Исправление:** отмечать shown только после фактического показа; реализовать отдельную PSS-4 форму/частоту и правила устойчивого стресса, либо честно обозначить этот функционал как незавершенный. Не выводить PSS-4 из пяти нынешних вопросов. Проверить исходное false, реальный показ и повторное открытие.

**Уверенность:** высокая; подтверждено поиском всех production uses PSS-4/resources-shown. Это оценка реализации, не медицинская рекомендация.

## Warnings

### WR-F01 — WARNING: сохраненный анализ нельзя исправить или удалить отдельно

**Файл:** `ios/LifeOS/Modules/Labs/LabScanDetailView.swift:25–88`, `:204–258`, `:290–329`.

**Сценарий:** после сохранения заметить неверное значение OCR/дату или случайно подтвердить дубликат. Редактирование доступно только в capture Review до первого save. В detail присутствуют просмотр, refresh, reviewed и pin; нет edit/delete отдельного scan/measurement. Повторный импорт создает еще одну запись, оставляя ошибочную.

**Влияние:** пользователь не может привести собственную историю в порядок; ошибочный маркер продолжает существовать среди исходных данных анализа.

**Исправление:** добавить correction повторно используемым Review, историю исправлений и scoped soft-delete с синхронизацией; перерасчитывать derived results. Уверенность высокая.

### WR-F02 — WARNING: ошибочный прием БАДа нельзя отменить, дозу/время элемента стека нельзя исправить

**Файл:** `ios/LifeOS/Modules/Supplements/SupplementsDayView.swift:175–190`, `:253–308`, `:1539–1590`.

**Сценарий:** случайно нажать Taken либо ошибиться в дозе при создании. Taken превращается в статичный badge, log row не имеет edit/delete/undo, stack row позволяет лишь active toggle. Добавление второго элемента не исправляет старую историю.

**Влияние:** ошибка пользователя остается в данных и adherence; повторное ежедневное использование требует обходных действий.

**Исправление:** undo приема, редактирование/удаление log, отдельное изменение дозы/схемы с явной датой вступления в силу. Уверенность высокая.

### WR-F03 — WARNING: OCR анализов не переживает уход с экрана до сохранения

**Файл:** `ios/LifeOS/Modules/Labs/LabsView.swift:373–388`, `:514–520`, `:668–717`, `:759–785`.

**Сценарий:** запустить OCR PDF/фото и закрыть modal до Save либо завершить приложение. CapturedAsset, text, markers и review state хранятся только в `@State`; файл и запись появляются лишь в `persistMarkers`. Dismiss блокируется только при `isSavingReview`, а не при OCR. Возврат не восстанавливает работу.

**Влияние:** обещание acceptance §8.1 «user can leave and return later» не реализовано; пользователь повторяет импорт и исправления. Сам распознающий Task асинхронен, но это не resumable job.

**Исправление:** сохранять защищенный local draft/job до OCR, восстанавливать status и review по ID, очищать отмененные drafts; затем проверить exit/reopen/kill/relaunch. Уверенность высокая для отсутствия persistent state, force-quit на устройстве не выполнялся.

## Проверка прошлых выводов и границы тестов

- Старый overwrite pending edits у еды/тренировок **не повторен как открытая находка**: `NutritionService.swift:1748–1770` и `TrainingService.swift:739–766` теперь проверяют outbox и timestamps в транзакции и возвращают итоговое local detail.
- Labs дата и duplicate detection действительно появились: `LabsView.swift:780–808`; review сбрасывает подтверждение при изменении полей, запрещает invalid markers. Старые выводы «дата всегда сегодня / дубликаты не проверяются» устарели.
- Unified Diary month grid теперь существует: `DiaryView.swift:54–60`, `:2330–2418`; нельзя повторять прежний вывод о его полном отсутствии.
- Experiment analysis теперь использует baseline/intervention means, минимум 3 наблюдения на фазу, adherence/unit/phase checks и нейтральное направление неизвестных метрик (`InsightDetailView.swift:1047–1110`). Старое сравнение первой и последней точки не повторено.
- Два фактически выполненных изолированных Swift probes: per-serving nutrition label и Monday-first calendar. Они использовали текущие helpers/Foundation и не подменяли продукты/данные пользователя.
- Unit/service/coverage tests прочитаны для оценки того, что именно они проверяют; xcodebuild и simulator этим агентом не запускались. Render-body harnesses и assertions на эвристические значения не подтверждают правильность пользовательского сценария. Дефект длительности особенно показателен: тест прямо ожидает 15 минут.
- Для подтверждения реальной пригодности еще нужны последовательные сценарии UI→save→reopen→offline correction→reconnect на одном пользователе, реальное OCR русских/английских документов, photo/voice provider round trips, camera permissions и доставка уведомлений. Отсутствие такой проверки здесь обозначено как **непроверено**, а не автоматически как поломка.
- Общая безопасность, identity, sync, HealthKit импорт и backend mutations разделены с другими агентами; их находки не включены в численность этого файла. Доказанная серверная заглушка планов отражена в матрице и должна учитываться в общем отчете.

_Аудит только чтение; изменения production source отсутствуют._

## Воспроизводимая evidence: два изолированных Swift probes

Следующий Python-код запускается из корня репозитория и подает код в stdin `swift -`, без создания или изменения source-файлов. OCR probe использует извлеченные из текущего файла функции, а календарный probe воспроизводит действующие Foundation операции календаря.

```python
from pathlib import Path
import subprocess

source = Path("ios/LifeOS/Modules/Nutrition/NutritionAIServices.swift").read_text()
start = source.index("    private static func parseNutritionLabelText(")
end = source.index("    private static func isCloudAnalysisEnabled()", start)
helpers = source[start:end].replace("private static func", "static func")
start = source.index("    private static func normalizedRecognizedText(")
end = source.index("    private static func normalizedLines(")
normalized = source[start:end].replace("private static func", "static func")
program = "import Foundation\nenum Probe {\n" + normalized + helpers + "\n}\n"
program += '''
let result = Probe.parseNutritionLabelText("Protein Bar\\nServing 30 g\\nkcal 150\\nProtein 10 g\\nFat 6 g\\nCarbs 15 g")
print("Serving", result.servingSizeG, "kcalPer100g", result.caloriesPer100g,
      "proteinPer100g", result.proteinPer100g)
var cal = Calendar(identifier: .gregorian)
cal.locale = Locale(identifier: "ru_RU")
cal.firstWeekday = 2
let date = cal.date(from: DateComponents(year: 2026, month: 9, day: 1))!
let index = (cal.component(.weekday, from: date) - cal.firstWeekday + 7) % 7
print("2026-09-01 grid column", index, "header", cal.shortWeekdaySymbols[index],
      "actual weekday", cal.component(.weekday, from: date))
'''
completed = subprocess.run(["swift", "-"], input=program, text=True, capture_output=True)
print(completed.stdout)
print(completed.stderr)
raise SystemExit(completed.returncode)
```

Фактический результат, exit code 0:

```text
Serving 30.0 kcalPer100g 150.0 proteinPer100g 10.0
2026-09-01 grid column 1 header Пн actual weekday 3
```

Отдельно главный агент сообщил о завершенных 831 unit tests (5 skipped), 4 widget tests и 66 backend route checks, трех подтвержденных SQL security/deletion probes и четырех новых failing prediction assertions. Эти результаты принадлежат общему аудиту и не превращают перечисленные выше source-based findings в проведенные UI-тесты. Доказательства и точные условия общих прогонов следует брать из отчета главного агента.
