# Training accessibility fixes — 2026-09-09

- `TrainingDayView.swift`, only the `TrainingDayView` declaration: date, cloud availability, empty state and supporting plan/session text use existing `LifeOSColors.Text.secondary/tertiary`. These tokens replace system secondary/tertiary colors which failed or nearly failed contrast on the warm application surfaces.
- `TrainingCalendarSupport.swift`, UI declarations only: week summary labels and calendar captions use the same text tokens; selected weekday uses primary text; Month uses the existing stronger semantic primary tint.
- The week grid retains seven columns at standard sizes, changes to four for larger ordinary Dynamic Type and two for accessibility sizes. Metric text wraps instead of shrinking; summary values expand vertically. This addresses the same audit's weekday Dynamic Type failures without suppressing audit issues.
- Database loaders, calendar dates, selection callbacks, workout editing and view models are unchanged by this patch.
- `git diff --check`: PASS. No Xcode/build/simulator command was run by this worker. The parent runs the actual accessibility audit against the rebuilt app; no runtime PASS is claimed here.

## Follow-up after the actual audit

`ios-a11y-final.log` no longer reported the date, cloud notice, empty state or summary-title contrast findings. It still reported Month, two narrow “T” glyphs, and Dynamic Type issues on weekday/date/blank metric nodes and summary titles.

- Month now uses primary foreground explicitly. Weekday glyphs use primary foreground and scalable subheadline semibold instead of caption2.
- Removed the blank `Text(" ")` metric placeholders. Missing metrics render no text node.
- Each day button exposes a combined, complete date/workout/status accessibility label, retaining the selected trait. Decorative dots are not separate accessibility elements; their meaning remains in the date button summary.
- Summary title/value are a combined element. `AnyLayout` switches between horizontal and vertical layout while retaining the same child views; the previous `ViewThatFits` had two distinct sets of text nodes.
- Dynamic fonts, adaptive grid, wrapping and all actual text remain available. Audit rules were not filtered or suppressed. Rebuilt runtime verification remains the parent's next step.

## Final integrated result

The remaining week-row Dynamic Type issue was resolved by replacing `LazyVGrid` with an eager `AnyLayout`: horizontal at standard sizes, vertical above `.large`. This retains the same accessibility nodes during font-size changes and gives each date room to wrap. This supersedes the intermediate four/two-column layout described above.

The rebuilt critical-flow accessibility test passed for Nutrition, Training, Insights and Privacy: `ios-a11y-recheck2.log`, 54.782 seconds, no issues excluded or suppressed. The accompanying Insights/Experiments scenario also passed; the run completed with 2 tests and 0 failures.
