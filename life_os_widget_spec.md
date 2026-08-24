# LIFE OS — iOS WIDGET SPECIFICATION

**Version:** 0.2  
**Date:** February 16, 2026  
**Platforms:** iOS 17+ (WidgetKit)  
**Purpose:** Implementation-ready specification for iOS Home Screen and Lock Screen widgets.

> [!IMPORTANT]
> Widgets are **read-only surfaces** that display pre-computed data from the local database.  
> They never make network calls, never call AI, and never write data.

> [!NOTE]
> **Related specs:** watchOS companion surfaces (`life_os_watchos_spec.md`) use a separate `WatchSnapshot` schema scoped to recovery + one-tap actions. Widget analytics events are defined in `life_os_analytics_catalog.md` (§ Widget Events).

---

## 0) Non-Negotiables

1. **No network in widgets.** All data comes from a shared App Group container (GRDB database or UserDefaults).
2. **No business logic in widgets.** Widget timelines display cached `WidgetSnapshot` data produced by the main app.
3. **Privacy:** Widgets must never display sensitive data (menstrual cycle, health diagnoses, medical scan results) unless user explicitly enables it in Settings → Widget Privacy.
4. **Accessibility:** All widget text respects Dynamic Type. Colors follow Okabe-Ito palette with icon + text (never color-only).
5. **Redacted mode:** Widgets must implement `.redacted(reason: .placeholder)` for Lock Screen and StandBy mode.

---

## 1) Widget Catalog

### 1.1 Recovery Score (Primary Widget)

| Property | Value |
|----------|-------|
| **Families** | `systemSmall`, `systemMedium`, `accessoryCircular`, `accessoryRectangular`, `accessoryInline` |
| **Refresh cadence** | Every 30 minutes (or on significant timeline change via `WidgetCenter.shared.reloadTimelines`) |
| **Data source** | `physiological_states.recovery_score` + `physiological_states.recovery_zone` |

**systemSmall layout:**
```
┌────────────────────┐
│  Recovery          │
│                    │
│     78%            │  ← Hero number, zone color
│   ✓ Optimal        │  ← Icon + zone label
│                    │
│  ↗ +5 vs yesterday │  ← Trend delta
└────────────────────┘
```

**accessoryCircular (Lock Screen):**
```
┌───────┐
│  78%  │  ← Recovery score
│   ✓   │  ← Zone icon
└───────┘
```

**accessoryRectangular (Lock Screen):**
```
┌─────────────────────────┐
│ Recovery: 78% ✓ Optimal │
│ ↗ +5 vs yesterday       │
└─────────────────────────┘
```

**accessoryInline (Lock Screen — single line):**
```
Recovery: 78% ✓
```
> Shows recovery score + zone icon as a compact single‑line widget. Ideal for StandBy mode and Lock Screen top row.

### 1.2 Nutrition Progress

| Property | Value |
|----------|-------|
| **Families** | `systemSmall`, `systemMedium` |
| **Refresh cadence** | Every 15 minutes |
| **Data source** | Aggregated `food_logs` for current day |

**systemSmall layout:**
```
┌────────────────────┐
│  Today's Macros    │
│                    │
│  P  ████░░  65g    │  ← Protein progress bar
│  C  ██████  180g   │  ← Carbs progress bar
│  F  ███░░░  42g    │  ← Fat progress bar
│                    │
│  1,350 / 2,100 cal │
└────────────────────┘
```

**systemMedium layout:** Same as small but adds fiber + water progress.

### 1.3 Supplement Schedule

| Property | Value |
|----------|-------|
| **Families** | `systemSmall`, `systemMedium` |
| **Refresh cadence** | Every 15 minutes |
| **Data source** | `user_supplements` + `supplement_logs` for today |

**systemSmall layout:**
```
┌────────────────────┐
│  Supplements       │
│                    │
│  ✓ Vitamin D  AM   │  ← Taken
│  ✓ Omega-3    AM   │  ← Taken
│  ○ Magnesium  PM   │  ← Pending
│  ○ ZMA        PM   │  ← Pending
│                    │
│  2 of 4 taken      │
└────────────────────┘
```

### 1.4 Next Workout (Training Plan)

| Property | Value |
|----------|-------|
| **Families** | `systemSmall`, `accessoryRectangular` |
| **Refresh cadence** | Every 60 minutes |
| **Data source** | `training_plans` → next scheduled session |

**systemSmall layout:**
```
┌────────────────────┐
│  Next Workout      │
│                    │
│  Upper Body A      │
│  Push emphasis      │
│                    │
│  ~45 min           │
│  5 exercises       │
└────────────────────┘
```

---

## 2) Data Flow

```
Main App (foreground/background)
  │
  ├── Computes WidgetSnapshot on:
  │     - App launch
  │     - Data change (food log, supplement log, recovery refresh)
  │     - Background refresh task
  │
  ├── Writes snapshot to App Group container:
  │     UserDefaults(suiteName: "group.app.lifeos.widgets")
  │       key: "widget_snapshot_v1"
  │       value: JSON-encoded WidgetSnapshot
  │
  └── Calls WidgetCenter.shared.reloadTimelines(ofKind:)
        when data changes significantly

Widget Extension
  │
  ├── TimelineProvider.getTimeline()
  │     reads WidgetSnapshot from App Group
  │
  └── Renders SwiftUI view from snapshot
```

### 2.1 WidgetSnapshot Schema

```swift
struct WidgetSnapshot: Codable {
    let generatedAt: Date
    
    // Recovery
    let recoveryScore: Int?         // 0-100
    let recoveryZone: String?       // optimal|ready|caution|critical
    let recoveryDelta: Int?         // vs yesterday
    
    // Nutrition
    let caloriesConsumed: Int
    let caloriesTarget: Int
    let proteinG: Double
    let proteinTargetG: Double
    let carbsG: Double
    let carbsTargetG: Double
    let fatG: Double
    let fatTargetG: Double
    let fiberG: Double
    let waterMl: Int
    let waterTargetMl: Int
    
    // Supplements
    let supplementsTotal: Int
    let supplementsTaken: Int
    let nextSupplement: SupplementEntry?
    
    // Training
    let nextWorkout: WorkoutEntry?
    
    struct SupplementEntry: Codable {
        let name: String
        let scheduledTime: String     // "21:00"
    }
    
    struct WorkoutEntry: Codable {
        let sessionName: String
        let focus: String
        let estimatedDurationMin: Int
        let exerciseCount: Int
    }
}
```

---

## 3) Timeline Strategy

```swift
struct RecoveryWidgetProvider: TimelineProvider {
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let snapshot = loadSnapshot()  // From App Group
        
        let currentEntry = RecoveryEntry(date: Date(), snapshot: snapshot)
        
        // Next refresh: 30 minutes from now
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 30, to: Date())!
        
        let timeline = Timeline(entries: [currentEntry], policy: .after(nextRefresh))
        completion(timeline)
    }
}
```

**Refresh triggers:**
- `TimelineReloadPolicy.after()` — periodic refresh (cadence per widget type).
- `WidgetCenter.shared.reloadTimelines(ofKind:)` — called by main app when relevant data changes.
- Background app refresh — updates snapshot even when app is not in foreground.

---

## 4) Deep Links

Each widget taps through to the relevant screen in the main app:

| Widget | Deep Link | Target Screen |
|--------|-----------|---------------|
| Recovery Score | `lifeos://recovery` | Recovery detail screen |
| Nutrition Progress | `lifeos://diary/today` | Diary day view |
| Supplement Schedule | `lifeos://supplements/today` | Supplement schedule |
| Next Workout | `lifeos://training/next` | Workout session screen |

---

## 5) Privacy Controls

```swift
// Settings → Widget Privacy
struct WidgetPrivacySettings: Codable {
    var showRecoveryScore: Bool = true       // Default: shown
    var showNutrition: Bool = true           // Default: shown
    var showSupplements: Bool = true         // Default: shown
    var showTraining: Bool = true            // Default: shown
    // Sensitive data — never shown by default
    var showMenstrualData: Bool = false      // Default: hidden
    var showHealthDiagnoses: Bool = false    // Default: hidden
}
```

When a widget type is hidden:
- Show a placeholder with the widget name and "Tap to open Life OS" instead of data.
- Do NOT show "Hidden for privacy" (that itself leaks information).

---

## 6) StandBy & Lock Screen Considerations

- **StandBy mode (iOS 17+):** Widgets should render well in the large clock-side format. Use high-contrast colors.
- **Lock Screen:** `accessoryCircular` and `accessoryRectangular` families only. Keep text minimal.
- **Always On Display:** Widgets must support `.redacted(reason: .privacy)` for when the phone is locked.

---

## 7) Implementation Checklist

- [ ] Create Widget Extension target with App Group capability.
- [ ] Implement `WidgetSnapshot` encoding/decoding in shared framework.
- [ ] Implement `TimelineProvider` for each widget kind.
- [ ] Add `WidgetCenter.shared.reloadTimelines` calls in main app data layer.
- [ ] Add deep link handling in main app's `onOpenURL`.
- [ ] Add widget privacy settings to Settings screen.
- [ ] Test all widget families at all Dynamic Type sizes.
- [ ] Test Lock Screen widgets in Always On Display mode.
- [ ] Test StandBy mode rendering.
