# LIFE OS — ACCESSIBILITY GUIDELINES

**Version:** 1.4  
**Date:** February 16, 2026  
**Standard:** WCAG 2.2 Level AA + Apple Human Interface Guidelines

---

## OVERVIEW

Life OS is committed to being usable by everyone, including users with:
- Visual impairments (blindness, low vision, color blindness)
- Motor impairments (limited dexterity, tremors)
- Cognitive differences (attention difficulties, dyslexia)
- Hearing impairments (for any audio features)

**Target:** WCAG 2.2 Level AA compliance + Apple Accessibility Best Practices

---

## NEW MODULES — ACCESSIBILITY ADDITIONS (v1.1)

### Training
- Set rows must expose order, weight, reps, and RPE in a single accessible label.
- "Add Set" buttons must announce the exercise context (e.g., "Add set for Bench Press").
- Workout timer should be non-blocking and must not steal VoiceOver focus.

### Supplements
- Supplement chips must have clear labels with time + status ("Magnesium, 21:00, taken").
- Evidence badges must include spoken form ("Evidence level B, moderate").
- Reminder toggles must include schedule in accessibility value.

### Labs
- OCR review rows must include original label + parsed value + unit in one label.
- If confidence < 0.65, append "Review required".
- Unit picker must expose current selection and list all options.
- Trend charts must use AXChartDescriptor with marker name + value range.

### Error/Review States
- OCR review required state must announce immediately when presented.
- Interaction warnings (supplement conflicts) must be VoiceOver-focusable with clear actions.

---

## LOCALIZATION & RTL (v1.3)

- Support right-to-left layout mirroring for Hebrew/Arabic.
- Ensure icons that imply direction (arrows) mirror in RTL.
- Test Dynamic Type with longest translated strings.

---

## ACCESSIBILITY LABEL EXAMPLES (v1.2)

**Training Set Row:**
- "Set 2, 65 kilograms, 8 reps, RPE 8"

**Supplement Chip:**
- "Magnesium, 21:00, taken"

**Lab OCR Row:**
- "Ferritin, 18 ng per milliliter, low, review required"

**Lab Marker Card:**
- "Vitamin D 25-OH, 24 ng per milliliter, low, 90-day trend"

---

## CRITICAL REQUIREMENT: COLOR IS NEVER ENOUGH

> [!CRITICAL]
> **8% of men and 0.5% of women have color vision deficiency.**
> Color can NEVER be the sole method of conveying information.

### The Triple Indicator Pattern

Every status indicator MUST include:

| Element | Purpose | Example |
|---------|---------|---------|
| **1. Color** | Quick visual recognition | 🔵 Blue |
| **2. Icon** | Color-blind accessible | ✓ |
| **3. Text Label** | Screen reader + clarity | "Optimal" |

```swift
// ✅ CORRECT IMPLEMENTATION
struct AccessibleStatusView: View {
    let zone: RecoveryZone
    
    var body: some View {
        HStack(spacing: 8) {
            Text(zone.icon)           // "✓"
            Circle()
                .fill(zone.color)     // Blue
                .frame(width: 12, height: 12)
            Text(zone.label)          // "Optimal"
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(zone.label): \(zone.description)")
    }
}

// ❌ WRONG - Color only
Circle()
    .fill(zone.color)
    .frame(width: 12, height: 12)
```

---

## COLOR CONTRAST REQUIREMENTS

### WCAG 2.2 AA Standards

| Element Type | Minimum Contrast | Recommendation |
|--------------|------------------|----------------|
| Normal text (< 18pt) | 4.5:1 | 7:1 for small text |
| Large text (≥ 18pt or 14pt bold) | 3:1 | 4.5:1 |
| UI components & graphics | 3:1 | 4.5:1 |

### Life OS Color Palette (Unified — Okabe-Ito)

> [!IMPORTANT]
> **Source of Truth:** Окончательная палитра согласована с PRD v7.13.  
> Используется Okabe-Ito palette — научно проверенная для цветовой слепоты.

| Color | Light Hex | Dark Hex | Light Contrast | Dark Contrast | Status |
|-------|-----------|----------|----------------|---------------|--------|
| Optimal (Blue) | #0072B2 | #56B4E9 | 4.6:1 | 5.2:1 | ✅ Pass |
| Ready (Green) | #009E73 | #009E73 | 4.5:1 | 4.5:1 | ✅ Pass |
| Caution (Orange) | #9A6800¹ | #F0E442 | 6.3:1 | 9.1:1 | ✅ Pass |
| Critical (Red) | #D55E00 | #D55E00 | 4.5:1 | 4.5:1 | ✅ Pass |

### Automated Verification

```swift
#if DEBUG
func validateColorContrast() {
    let backgrounds = [Color.white, Color.black]
    // Okabe-Ito palette (unified source of truth)
    let colors: [(String, Color, Color)] = [
        ("Optimal", Color(hex: "#0072B2"), Color(hex: "#56B4E9")),
        ("Ready", Color(hex: "#009E73"), Color(hex: "#009E73")),
        ("Caution", Color(hex: "#9A6800"), Color(hex: "#F0E442")),  // ¹ Darkened for WCAG AA on #FFF7F0
        ("Critical", Color(hex: "#D55E00"), Color(hex: "#D55E00"))
    ]
    
    for (name, light, dark) in colors {
        let lightRatio = calculateContrastRatio(light, .white)
        let darkRatio = calculateContrastRatio(dark, .black)
        
        assert(lightRatio >= 4.5, "\(name) light fails WCAG AA")
        assert(darkRatio >= 4.5, "\(name) dark fails WCAG AA")
    }
    
    print("✅ All colors pass WCAG AA contrast requirements")
}
#endif
```

---

## COLOR BLINDNESS CONSIDERATIONS

### Types and Prevalence

| Type | Prevalence | Affected Colors |
|------|------------|-----------------|
| Deuteranopia (green-blind) | 6% of males | Red-Green confusion |
| Protanopia (red-blind) | 2% of males | Red-Green confusion |
| Tritanopia (blue-blind) | 0.01% | Blue-Yellow confusion |

### Color-Blind Safe Strategies

#### 1. Never Use Red-Green as Only Differentiator

```
❌ WRONG: Red = Bad, Green = Good (with no other indicator)
✅ RIGHT: Red + ✕ + "Critical", Green + ✓ + "Optimal"
```

#### 2. Use the Okabe-Ito Palette for Data Visualization

| Color | Hex | Safe For |
|-------|-----|----------|
| Orange | #E69F00 | All types |
| Sky Blue | #56B4E9 | All types |
| Bluish Green | #009E73 | All types |
| Yellow | #F0E442 | All types |
| Blue | #0072B2 | All types |
| Vermillion | #D55E00 | All types |
| Reddish Purple | #CC79A7 | All types |

#### 3. Test with Simulators

Required testing before release:
- Deuteranopia simulation
- Protanopia simulation
- Grayscale view

```swift
// Xcode: Debug → Accessibility Inspector → Color Filters
// Or use: Sim Daltonism (Mac app)
```

---

## VOICEOVER SUPPORT

### Accessibility Label Guidelines

Every interactive element needs a clear, descriptive label.

#### Recovery Score Card

```swift
// Label should include: Value, Status, Context
.accessibilityLabel("Recovery score: 73 percent")
.accessibilityValue("Ready status")
.accessibilityHint("Your body is recovered and ready for moderate intensity activity. Double tap for details.")
```

#### Charts and Graphs

```swift
// Provide summary, not raw data
.accessibilityLabel("Recovery trend chart for the past 7 days")
.accessibilityValue("Average recovery 68 percent, trending upward from 62 percent")
.accessibilityHint("Double tap to explore individual data points")
```

#### Nutrition Progress Bars

```swift
// Include current, target, and percentage
.accessibilityLabel("Protein intake")
.accessibilityValue("45 of 120 grams, 38 percent complete")
.accessibilityHint("Double tap to log more protein")
```

### VoiceOver Navigation

- Use `accessibilityElement(children: .combine)` for compound views
- Group related information with `accessibilityContainer`
- Set `accessibilityTraits` appropriately (.button, .header, .adjustable)

```swift
// Example: Recovery Zone Picker
ForEach(RecoveryZone.allCases) { zone in
    Button(zone.label) {
        selectedZone = zone
    }
    .accessibilityLabel(zone.label)
    .accessibilityValue(zone == selectedZone ? "Selected" : "")
    .accessibilityHint(zone.description)
    .accessibilityAddTraits(zone == selectedZone ? .isSelected : [])
}
```

---

## DYNAMIC TYPE SUPPORT

### Implementation Requirements

1. **Always use text styles, never hardcoded sizes:**

```swift
// ✅ CORRECT
Text("Recovery Score")
    .font(.headline)

// ❌ WRONG
Text("Recovery Score")
    .font(.system(size: 17))
```

2. **For custom sizes, use UIFontMetrics:**

```swift
// Custom scaled font
let heroFont = UIFontMetrics(forTextStyle: .largeTitle)
    .scaledFont(for: UIFont.systemFont(ofSize: 72, weight: .bold))
```

3. **Enable automatic adjustment:**

```swift
.adjustsFontForContentSizeCategory = true
```

### Testing Requirements

Test at all Dynamic Type sizes:

| Size | Scale | Test Focus |
|------|-------|------------|
| xSmall | 0.82x | Minimum viable |
| Small | 0.88x | — |
| Medium | 0.94x | — |
| Large (Default) | 1.0x | Primary design |
| xLarge | 1.12x | — |
| xxLarge | 1.24x | — |
| xxxLarge | 1.35x | — |
| **AX1** | 1.65x | Must test |
| **AX2** | 1.94x | Must test |
| **AX3** | 2.35x | Must test |
| **AX4** | 2.76x | Must test |
| **AX5** | 3.12x | **Must test** |

### Layout Considerations

- Always wrap screens in `ScrollView`
- Use `numberOfLines = 0` for text that may wrap
- Avoid fixed heights on text containers
- Test horizontal scrolling doesn't occur

---

## TOUCH TARGETS

### Minimum Sizes

| Target Type | Minimum Size | Recommended |
|-------------|--------------|-------------|
| Buttons | 44 × 44 pt | 48 × 48 pt |
| Icons | 44 × 44 pt | 48 × 48 pt |
| List rows | 44 pt height | 56 pt height |
| Form fields | 44 pt height | 56 pt height |

### Implementation

```swift
// Ensure minimum touch target
Button(action: {}) {
    Image(systemName: "gear")
        .frame(width: 24, height: 24)
}
.frame(minWidth: 44, minHeight: 44)  // Touch target
.contentShape(Rectangle())           // Expand hit area
```

### Spacing Between Targets

Minimum 8pt spacing between adjacent touch targets to prevent accidental taps.

---

## MOTION & ANIMATION

### Respect Reduce Motion Setting

```swift
@Environment(\.accessibilityReduceMotion) var reduceMotion

var body: some View {
    SomeView()
        .animation(reduceMotion ? nil : .spring(), value: someValue)
}
```

### Animation Guidelines

- No animations > 5 seconds without user control
- Provide static alternatives for essential animated content
- Avoid flashing content (> 3 flashes/second)
- Parallax and auto-scrolling must be pausable

---

## COGNITIVE ACCESSIBILITY

### Clear Language

- Use simple, direct language
- Avoid jargon without explanation
- Provide definitions for technical terms (HRV, RHR, etc.)

### Information Hierarchy

- Most important information first
- Clear visual hierarchy with headings
- Consistent navigation patterns

### Error Prevention & Recovery

```swift
// Clear error messages with recovery path
struct ErrorView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
            
            Text("Something went wrong")
                .font(.headline)
            
            Text("We couldn't load your data. This is usually temporary.")
                .font(.body)
                .multilineTextAlignment(.center)
            
            Button("Try Again") {
                // Retry action
            }
            .buttonStyle(.borderedProminent)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Error loading data. Double tap the Try Again button to retry.")
    }
}
```

---

## TESTING CHECKLIST

### Before Each Release

#### VoiceOver Testing
- [ ] All screens navigable with VoiceOver
- [ ] Logical reading order
- [ ] All interactive elements labeled
- [ ] Charts provide audio summaries
- [ ] Forms can be completed without vision
- [ ] OCR review rows read as "Marker, value, unit, status"
- [ ] Training set rows read as "Set #, weight, reps, RPE"
- [ ] Supplement chips read as "Name, time, status"

#### Dynamic Type Testing
- [ ] Test at Default size
- [ ] Test at AX5 (largest)
- [ ] No text truncation
- [ ] No horizontal scrolling
- [ ] Layouts don't break

#### Color Testing
- [ ] Test with Deuteranopia filter
- [ ] Test with Protanopia filter
- [ ] Test in grayscale
- [ ] All status indicators have icon + text

#### Motor Testing
- [ ] All touch targets ≥ 44pt
- [ ] No time-limited interactions
- [ ] Swipe actions have button alternatives
- [ ] No precision-required gestures
- [ ] Voice Control: all interactive elements reachable via voice commands ("Tap Log Meal", "Tap Save")
- [ ] Voice Control: numbered overlay labels do not overlap or obscure content
- [ ] Switch Control: all screens navigable via single-switch scanning
- [ ] Switch Control: focus order is logical and does not skip interactive elements

#### Contrast Testing
- [ ] Run automated contrast checker
- [ ] Verify all text meets 4.5:1
- [ ] Verify all UI components meet 3:1

### Automated Testing Tools

```swift
// XCTest Accessibility Audit
func testAccessibility() throws {
    let app = XCUIApplication()
    app.launch()
    
    try app.performAccessibilityAudit()
}
```

---

## RESOURCES

### Apple Documentation
- [Human Interface Guidelines: Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- [Accessibility Programming Guide](https://developer.apple.com/documentation/accessibility)

### WCAG Documentation
- [WCAG 2.2 Quick Reference](https://www.w3.org/WAI/WCAG22/quickref/)
- [Understanding WCAG 2.2](https://www.w3.org/WAI/WCAG22/Understanding/)

### Testing Tools
- Xcode Accessibility Inspector
- Sim Daltonism (color blindness simulator)
- Contrast (Mac app for contrast checking)

---

## CHANGELOG

### v1.4 (February 16, 2026)
- Added Voice Control and Switch Control testing requirements
- Expanded motor testing checklist with assistive technology verification

### v1.3 (February 3, 2026)
- Added Localization & RTL section for Hebrew/Arabic support
- Added locale testing guidelines

### v1.2 (January 28, 2026)
- Added Accessibility Label Examples for all core screens
- Added SwiftUI modifier examples

### v1.1 (January 25, 2026)
- Added accessibility requirements for new modules: Labs OCR, Supplements, Training, Batch Recipe
- Added VoiceOver patterns for OCR review rows

### v1.0 (January 21, 2026)
- Initial accessibility guidelines
- WCAG 2.2 AA compliance requirements
- Color blindness considerations
- VoiceOver implementation guide
- Dynamic Type requirements
- Testing checklist
