# LIFE OS — DESIGN SYSTEM SPECIFICATION

**Version:** 2.24
**Date:** February 9, 2026  
**Purpose:** Complete design system specification for visual design.

---

## COLOR PALETTE (UNIFIED)

> [!IMPORTANT]
> **Source of Truth.** Okabe-Ito palette is required for **semantics and status** (recovery zones, warnings, data viz).  
> Surfaces (background/cards) use **Warm Neutrals** (see `Surface Theme — Warm Neutrals`).

### Recovery Zones

| Zone | Status | Icon | Light Mode | Dark Mode | Use Case |
|------|--------|--------|------------|-----------|----------|
| **Optimal** | 75-100% | ✓ | #0072B2 | #56B4E9 | "Ready for anything" |
| **Ready** | 50-74% | ↗ | #009E73 | #009E73 | "Good to go" |
| **Caution** | 25-49% | ⚠ | #9A6800¹ | #F0E442 | "Take it easy" |
| **Critical** | 0-24% | ✕ | #D55E00 | #D55E00 | "Rest required" |

> ¹ **Accessibility override:** Original Okabe-Ito caution is `#E69F00`, but it fails WCAG AA ≥4.5:1 contrast on the warm neutral background `#FFF7F0`. Darkened to `#9A6800` in implementation. Dark mode retains `#F0E442` (passes on `#12100E`).

### UI Colors

| Purpose | Light Mode | Dark Mode | Contrast |
|------------|------------|-----------|----------|
| Text Primary | #000000 | #FFFFFF | ∞ |
| Text Secondary | #3C3C43/60% | #EBEBF5/60% | 4.5:1 |
| Text Tertiary | #3C3C43/30% | #EBEBF5/30% | 3:1 |
| Background | #FFF7F0 | #12100E | — |
| Card Background | #F7EEE4 | #1B1713 | — |
| Separator | #E6D8CB | #3A3128 | — |

### Surface Theme — Warm Neutrals (Default)

Warm surfaces are the base theme for the consumer version.  
Okabe‑Ito remains required for semantics, status, and charts.

| Token | Light | Dark | Use |
|------|-------|------|-----|
| `surface.background` | #FFF7F0 | #12100E | Primary screen background |
| `surface.card` | #F7EEE4 | #1B1713 | Cards, lists |
| `surface.card_elevated` | #FFFBF7 | #221C17 | Modals, sheets |
| `surface.separator` | #E6D8CB | #3A3128 | Separators |

**Legacy neutral (reference only):** Light `#FFFFFF / #F2F2F7 / #C6C6C8`, Dark `#000000 / #1C1C1E / #38383A`.

### Semantic Colors

| Purpose | Light Mode | Dark Mode |
|------------|------------|-----------|
| Link/Interactive | #007AFF | #0A84FF |
| Success | #34C759 | #30D158 |
| Warning | #FF9500 | #FF9F0A |
| Error/Destructive | #FF3B30 | #FF453A |

---

## TYPOGRAPHY

> [!NOTE]
> Use SF Pro only (iOS system font).  
> All sizes support Dynamic Type.

### Text Hierarchy

| Style | Size | Weight | Line Height | Use Case |
|-------|------|--------|-------------|----------|
| **Large Title** | 34pt | Bold | 41pt (1.2) | Screen titles |
| **Title 1** | 28pt | Bold | 34pt (1.2) | Sections |
| **Title 2** | 22pt | Bold | 28pt (1.3) | Cards |
| **Title 3** | 20pt | Semibold | 25pt (1.25) | Subheads |
| **Headline** | 17pt | Semibold | 22pt (1.3) | Emphasis text |
| **Body** | 17pt | Regular | 22pt (1.3) | Body text |
| **Callout** | 16pt | Regular | 21pt (1.3) | Secondary text |
| **Subhead** | 15pt | Regular | 20pt (1.3) | Metadata |
| **Footnote** | 13pt | Regular | 18pt (1.4) | Footnotes |
| **Caption 1** | 12pt | Regular | 16pt (1.3) | Small captions |
| **Caption 2** | 11pt | Regular | 13pt (1.2) | Microcopy |

### Hero Numbers (Recovery Score)

| Context | Size | Weight | Example |
|---------|------|--------|---------|
| Main Score | 72pt | Bold | "73" |
| Status Label | 20pt | Semibold | "✓ Ready" |
| Sparkline value | 17pt | Medium | "↗ +5%" |

### Tabular Figures

Use **tabular figures** (monospaced digits) for numeric data:
```swift
Text("1,420 / 2,100 kcal")
    .font(.system(.body, design: .rounded))
    .monospacedDigit()
```

---

## SPACING SYSTEM (8PT GRID)

All spacing is in 8pt multiples:

| Token | Value | Use Case |
|-------|-------|----------|
| `spacing-xs` | 4pt | Exception only (icons) |
| `spacing-sm` | 8pt | Between items in a group |
| `spacing-md` | 16pt | Between sections in a card |
| `spacing-lg` | 24pt | Between cards |
| `spacing-xl` | 32pt | Between screen sections |
| `spacing-xxl` | 40pt | Top offset from title |
| `spacing-xxxl` | 48pt | Bottom safe area padding |

### Corner Radius

| Token | Value | Use Case |
|-------|-------|----------|
| `radius-sm` | 10pt | Buttons, small elements |
| `radius-md` | 16pt | Cards |
| `radius-lg` | 20pt | Modals |
| `radius-xl` | 24pt | Large cards, sheets |
| `radius-full` | 9999pt | Fully round (avatars) |

---

## TOUCH TARGETS

> [!CRITICAL]
> Minimum touch target size: **44×44pt**

| Element | Minimum Size | Recommended |
|---------|--------------|-------------|
| Buttons | 44×44pt | 48×48pt |
| Icons | 44×44pt | 48×48pt |
| List rows | 44pt height | 56pt height |
| Form fields | 44pt height | 56pt height |
| Tab bar items | 44×44pt | 44×49pt |

### Spacing Between Targets

Minimum **8pt** between adjacent touch targets.

---

## ANIMATIONS

### Standard Curves

| Animation | Curve | Duration | Use Case |
|-----------|-------|----------|----------|
| Default | ease-in-out | 0.3s | Most transitions |
| Quick | ease-out | 0.2s | Fast interactions |
| Spring | spring(0.5, 0.8) | ~0.5s | Bouncy feel (cards) |
| Slow | ease-in-out | 0.5s | Modals |

### Life OS‑Specific Animations

| Element | Animation | Parameters |
|---------|-----------|------------|
| Recovery Score update | Counting | 0.8s, ease-out |
| Zone color transition | Morph | 0.4s, ease-in-out |
| Card expansion | Spring | response: 0.5, damping: 0.8 |
| Success checkmark | Draw-on | 0.3s, delay: 0.1s |
| Photo → Results | Card flip | 0.5s, spring |
| Pull-to-refresh | Spring | default iOS |

### Haptic Feedback Mapping

| Action | Haptic Type |
|--------|-------------|
| Button tap | Light Impact |
| Toggle switch | Light Impact |
| Success action | Success Notification |
| Error | Error Notification |
| Long press | Medium Impact |
| Destructive action | Heavy Impact |
| Scroll snap | Selection Changed |

### Reduce Motion

If Reduce Motion is enabled:
- Fade transitions instead of slide
- Remove spring animations
- Remove parallax effects

```swift
@Environment(\.accessibilityReduceMotion) var reduceMotion

.animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(), value: isExpanded)
```

---

## MICRO-INTERACTIONS

> [!IMPORTANT]
> Every interaction must show visual feedback within 100ms for perceived responsiveness.

### Touch States Timeline

```
Touch Down (0ms)     → Scale to 0.98, opacity 0.7
Touch Hold (100ms)   → Haptic: Selection
Touch Up (150ms)     → Scale to 1.0, trigger action
Touch Cancel         → Scale to 1.0, no action
```

### Recovery Score Update

```
Trigger: New data received from HealthKit

Timeline:
  0ms     → Old score starts fading (opacity 1.0 → 0.3)
  200ms   → Counter starts (old → new), easing: easeOut
  800ms   → Counter completes
  850ms   → Zone color morph begins (if zone changed)
  1250ms  → Zone color morph completes
  1300ms  → Status label fades in
  1400ms  → Haptic: Success (if improvement) or Soft (if decline)
  1500ms  → Animation complete

Reduce Motion:
  0ms     → Cross-fade old → new (300ms)
  350ms   → Complete
```

```swift
// Recovery Score Counter Animation
struct RecoveryScoreView: View {
    let score: Int
    @State private var animatedScore: Double = 0
    
    var body: some View {
        Text("\(Int(animatedScore))")
            .font(.system(size: 72, weight: .bold, design: .rounded))
            .monospacedDigit()
            .contentTransition(.numericText())
            .onChange(of: score) { oldValue, newValue in
                withAnimation(.easeOut(duration: 0.8)) {
                    animatedScore = Double(newValue)
                }
            }
    }
}
```

### Button Press Animation

```
Primary Button:
  Touch Down:
    - Scale: 1.0 → 0.98 (100ms, easeOut)
    - Background: #007AFF → #005EC4 (100ms)
    - Haptic: Light Impact
  
  Touch Up:
    - Scale: 0.98 → 1.0 (150ms, spring: 0.5, 0.7)
    - Background: #005EC4 → #007AFF (150ms)
    - Action triggered

  Loading State:
    - Text fades out (100ms)
    - Spinner fades in (100ms) 
    - Button disabled, opacity 0.8
    - No scale on interaction
```

### Card Expansion

```
Trigger: Tap on collapsed card

Timeline:
  0ms     → Haptic: Light Impact
  0-50ms  → Card scales to 0.98
  50ms    → Card starts expanding
  50-400ms → Height animates (spring: response 0.5, damping 0.8)
  100-350ms → Content fades in (staggered, 50ms delay per element)
  400ms   → Complete

Collapse (reverse):
  0ms     → Content starts fading out (all at once, 150ms)
  150ms   → Height starts contracting (250ms, easeInOut)
  400ms   → Complete
```

### Pull to Refresh

```
Drag Start:
  - Threshold: 60pt before trigger
  - Progress indicator: Circular, follows drag 0-100%
  - Elastic resistance after 60pt

At 60pt:
  - Haptic: Light Impact
  - Visual: Indicator snaps to full

Release before 60pt:
  - Indicator springs back (200ms)
  - No refresh

Release after 60pt:
  - Indicator stays
  - Spinner animation starts
  - Data refresh begins

Refresh Complete:
  - Haptic: Success Notification
  - Spinner → Checkmark morph (300ms)
  - Indicator dismisses (300ms delay, 200ms animation)
```

### Photo Capture Flow

```
Shutter Press:
  0ms     → Haptic: Medium Impact
  0-100ms → Screen flash white (opacity 0 → 0.8 → 0)
  100ms   → Capture complete

Photo Analysis:
  0ms     → Photo shrinks to card (spring, 400ms)
  400ms   → "Analyzing..." overlay appears
  400-1000ms+ → AI processing (shimmer on overlay)
  
Analysis Complete:
  0ms     → Haptic: Success
  0-300ms → Overlay fades out
  300ms   → Results card expands in
  300-500ms → Nutrition bars animate in (staggered 50ms)
```

### Toggle Switch

```
Touch:
  0ms     → Haptic: Light Impact
  0-250ms → Thumb slides (spring: 0.4, 0.8)
  0-250ms → Background color morphs
  250ms   → Complete
```

### Delete Swipe

```
Swipe Start:
  - Red background reveals progressively
  - Trash icon appears at 44pt

At 80pt:
  - Haptic: Medium Impact
  - Full delete zone visible

Release < 80pt:
  - Row springs back (300ms)

Release ≥ 80pt:
  - Confirmation dialog appears
  - OR row deletes immediately (if configured)

Delete Animation:
  0ms     → Row height collapses (250ms, easeInOut)
  0ms     → Row opacity fades (200ms)
  250ms   → Row removed from list
  300ms   → Haptic: Success
```

---

## GESTURE SYSTEM

### Supported Gestures

| Gesture | Use Case | Cancellable? |
|---------|----------|--------------|
| Tap | Primary action | N/A |
| Long Press | Context menu | Yes |
| Swipe Left | Delete/Archive | Yes |
| Swipe Right | Mark as done | Yes |
| Swipe Down | Dismiss modal | Yes |
| Pinch | Zoom charts | Yes |
| Edge Swipe | Back navigation | Yes |
| Pull Down | Refresh | Yes |

### Gesture Cancellation

> [!IMPORTANT]
> All destructive gestures MUST be cancellable. The user can change their mind mid‑gesture.

```swift
// Cancellable swipe-to-delete
.swipeActions(edge: .trailing, allowsFullSwipe: false) {
    Button(role: .destructive) {
        showDeleteConfirmation = true  // Confirm, don't delete immediately
    } label: {
        Label("Delete", systemImage: "trash")
    }
}

// Long press with cancel
.contextMenu {
    // Menu appears on release, cancelled if finger moves away
    Button("Edit") { }
    Button("Share") { }
    Button("Delete", role: .destructive) { }
}
```

### Edge Swipe Back

```
Gesture Start (from left edge, first 20pt):
  - Previous screen starts appearing (parallax: 0.3x speed)
  - Current screen follows finger
  - Interactive: user controls position

At 50% screen width:
  - Haptic: Light Impact
  - "Committed" threshold

Release before 50%:
  - Current screen springs back (300ms)
  - Previous screen slides out

Release after 50%:
  - Animation completes to back
  - Haptic: Selection
```

### Chart Interaction Gestures

```
Single Tap on Chart:
  - Show data point tooltip
  - Haptic: Selection

Long Press + Drag:
  - Scrubbing mode
  - Tooltip follows finger
  - Haptic: Selection (on each data point)
  - VoiceOver: Announce value at each point

Pinch:
  - Zoom in/out time range
  - Min: 7 days, Max: 365 days
  - Haptic: at min/max limits

Double Tap:
  - Reset to default zoom
  - Haptic: Light Impact
```

---

## HAPTIC FEEDBACK — FULL SPECIFICATION

### Haptic Types Reference

| Type | UIKit | SwiftUI | Feel |
|------|-------|---------|------|
| Light Impact | `.light` | `.impact(.light)` | Subtle tap |
| Medium Impact | `.medium` | `.impact(.medium)` | Noticeable |
| Heavy Impact | `.heavy` | `.impact(.heavy)` | Strong |
| Soft | `.soft` | `.impact(.soft)` | Gentle |
| Rigid | `.rigid` | `.impact(.rigid)` | Sharp |
| Selection | `.selectionChanged` | `.selection` | Tick |
| Success | `.success` | `.notification(.success)` | Double-tap up |
| Warning | `.warning` | `.notification(.warning)` | Double-tap down |
| Error | `.error` | `.notification(.error)` | Triple-tap |

### Haptics by Screen

#### Home Screen

| Action | Haptic | Timing |
|--------|--------|--------|
| Pull to refresh trigger | Light Impact | At 60pt threshold |
| Refresh complete | Success | Data loaded |
| Recovery card tap | Light Impact | Touch down |
| Zone change animation | Soft | At zone color morph |
| Notification badge tap | Light Impact | Touch down |

#### Nutrition Screen

| Action | Haptic | Timing |
|--------|--------|--------|
| Photo capture | Medium Impact | Shutter moment |
| AI analysis complete | Success | Results ready |
| AI low confidence | Warning | On confidence < 0.65 |
| Macro goal reached | Success | At 100% |
| Add meal | Light Impact | Touch down |
| Delete meal swipe | Medium Impact | At delete threshold |
| Undo delete | Light Impact | On undo tap |

#### Insights Screen

| Action | Haptic | Timing |
|--------|--------|--------|
| New insight reveal | Success | First view |
| Experiment start | Success | On confirmation |
| Experiment complete | Success + Success (double) | On completion |
| Chart scrubbing | Selection | Each data point |
| Chart zoom limit | Rigid | At min/max |

#### Settings Screen

| Action | Haptic | Timing |
|--------|--------|--------|
| Toggle switch | Light Impact | On toggle |
| Destructive action tap | Heavy Impact | On confirm button |
| Export data start | Light Impact | On start |
| Export complete | Success | On complete |
| Logout | Medium Impact | On confirm |
| Delete account | Heavy Impact + Error | On final confirm |

#### Notifications

| Action | Haptic | Timing |
|--------|--------|--------|
| Notification received | Default (system) | Delivery |
| Positive notification | Soft (custom) | If app in foreground |
| Warning notification | Warning | If app in foreground |
| Clear notification | Light Impact | On swipe |
| Clear all | Medium Impact | On confirm |

### SwiftUI Implementation

```swift
// Haptic manager for consistent usage
struct HapticManager {
    static let shared = HapticManager()
    
    private let lightImpact = UIImpactFeedbackGenerator(style: .light)
    private let mediumImpact = UIImpactFeedbackGenerator(style: .medium)
    private let heavyImpact = UIImpactFeedbackGenerator(style: .heavy)
    private let selection = UISelectionFeedbackGenerator()
    private let notification = UINotificationFeedbackGenerator()
    
    func prepare() {
        lightImpact.prepare()
        mediumImpact.prepare()
        selection.prepare()
    }
    
    func light() { lightImpact.impactOccurred() }
    func medium() { mediumImpact.impactOccurred() }
    func heavy() { heavyImpact.impactOccurred() }
    func selection() { selection.selectionChanged() }
    func success() { notification.notificationOccurred(.success) }
    func warning() { notification.notificationOccurred(.warning) }
    func error() { notification.notificationOccurred(.error) }
}

// Usage in SwiftUI
Button("Delete") {
    HapticManager.shared.heavy()
    deleteItem()
}
```

### Reduce Haptics Support

```swift
// Check system setting and reduce if needed
@Environment(\.accessibilityReduceMotion) var reduceMotion

func triggerHaptic(_ type: HapticType) {
    // Reduce Motion also implies reduce haptics for some users
    guard !reduceMotion else { return }
    // Trigger haptic
}
```

---

## ACCESSIBILITY ROTOR

> [!IMPORTANT]
> VoiceOver Rotor allows users to quickly navigate between content types.

### Custom Rotor Items

#### Home Screen Rotor

```swift
struct HomeView: View {
    var body: some View {
        ScrollView {
            // Content
        }
        .accessibilityRotor("Recovery Factors") {
            ForEach(factors) { factor in
                AccessibilityRotorEntry(factor.name, id: factor.id) {
                    // Navigate to factor
                }
            }
        }
        .accessibilityRotor("Quick Actions") {
            AccessibilityRotorEntry("Log Meal", id: "logMeal")
            AccessibilityRotorEntry("View Insights", id: "insights")
            AccessibilityRotorEntry("See Trends", id: "trends")
        }
    }
}
```

#### Nutrition Screen Rotor

```swift
.accessibilityRotor("Meals") {
    ForEach(todayMeals) { meal in
        AccessibilityRotorEntry(meal.name, id: meal.id)
    }
}
.accessibilityRotor("Nutrients") {
    AccessibilityRotorEntry("Protein: \(protein)g of \(proteinGoal)g", id: "protein")
    AccessibilityRotorEntry("Carbs: \(carbs)g of \(carbsGoal)g", id: "carbs")
    AccessibilityRotorEntry("Fat: \(fat)g of \(fatGoal)g", id: "fat")
    AccessibilityRotorEntry("Fiber: \(fiber)g of \(fiberGoal)g", id: "fiber")
}
```

#### Charts Rotor

```swift
// Allow VoiceOver users to navigate chart data points
.accessibilityRotor("Data Points") {
    ForEach(chartData) { point in
        AccessibilityRotorEntry(
            "\(point.date.formatted()): \(point.value) percent",
            id: point.id
        )
    }
}
.accessibilityRotor("Trends") {
    AccessibilityRotorEntry("Highest: \(max) on \(maxDate)", id: "max")
    AccessibilityRotorEntry("Lowest: \(min) on \(minDate)", id: "min")
    AccessibilityRotorEntry("Average: \(average)", id: "avg")
}
```

### Rotor Actions per Screen

| Screen | Rotor Name | Contents |
|--------|------------|----------|
| **Home** | Recovery Factors | Sleep, HRV, RHR factors |
| **Home** | Quick Actions | Log Meal, View Insights, See Trends |
| **Nutrition** | Meals | Today's logged meals |
| **Nutrition** | Nutrients | Protein, Carbs, Fat, Fiber |
| **Insights** | Patterns | Discovered patterns |
| **Insights** | Experiments | Active/completed experiments |
| **Trends** | Data Points | Individual chart points |
| **Trends** | Metrics | Recovery, Sleep, Nutrition |
| **Settings** | Sections | Health, Notifications, Preferences, Privacy |

### Magic Tap

```swift
// Two-finger double tap for primary action
.accessibilityAction(.magicTap) {
    if currentScreen == .nutrition {
        openCamera() // Quick photo log
    } else if currentScreen == .home {
        showRecoveryDetail()
    }
}
```

### Escape Gesture

```swift
// Two-finger Z gesture to dismiss
.accessibilityAction(.escape) {
    dismiss()
}
```

---

## TRANSITION SPECIFICATIONS

### Screen Transitions

| From | To | Transition | Duration |
|------|----|-----------| ---------|
| Tab A | Tab B | Cross-fade | 200ms |
| List | Detail | Push (slide) | 350ms |
| Any | Modal | Slide up | 350ms |
| Modal | Any | Slide down | 300ms |
| Any | Full screen | Zoom | 400ms |

### Modal Presentation

```swift
.sheet(isPresented: $showModal) {
    ModalView()
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(20)
        .interactiveDismissDisabled(hasUnsavedChanges)
}
```

### Interactive Dismissal

```
Drag threshold: 150pt
Velocity threshold: 500pt/s

Below both thresholds: Springs back
Above either threshold: Dismisses

Haptic: Light Impact at commit point

If interactiveDismissDisabled:
  - Rubber-band effect only
  - Haptic: Rigid at max drag
  - Alert shown on release
```

---


## ICONS

### SF Symbols

Life OS uses **SF Symbols 5.0+**. No custom icons required.

| Function | Symbol | Rendering |
|---------|--------|-----------|
| Recovery Optimal | checkmark.circle.fill | Multicolor |
| Recovery Ready | arrow.up.right.circle.fill | Multicolor |
| Recovery Caution | exclamationmark.triangle.fill | Multicolor |
| Recovery Critical | xmark.circle.fill | Multicolor |
| Camera | camera.fill | Hierarchical |
| Food Log | fork.knife | Hierarchical |
| Training | dumbbell.fill | Hierarchical |
| Supplements | pills.fill | Hierarchical |
| Lab Scan | doc.text.viewfinder | Hierarchical |
| Insights | lightbulb.fill | Hierarchical |
| Trends | chart.line.uptrend.xyaxis | Hierarchical |
| Settings | gearshape.fill | Hierarchical |
| Notification | bell.fill | Hierarchical |
| Calendar On Target | checkmark.circle | Hierarchical |
| Calendar Over Target | arrow.up.right.circle | Hierarchical |
| Calendar Under Target | arrow.down.right.circle | Hierarchical |
| Calendar Needs Review | questionmark.circle | Hierarchical |
| Calendar Planned | circle | Hierarchical |
| Calendar Missed | exclamationmark.circle | Hierarchical |

### Triple Indicator Pattern

Each status MUST include:
1. **Color** (quick recognition)
2. **Icon** (color‑blind support)
3. **Text label** (VoiceOver)

```
✓ Optimal   ↗ Ready   ⚠ Caution   ✕ Critical
  #0072B2     #009E73    #9A6800      #D55E00
```

---

## COMPONENTS — HEALTH ECOSYSTEM (NEW v2.1)

### Quick Log Sheet (Central Log)

**Purpose:** Single entry point for all data capture.

Actions:
- 📷 Food Photo
- 🧾 Barcode Scan
- 🎙️ Voice Log
- 🏋️ Workout
- 💊 Supplement
- 🧪 Lab Scan

**Specs:**
- Row height: 56pt
- Icon size: 24pt
- Tap target: full row
- Sheet detents: medium, large
- Drag indicator visible

### Food Photo Capture Overlay

**Elements:**
- Grid overlay (3x3)
- Lighting warning chip (if low light)
- Confidence hint after capture
- Retake + Manual entry buttons

**Copy rules:**
- Use short guidance: "Hold steady", "Include full plate"
- Never blame user

### Macro Progress Component

```
🥩 Protein  45/120g   ████████░░░░
🥑 Fat      38/70g    █████████░░░
🍞 Carbs    180/250g  ██████████░░
🥬 Fiber    12/30g    ████░░░░░░░░
```

**Specs:**
- Use monospaced digits
- Progress bar height: 6pt
- Color: neutral + accent on fill

### Calendar — Week Strip (Diaries)

**Purpose:** Fast day switching for diary screens (Nutrition, Training).

**Layout (per day cell):**
- Weekday letter (Caption 2)
- Day number (Headline, monospaced digit)
- Status icon (SF Symbol, 12–14pt) OR dot + icon combo

**Specs:**
- Height: 64pt
- 7 cells visible (no horizontal scroll inside a week)
- Selected cell: warm elevated surface (`surface.card_elevated`), subtle shadow
- Today indicator: small outline ring around day number (not color-only; include “Today” in a11y label)

**Interactions:**
- Tap: select day (Haptic: Selection)
- Swipe left/right on strip: move week (Haptic: Selection at week snap)
- Long press on a day: open contextual quick add (meal or workout) for that date

**Accessibility:**
- Each cell uses a full label: “Mon, Feb 18. Nutrition: 1,420 of 1,850 kcal. On target.”
- Provide adjustable action: next/previous day (VoiceOver).

### Calendar — Month Grid (Diaries)

**Purpose:** Overview + jump to a date.
**Presentation:** sheet with month header + grid (7 columns).

**Month cell states (common):**
- Selected: filled warm surface background
- Today: outline ring + “Today” in a11y label
- Disabled (future beyond available data, optional): reduced opacity + still tappable if planning is enabled

**Nutrition status icons:**
- `no_data`: none
- `on_target`: `checkmark.circle`
- `under_target`: `arrow.down.right.circle`
- `over_target`: `arrow.up.right.circle`
- `needs_review`: `questionmark.circle`

**Training status icons:**
- `rest`: none
- `planned`: `circle`
- `completed`: `checkmark.circle.fill`
- `missed`: `exclamationmark.circle`

**Unified Diary status icons (V2):**
- `no_data`: none
- `incomplete`: `circle`
- `needs_review`: `questionmark.circle`
- `complete`: `checkmark.circle`

**Rule:** icons carry meaning; color is secondary. If color is used, keep contrast and never encode meaning by color alone.

### Food Item Row

**Fields:**
- Item name
- Portion (g, ml, or unit)
- Calories + macros
- Confidence badge (if AI)

### Confidence Badge

**States:**
- High (>=0.85) = green dot + "High"
- Medium (0.65-0.84) = yellow dot + "Medium"
- Low (<0.65) = orange dot + "Low"

### Evidence Badge (Supplements)

**Labels:** A (Strong), B (Moderate), C (Weak), D (Anecdotal)  
**Style:** pill + letter + short label

### Workout Session Card

**Fields:**
- Workout type + duration
- Volume or calories
- RPE summary
- Link to details

### Set Row (Strength)

**Layout:**
- Set number
- Weight
- Reps
- RPE
- Flags: warmup, failure, dropset

### Training Plan Card

**Fields:**
- Plan name + week number
- Next session type
- Status (on track, adjusted)

### Recovery Adjustment Banner

**Use:** Appears when plan is auto-adjusted.

**Example:**
"Recovery low today. Reduced volume by 30%."

### Supplement Schedule Card

**Fields:**
- Time slot
- Supplements list (chips)
- With food indicator

### Supplement Chip

**Specs:**
- Capsule shape, 28pt height
- Icon + name
- Status color when taken

### Lab Marker Card

**Fields:**
- Marker name
- Value + unit
- Status (low/optimal/high)
- Trend sparkline (7/30/90)

### OCR Review Table

**Purpose:** User verification of extracted lab values.

**Layout:**
- Original label
- Parsed value + unit
- Editable input
- Confidence icon

**Validation rules:**
- If value is empty -> disable Save
- If unit is unknown -> show unit picker
- If confidence < 0.65 -> show "Review required" badge

**UI layout example:**
```
┌─────────────────────────────────────────┐
│ OCR Review                              │
│                                         │
│  1. Ferritin                            │
│     18  [ng/mL ▼]   Low                 │
│     Original: "Ferritin"                │
│                                         │
│  2. Vitamin D (25-OH)                   │
│     24  [ng/mL ▼]   Low                 │
│     Original: "25-OH Vitamin D"         │
│                                         │
│  [ Save Results ]  [ Cancel ]           │
└─────────────────────────────────────────┘
```

### Labs Duplicate Warning (Sheet)

**When:** user imports a report that looks similar to a recent test.

**Copy IDs:**
- `labs.duplicate_title`, `labs.duplicate_helper`
- `labs.duplicate_keep_both`, `labs.duplicate_replace`, `labs.duplicate_review`

**Layout (concept):**
```
┌─────────────────────────────────────────┐
│ Possible duplicate test                 │
│ We found a recent test that looks       │
│ similar. What would you like to do?     │
│                                         │
│ [ Keep both ]                           │
│ [ Replace previous ]                    │
│ [ Review differences ]                  │
└─────────────────────────────────────────┘
```

### Labs Storage Toggle Row

**Purpose:** communicate privacy posture without overwhelming.

**Default:** local-only

**Rows:**
- `labs.storage_local_only` (ON by default)
- `labs.storage_cloud_optin` (OFF by default)

---

## SCREEN SPECS — NUTRITION (NEW v2.16)

### Nutrition Diary (Day View)

**Primary CTA:** `nutrition.diary_log_primary`  
**Entry:** Nutrition tab  
**Default:** opens on today

```
┌─────────────────────────────────────────┐
│ Nutrition                     Feb 2026 ▾│
│ Mon Tue Wed Thu Fri Sat Sun             │
│  12  13  14  15  16  17  18 ●           │
│            (week strip)                 │
│                                         │
│  1,420 / 1,850 kcal   77%               │
│  Protein 95/120g  ━━━━━━━░░             │
│  Carbs   140/180g ━━━━━━━░░             │
│  Fat      45/60g  ━━━━━━━░░             │
│                                         │
│  Breakfast  08:30   420 kcal            │
│  Lunch      13:45   520 kcal            │
│  Snack      17:10   180 kcal            │
│                                         │
│  [ Log Meal ]                           │
└─────────────────────────────────────────┘
```

**Rules:**
- Week strip is always visible
- Month grid opens as a sheet from the month label
- Tapping a meal opens Meal Detail/Review

**States:**
- Empty: show `nutrition.empty_*`
- Offline: banner `error.offline_*`

### Month Grid (Sheet)

```
┌─────────────────────────────────────────┐
│ Feb 2026                     [ Done ]   │
│ Su Mo Tu We Th Fr Sa                    │
│                 1                       │
│  2  3  4  5  6  7  8                     │
│  9 10 11 12 13 14 15                     │
│ 16 17 18 ✓ 19 ↗ 20 21                    │
│ 23 24 25 26 27 28                        │
└─────────────────────────────────────────┘
```

- Icons are primary meaning; color is secondary
- Each date cell has full accessibility label

### Review Meal (After Photo/AI)

**Primary CTA:** `nutrition.meal_save_primary`  
**Secondary CTA:** `nutrition.meal_save_secondary`

```
┌─────────────────────────────────────────┐
│ Review Meal                     [ Edit ]│
│ Lunch • 13:45 • Restaurant              │
│                                         │
│  Total: 520 kcal   P45 F18 C35           │
│                                         │
│  Chicken breast   150g   248 kcal   (✓)  │
│  Salad mix        120g    60 kcal   (?)  │
│  Dressing          30g   212 kcal   (?)  │
│                                         │
│ [ Save Meal ]   [ Edit Items ]           │
└─────────────────────────────────────────┘
```

**Low confidence rule:**
- If overall confidence < 0.65, show `nutrition.ai_low_*` modal and force review before save.

---

### Log Meal — Method Picker (Sheet)

**Purpose:** one place to choose the fastest logging method without cluttering the diary.

**Entry:** `nutrition.diary_log_primary`  
**Presentation:** bottom sheet (medium detent), warm surface `surface.card_elevated`

**Layout (concept):**
```
┌─────────────────────────────────────────┐
│ Log Meal                        [ Close ]│
│                                         │
│ Meal type:  Breakfast  Lunch  Dinner    │
│            [ Snack ]                    │
│ Time:  13:45  [ Now ]                   │
│                                         │
│ [ Photo ]   [ Barcode ]                 │
│ [ Voice ]   [ Search ]                  │
│ [ Quick Add ] [ Recipe ]                │
└─────────────────────────────────────────┘
```

**Tile specs:**
- 2-column grid
- Each tile ≥ 64pt height, radius `radius-md`
- Icon + title + 1-line helper
- Selected/last-used method gets a subtle outline (not color-only)

**Haptics:** Selection on tile tap.

---

### Barcode Scanner (Nutrition)

**Purpose:** fast packaged food logging.

**Visual rules:**
- Avoid full-screen black; use warm vignette behind the camera cutout.
- Scanner frame uses `surface.separator` with 2pt stroke.
- “Detected” state: frame pulses once + selection haptic.

**Top-left:** Back  
**Top-right:** Flash (if available)  
**Bottom:** “Type code” link (accessibility fallback)

---

### Food Search (Nutrition)

**Purpose:** power-user manual logging (search + multi-item meal).

**Search bar:**
- iOS native search with warm surface background.
- Clear button always visible once text exists.

**Result row:**
- Left: food name + brand (secondary)
- Right: kcal per 100g (monospaced digits)
- Optional: small barcode icon if item has barcode

**Current Meal tray:**
- Sticky bottom tray with:
  - “Items: N” + kcal total
  - Primary CTA: “Review & Save”

**Accessibility:** tray CTA must be reachable as a single element, not split into tiny taps.

---

### Portion Editor (Shared)

**Purpose:** portion changes must be quick and obvious.

**Presentation:** bottom sheet (small/medium detent)

**Controls:**
- Unit toggle: Serving / Grams (Serving only if serving_size known)
- Big stepper (− / +) with 44×44pt minimum per control
- Numeric input (optional) with validation
- Quick chips: 50g, 100g, 150g (context-aware)

**Typography:** macros use tabular digits.

---

### Voice Log (Nutrition)

**Purpose:** hands-free logging.

**Layout rules:**
- Centered record button (very large target)
- Transcript area is editable, but stays lightweight (not a full editor)
- Primary CTA: “Continue” (disabled until transcript non-empty)

**Error state:**
- If transcription fails: show inline error + “Type instead” secondary CTA.

---

### Quick Add (Nutrition)

**Purpose:** one-tap logging for routine meals.

**Copy IDs:**
- `nutrition.quick_add_title`
- `nutrition.quick_add_repeat_last`

**List rules:**
- Templates sorted by recency
- Show kcal + item count for each template row

### Save As Template (Sheet)

**Copy IDs:**
- `nutrition.save_as_template`
- `nutrition.template_name_title`, `nutrition.template_name_placeholder`

**UI:**
- Single text field + Save button
- Default name suggestion (e.g. “Lunch template”)

---

### Product Source Badge (Nutrition)

**Purpose:** trust + transparency for food data sources without adding cognitive load.

**Badge types (derived from API response):**
- `open_food_facts`: “Open Food Facts”
- `lifeos_label_ocr`: “Community (Label scan)”
- `user_override`: “You”

**Style:**
- Pill: height 24pt, horizontal padding 10pt, radius 12pt
- Border: `surface.separator` 1pt
- Background: `surface.card_elevated`
- Text: SF Pro 12pt Semibold (tabular digits when showing numbers)
- Icon (optional): 14pt SF Symbol
  - OFF: `globe`
  - Community: `person.2`
  - You: `person.fill`

**Accessibility:**
- Single element label, e.g. “Data source: Open Food Facts.”

---

### Nutrition Label Scan (Barcode Fallback)

**Purpose:** CIS-critical “barcode not found” recovery flow.

**Entry:** Barcode not found state → CTA `nutrition.barcode_not_found_scan_label`  
**Copy IDs:** `nutrition.label_scan_title`, `nutrition.label_scan_helper`, `nutrition.label_scan_primary`, `nutrition.label_scan_secondary`

**Visual rules:**
- Same warm camera treatment as Barcode Scanner (avoid pure black)
- Use a **rectangular target frame** sized for nutrition tables (wider than tall)
- Add glare hint chip when histogram detects highlights (optional)

**Capture steps:**
- Step 1 (required): nutrition panel (table)
- Step 2 (optional): front pack (name/brand), clearly marked “Optional”

**Controls:**
- Capture (primary)
- Flash toggle
- Photo library
- Back

**Post-capture:**
- Preview + Retake / Use Photo
- Loading uses `loading.food_title` (same skeleton language, but with helper “Reading label…”)

**Hard rule:** no silent save. Always route into Review Product before persisting.

---

### Review Product (Label OCR)

**Purpose:** one-time verification to turn OCR extraction into a reusable barcode product.

**Copy IDs:** `nutrition.product_review_title`, `nutrition.product_review_helper`, `nutrition.product_save_primary`, `nutrition.product_save_secondary`

**Layout (concept):**
```
┌─────────────────────────────────────────┐
│ Review Product                 [ Cancel ]│
│ Community (Label scan)  (source badge)  │
│                                         │
│ Name        [ Kefir 2.5%            ]   │
│ Brand       [ BrandName             ]   │
│ Serving (g) [ 200                  ]   │
│                                         │
│ Per 100g                                 │
│ kcal   [ 53 ]  P [ 3.0 ]  F [ 2.5 ] C [4]│
│                                         │
│ Warnings (if any)                        │
│ ⚠ Serving size unclear                   │
│                                         │
│ [ Save product ]                         │
└─────────────────────────────────────────┘
```

**Input rules (validation):**
- Per-100g fields must be non-negative; calories max 900/100g (soft warn above 650)
- If kcal vs macros mismatch beyond tolerance, show warning inline (do not block save)
- If serving size is missing, allow save but keep serving null and show warning

**UX safety:**
- Low confidence: show a non-blocking “Needs review” banner; Save remains available.

---

### Meal Prep (Batch Recipes)

**Purpose:** “Cook once, log portions in seconds” with weight-based tracking.

**Primary entry points:**
- Log Meal → Method tile `nutrition.method_recipe`
- Nutrition tab (optional shortcut card)

#### Meal Prep Library

**Copy IDs:** `nutrition.batch_library_title`, `nutrition.batch_library_create_primary`, `nutrition.batch_library_empty_*`

**Row/card fields:**
- Name
- Cooked date (if known)
- Remaining weight (g) + optional “portions remaining” (if portions set)
- Per-portion macro chip (kcal + P/F/C)
- Quick action: “Log portion” (opens sheet)

**Card style:**
- Elevated warm card (`surface.card_elevated`)
- Progress bar: Remaining/Total (6pt height)

#### Create Meal Prep — Mode Picker

**Copy IDs:** `nutrition.batch_create_title`, `nutrition.batch_create_helper`, `nutrition.batch_mode_*`

**Layout:**
- Two large tiles:
  - Precise (best accuracy)
  - Quick (Photo) (draft, review required)

#### Create Meal Prep — Precise (Ingredients)

**Copy IDs:** `nutrition.batch_total_weight_label`, `nutrition.batch_total_portions_label`, `nutrition.batch_cooked_at_label`, `nutrition.batch_add_ingredient_title`

**Rules:**
- Total cooked weight is required (grams)
- Portions is optional in UX (default 1) but used for per-portion convenience
- Ingredient add uses the same Search/Barcode components as nutrition logging

#### Create Meal Prep — Quick (Photo Draft)

**Rule:** AI draft is never saved without user review (`needs_review = true`).

**UX:**
- Require total cooked weight (grams) before analyze
- Photo capture can be:
  - the final cooked batch in container(s), or
  - ingredients laid out (less ideal; lower confidence)

#### Review Batch (Before Save)

**Copy IDs:** `nutrition.batch_review_title`, `nutrition.batch_review_helper`, `nutrition.batch_save_primary`, `nutrition.batch_save_secondary`

**Layout blocks:**
- Totals (batch) + per-100g + per-portion
- Ingredient list with weights + edit affordance
- Confidence badge + warnings list

#### Batch Detail + Log Portion

**Quick actions:**
- `nutrition.batch_log_title` sheet: grams stepper + remaining weight context
- `nutrition.batch_duplicate` (“Cook again”) duplicates ingredients and resets tracking
- `nutrition.batch_archive` archives the batch from the active list

---

## SCREEN SPECS — DIARY (NEW v2.18)

### Diary (Unified Day View)

**Purpose:** One place to answer “what did I eat / train / take / how did I sleep?” for any day.

**Entry points:**
- Home avatar → `Diary`
- Central Log (long press) → `diary.view_day`
- From module diaries: “View full day”

**Primary CTAs (per section):**
- Meals: `nutrition.diary_log_primary`
- Training: `training.start_primary`
- Supplements: `supplements.log_primary`
- Labs: `labs.scan_primary` (only if pending/recommended)

**Layout (concept):**
```
┌─────────────────────────────────────────┐
│ Diary                        Feb 2026 ▾ │
│ Mon Tue Wed Thu Fri Sat Sun             │
│  12  13  14  15  16  17  18 ●           │
│            (week strip)                 │
│                                         │
│  Recovery  73% ✓ Ready                  │
│  Sleep     7h 20m (Deep 18% • REM 22%)  │
│                                         │
│  Meals (3)                               │
│  Lunch 13:45 • 520 kcal                  │
│  [ Log Meal ]                            │
│                                         │
│  Training (1)                            │
│  Strength • 65 min • TRIMP 55            │
│  [ Start Workout ]                       │
│                                         │
│  Supplements                             │
│  08:00  ✓ Vitamin D3                     │
│  21:00  ○ Magnesium                       │
│  [ Taken ]                               │
└─────────────────────────────────────────┘
```

**Rules:**
- Calendar navigation uses the shared Week Strip + Month Grid components.
- The screen must remain “calm”: show only 1–2 rows per section and use “View all” for overflow.
- TRIMP is a training load score (duration + intensity); see `life_os_health_ecosystem_spec.md` for definition.
- Sections are reorderable in Settings (optional, V1+).

**States:**
- Empty: show `diary.empty_*` and offer exactly one next best action.
- Offline: show `error.offline_*` banner.
- Needs review: show badge if the day includes low-confidence AI data (nutrition OCR/vision, labs OCR).

---

## SCREEN SPECS — SLEEP (NEW v2.19)

### Sleep Detail (Read-First)

**Purpose:** clear sleep understanding + actionable, non-medical improvements.

**Entry:**
- From Unified Diary: tap “Sleep” row

**Title:** `sleep.title`

**Layout (concept):**
```
┌─────────────────────────────────────────┐
│ Sleep                                   │
│                                         │
│  Score  85   (0–100)                    │
│  7h 20m • Bed 23:40 • Wake 07:05        │
│                                         │
│  Sleep stages                           │
│  Deep 18%  ▓▓▓▓                         │
│  REM  22%  ▓▓▓▓▓                        │
│  Light 55% ▓▓▓▓▓▓▓▓▓▓                   │
│  Awake  5% ▓                            │
│                                         │
│  Last 7 days  (mini chart)              │
│                                         │
│  What affected sleep                    │
│  • Late dinner within 2h of bed         │
│  • Low deep sleep (below baseline)      │
│                                         │
│  Try tonight                            │
│  • Earlier dinner by 60 minutes         │
│  • 10 min wind-down routine             │
└─────────────────────────────────────────┘
```

**States:**
- No Sleep data: show empty state (`sleep.missing_*`) + CTA `sleep.connect_primary`
- Stages unavailable: hide stage breakdown and show `sleep.stages_unavailable`
- Partial permissions: banner `sleep.partial_*` (non-blocking)

### Sleep Diary (V2)

**Purpose:** month/week/day navigation for sleep with trend-first presentation.

**Entry:**
- Home → Sleep

**Day view layout (concept):**
```
┌─────────────────────────────────────────┐
│ Sleep                        Feb 2026 ▾│
│ Mon Tue Wed Thu Fri Sat Sun             │
│  12  13  14  15  16  17  18 ●           │
│                                         │
│  Score  85   (0–100)                    │
│  7h 20m                                 │
│                                         │
│  Stages (if available)                  │
│  Deep 18% • REM 22% • Light 55% • Awake │
│                                         │
│  Last 7 days (mini chart)               │
└─────────────────────────────────────────┘
```

**Month grid icon rules (sleep):**
- `good` → `checkmark.circle`
- `low` → `arrow.down.right.circle`
- `no_data` → none

## SCREEN SPECS — TRAINING (NEW v2.2)

### Workout Conflict Resolution (Import vs Manual)

**When:** wearable import overlaps a manual workout on the same day.
**Goal:** keep data quality and user trust (never silently delete).

**Modal copy IDs:** `training.merge_title`, `training.merge_helper`, `training.merge_primary`, `training.merge_secondary`, `training.merge_tertiary`

```
┌─────────────────────────────────────────┐
│ Duplicate workout found                 │
│ Keep imported, keep manual, or merge.   │
│                                         │
│ Imported: Cardio • 18:02–19:05          │
│ Manual:   Strength • 18:00–19:05        │
│                                         │
│ [ Merge ]                               │
│ [ Keep Manual ]                         │
│ [ Keep Imported ]                       │
└─────────────────────────────────────────┘
```

**Default recommendation:** Merge (keeps sets + attaches calories/HR).
**Undo:** always available after destructive choices.

### Training Diary (Day View)

**Purpose:** Calendar-based daily view of planned vs logged workouts.

**Primary CTA:** `training.start_primary`  
**Secondary CTA:** `training.start_secondary` (template)  
**Filters:** `training.diary_filter_planned`, `training.diary_filter_logged`

```
┌─────────────────────────────────────────┐
│ Training                     Feb 2026 ▾│
│ Mon Tue Wed Thu Fri Sat Sun             │
│  12  13  14  15  16  17  18 ●           │
│            (week strip)                 │
│                                         │
│ Today summary                            │
│  65 min • TRIMP 55 • Load: Optimal       │
│                                         │
│ [ Planned ] [ Logged ]                   │
│                                         │
│ Planned                                  │
│ Upper A • 18:00                 Planned  │
│ [ Start ]                                │
│                                         │
│ Logged                                   │
│ Strength • 65 min • Volume 1040     ✓    │
│                                         │
│ [ Start ]   [ Choose Template ]          │
└─────────────────────────────────────────┘
```

**Rules:**
- Planned and logged can both appear on the same day.
- Planned items come from `training_plan_sessions`.
- Logged items come from `workout_sessions`.
- Filter chips are optional; default shows both sections.
- If recovery is `critical`, starting a planned session shows a warning banner and suggests mobility.

**States:**
- Empty day: use `empty.training_*`.
- Offline: allow local logging; show `syncFailed` messaging.
- Conflict detected (import vs manual): show conflict modal (above).

### Training Month Grid (Sheet)

```
┌─────────────────────────────────────────┐
│ Feb 2026                     [ Done ]   │
│ Su Mo Tu We Th Fr Sa                    │
│                 1                       │
│  2  3  4  5  6  7  8                     │
│  9 10 11 12 13 14 15                     │
│ 16 17 18 ✓ 19 ○ 20 ! 21                  │
│ 23 24 25 26 27 28                        │
└─────────────────────────────────────────┘
```

- `✓` completed
- `○` planned
- `!` missed
- Each date cell has an accessibility label that explains the icon meaning.

### Start Workout (Manual)

**Purpose:** start logging fast with minimal setup.

**Copy IDs:** `training.start_*`, `training.start_planned_primary`, `training.start_empty_secondary`

**Layout rules:**
- One primary “Start” action
- If a planned session exists, show it as the recommended path
- Templates are optional and shown below

### Exercise Picker (Search)

**Copy IDs:** `training.exercise_picker_title`, `training.exercise_search_placeholder`

**Row specs:**
- Name (primary)
- Muscle/equipment (secondary)
- Right-side “Add” CTA (44×44pt target)

### Rest Timer Pill (Optional)

**Purpose:** reduce context switching; keep user in flow.

**Copy ID:** `training.rest_timer_label`

**Behavior:**
- Starts when a set is marked done
- Dismissible (swipe) but can be reopened from header

### Training Log (Daily)

```
┌─────────────────────────────────────────┐
│ Training                               │
│                                         │
│  Today: Push Day                        │
│  Recovery: 73% ✓ Ready                  │
│                                         │
│  ┌───────────────────────────────────┐  │
│  │ Bench Press                       │  │
│  │ Set 1: 60kg x 8   RPE 7            │  │
│  │ Set 2: 65kg x 8   RPE 8            │  │
│  │ [Add Set]                          │  │
│  └───────────────────────────────────┘  │
│                                         │
│  ┌───────────────────────────────────┐  │
│  │ Pull-ups                           │  │
│  │ Set 1: BW x 8     RPE 8            │  │
│  │ Set 2: BW x 6     RPE 9            │  │
│  │ [Add Set]                          │  │
│  └───────────────────────────────────┘  │
│                                         │
│  [ Finish Workout ]                     │
└─────────────────────────────────────────┘
```

### Training Plan (Calendar)

```
┌─────────────────────────────────────────┐
│ Training Plan                           │
│  4-Week Hypertrophy Block               │
│  Week 2 of 4                             │
│                                         │
│  Mon  Push      ✓ Done                  │
│  Wed  Pull      • Today                 │
│  Fri  Legs      ○ Planned               │
│  Sat  Mobility  ○ Planned               │
│                                         │
│  Recovery Adjustment                    │
│  "Recovery low. Volume -30% today."     │
│                                         │
│  [ View Session ]                       │
└─────────────────────────────────────────┘
```

### Training Detail (Session)

```
┌─────────────────────────────────────────┐
│ Workout Detail                          │
│  Push Day • 65 min                       │
│  Recovery: 73% ✓ Ready                   │
│                                         │
│  Bench Press                             │
│  1) 60kg x 8  RPE 7                      │
│  2) 65kg x 8  RPE 8                      │
│  3) 65kg x 6  RPE 9                      │
│                                         │
│  Incline DB Press                        │
│  1) 22kg x 10 RPE 7                      │
│  2) 22kg x 8  RPE 8                      │
│                                         │
│  Notes: "Felt strong"                    │
│                                         │
│  [ Edit ]   [ Share Summary ]            │
└─────────────────────────────────────────┘
```

---

## SCREEN SPECS — SUPPLEMENTS (NEW v2.2)

### Supplement Schedule

```
┌─────────────────────────────────────────┐
│ Supplements                             │
│                                         │
│  Morning 08:00                           │
│  [ Vitamin D3 ] [ Omega-3 ]             │
│                                         │
│  Evening 21:00                           │
│  [ Magnesium ] [ Zinc ]                 │
│                                         │
│  Adherence Today: 3/5                   │
│                                         │
│  [ Log Intake ]                         │
└─────────────────────────────────────────┘
```

### Supplements Daily (Schedule + Taken)

**Purpose:** Diary-friendly view where the user can mark scheduled items as taken.
**Data:** `GET /api/supplements/daily?date=...`

```
┌─────────────────────────────────────────┐
│ Supplements                     Today   │
│  Adherence Today: 3/5                   │
│                                         │
│  08:00                                   │
│  [✓ Vitamin D3]  [✓ Omega-3]            │
│                                         │
│  21:00                                   │
│  [○ Magnesium]   [○ Zinc]               │
│                                         │
│  Unscheduled                             │
│  15:10  Zinc (✓)                         │
│                                         │
│  [ Log Intake ]                          │
└─────────────────────────────────────────┘
```

**Interaction:** tapping a chip toggles taken status (Haptic: Light Impact).
**Safety:** no dosing suggestions; dose is user-entered only.

### Supplement Detail

```
┌─────────────────────────────────────────┐
│ Magnesium Glycinate                     │
│ Evidence: B (Moderate)                  │
│                                         │
│  Schedule                               │
│  • 21:00 (with food)                    │
│                                         │
│  Adherence (7d)  5/7                    │
│                                         │
│  Notes                                  │
│  "Helps sleep quality"                  │
│                                         │
│  [ Log Intake ]  [ Edit Schedule ]      │
└─────────────────────────────────────────┘
```

---

## SCREEN SPECS — LABS (NEW v2.2)

### Lab Scan Review

```
┌─────────────────────────────────────────┐
│ Labs                                    │
│  Scan Review                             │
│                                         │
│  Vitamin D (25-OH)    24 ng/mL   LOW    │
│  Ferritin             18 ng/mL   LOW    │
│  Hemoglobin           14 g/dL    OK     │
│                                         │
│  [ Edit Values ]   [ Save Results ]     │
└─────────────────────────────────────────┘
```

### Biomarker Trend

```
┌─────────────────────────────────────────┐
│ Vitamin D (25-OH)                       │
│  24 ng/mL  (Low)                         │
│  ▁▂▃▄▅▃▄  90-day trend                   │
│                                         │
│  Last test: Jan 18, 2026                │
│  Previous: Nov 02, 2025                 │
│                                         │
│  [ Compare ]    [ Add Note ]            │
└─────────────────────────────────────────┘
```

### Lab Detail (Marker)

```
┌─────────────────────────────────────────┐
│ Lab Marker                              │
│  Ferritin                               │
│  18 ng/mL  (Low)                         │
│                                         │
│  Reference Range: 30-300 ng/mL          │
│  Last 3 results                          │
│  • Jan 18, 2026: 18 (Low)               │
│  • Nov 02, 2025: 28 (Low)               │
│  • Aug 12, 2025: 36 (OK)                │
│                                         │
│  Insights                               │
│  "Low ferritin correlates with fatigue" │
│                                         │
│  [ Add Note ]  [ Compare ]              │
└─────────────────────────────────────────┘
```

### OCR Capture Flow (Labs)

```
┌─────────────────────────────────────────┐
│ Scan Lab Report                         │
│                                         │
│  [ Camera Preview + Grid ]              │
│                                         │
│  Tip: include the results table          │
│                                         │
│  [ Capture ]   [ Upload PDF ]           │
└─────────────────────────────────────────┘
```

### OCR Error / Low Confidence

```
┌─────────────────────────────────────────┐
│ Scan Needs Review                       │
│                                         │
│  We found values but confidence is low. │
│  Please review before saving.           │
│                                         │
│  [ Review Values ]  [ Retake Photo ]    │
│  [ Upload PDF ]                         │
└─────────────────────────────────────────┘
```

---

## COPY LIBRARY — NEW MODULES (NEW v2.7)

> [!IMPORTANT]
> The definitive copy source of truth is `life_os_copy_catalog.md`.
> This section mirrors the catalog for quick reference only.

**Copy ID usage:**
- Every CTA and title must map to a `copy_id`
- No inline strings in UI specs unless tagged with `copy_id`

**Localization constraints:**
- Titles must fit in 2 lines at Dynamic Type L
- CTAs must fit in 1 line at Dynamic Type L
- Truncate with ellipsis only on helper text (never on CTAs)

### Training

| Context | Title | Helper | Primary CTA | Secondary CTA |
|---------|-------|--------|-------------|---------------|
| Start workout | "Start Workout" | "Log sets, reps, or import from Apple Health." | "Start" | "Choose Template" |
| Finish workout | "Finish Workout" | "Summary will update your training load." | "Finish" | "Review Sets" |
| Recovery adjustment | "Plan Adjusted" | "Recovery is low today. Volume reduced by 30%." | "View Session" | "Keep Original" |
| Plan generation failed | "Could not build plan" | "We need your available days and equipment access." | "Add details" | "Choose template" |
| Set error | "Set data is incomplete. Please review." | — | "Fix Set" | "Save as is" |

### Supplements

| Context | Title | Helper | Primary CTA | Secondary CTA |
|---------|-------|--------|-------------|---------------|
| Add stack | "Add Supplements" | "Create your schedule for reminders and insights." | "Add" | "Browse Catalog" |
| Log intake | "Log Intake" | "Mark as taken to improve adherence." | "Taken" | "Skip" |
| Interaction warning | "Timing Tip" | "Calcium may reduce iron absorption." | "Adjust Timing" | "Keep Schedule" |

### Labs

| Context | Title | Helper | Primary CTA | Secondary CTA |
|---------|-------|--------|-------------|---------------|
| Scan start | "Scan Lab Report" | "Include the results table in the frame." | "Capture" | "Upload PDF" |
| OCR review | "Review Values" | "Confirm extracted values before saving." | "Save Results" | "Edit Values" |
| Lab detail | "Marker Detail" | "Trends are based on your historical tests." | "Compare" | "Add Note" |

---

## ACCESSIBILITY LABELS — COMPONENT EXAMPLES (NEW v2.7)

**Training Set Row:**
```
"Set 2, 65 kilograms, 8 reps, RPE 8"
```

**Supplement Chip:**
```
"Magnesium, 21:00, taken"
```

**Lab OCR Row:**
```
"Ferritin, 18 ng per milliliter, low, review required"
```

**Lab Marker Card:**
```
"Vitamin D 25-OH, 24 ng per milliliter, low, 90-day trend"
```

---

## SCREENS — SPEC STATUS

### ✅ Specified

| Screen | Document | Status |
|-------|----------|--------|
| Onboarding (6 steps) | PRD v7.13 | ✅ Wireframes |
| Home (Recovery Card) | PRD v7.13 | ✅ Wireframe |
| Nutrition Progress | PRD v7.13 | ✅ Wireframe |
| Notifications | PRD v7.13 | ✅ Full spec |
| Training Log | Design System v2.24 | ✅ Wireframe |
| Training Plan | Design System v2.24 | ✅ Wireframe |
| Supplements | Design System v2.24 | ✅ Wireframe |
| Labs | Design System v2.24 | ✅ Wireframe |
| Lab Detail | Design System v2.24 | ✅ Wireframe |
| OCR Capture | Design System v2.24 | ✅ Wireframe |
| Training Detail | Design System v2.24 | ✅ Wireframe |
| Supplement Detail | Design System v2.24 | ✅ Wireframe |

---

## WATCHOS DESIGN (V2 Companion)

> Source of truth for watchOS behavior: `life_os_watchos_spec.md`
> This section covers visual design tokens for the watch surfaces only.

### Watch Surfaces

| Surface | Type | Description |
|---------|------|-------------|
| **Complication** | Corner/Circular | Recovery score + zone color + icon |
| **Glance** | Full-screen summary | Recovery score, top 3 metrics, next action |
| **One-Tap Actions** | Button list | Pre-configured safe actions (routed to iPhone) |

### Watch Color Tokens

Recovery zone colors on watchOS use the same Okabe-Ito palette as iOS:

| Zone | Watch Color | Notes |
|------|-------------|-------|
| Optimal | `#56B4E9` | Always use dark-mode variant (OLED) |
| Ready | `#009E73` | Same in light/dark |
| Caution | `#F0E442` | Dark-mode variant for OLED contrast |
| Critical | `#D55E00` | Same in light/dark |

### Watch Typography

| Style | Size | Weight | Use |
|-------|------|--------|-----|
| Score (hero) | 42pt | Bold | Recovery score number |
| Label | 15pt | Semibold | Zone label ("Ready", "Caution") |
| Metric value | 13pt | Medium | Individual metric values |
| Metric label | 11pt | Regular | Metric names |
| Caption | 9pt | Regular | Timestamps, secondary info |

### Complication Layouts

**Circular (CornerComplication):**
- Center: recovery score (2-3 digits)
- Ring: filled arc proportional to score (0–100)
- Ring color: zone color
- Gauge style: `CircularProgressViewStyle`

**Rectangular (AccessoryRectangular):**
- Line 1: "Recovery" + score + icon
- Line 2: zone label + top concern (e.g., "Sleep debt")
- Background tint: zone color at 15% opacity

### Glance Screen Layout

```
┌──────────────────────────┐
│  Recovery Score (hero)    │
│  ✓ Ready  73             │
│──────────────────────────│
│  Sleep    7.2h    ↗      │
│  HRV     lnRMSSD 4.1     │
│  Load    ACWR 1.1         │
│──────────────────────────│
│  [Next Action Button]     │
│  "Log supplements"        │
└──────────────────────────┘
```

- Touch targets: ≥ 38×38pt (Apple Watch minimum)
- Font: SF Compact (watchOS system font)
- Background: pure black (`#000000`) for OLED power efficiency

### One-Tap Action Buttons

| Action | Label | Icon | Route |
|--------|-------|------|-------|
| Log supplement | "Take {name}" | 💊 | → iPhone → POST /api/supplements/log |
| Start workout | "Start {template}" | 🏋️ | → iPhone → Opens workout screen |
| Log water | "Log water" | 💧 | → iPhone → POST /api/hydration/log |

**Constraint:** All one-tap actions route to iPhone via WatchConnectivity. Watch never calls backend directly.

### Accessibility (watchOS)

- VoiceOver: All elements must have accessibility labels
- Recovery score announces: "{score} percent, {zone_name} zone"
- Complication ring announces: "Recovery {score} percent"
- Touch targets: ≥ 38×38pt per Apple Watch HIG
- Reduce Motion: Disable gauge animations when enabled

---

### ✅ Specification Status

| Screen | Status | Location |
|-------|--------|----------|
| **Settings (Profile)** | ✅ Complete | SCREEN: SETTINGS (PROFILE) section |
| **Settings (Notifications)** | ✅ Complete | SCREEN: NOTIFICATION SETTINGS section |
| **Settings (Control Level)** | ✅ Complete | SCREEN: CONTROL LEVEL section |
| **Settings (Privacy & Data)** | ✅ Complete | SCREEN: PRIVACY & DATA MANAGEMENT section |
| **Settings (Data Sources)** | ✅ Complete | SCREEN: DATA SOURCES section |
| **Trends/Charts** | ✅ Complete | SCREEN: TRENDS / CHARTS section |
| **Insights Detail** | ✅ Complete | SCREEN SPECS: INSIGHTS DETAIL section |
| **Experiment Detail** | ✅ Complete | SCREEN SPECS: EXPERIMENT DETAIL section |
| **Experiment Results** | ✅ Complete | SCREEN SPECS: EXPERIMENT RESULTS section |
| **Training Log** | ✅ Complete | SCREEN SPECS — TRAINING section |
| **Training Plan** | ✅ Complete | SCREEN SPECS — TRAINING section |
| **Supplements** | ✅ Complete | SCREEN SPECS — SUPPLEMENTS section |
| **Labs** | ✅ Complete | SCREEN SPECS — LABS section |
| **Lab Detail** | ✅ Complete | SCREEN SPECS — LABS section |
| **OCR Capture** | ✅ Complete | SCREEN SPECS — LABS section |
| **Widgets (iOS)** | ✅ Complete | iOS WIDGETS section |
| **Watch App** | ✅ Complete | WATCHOS DESIGN (V2 Companion) section |
| **Empty States** | ✅ Complete | EMPTY STATES — FULL SPECIFICATIONS section |
| **Loading States** | ✅ Complete | LOADING STATES — FULL SPECIFICATIONS section |
| **Error States** | ✅ Complete | ERROR STATES — FULL SPECIFICATIONS section |
| **Offline Mode** | ✅ Complete | OFFLINE MODE UX section |

---

## SCREEN: NOTIFICATION SETTINGS (NEW v2.24)

> UX logic reference: `life_os_ux_screens.md` §10.1
> API: `GET/PATCH /api/settings/notifications`
> Copy IDs: `settings.notifications_*`

### Layout

```
┌─────────────────────────────────────────────────────────┐
│  ← Notifications                                        │
│─────────────────────────────────────────────────────────│
│                                                         │
│  Daily limit: 6 notifications max                       │
│                                                         │
│  MORNING BRIEF                                          │
│  ┌─────────────────────────────────────────────────┐   │
│  │  🌅  Morning Brief                        ON ○   │   │
│  │      Time                             07:00  →   │   │
│  │      Content         Recovery + Top insight  →   │   │
│  └─────────────────────────────────────────────────┘   │
│                                                         │
│  POSITIVE REINFORCEMENT                                 │
│  ┌─────────────────────────────────────────────────┐   │
│  │  🎉  Celebrations                       ON ○     │   │
│  │      Streaks, goals, milestones                  │   │
│  │      Max: 3/day                                  │   │
│  └─────────────────────────────────────────────────┘   │
│                                                         │
│  GENTLE NUDGES                                          │
│  ┌─────────────────────────────────────────────────┐   │
│  │  💡  Nudges                             ON ○     │   │
│  │      Meal logging, supplement reminders          │   │
│  │      Max: 2/day                                  │   │
│  └─────────────────────────────────────────────────┘   │
│                                                         │
│  CRITICAL ALERTS                                        │
│  ┌─────────────────────────────────────────────────┐   │
│  │  ⚠️  Critical only                       OFF ○   │   │
│  │      When ON: disables all except critical       │   │
│  │      Forces Control Level → Advisory             │   │
│  └─────────────────────────────────────────────────┘   │
│                                                         │
│  QUIET HOURS                                            │
│  ┌─────────────────────────────────────────────────┐   │
│  │  🌙  Quiet Hours                        ON ○     │   │
│  │      Start                          22:00    →   │   │
│  │      End                            07:00    →   │   │
│  └─────────────────────────────────────────────────┘   │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

### Interaction Rules

| Rule | Behavior |
|------|----------|
| Critical Only toggle ON | Disables Celebrations, Nudges, Morning Brief toggles (greyed + disabled). Shows inline note: "Only critical health alerts will be sent." Forces Control Level to Advisory. |
| Critical Only toggle OFF | Re-enables all toggles to previous state |
| Quiet Hours time pickers | iOS native time picker wheel (medium detent sheet) |
| Morning Brief time | System time picker, 24h format, default 07:00 |
| Daily cap display | Always visible at top; read-only (hard cap ≤ 6) |

### Row Specifications

Same as Settings Profile rows (48pt height, 24×24 icon, system UISwitch for toggles).

### States

- **Default:** All ON, Quiet Hours 22:00–07:00
- **Critical Only:** Only critical toggle active, others visually disabled (opacity 0.4)
- **Error saving:** Inline error banner with retry CTA

### VoiceOver

- Toggle: "Morning Brief, switch button, on. Double tap to toggle."
- Section header: "Morning Brief section, heading level 2"
- Time picker: "Morning Brief time, 7 AM. Double tap to change."

---

## SCREEN: CONTROL LEVEL (NEW v2.24)

> UX logic reference: `life_os_ux_screens.md` §10.2–10.3
> API: `PATCH /api/settings/notifications`
> Copy IDs: `settings.control_*`

### Layout

```
┌─────────────────────────────────────────────────────────┐
│  ← Control Level                                        │
│─────────────────────────────────────────────────────────│
│                                                         │
│  How much should Life OS guide your day?                │
│                                                         │
│  ┌─────────────────────────────────────────────────┐   │
│  │  💬  Advisory                             ● ○    │   │
│  │      Suggestions only. You decide.               │   │
│  │      No app restrictions.                        │   │
│  └─────────────────────────────────────────────────┘   │
│                                                         │
│  ┌─────────────────────────────────────────────────┐   │
│  │  🛡️  Protective                           ○ ○    │   │
│  │      Proactive reminders + gentle blocks.        │   │
│  │      Snooze actions, bedtime nudge.              │   │
│  └─────────────────────────────────────────────────┘   │
│                                                         │
│  ┌─────────────────────────────────────────────────┐   │
│  │  🔒  Guardian                              ○ ○    │   │
│  │      Full protection with app blocking.          │   │
│  │      Requires Focus Control permission.          │   │
│  └─────────────────────────────────────────────────┘   │
│                                                         │
│  ┌─ ℹ️ ─────────────────────────────────────────────┐  │
│  │  You can change this at any time.                │  │
│  │  "Pause for today" is always available.          │  │
│  └──────────────────────────────────────────────────┘  │
│                                                         │
│  [ Pause Control for Today ]                            │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

### Guardian Selection Flow

When user selects Guardian:

```
┌─────────────────────────────────────────────────────────┐
│                                                         │
│                        🔒                               │
│                                                         │
│              Focus Control Required                     │
│                                                         │
│     Guardian mode uses iOS Screen Time to               │
│     block distracting apps during recovery.             │
│                                                         │
│     What this means:                                    │
│     • Selected apps blocked during Quiet Hours          │
│     • You can always override with a 15-min delay       │
│     • Your data stays on your device                    │
│                                                         │
│     ┌─────────────────────────────────────────────┐     │
│     │         Enable Focus Control               │     │
│     └─────────────────────────────────────────────┘     │
│                                                         │
│              Not now →                                  │
│              Learn more →                               │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

**If permission denied:** Inline banner: "Focus Control permission required. Falling back to Protective." with "Open Settings" CTA.

### Guardian — App Selection

```
┌─────────────────────────────────────────────────────────┐
│  ← Blocked Apps                                         │
│─────────────────────────────────────────────────────────│
│                                                         │
│  Select apps to block during recovery periods:          │
│                                                         │
│  ┌─────────────────────────────────────────────────┐   │
│  │  📱  Social Media                       [ ✓ ]    │   │
│  │  🎮  Games                              [ ✓ ]    │   │
│  │  📺  Streaming                          [   ]    │   │
│  │  📰  News                               [   ]    │   │
│  └─────────────────────────────────────────────────┘   │
│                                                         │
│  SCHEDULE                                               │
│  ┌─────────────────────────────────────────────────┐   │
│  │  Block during Quiet Hours only           ○ ●     │   │
│  │  Block when Recovery ≤ Caution           ○ ○     │   │
│  └─────────────────────────────────────────────────┘   │
│                                                         │
│  [ Save ]                                               │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

### Interaction Rules

| Rule | Behavior |
|------|----------|
| Radio selection | Single-select across Advisory/Protective/Guardian |
| Guardian without permission | Shows permission flow; if denied, reverts to Protective with inline banner |
| Critical Only mode active | Forces Advisory; Guardian/Protective disabled with note |
| Pause CTA | Secondary button; pauses until midnight local time |
| App selection | Uses `FamilyActivityPicker` (system API); categories shown, not individual apps |

---

## SCREEN: PRIVACY & DATA MANAGEMENT (NEW v2.24)

> Copy IDs: `settings.privacy_*`, `privacy.*`

### Layout

```
┌─────────────────────────────────────────────────────────┐
│  ← Privacy & Data                                       │
│─────────────────────────────────────────────────────────│
│                                                         │
│  YOUR DATA                                              │
│  ┌─────────────────────────────────────────────────┐   │
│  │  🔐  Data stays on your device                  │   │
│  │      Health data is processed locally.           │   │
│  │      Only anonymized summaries are synced.       │   │
│  └─────────────────────────────────────────────────┘   │
│                                                         │
│  DATA MANAGEMENT                                        │
│  ┌─────────────────────────────────────────────────┐   │
│  │  📊  Export My Data                         →    │   │
│  │  🗑️  Delete Account                         →    │   │
│  └─────────────────────────────────────────────────┘   │
│                                                         │
│  PHOTO & SCAN RETENTION                                 │
│  ┌─────────────────────────────────────────────────┐   │
│  │  📷  Food Photos                                │   │
│  │      Deleted after 30 days                       │   │
│  │      (macros kept permanently)                   │   │
│  │                                                  │   │
│  │  🔬  Lab Scans                                   │   │
│  │      Deleted after 90 days                       │   │
│  │      (extracted values kept permanently)          │   │
│  └─────────────────────────────────────────────────┘   │
│                                                         │
│  SENSITIVE DATA                                         │
│  ┌─────────────────────────────────────────────────┐   │
│  │  🩸  Menstrual Cycle Data                       │   │
│  │      On-device only. Never uploaded.             │   │
│  │                                                  │   │
│  │  Share derived phase for scoring      OFF ○      │   │
│  └─────────────────────────────────────────────────┘   │
│                                                         │
│  LEGAL                                                  │
│  ┌─────────────────────────────────────────────────┐   │
│  │  📜  Privacy Policy                         →    │   │
│  │  📜  Terms of Service                       →    │   │
│  └─────────────────────────────────────────────────┘   │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

### Export Flow

Tapping "Export My Data" triggers:
1. Confirmation sheet: "We'll prepare your data export. You'll receive an email when it's ready (usually within 24 hours)."
2. Primary CTA: "Request Export"
3. API: `POST /api/account/export`
4. After request: row changes to "Export requested — check your email" with progress indicator

### Delete Account Flow

Tapping "Delete Account" triggers the destructive dialog (already specified in Settings Profile section).

**Grace period note:** After scheduling deletion, show inline banner:
```
Your account is scheduled for deletion on {date}.
You have 30 days to change your mind.
[ Cancel Deletion ]
```

### Row Specifications

Same as Settings Profile rows. Info cards use `surface.card` background with `spacing-md` padding.

---

## SCREEN SPECS: INSIGHTS DETAIL (NEW v2.24)

> UX logic reference: `life_os_ux_screens.md` §9.2
> API: `GET /api/insights/{id}`
> Copy IDs: `insights.*`

### Layout

```
┌─────────────────────────────────────────────────────────┐
│  ← Insight                                              │
│─────────────────────────────────────────────────────────│
│                                                         │
│  ┌─ Nutrition ─────────────────────────────────────┐   │
│  │                                                  │   │
│  │  Late Dinners Affect Your Sleep                 │   │  ← Title 1
│  │                                                  │   │
│  │  Confidence: ●●●○ High                          │   │
│  │                                                  │   │
│  └──────────────────────────────────────────────────┘   │
│                                                         │
│  PATTERN OBSERVED                                       │
│  ┌──────────────────────────────────────────────────┐  │
│  │  On nights when you ate dinner after 21:00,     │  │
│  │  your deep sleep dropped by 18% on average.      │  │
│  │                                                   │  │
│  │  ▁▂▃▅▇▅▃▁   (mini chart: dinner time vs sleep)  │  │
│  └──────────────────────────────────────────────────┘  │
│                                                         │
│  WHY IT MATTERS                                         │
│  ┌──────────────────────────────────────────────────┐  │
│  │  Deep sleep is when your body does most of its   │  │
│  │  physical repair. Eating close to bedtime raises  │  │
│  │  core temperature, which delays sleep onset.      │  │
│  └──────────────────────────────────────────────────┘  │
│                                                         │
│  RECOMMENDED ACTION                                     │
│  ┌──────────────────────────────────────────────────┐  │
│  │  🎯  Try finishing dinner by 20:00               │  │
│  │      for the next 7 days.                         │  │
│  └──────────────────────────────────────────────────┘  │
│                                                         │
│  ┌─────────────────────────────────────────────┐       │
│  │          Start Experiment                    │       │
│  └─────────────────────────────────────────────┘       │
│                                                         │
│  Got it — dismiss insight →                             │
│                                                         │
│  Why am I seeing this? →                                │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

### Specifications

| Element | Spec |
|---------|------|
| Category tag | Pill shape, 8pt radius, module color, SF Pro 13pt Semibold |
| Title | Title 1 (28pt Bold) |
| Confidence dots | 4 dots, filled = active (Okabe-Ito semantic), empty = `surface.separator` |
| Pattern card | `surface.card`, `radius-md`, `spacing-md` padding |
| Mini chart | 80pt height, Swift Charts `LineMark`, same chart specs as Trends |
| Section headers | 13pt ALL CAPS, Tertiary color, `spacing-xl` top margin |
| Recommended action | Highlight card with left accent bar (2pt, accent color) |
| Primary CTA | Standard Primary Button (full width) |
| Dismiss | Tertiary button |
| "Why am I seeing this?" | Ghost button → expands educational context inline |

### Interaction Rules

| Rule | Behavior |
|------|----------|
| Low confidence (< 0.65) | "Start Experiment" CTA hidden; show note: "More data needed before experimenting." |
| Dismiss | Confirmation: "Dismiss this insight? You can find it in History." |
| Start Experiment | Navigates to Experiment Setup (pre-filled with insight hypothesis) |
| Mini chart | Tappable data points with tooltip (same as Trends charts) |

### States

- **Loading:** Skeleton with shimmer (title + 2 card blocks + CTA)
- **Error:** Inline error banner with retry
- **Already dismissed:** Greyed header + "Dismissed on {date}" label

### VoiceOver

```
"Insight: Late Dinners Affect Your Sleep. Category: Nutrition. Confidence: High.
Pattern: On nights when you ate dinner after 21:00, your deep sleep dropped by 18%.
Button: Start Experiment. Button: Dismiss insight. Button: Why am I seeing this."
```

---

## SCREEN SPECS: EXPERIMENT DETAIL (NEW v2.24)

> UX logic reference: `life_os_ux_screens.md` §9.4
> API: `GET /api/experiments/{id}`, `POST /api/experiments/{id}/log`
> Copy IDs: `experiments.*`

### Active Experiment Layout

```
┌─────────────────────────────────────────────────────────┐
│  ← Experiment                                           │
│─────────────────────────────────────────────────────────│
│                                                         │
│  Earlier Dinner Timing                                  │
│  Day 4 of 14                                            │
│                                                         │
│  HYPOTHESIS                                             │
│  ┌──────────────────────────────────────────────────┐  │
│  │  "Finishing dinner by 20:00 will improve my       │  │
│  │   deep sleep percentage by at least 10%."         │  │
│  └──────────────────────────────────────────────────┘  │
│                                                         │
│  PROTOCOL                                               │
│  ┌──────────────────────────────────────────────────┐  │
│  │  ✓  Eat last meal before 20:00                    │  │
│  │  ✓  No snacks after dinner                        │  │
│  │  ◯  Log dinner time each day                      │  │
│  │  Duration: 14 days                                │  │
│  └──────────────────────────────────────────────────┘  │
│                                                         │
│  TODAY'S LOG                                            │
│  ┌──────────────────────────────────────────────────┐  │
│  │  Did you follow the protocol today?               │  │
│  │                                                   │  │
│  │  [ Yes ✓ ]    [ Partially ]    [ No ]             │  │
│  │                                                   │  │
│  │  Dinner time:  [ 19:30 ]                          │  │
│  │                                                   │  │
│  │  Notes (optional):  _______________               │  │
│  │                                                   │  │
│  │  [ Log Today ]                                    │  │
│  └──────────────────────────────────────────────────┘  │
│                                                         │
│  PROGRESS                                               │
│  ┌──────────────────────────────────────────────────┐  │
│  │  ●●●●○○○○○○○○○○                                  │  │
│  │  Day 1  2  3  4  5  6  7  8  9  10 11 12 13 14   │  │
│  │  ✓ ✓ ✓ ·                                         │  │
│  │                                                   │  │
│  │  Compliance: 3/3 days (100%)                      │  │
│  └──────────────────────────────────────────────────┘  │
│                                                         │
│  Stop experiment →                                      │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

### Specifications

| Element | Spec |
|---------|------|
| Title | Title 1 (28pt Bold) |
| Day counter | Subhead (15pt Regular), Secondary color |
| Hypothesis card | `surface.card_elevated`, italic text, `radius-md` |
| Protocol checklist | `surface.card`, checkmarks in accent color |
| Compliance chips | Three equal-width buttons (tertiary style), selected = accent fill |
| Time input | Compact time picker, same as Notification settings |
| Progress dots | 12pt circles; filled = logged, half = partial, empty = pending, `×` = missed |
| Log CTA | Primary Button, disabled until compliance selected |
| Stop | Destructive tertiary, confirmation required |

### Interaction Rules

| Rule | Behavior |
|------|----------|
| Already logged today | Log section shows "Logged ✓" with edit link |
| Missed day | Progress dot shows `×`; no judgment; tooltip: "Missed — that's OK, keep going!" |
| Stop experiment | Confirmation: "Stop this experiment? You'll still see partial results." |
| Daily log time | Should take < 20 seconds (3 taps + optional note) |

### States

- **Not yet started:** Show hypothesis + "Begin Experiment" CTA
- **Active (today not logged):** Full layout above
- **Active (today logged):** Log section collapsed, shows summary
- **Completed:** Auto-navigates to Results screen
- **Stopped early:** Shows partial results banner + "View Results" CTA

### VoiceOver

```
"Experiment: Earlier Dinner Timing. Day 4 of 14. Compliance: 100 percent.
Log today: Did you follow the protocol? Three options: Yes, Partially, No.
Button: Log Today."
```

---

## SCREEN SPECS: EXPERIMENT RESULTS (NEW v2.24)

> UX logic reference: `life_os_ux_screens.md` §9.5
> API: `GET /api/experiments/{id}`
> Copy IDs: `experiments.results_*`

### Layout

```
┌─────────────────────────────────────────────────────────┐
│  ← Results                                              │
│─────────────────────────────────────────────────────────│
│                                                         │
│                       🎉                                │
│               Experiment Complete                       │
│                                                         │
│  Earlier Dinner Timing                                  │
│  14 days • 12/14 compliance (86%)                       │
│                                                         │
│  RESULT                                                 │
│  ┌──────────────────────────────────────────────────┐  │
│  │                                                   │  │
│  │  ✓  Positive Effect Detected                      │  │
│  │                                                   │  │
│  │  Deep sleep improved by +22% on protocol days     │  │
│  │  vs baseline days.                                 │  │
│  │                                                   │  │
│  │  Effect size: Medium (Cohen's d = 0.6)            │  │
│  │  Confidence: High (p < 0.05)                      │  │
│  │                                                   │  │
│  └──────────────────────────────────────────────────┘  │
│                                                         │
│  COMPARISON CHART                                       │
│  ┌──────────────────────────────────────────────────┐  │
│  │                                                   │  │
│  │  Deep Sleep %                                     │  │
│  │   25% ┬──────────────────────────                 │  │
│  │       │  ▓▓▓▓▓▓▓▓                                │  │  ← Protocol
│  │   20% ┼──────────────────────────                 │  │
│  │       │  ▒▒▒▒▒▒                                  │  │  ← Baseline
│  │   15% ┼──────────────────────────                 │  │
│  │       │                                           │  │
│  │   10% ┴──────────────────────────                 │  │
│  │        Baseline      Protocol                     │  │
│  │                                                   │  │
│  │  ▓ Protocol days (avg)  ▒ Baseline (avg)          │  │
│  │                                                   │  │
│  └──────────────────────────────────────────────────┘  │
│                                                         │
│  SUGGESTED NEXT STEP                                    │
│  ┌──────────────────────────────────────────────────┐  │
│  │  📌  Make this a habit                            │  │
│  │      Set a daily reminder for dinner by 20:00.    │  │
│  └──────────────────────────────────────────────────┘  │
│                                                         │
│  ┌─────────────────────────────────────────────┐       │
│  │          Set Reminder                        │       │
│  └─────────────────────────────────────────────┘       │
│                                                         │
│  Run again with different params →                      │
│  Share results →                                        │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

### Result States

| Outcome | Icon | Color | Message |
|---------|------|-------|---------|
| Positive | ✓ | recoveryOptimal (#0072B2) | "Positive Effect Detected" |
| Neutral | → | recoveryReady (#009E73) | "No Significant Change" |
| Negative | ↘ | recoveryCaution (#9A6800) | "Unexpected Result — Consider Adjusting" |
| Insufficient data | ? | Text Secondary | "Not Enough Data — Try Running Again" |

### Chart Specifications

- Bar chart (grouped), same chart spec tokens as Trends section
- Two bars: Baseline (secondary fill) vs Protocol (accent fill)
- Accessible: `AXChartDescriptor` with comparison values
- Height: 200pt

### VoiceOver

```
"Experiment complete. Earlier Dinner Timing. Result: Positive effect detected.
Deep sleep improved by 22 percent on protocol days.
Effect size: medium. Confidence: high.
Button: Set Reminder. Link: Run again. Link: Share results."
```

---

## ERROR STATES — FULL SPECIFICATIONS (NEW v2.24)

> Error taxonomy reference: `life_os_error_handling.md`
> Copy IDs: `error.*`

### Principles

1. **Be specific** — tell the user what happened and what they can do
2. **Never blame the user** — use passive voice for system errors
3. **Offer a next step** — always provide at least one actionable CTA
4. **Stay on-brand** — supportive tone, warm surfaces, no scary red unless destructive

### Network Error (Full Screen)

```
┌─────────────────────────────────────────────────────────┐
│                                                         │
│                        📶                               │
│                   (wifi.slash)                           │
│                                                         │
│              You're Offline                             │
│                                                         │
│     Don't worry — your data is saved locally            │
│     and will sync when you're back online.              │
│                                                         │
│     What still works offline:                           │
│     ✓ Log meals, workouts, supplements                 │
│     ✓ View today's diary                               │
│     ✓ Check your recovery score                        │
│                                                         │
│     ┌─────────────────────────────────────────────┐     │
│     │              Try Again                      │     │
│     └─────────────────────────────────────────────┘     │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

### Network Error (Inline Banner)

```
┌─────────────────────────────────────────────────────────┐
│  ⚠️  You're offline. Changes saved locally.     [ ✕ ]   │
└─────────────────────────────────────────────────────────┘
```

| Parameter | Value |
|-----------|-------|
| Height | 44pt |
| Background | `recoveryCaution` (#9A6800 light / #F0E442 dark) at 15% opacity |
| Icon | `wifi.slash` 16pt |
| Text | SF Pro 15pt Regular |
| Dismiss | `✕` button, 44×44pt target |
| Position | Sticky top, below navigation bar |

### Permission Denied Error

```
┌─────────────────────────────────────────────────────────┐
│                                                         │
│                        🔒                               │
│                   (lock.fill)                           │
│                                                         │
│              {Permission} Access Required               │
│                                                         │
│     Life OS needs {permission_description}              │
│     to {feature_benefit}.                               │
│                                                         │
│     ┌─────────────────────────────────────────────┐     │
│     │          Open Settings                      │     │
│     └─────────────────────────────────────────────┘     │
│                                                         │
│              Skip for now →                             │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

**Variants:**

| Permission | Description | Benefit |
|------------|-------------|---------|
| HealthKit | access to your health data | provide personalized recovery insights |
| Camera | camera access | scan food and lab reports |
| Notifications | notification permission | send timely reminders |
| Motion & Fitness | motion data | track your daily activity |
| Focus Control | Screen Time access | block distracting apps during recovery |

### AI Analysis Error

```
┌─────────────────────────────────────────────────────────┐
│                                                         │
│                        🤔                               │
│                                                         │
│              AI Couldn't Analyze This                   │
│                                                         │
│     {specific_reason}                                   │
│                                                         │
│     ┌─────────────────────────────────────────────┐     │
│     │             Try Again                       │     │
│     └─────────────────────────────────────────────┘     │
│                                                         │
│              Enter manually instead →                   │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

**Reason variants:**

| Error | Reason text |
|-------|-------------|
| Blurry photo | "The photo was a bit blurry. Try again with steady hands and good lighting." |
| No food detected | "We couldn't identify food in this photo. Try taking a closer photo of your plate." |
| Lab OCR failed | "The scan was hard to read. Try a clearer photo, or upload a PDF." |
| Label no table | "No nutrition table found. Try capturing just the label area." |
| Parse failed (voice) | "Couldn't understand that. Try speaking more slowly, or type instead." |
| Rate limited | "Our AI is temporarily busy. Please try again in a moment." |

### Sync Error (Inline)

```
┌─────────────────────────────────────────────────────────┐
│  ⚠️  Sync failed. {N} changes pending.    [ Retry ]     │
└─────────────────────────────────────────────────────────┘
```

| Parameter | Value |
|-----------|-------|
| Background | `recoveryCaution` at 15% opacity |
| Retry CTA | Tertiary button, 44×44pt target |
| Auto-retry | Every 30 seconds when app is foregrounded |
| Dead letter | After 5 failed retries, show: "Some changes couldn't sync. [ View Details ]" |

### Server Error (500)

```
┌─────────────────────────────────────────────────────────┐
│                                                         │
│                        ⚙️                               │
│                   (gearshape)                           │
│                                                         │
│              Something Went Wrong                       │
│                                                         │
│     We're having trouble on our end.                    │
│     Your data is safe — please try again.               │
│                                                         │
│     ┌─────────────────────────────────────────────┐     │
│     │              Try Again                      │     │
│     └─────────────────────────────────────────────┘     │
│                                                         │
│              Contact support →                          │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

### Validation Error (Inline Field)

```
┌─────────────────────────────────────────────────────────┐
│                                                         │
│  Serving size                                           │
│  ┌─────────────────────────────────────────────────┐   │
│  │  -500                                           │   │  ← Red border (1pt)
│  └─────────────────────────────────────────────────┘   │
│  ⚠️  Must be a positive number                         │   │  ← Error text (13pt, Error color)
│                                                         │
└─────────────────────────────────────────────────────────┘
```

| Parameter | Value |
|-----------|-------|
| Border color | Error (#FF3B30 light / #FF453A dark) |
| Error text | SF Pro 13pt Regular, Error color |
| Icon | `exclamationmark.triangle.fill` 13pt |
| Spacing | 4pt below field |

### Error Illustration Specs

Same illustration style as Empty States (minimalist, warm, abstract, no faces). Each error screen uses a relevant SF Symbol (never custom icons for errors).

---

## OFFLINE MODE UX (NEW v2.24)

> Sync engine reference: `life_os_sync_engine_spec.md`
> Copy IDs: `sync.*`, `error.offline_*`

### Offline Indicator (Persistent)

```
┌─────────────────────────────────────────────────────────┐
│  📶 Offline — changes saved locally              [ ✕ ]  │
└─────────────────────────────────────────────────────────┘
```

**Behavior:**
- Appears at top of screen (below nav bar) when device has no connectivity
- Auto-dismisses when connectivity restored + sync succeeds
- User can dismiss manually (reappears on next screen transition if still offline)

### Offline Capability Matrix

| Feature | Offline Support | Notes |
|---------|----------------|-------|
| View recovery score | ✅ Full | Cached from last sync |
| View diary (today) | ✅ Full | Local GRDB |
| Log meal (manual) | ✅ Full | Queued in outbox |
| Log meal (photo AI) | ⚠️ Partial | Photo saved; AI analysis queued for when online |
| Log meal (barcode) | ⚠️ Partial | Cached barcodes work; unknown codes queued |
| Log workout | ✅ Full | Local GRDB |
| Log supplement | ✅ Full | Local GRDB |
| View trends/charts | ✅ Full | Cached data |
| View insights | ✅ Cached | Shows last-synced insights |
| Start experiment | ❌ Requires online | Needs server-side setup |
| Lab OCR scan | ⚠️ Partial | Photo saved; OCR queued |
| Export data | ❌ Requires online | Server-side job |
| Delete account | ❌ Requires online | Server-side operation |

### Visual States

#### Online (Normal)
No indicator. All features available.

#### Offline
```
┌─ Screen ────────────────────────────────────────────────┐
│  📶 Offline — changes saved locally              [ ✕ ]  │
│─────────────────────────────────────────────────────────│
│                                                         │
│  [Normal screen content]                                │
│                                                         │
│  Features requiring online show:                        │
│  ┌──────────────────────────────────────────────────┐  │
│  │  ☁️  Requires Internet                           │  │
│  │  This feature needs a connection.                 │  │
│  │  Your other data is saved and will sync later.    │  │
│  └──────────────────────────────────────────────────┘  │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

#### Reconnected (Syncing)

```
┌─────────────────────────────────────────────────────────┐
│  🔄 Syncing {N} changes...                              │
└─────────────────────────────────────────────────────────┘
```

| Parameter | Value |
|-----------|-------|
| Background | `recoveryReady` (#009E73) at 15% opacity |
| Duration | Visible until sync completes or fails |
| Spinner | System `ProgressView` inline, 16pt |

#### Sync Complete

```
┌─────────────────────────────────────────────────────────┐
│  ✓ All changes synced                                   │
└─────────────────────────────────────────────────────────┘
```

| Parameter | Value |
|-----------|-------|
| Background | `recoveryOptimal` (#0072B2) at 15% opacity |
| Auto-dismiss | After 3 seconds |
| Haptic | Success Notification |

#### Sync Failed (Partial)

```
┌─────────────────────────────────────────────────────────┐
│  ⚠️  {N} changes couldn't sync.               [ Retry ] │
└─────────────────────────────────────────────────────────┘
```

### Outbox Badge

When offline changes are pending, show badge on relevant tab:

| Tab | Badge condition |
|-----|-----------------|
| Nutrition | Pending food logs in outbox |
| Training | Pending workout logs in outbox |
| Supplements | Pending supplement logs in outbox |

Badge style: Small red dot (8pt), no number (to avoid anxiety).

### Conflict Resolution Modal

When sync detects a conflict (offline edit vs server state):

```
┌─────────────────────────────────────────────────────────┐
│                                                         │
│              Sync Conflict                              │
│                                                         │
│     This item was changed on another device             │
│     while you were offline.                             │
│                                                         │
│     Your version:                                       │
│     Lunch — 520 kcal (edited 14:30)                     │
│                                                         │
│     Server version:                                     │
│     Lunch — 480 kcal (edited 14:25)                     │
│                                                         │
│     ┌─────────────────────────────────────────────┐     │
│     │          Keep My Version                    │     │
│     └─────────────────────────────────────────────┘     │
│                                                         │
│     ┌─────────────────────────────────────────────┐     │
│     │          Use Server Version                 │     │
│     └─────────────────────────────────────────────┘     │
│                                                         │
│              View differences →                         │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

**Default:** Server version wins (last-write-wins) unless user explicitly chooses. Modal only shown for significant changes (>10% calorie difference or edited fields conflict).

### Accessibility (Offline)

- Offline banner: VoiceOver announces "You are offline. Changes are saved locally."
- Sync progress: VoiceOver announces "Syncing {N} changes"
- Sync complete: VoiceOver announces "All changes synced successfully"
- Disabled features: VoiceOver announces "Requires internet connection. Not available offline."

---

## EMPTY STATES

> See **EMPTY STATES — FULL SPECIFICATIONS** section below for all wireframes, VoiceOver annotations, and per-screen specs.

---

## LOADING STATES

> See **LOADING STATES — FULL SPECIFICATIONS** section below for skeleton wireframes, shimmer animation code, and skeleton colors.


---

## TAB BAR STRUCTURE

> [!IMPORTANT]
> Tab Bar is the primary navigation surface. Max 5 items per Apple HIG.

### Tab Items

| # | Label | Icon (SF Symbol) | Badge | Description |
|---|-------|------------------|-------|-------------|
| 1 | **Home** | `house.fill` | Recovery alert | Home screen with Recovery Score |
| 2 | **Nutrition** | `fork.knife` | — | Nutrition and food logging |
| 3 | **Log** | `plus.circle.fill` | — | **Central button** (oversized) |
| 4 | **Training** | `dumbbell.fill` | Planned session | Workouts and plans |
| 5 | **Supplements** | `pills.fill` | Due today | Supplements + labs |

### Tab Bar Specifications

```
┌─────────────────────────────────────────────────────────┐
│                                                         │
│  🏠      🍴      ⊕        🏋️       💊                   │
│ Home  Nutrition  Log   Training Supplements             │
│                                                         │
└─────────────────────────────────────────────────────────┘
     44pt    44pt   56pt    44pt     44pt   (touch targets)
```

| Parameter | Value |
|-----------|-------|
| Height | 49pt (standard) + Safe Area |
| Background Light | `surface.background` (warm neutral) with blur |
| Background Dark | `surface.background` (warm neutral) with blur |
| Selected icon | SF Symbol .fill variant |
| Unselected icon | SF Symbol outlined |
| Selected color Light | #007AFF |
| Selected color Dark | #0A84FF |
| Unselected color | `Text Secondary` (#3C3C43/60% light, #EBEBF5/60% dark) |
| Label font | SF Pro Text, 10pt, Medium |
| Icon size | 24×24pt (Log button: 32×32pt) |

**Profile access:** Top-right avatar on Home (NavigationStack push to Settings).

### Central Log Button (Special)

```swift
// Oversized central button for quick logging
Button {
    showQuickLog = true
} label: {
    Image(systemName: "plus.circle.fill")
        .font(.system(size: 32))
        .foregroundStyle(.white, Color.accentColor)
}
.frame(width: 56, height: 56)
.background(Color.accentColor)
.clipShape(Circle())
.shadow(color: .black.opacity(0.15), radius: 8, y: 4)
```

**Quick Log Actions (sheet):**
- Food photo
- Barcode scan
- Voice log
- Workout
- Supplement
- Lab scan

---

## NAVIGATION PATTERNS

### NavigationStack Structure

```swift
// Primary navigation pattern
NavigationStack {
    ContentView()
        .navigationTitle("Home")
        .navigationBarTitleDisplayMode(.large) // or .inline
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { } label: {
                    Image(systemName: "bell.fill")
                }
            }
        }
}
```

### Navigation Rules

| Rule | Implementation |
|------|----------------|
| Max depth | 3 levels (Home → Detail → Sub‑detail) |
| Back button | System chevron.left + previous title |
| Swipe back | Always enabled (edge swipe) |
| Title style | .large on Level 1, .inline on Level 2+ |
| Transition | Push (default iOS) |

### Modal Presentations

| Type | Usage | Detent |
|------|-------|--------|
| Sheet (medium) | Quick actions, filters | .medium |
| Sheet (large) | Forms, detailed content | .large |
| Full screen | Onboarding, critical flows | — |

### Navigation Hierarchy

```
Tab Bar (Level 0)
├── Home
│   ├── Recovery Detail → Factor Detail
│   └── Notifications List → Notification Detail
│   ├── Insights List → Insight Detail → Experiment Setup
│   └── Experiments List → Experiment Results
├── Nutrition
│   ├── Daily Log → Meal Detail → Edit Meal
│   └── History → Day Detail
├── Log (Modal)
│   ├── Photo → Review → Confirm
│   └── Manual Entry
└── Profile (Settings)
    ├── Account
    ├── Notifications Settings
    ├── Integrations → Integration Detail
    └── Privacy → Data Management
```

---

## BUTTON SYSTEM

### Button Hierarchy

| Type | Use Case | Style |
|------|----------|-------|
| **Primary** | Main action (1 per screen) | Filled, accent color |
| **Secondary** | Alternative actions | Outlined, accent color |
| **Tertiary** | Less important actions | Text only |
| **Destructive** | Delete, cancel subscription | Red filled/outlined |
| **Ghost** | Inline actions, links | Text with underline |

### Button Specifications

#### Primary Button

```
┌─────────────────────────────────────┐
│          Connect HealthKit          │
└─────────────────────────────────────┘
```

| State | Background | Text | Border |
|-------|------------|------|--------|
| Normal | #007AFF | #FFFFFF | — |
| Pressed | #005EC4 | #FFFFFF | — |
| Disabled | #007AFF (30%) | #FFFFFF (50%) | — |
| Loading | #007AFF | Spinner | — |

**Specs:**
- Height: 50pt
- Corner radius: 12pt
- Font: SF Pro, 17pt, Semibold
- Padding horizontal: 24pt
- Shadow: none

#### Secondary Button

```
┌─────────────────────────────────────┐
│            Skip for now             │
└─────────────────────────────────────┘
```

| State | Background | Text | Border |
|-------|------------|------|--------|
| Normal | Transparent | #007AFF | #007AFF (1pt) |
| Pressed | #007AFF (10%) | #005EC4 | #005EC4 |
| Disabled | Transparent | #007AFF (30%) | #007AFF (30%) |

#### Tertiary Button

| State | Text Color |
|-------|------------|
| Normal | #007AFF |
| Pressed | #005EC4 |
| Disabled | #007AFF (30%) |

**Specs:** No background, no border, underline optional

#### Destructive Button

| Variant | Background | Text |
|---------|------------|------|
| Primary | #FF3B30 | #FFFFFF |
| Secondary | Transparent | #FF3B30, border #FF3B30 |

### Button States Visual

```swift
struct PrimaryButton: View {
    let title: String
    let action: () -> Void
    @State private var isPressed = false
    let isEnabled: Bool
    let isLoading: Bool
    
    var body: some View {
        Button(action: action) {
            HStack {
                if isLoading {
                    ProgressView()
                        .tint(.white)
                } else {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(backgroundColor)
            .foregroundColor(.white.opacity(isEnabled ? 1 : 0.5))
            .cornerRadius(12)
        }
        .disabled(!isEnabled || isLoading)
        .scaleEffect(isPressed ? 0.98 : 1.0)
        .animation(.easeInOut(duration: 0.1), value: isPressed)
    }
    
    var backgroundColor: Color {
        if !isEnabled { return Color.accentColor.opacity(0.3) }
        if isPressed { return Color(hex: "#005EC4") }
        return Color.accentColor
    }
}
```

### Icon Buttons

| Size | Touch Target | Icon Size |
|------|--------------|-----------|
| Small | 44×44pt | 20×20pt |
| Medium | 48×48pt | 24×24pt |
| Large | 56×56pt | 28×28pt |

---

## SHADOW & ELEVATION SYSTEM

### Elevation Levels

| Level | Use Case | Shadow (Light) | Shadow (Dark) |
|-------|----------|----------------|---------------|
| **0** | Flat content | none | none |
| **1** | Cards, list items | 0 2 8 rgba(0,0,0,0.08) | 0 2 8 rgba(0,0,0,0.3) |
| **2** | Floating buttons | 0 4 16 rgba(0,0,0,0.12) | 0 4 16 rgba(0,0,0,0.4) |
| **3** | Modals, sheets | 0 8 24 rgba(0,0,0,0.16) | 0 8 24 rgba(0,0,0,0.5) |
| **4** | Popovers | 0 12 32 rgba(0,0,0,0.20) | 0 12 32 rgba(0,0,0,0.6) |

### Swift Implementation

```swift
extension View {
    func cardShadow() -> some View {
        self.shadow(
            color: Color.black.opacity(0.08),
            radius: 8,
            x: 0,
            y: 2
        )
    }
    
    func floatingShadow() -> some View {
        self.shadow(
            color: Color.black.opacity(0.12),
            radius: 16,
            x: 0,
            y: 4
        )
    }
    
    func modalShadow() -> some View {
        self.shadow(
            color: Color.black.opacity(0.16),
            radius: 24,
            x: 0,
            y: 8
        )
    }
}
```

---

## SAFE AREAS

### Device-Specific Handling

| Device Type | Top Safe Area | Bottom Safe Area |
|-------------|---------------|------------------|
| iPhone SE | 20pt (status bar) | 0pt |
| iPhone 14 | 59pt (Dynamic Island) | 34pt |
| iPhone 14 Pro | 59pt (Dynamic Island) | 34pt |
| iPhone 15 Pro Max | 59pt (Dynamic Island) | 34pt |

### Layout Rules

```swift
// Always use safeAreaInset
VStack {
    // Content
}
.safeAreaInset(edge: .bottom) {
    // Bottom action bar
}

// For full-screen content
.ignoresSafeArea(.container, edges: .top)
```

### Dynamic Island Considerations

```swift
// Check for Dynamic Island
var hasDynamicIsland: Bool {
    if #available(iOS 16.1, *) {
        return UIScreen.main.bounds.height >= 852
    }
    return false
}

// Adaptive top padding
var topPadding: CGFloat {
    hasDynamicIsland ? 12 : 0
}
```

---

## SCREEN: SETTINGS (PROFILE)

### Screen Structure

```
┌─────────────────────────────────────────────────────────┐
│  ← Profile                                         ⚙️   │
│─────────────────────────────────────────────────────────│
│                                                         │
│  ┌─────────────────────────────────────────────────┐   │
│  │  👤  Alex                                       │   │
│  │      alex@email.com                             │   │
│  │      Member since Jan 2026                      │   │
│  └─────────────────────────────────────────────────┘   │
│                                                         │
│  HEALTH DATA                                            │
│  ┌─────────────────────────────────────────────────┐   │
│  │  ❤️  HealthKit                          Connected │   │
│  │  ⌚  Apple Watch                       Paired ✓   │   │
│  │  🎯  Goals                                    →   │   │
│  └─────────────────────────────────────────────────┘   │
│                                                         │
│  NOTIFICATIONS                                          │
│  ┌─────────────────────────────────────────────────┐   │
│  │  🔔  Push Notifications                    ON ○   │   │
│  │  🌅  Morning Brief              07:00        →   │   │
│  │  🌙  Quiet Hours           22:00 - 07:00    →   │   │
│  └─────────────────────────────────────────────────┘   │
│                                                         │
│  PREFERENCES                                            │
│  ┌─────────────────────────────────────────────────┐   │
│  │  🎨  Appearance                          Auto →   │   │
│  │  📏  Units                             Metric →   │   │
│  │  🌍  Language                          English →  │   │
│  │  🏃  Activity Level                   Moderate →  │   │
│  └─────────────────────────────────────────────────┘   │
│                                                         │
│  PRIVACY & DATA                                         │
│  ┌─────────────────────────────────────────────────┐   │
│  │  🔒  Privacy Policy                           →   │   │
│  │  🧾  Data Sources                             →   │   │
│  │  📊  Export My Data                           →   │   │
│  │  🗑️  Delete Account                           →   │   │
│  └─────────────────────────────────────────────────┘   │
│                                                         │
│  SUPPORT                                                │
│  ┌─────────────────────────────────────────────────┐   │
│  │  ❓  Help & FAQ                               →   │   │
│  │  💬  Contact Support                          →   │   │
│  │  ⭐  Rate Life OS                             →   │   │
│  └─────────────────────────────────────────────────┘   │
│                                                         │
│  Version 1.0.0 (Build 42)                               │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

### Settings Row Specifications

| Element | Specification |
|---------|--------------|
| Row height | 48pt |
| Icon size | 24×24pt |
| Icon background | 28×28pt rounded square (6pt radius) |
| Title font | SF Pro, 17pt, Regular |
| Value font | SF Pro, 17pt, Regular, Secondary color |
| Chevron | SF Symbol `chevron.right`, 14pt, Tertiary |
| Toggle | System UISwitch |
| Separator | 0.5pt, warm neutral separator token (no legacy neutrals) |
| Section header | SF Pro, 13pt, Regular, Tertiary, ALL CAPS |
| Section spacing | 32pt between sections |

### Destructive Actions

```
┌─────────────────────────────────────────────────────────┐
│                                                         │
│               Delete Account?                           │
│                                                         │
│   This will permanently delete all your data.           │
│   This action cannot be undone.                         │
│                                                         │
│   ┌─────────────────────────────────────────────────┐   │
│   │            Delete My Account                    │   │  ← Red, destructive
│   └─────────────────────────────────────────────────┘   │
│                                                         │
│   ┌─────────────────────────────────────────────────┐   │
│   │                 Cancel                          │   │  ← Secondary
│   └─────────────────────────────────────────────────┘   │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

---

## SCREEN: DATA SOURCES (Attribution)

**Purpose:** legal/store readiness + trust for food data sources.

**Copy IDs:** `settings.data_sources_*`

```
┌─────────────────────────────────────────────────────────┐
│  ← Data Sources                                         │
│─────────────────────────────────────────────────────────│
│                                                         │
│  Product data                                           │
│  From Open Food Facts (ODbL)                    ↗       │
│                                                         │
│  Community products                                     │
│  Added by users via label scan                          │
│                                                         │
│  Verify nutrition labels if unsure.                     │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

**Rules:**
- Keep this screen extremely lightweight (no long legal text).
- External link opens in an in-app browser.

---

## SCREEN: TRENDS / CHARTS

### Period Selector

```
┌─────────────────────────────────────────────────────────┐
│  ← Trends                                               │
│─────────────────────────────────────────────────────────│
│                                                         │
│   ┌───────────┬───────────┬───────────┐                 │
│   │    7D     │    30D    │    90D    │  ← Segmented    │
│   └───────────┴───────────┴───────────┘    Control      │
│                                                         │
```

### Recovery Trends Chart

```
┌─────────────────────────────────────────────────────────┐
│                                                         │
│  Recovery Score                          Avg: 68% ↗     │
│                                                         │
│  100% ┬─────────────────────────────────────────────    │
│       │     ╭──╮                                        │
│   75% ┼─────╯  ╰──╮        ╭─────╮                      │
│       │           ╰────────╯     ╰────╮                 │
│   50% ┼                               ╰────             │
│       │                                                 │
│   25% ┼                                                 │
│       │                                                 │
│    0% ┴─────────────────────────────────────────────    │
│        Mon  Tue  Wed  Thu  Fri  Sat  Sun                │
│                                                         │
│  ● Optimal  ● Ready  ● Caution  ● Critical              │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

### Chart Specifications

| Parameter | Value |
|-----------|-------|
| Chart height | 200pt |
| Line width | 2pt |
| Data point | 8pt circle (on tap) |
| Grid lines | 0.5pt, Tertiary color |
| Axis labels | SF Pro, 11pt, Tertiary |
| Legend | SF Pro, 13pt, with color dots (8pt) |
| Gradient fill | Line color → transparent (20% opacity) |

### Chart Accessibility

```swift
// VoiceOver for charts
Chart(data) { point in
    LineMark(
        x: .value("Date", point.date),
        y: .value("Recovery", point.value)
    )
}
.accessibilityLabel("Recovery trend chart for the past 7 days")
.accessibilityValue("Average recovery \(average) percent, trending \(trend)")
.accessibilityHint("Double tap to explore individual data points")
.accessibilityChartDescriptor(RecoveryChartDescriptor(data: data))

// Structural descriptor for deeper exploration
struct RecoveryChartDescriptor: AXChartDescriptorRepresentable {
    let data: [RecoveryPoint]
    
    func makeChartDescriptor() -> AXChartDescriptor {
        let xAxis = AXCategoricalDataAxisDescriptor(
            title: "Day",
            categoryOrder: data.map { $0.dayName }
        )
        
        let yAxis = AXNumericDataAxisDescriptor(
            title: "Recovery Percent",
            range: 0...100,
            gridlinePositions: [25, 50, 75, 100]
        ) { value in
            "\(Int(value)) percent"
        }
        
        let series = AXDataSeriesDescriptor(
            name: "Recovery Score",
            isContinuous: true,
            dataPoints: data.map { point in
                AXDataPoint(
                    x: point.dayName,
                    y: Double(point.value),
                    label: "\(point.dayName): \(point.value) percent, \(point.zone.label)"
                )
            }
        )
        
        return AXChartDescriptor(
            title: "Recovery Trend",
            summary: "Shows your recovery score over time",
            xAxis: xAxis,
            yAxis: yAxis,
            series: [series]
        )
    }
}
```

### Sleep Trends Chart

```
┌─────────────────────────────────────────────────────────┐
│                                                         │
│  Sleep Duration                          Avg: 7h 23m    │
│                                                         │
│   9h ┬─────────────────────────────────────────────     │
│      │         ▇                                        │
│   8h ┼    ▇    ▇    ▇              ▇                    │
│      │    ▇    ▇    ▇    ▇    ▇    ▇    ▇               │
│   7h ┼────▇────▇────▇────▇────▇────▇────▇────           │  ← Target line
│      │    ▇    ▇    ▇    ▇    ▇    ▇    ▇               │
│   6h ┼                   ▇                              │
│      │                                                  │
│   5h ┴─────────────────────────────────────────────     │
│        Mon  Tue  Wed  Thu  Fri  Sat  Sun                │
│                                                         │
│  ━━━ Target: 7.5h                                       │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

### Nutrition Trends

```
┌─────────────────────────────────────────────────────────┐
│                                                         │
│  Macros                                  Avg adherence  │
│                                                         │
│  Protein   ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░   82%  ↗ +5%           │
│  Carbs     ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░   94%  → 0%            │
│  Fat       ▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░   71%  ↘ -3%           │
│  Fiber     ▓▓▓▓▓▓▓▓░░░░░░░░░░░░   45%  ↗ +8%           │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

---

## EMPTY STATES — FULL SPECIFICATIONS

### Principles

1. **Never a blank screen** — illustration + text + action
2. **Explain why** — what the user should do
3. **Provide an action** — a clear button to resolve
4. **Tone: supportive** — not blaming

### Home — No Recovery data

```
┌─────────────────────────────────────────────────────────┐
│                                                         │
│                        ❤️                               │
│                   (heart.fill)                          │
│                                                         │
│              Connect Health Data                        │
│                                                         │
│     To calculate your Recovery Score, we need           │
│     access to your health data from Apple Health.       │
│                                                         │
│     ┌─────────────────────────────────────────────┐     │
│     │           Connect HealthKit                 │     │
│     └─────────────────────────────────────────────┘     │
│                                                         │
│              Learn more about privacy →                 │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

**VoiceOver:** "No recovery data. Connect Health Kit to calculate your recovery score. Button: Connect HealthKit. Link: Learn more about privacy."

### Home — Waiting for data

```
┌─────────────────────────────────────────────────────────┐
│                                                         │
│                        ⏳                               │
│                   (hourglass)                           │
│                                                         │
│              Collecting Your Data                       │
│                                                         │
│     We need at least one night of sleep data            │
│     to calculate your first Recovery Score.             │
│                                                         │
│     Wear your Apple Watch tonight and check             │
│     back tomorrow morning.                              │
│                                                         │
│     ┌─────────────────────────────────────────────┐     │
│     │              Got It                         │     │
│     └─────────────────────────────────────────────┘     │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

### Nutrition — No meals today

```
┌─────────────────────────────────────────────────────────┐
│                                                         │
│                      🍽️ 📷                              │
│                                                         │
│              Log Your First Meal                        │
│                                                         │
│     Take a photo of your food and we'll                 │
│     analyze it in seconds using AI.                     │
│                                                         │
│     ┌─────────────────────────────────────────────┐     │
│     │           📷  Take Photo                    │     │
│     └─────────────────────────────────────────────┘     │
│                                                         │
│              Or enter manually →                        │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

### Insights — Not enough data

```
┌─────────────────────────────────────────────────────────┐
│                                                         │
│                        💡                               │
│                   (lightbulb)                           │
│                                                         │
│              Insights Coming Soon                       │
│                                                         │
│     We need 7 days of data to find your                 │
│     personal patterns.                                  │
│                                                         │
│     ━━━━━━━━●━━━━━━━━━━━━  Day 3 of 7                   │
│                                                         │
│     Keep logging your meals and wearing                 │
│     your Apple Watch!                                   │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

### Experiments — No experiments

```
┌─────────────────────────────────────────────────────────┐
│                                                         │
│                        🧪                               │
│                   (flask.fill)                          │
│                                                         │
│              Start Your First Experiment                │
│                                                         │
│     Discover what works best for YOUR body              │
│     with personalized N-of-1 experiments.               │
│                                                         │
│     Popular experiments:                                │
│     • Does caffeine cutoff time affect my sleep?        │
│     • Is 10,000 steps really my optimal?                │
│                                                         │
│     ┌─────────────────────────────────────────────┐     │
│     │           Browse Experiments                │     │
│     └─────────────────────────────────────────────┘     │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

### HealthKit Denied

```
┌─────────────────────────────────────────────────────────┐
│                                                         │
│                        🔒                               │
│                   (lock.fill)                           │
│                                                         │
│              Health Access Required                     │
│                                                         │
│     Life OS needs access to your health data            │
│     to provide personalized insights.                   │
│                                                         │
│     ┌─────────────────────────────────────────────────┐ │
│     │  🔐 Your data stays on your device             │ │
│     │  • We never sell or share your data            │ │
│     │  • Processing happens locally                  │ │
│     └─────────────────────────────────────────────────┘ │
│                                                         │
│     ┌─────────────────────────────────────────────┐     │
│     │          Open Settings                      │     │
│     └─────────────────────────────────────────────┘     │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

### Network Error

```
┌─────────────────────────────────────────────────────────┐
│                                                         │
│                        📶                               │
│                   (wifi.slash)                          │
│                                                         │
│              You're Offline                             │
│                                                         │
│     Some features require an internet connection.       │
│     Your data is saved and will sync when               │
│     you're back online.                                 │
│                                                         │
│     ┌─────────────────────────────────────────────┐     │
│     │              Try Again                      │     │
│     └─────────────────────────────────────────────┘     │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

---

## LOADING STATES — FULL SPECIFICATIONS

### Home Screen Skeleton

```
┌─────────────────────────────────────────────────────────┐
│                                                         │
│  ████████████████                                       │  ← Title shimmer
│                                                         │
│  ┌─────────────────────────────────────────────────┐   │
│  │                                                 │   │
│  │        ██████                                   │   │  ← Score number
│  │     ████████████                                │   │  ← Status label
│  │                                                 │   │
│  │  ██████████████████████████████████████████    │   │  ← Progress bar
│  │                                                 │   │
│  │  ████████████████████████                       │   │  ← Message
│  │  ██████████████████████████████████████████    │   │
│  │                                                 │   │
│  └─────────────────────────────────────────────────┘   │
│                                                         │
│  ████████                                               │  ← Section header
│                                                         │
│  ┌───────────────┐ ┌───────────────┐ ┌───────────────┐ │
│  │ ████████████  │ │ ████████████  │ │ ████████████  │ │  ← Quick stats
│  │ ██████        │ │ ██████        │ │ ██████        │ │
│  └───────────────┘ └───────────────┘ └───────────────┘ │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

### Nutrition Screen Skeleton

```
┌─────────────────────────────────────────────────────────┐
│                                                         │
│  ████████████████                                       │
│                                                         │
│  ████████████ / ████████████                            │  ← Calories
│                                                         │
│  ████  ██████████████████████████░░░░░   ████           │  ← Protein
│  ████  ██████████████████████░░░░░░░░░   ████           │  ← Carbs
│  ████  ████████████████░░░░░░░░░░░░░░░   ████           │  ← Fat
│  ████  ██████████░░░░░░░░░░░░░░░░░░░░░   ████           │  ← Fiber
│                                                         │
│  ████████                                               │
│                                                         │
│  ┌─────────────────────────────────────────────────┐   │
│  │  ██████████████        ████████████████          │   │
│  │  ████████              ████████                  │   │
│  └─────────────────────────────────────────────────┘   │
│                                                         │
│  ┌─────────────────────────────────────────────────┐   │
│  │  ██████████████        ████████████████          │   │
│  │  ████████              ████████                  │   │
│  └─────────────────────────────────────────────────┘   │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

### Shimmer Animation

```swift
struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = 0
    
    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geometry in
                    LinearGradient(
                        gradient: Gradient(stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .white.opacity(0.5), location: 0.5),
                            .init(color: .clear, location: 1)
                        ]),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geometry.size.width * 2)
                    .offset(x: phase * geometry.size.width * 2 - geometry.size.width)
                }
            )
            .mask(content)
            .onAppear {
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

extension View {
    func shimmer() -> some View {
        modifier(ShimmerModifier())
    }
}
```

### Skeleton Colors

| Mode | Skeleton Base | Skeleton Highlight |
|------|---------------|-------------------|
| Light | #EDE1D6 | #FFFBF7 |
| Dark | #2A231D | #3A3128 |

**Copy ID mapping (loading text):**
- Food photo: `loading.food_title`
- OCR analysis: `loading.ocr_title`
- Plan generation: `loading.plan_title`

---

## iOS WIDGETS

### Small Widget (2×2)

```
┌─────────────────────┐
│                     │
│        73           │   34pt Bold
│      ✓ Ready        │
│                     │
│   ━━━━━━━━━━░░░░   │   Progress bar
│                     │
└─────────────────────┘
```

**Interactivity (iOS 17+):** Tap → opens app to Recovery Detail

### Medium Widget (4×2)

```
┌───────────────────────────────────────────┐
│                                           │
│  73% ✓ Ready            1,420 / 2,100    │
│  Your body is ready     kcal             │
│                                           │
│  ━━━━━━━━━━░░░░         ━━━━━━━━░░░░░    │
│                                           │
│  HRV: 52ms  Sleep: 7h   🥩 45g  🥑 38g   │
│                                           │
└───────────────────────────────────────────┘
```

### Large Widget (4×4)

```
┌───────────────────────────────────────────┐
│  Life OS                                  │
│───────────────────────────────────────────│
│                                           │
│              73                           │
│           ✓ Ready                         │
│                                           │
│  "Your body is recovered and ready        │
│   for moderate intensity today"           │
│                                           │
│───────────────────────────────────────────│
│  7-Day Trend                              │
│  ▁▂▃▄▅▃▄                    Avg: 68%     │
│───────────────────────────────────────────│
│  Nutrition Today                          │
│  🥩 Protein   45/120g  ━━━━━░░░   38%    │
│  🥑 Fat       38/70g   ━━━━━━░░   54%    │
│  🍞 Carbs    180/250g  ━━━━━━━░   72%    │
│───────────────────────────────────────────│
│  [ 📷 Log Meal ]      [ View Details ]   │
└───────────────────────────────────────────┘
```

### Widget Configuration

```swift
struct LifeOSWidget: Widget {
    let kind: String = "LifeOSWidget"
    
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            LifeOSWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Recovery Score")
        .description("See your daily recovery at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
```

---

## BRAND VOICE GUIDELINES

### Tone Principles

| Principle | Description | Example |
|---------|----------|--------|
| **Supportive Partner** | AI as a supportive partner, not a judge | "Your body needs rest today" NOT "You failed to recover" |
| **Honest but Kind** | Truth without judgment | "Sleep was short at 5h. Here's how to catch up." |
| **Curious Explorer** | Exploring together | "I noticed a pattern — want to explore it?" |
| **Respectful of Autonomy** | Choice stays with the user | "Would you like to..." NOT "You should..." |

### Language Patterns

#### ✅ DO

```
"Your body is telling us it needs rest"
"I noticed you sleep better on weekdays — want to explore why?"
"Great consistency this week — 6 out of 7 days logged!"
"Recovery is lower today. Consider lighter activity."
"You're developing body awareness!"
"Scan complete. Please review your lab values."
"Supplement timing optimized for your schedule."
"Training adjusted based on recovery."
```

#### ❌ DON'T

```
"You failed to meet your goal"
"You should have slept more"
"Your streak is broken!"
"You're doing worse than last week"
"The app detected a problem"
"Your labs are bad"
"You must take supplements"
"You're training wrong"
```

### Metric Language

| Metric | Positive Frame | Neutral Frame | Negative Frame |
|--------|----------------|---------------|----------------|
| Recovery | "Ready for anything" | "Good to go" | "Rest recommended" |
| Sleep | "Excellent restoration" | "Adequate" | "Room to improve" |
| Nutrition | "Nailing your targets" | "On track" | "Opportunity to adjust" |
| Training | "On plan" | "Balanced" | "Reduce load" |
| Supplements | "Consistent" | "On schedule" | "Missed timing" |

### Error Messages Tone

| Type | Tone | Example |
|------|------|---------|
| User error | Helpful | "That photo was a bit blurry. Try again with steady hands?" |
| System error | Apologetic | "Something went wrong on our end. Trying again..." |
| Limitation | Honest | "AI isn't sure about this one. Mind reviewing?" |

### Progress Framing

```
Week 1: "You're off to a great start!"
Week 4: "You're building real habits now"
Week 12: "You've developed strong body awareness"
Week 24: "You know your patterns better than most"
```

---

## ILLUSTRATION STYLE

### Principles

1. **Minimalist** — Simple shapes, limited colors
2. **Warm** — Soft corners, friendly forms
3. **Consistent** — Same visual language across all illustrations
4. **Meaningful** — Each element has purpose

### Style Guide

| Element | Style |
|---------|-------|
| Line weight | 2pt |
| Corner radius | Rounded (never sharp) |
| Colors | Warm neutrals for surfaces + Okabe-Ito for semantic accents |
| Shadows | None (flat design) |
| Characters | Abstract (no faces) |

### Icon Illustrations (Empty States)

| Screen | Illustration | Description |
|--------|--------------|-------------|
| No Recovery | Heart with pulse line | Simple heart outline with gentle wave |
| No Food | Plate with camera | Circular plate with camera icon overlay |
| No Insights | Lightbulb with sparkles | Lightbulb outline with 3 star accents |
| No Experiments | Flask with dots | Laboratory flask with floating particles |
| Offline | Cloud with X | Simplified cloud with disconnection mark |

---

## CHANGELOG

### v2.24 (February 9, 2026) — Complete Screen Specifications
Added:
- Notification Settings screen (full wireframe, interaction rules, VoiceOver)
- Control Level screen (Advisory/Protective/Guardian selection, permission flow, app selection)
- Privacy & Data Management screen (data info, export, retention, menstrual privacy, delete)
- Insights Detail screen (pattern card, mini chart, confidence dots, experiment CTA, VoiceOver)
- Experiment Detail screen (hypothesis, protocol, daily log, progress timeline, VoiceOver)
- Experiment Results screen (outcome states, comparison chart, suggested next step, VoiceOver)
- Error States — Full Specifications (network, permission, AI, sync, server, validation errors)
- Offline Mode UX (indicator, capability matrix, sync states, conflict resolution, outbox badge)
Updated:
- "Needs Specification" table → "Specification Status" table — all 21 screens now ✅ Complete
- Removed duplicate `watchOS DESIGN (PHASE 2)` section (content merged into primary WATCHOS DESIGN)

### v2.23 (February 4, 2026) — watchOS Complications A11y
Updated:
- Clarified complication content to always include zone icon (never color-only)

### v2.22 (February 4, 2026) — watchOS V2 Alignment
Updated:
- Marked watch “Full View” as future-only (not in V2) and clarified iPhone routing for complex actions
- Raised watch tap target minimum to 44×44pt for accessibility consistency

### v2.21 (February 4, 2026) — Settings Data Sources
Added:
- Settings → Data Sources attribution screen spec (Open Food Facts + community label scan disclosure)

### v2.20 (February 4, 2026) — Nutrition Label OCR + Meal Prep
Added:
- Product source badges (Open Food Facts / Community label scan / User override)
- Nutrition label scan and Review Product screen specs (barcode fallback)
- Meal Prep (batch recipes) library + create + review + log portion screen specs

### v2.18 (February 3, 2026) — Diary Screens
Added:
- Clarified Okabe-Ito vs warm surfaces rule (semantic vs surfaces)
- Unified Diary (day view) screen spec
- Training Diary (day view + month grid) screen specs

### v2.17 (February 3, 2026) — Diary Support
Added:
- Workout conflict resolution modal spec (import vs manual)
- Supplements daily schedule + taken status screen spec

### v2.16 (February 3, 2026) — Nutrition Screens
Added:
- Nutrition calendar diary + meal review screen specs

### v2.15 (February 3, 2026) — Calendar Components
Added:
- Week strip + month grid calendar component specs for Nutrition and Training diaries

### v2.14 (February 3, 2026) — Warm Surfaces
Added:
- Warm neutral surface theme (background + cards) while keeping Okabe‑Ito for semantic states
- Updated skeleton colors to match warm surfaces

### v2.13 (February 3, 2026) — Loading Copy Mapping
Added:
- Loading state copy ID mapping

### v2.12 (February 3, 2026) — Empty State Mapping
Added:
- Copy ID mapping for empty states

### v2.11 (February 3, 2026) — Empty State Copy
Added:
- Empty state copy source note

### v2.10 (February 3, 2026) — Copy Library Extension
Added:
- Training error and plan failure copy entries

### v2.9 (February 3, 2026) — Localization Rules
Added:
- Copy ID usage rules
- Localization length constraints

### v2.8 (February 3, 2026) — Copy Catalog Link
Added:
- Copy catalog reference and source of truth

### v2.7 (February 3, 2026) — Copy + Labels
Added:
- OCR error/low confidence screen spec
- UX copy library for new modules
- Accessibility label examples

### v2.6 (February 3, 2026) — OCR Review Spec
Added:
- OCR review UI layout example

### v2.5 (February 3, 2026) — Copy + OCR
Added:
- Brand voice examples for training/supps/labs
- OCR review empty state

### v2.4 (February 3, 2026) — Labs Detail
Added:
- Lab Detail screen spec
- OCR capture flow wireframe

### v2.3 (February 3, 2026) — Detail Screens
Added:
- Training Detail screen spec
- Supplement Detail screen spec

### v2.2 (February 3, 2026) — Screen Specs
Added:
- Training, Supplements, Labs wireframes
- Updated screen status table

### v2.1 (February 3, 2026) — Ecosystem Expansion
Added:
- New tab bar mapping (Home, Nutrition, Training, Supplements)
- Quick Log sheet actions for all modules
- Components for Training, Supplements, Labs
- Empty states for new modules

### v2.0 (February 2, 2026) — Design Audit Fixes
Based on comprehensive design audit, added:

**Navigation & Structure:**
- Tab Bar specification (5 items, central Log button)
- NavigationStack patterns and hierarchy
- Safe Areas handling (Dynamic Island, notch)

**Components:**
- Button system (Primary/Secondary/Tertiary/Destructive)
- Button states (normal, pressed, disabled, loading)
- Shadow & elevation system (4 levels)

**Screen Specifications:**
- Settings (Profile) screen wireframe
- Trends/Charts screen with period selector
- Full Empty States for all screens
- Full Loading States (skeleton screens)

**Data Visualization:**
- Chart specifications with accessibility
- AXChartDescriptor for VoiceOver
- Recovery, Sleep, Nutrition trend charts

**Platform Extensions:**
- watchOS design (Complication, Glance, Full App)
- iOS Widgets (Small, Medium, Large)

**Brand:**
- Brand Voice Guidelines
- Illustration style guide

### v1.0 (February 1, 2026)
- Initial design system specification
- Unified color palette (Okabe-Ito)
- Typography scale
- Spacing system (8pt grid)
- Animation specifications
- Touch target requirements
- Icon guidelines
- Empty/Loading states guidelines
- Missing screens inventory
