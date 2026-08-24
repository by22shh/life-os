# LIFE OS — PRODUCT REQUIREMENTS DOCUMENT

**Version:** 7.13 (Monetization & Distribution)  
**Date:** February 16, 2026  
**Platform:** iOS 17+ (Native). watchOS 9+ is Phase 2 (companion-only; no core workflows in V1).  
**Vision:** Your external consciousness for human performance optimization

> [!IMPORTANT]
> **v7.13 Changes (Feb 16, 2026):**
> - Added Monetization & Subscription Model section (V1/V2 free, Premium V3+)
> - Added App Store Strategy section (review prompts, privacy labels, category)
>
> **v7.11 Changes (Feb 4, 2026):**
> - Locked V2 scope: Unified Daily Diary, Sleep surfaces, Templates mgmt, Insights/Experiments UX, watchOS companion
> - Added Focus Control technical flow + consent guardrails (Guardian mode)
> - Added deterministic notification orchestration algorithm + hard cap enforcement
>
> [!IMPORTANT]
> **v7.10 Changes (Feb 3, 2026):**
> - Expanded copy catalog scope to cover core app flows (incl. Onboarding + Nutrition)
> - Added diary (calendar) user flow notes (Nutrition + Training)
>
> **v7.9 Changes (Feb 3, 2026):**
> - Added analytics events taxonomy for new modules
>
> **v7.8 Changes (Feb 3, 2026):**
> - Added localization and i18n rules for new modules
> - Added Settings preferences for Training/Supplements/Labs
>
> **v7.7 Changes (Feb 3, 2026):**
> - Added copy catalog as source of truth
>
> **v7.6 Changes (Feb 3, 2026):**
> - Aligned UX copy with Design System copy library (Training/Supplements/Labs)
>
> **v7.5 Changes (Feb 3, 2026):**
> - Added edge case handling per module
>
> **v7.4 Changes (Feb 3, 2026):**
> - Added detailed user flows for Training, Supplements, and Labs
> - Finalized navigation rules (tabs + profile entry)
>
> **v7.3 Changes (Feb 3, 2026):**
> - Added full Training module (logging + AI plan + adaptive rules)
> - Added Supplements + Labs module (stack, timing, OCR scans, biomarker trends)
> - Updated Information Architecture for multi-domain use
> - Expanded onboarding profile to include training/diet/supplement preferences
> - Updated success metrics to include training/supplement adherence
>
> **v7.2 Changes (Feb 2026):**
> - Added Progress Indicator to Onboarding Flow
> - Enhanced HealthKit Permission messaging with privacy assurance
> - Added Internalization-Focused Design section (SDT research 2025)
> - Added Celebration Moments to notification strategy
> - Added optional Micro-Zones for Pro/Athlete users
> - Delayed notification permission to post-onboarding
>
> **v7.1 Changes:**
> - Added detailed Notification Strategy with Gottman 5:1 ratio
> - Updated Gamification → Self-Determination Theory approach
> - Added Accessibility Requirements section
> - Simplified Recovery Zones (6 → 4)
> - Added Onboarding Flow specification

---

## EXECUTIVE SUMMARY

### The Problem

Humans are complex biological machines with ~100 trillion variables affecting performance. Current solutions:
- **Fitness apps** track activity but ignore recovery
- **Food apps** count calories but miss context
- **Sleep apps** measure rest but don't adapt your day
- **Wellness apps** give generic advice, not personalized intelligence

**Result:** You're managing 5+ apps, manually connecting dots, burning willpower on basic decisions.

### The Solution

Life OS is your **external prefrontal cortex** — an AI system that:
1. **Sees** what you can't (patterns in 90 days of data)
2. **Remembers** everything (RAG-powered long-term memory)
3. **Thinks** for you (contextual recommendations)
4. **Protects** you (automatic intervention when biology says "stop")
5. **Adapts** constantly (no rigid plans, only dynamic optimization)

### The Vision

> "What if your phone knew you better than you know yourself — and used that knowledge only to help you thrive?"

**For:** You, personally. This is a tool-for-self, not a commercial product (yet).  
**When it works:** You can't imagine life without it. It becomes invisible infrastructure.

---

## RELEASE PLAN (V1 → V2) (LOCKED)

To avoid scope creep and ensure one-shot implementation quality, Life OS is shipped in two phases.

### V1 (iOS MVP)
- Core onboarding + HealthKit connect (read-only)
- Nutrition diary + fast logging (photo/barcode/voice/search) + CIS barcode fallback (label OCR + review)
- Training diary + manual strength logging + HealthKit import + conflict resolution
- Supplements basic stack + log + schedule endpoints
- Labs OCR import + review + privacy defaults
- Notifications settings + control levels (Advisory/Protective/Guardian) + Focus Control integration (optional)

### V2 (Ecosystem Surfaces + watchOS companion)
- Unified Daily Diary (one screen: sleep/recovery + meals + workouts + supplements + labs)
- Sleep surfaces (sleep diary + trends + dedicated sleep detail as a first-class feature)
- Nutrition templates management (library/edit/pin) for true “log in seconds”
- Insights & Experiments surfaces (list/detail + daily experiment logging)
- watchOS companion:
  - Complications (Recovery)
  - Glance view (Recovery + next action)
  - Lightweight confirmations (e.g., “Taken” for supplements) when safe

**Non-goals for V2:**
- Writing data back to Apple Health (still read-only)
- Clinical diagnosis or dosing recommendations

## PRODUCT PHILOSOPHY

### Core Metaphor: The Adaptive Operating System

```
┌─────────────────────────────────────────┐
│              HUMAN SYSTEM               │
│                                         │
│  INPUTS          PROCESSOR    OUTPUTS   │
│  ├─ Food        ┌─────────┐   ├─ Work  │
│  ├─ Sleep       │ YOUR    │   ├─ Sport │
│  ├─ Light       │ BIOLOGY │   ├─ Think │
│  └─ Movement    └─────────┘   └─ Heal  │
│                                         │
│  SENSORS         LIFE OS      ACTIONS   │
│  ├─ HRV         ┌─────────┐   ├─ Recommend │
│  ├─ Sleep       │   AI    │   ├─ Adjust    │
│  ├─ Activity    │ BRAIN   │   ├─ Block     │
│  └─ Nutrition   └─────────┘   └─ Optimize  │
└─────────────────────────────────────────┘
```

### Design Principles

#### 1. **Invisible Intelligence**
The best interface is no interface. Reduce decisions to zero.

**Bad:** "Should I work out today?"  
**Good:** Silent auto-adjustment based on HRV. You just see: "Light yoga today" vs "Heavy lifting unlocked"

#### 2. **Radical Honesty**
No toxic positivity. No gamification that lies. Real data, real consequences.

**Bad:** "Great job! 🎉" (when you skipped sleep)  
**Good:** "✕ Critical. Your body needs rest, not praise"

#### 3. **Asymmetric Awareness**
You see only what you need to act on. AI sees everything.

**User sees:** "Recovery: 73% ✓ Ready — Moderate intensity today"  
**AI knows:** HRV trend (-8%), sleep debt (2.3h), menstrual cycle day 14, caffeine intake pattern, stress biomarkers...

#### 4. **Proactive Protection**
The app intervenes BEFORE you make mistakes.

**Example:** You open Instagram at 23:00. If **Focus Control** is enabled, the app blocks it: "Your HRV is -12%. Screen time restricted for recovery"

#### 5. **N=1 Science**
Not population averages. YOUR data. YOUR patterns. YOUR optimal.

**Population:** "Drink 8 glasses of water"  
**N=1:** "YOUR optimal hydration is 2.3L, correlated with 3% better sleep when consumed before 18:00"

#### 6. **Predictive Analytics (What-If Scenarios) (NEW v7.14)**
Moving beyond tracking the past, the system helps you simulate the future before taking an action, heavily reinforcing the *Autonomy* pillar of SDT.

**Example:** "What if I sleep at 01:00 today after my workout?"  
**System responds:** Contextualizes historical N=1 data to project tomorrow's Recovery Score (e.g. 30-40% Caution) and explains *why* (disrupted slow-wave sleep affecting muscle repair). The user decides what to do with this forecast.

---

## USER PSYCHOLOGY & BEHAVIORAL DESIGN

### The Motivation Spectrum

Users exist on a spectrum of self-regulation:

```
Low Agency ←──────────────────→ High Agency
(need control)                   (want freedom)

Life OS adapts tone and autonomy based on recovery state:
```

**Critical Zone (Recovery 0-24%):**  
→ **Paternalistic mode:** "I'm taking over. No gym today. Apps blocked (if Focus Control enabled). Extra sleep scheduled"

**Caution Zone (Recovery 25-49%):**  
→ **Caution guidance:** "Take it easy today. Light activity only."

**Ready Zone (Recovery 50-74%):**  
→ **Collaborative mode:** "Here's what I see. What do you think?"

**Optimal Zone (Recovery 75-100%):**  
→ **Enabler mode:** "You're strong. Push harder today? I'll track the response"

### Habit Formation Strategy (UPDATED: SDT-Based)

> [!IMPORTANT]
> **v7.1 Update:** Based on Self-Determination Theory research, which shows intrinsic motivation outperforms external rewards for long-term behavior change.

**Goal:** Make the app a **reflex**, not a task — through intrinsic motivation, not dopamine manipulation.

#### The Three Pillars of Intrinsic Motivation (SDT)

1. **Autonomy** — User feels in control
   - Always offer choices, never force
   - "Would you like to..." not "You must..."
   - Customizable goals and thresholds

2. **Competence** — User feels effective
   - Clear progress indicators
   - Celebrate understanding, not just metrics
   - "You're learning your body's patterns"

3. **Relatedness** — User feels connected
   - AI as supportive partner, not judge
   - Community features (optional)
   - Shared experiments with friends

#### Phase 1: Discovery (Days 1-7)
- **Strategy:** Instant value demonstration
- **Hook:** AI Vision (photo → results in 2 seconds)
- **SDT Focus:** Competence ("Look what you can understand now!")

#### Phase 2: Pattern Recognition (Days 8-30)
- **Strategy:** Personalized insights
- **Hook:** First "aha moment" ("I noticed YOUR pattern...")
- **SDT Focus:** Autonomy ("Here's data. You decide what to do.")

#### Phase 3: Mastery (Days 31-90)
- **Strategy:** Self-experimentation
- **Hook:** N-of-1 experiments user designs
- **SDT Focus:** All three pillars active

#### Phase 4: Symbiosis (Day 90+)
- **Strategy:** Invisible infrastructure
- **Hook:** Life feels incomplete without it
- **SDT Focus:** Integrated into identity

### Internalization-Focused Design (NEW v7.2)

> [!TIP]
> **Research (Frontiers, 2025):** Design should help users internalize motivation, making the technology "progressively less necessary."

**Principle:** Shift language from app-dependency to self-awareness.

| Old Approach | Internalization Approach |
|--------------|-------------------------|
| "App reminds you to drink water" | "You're learning to recognize thirst patterns" |
| "We tracked your sleep" | "You now understand your sleep cycles" |
| "App blocked social media (if Focus Control enabled)" | "You chose to protect your recovery" |
| "AI detected a pattern" | "You're developing body awareness" |

**Implementation:**
- After 30 days: Celebrate user's own pattern recognition
- After 60 days: "You noticed this yourself before we did!"
- After 90 days: "Your intuition about recovery is now 85% aligned with data"

### Ethical Streak Design (NEW)

> [!WARNING]
> **Research finding:** Streaks can backfire. Users with broken streaks often abandon apps entirely.

**Principles:**

1. **Frame breaks as normal:**
   ```
   ❌ "You lost your 14-day streak 😢"
   ✅ "47 out of 50 days — incredible consistency! Rest is part of the journey."
   ```

2. **Flexible streaks:**
   - Weekly targets (5/7 days) instead of daily requirements
   - "Activity days this month: 23/31" not "Current streak: 0"

3. **Recovery mechanics:**
   - One "grace day" per week (automatic)
   - "Earn back" option for missed days

4. **Celebrate effort, not perfection:**
   ```
   "You logged meals on 89% of days this month. That's exceptional!"
   ```

---

## NOTIFICATION STRATEGY (NEW SECTION)

> [!CRITICAL]
> **Research insight:** Personalized notifications show 259% higher engagement.
> Mobile users receive ~46 notifications/day — selectivity is critical.

### The Gottman Ratio: 5:1 Positive to Negative

For every corrective/warning notification, send 5 supportive/positive ones.

**Why:** John Gottman's research on relationships shows that a 5:1 ratio of positive to negative interactions predicts lasting engagement.

### Notification Categories

#### 1. Morning Brief (Daily, ~7:00 AM)
**Frequency:** 1/day  
**Purpose:** Set the day's context

```
┌─────────────────────────────────────────┐
│  Good morning, Alex ☀️                  │
│                                         │
│  Recovery: 73% ✓ Ready                  │
│                                         │
│  "Your body is recovered. Moderate      │
│   intensity workout is appropriate."    │
│                                         │
│  Today's focus: +20g protein by lunch   │
│                                         │
│  [Open Life OS]                         │
└─────────────────────────────────────────┘
```

#### 2. Positive Reinforcement (0-3/day max)
**Frequency:** Triggered by achievements  
**Purpose:** Build confidence (Competence pillar)

```
Examples:
• "✨ Protein target hit 3 days in a row — your muscle recovery thanks you"
• "🎯 Sleep consistency this week: 92% — that's elite level"
• "💪 Your HRV is trending up 8% — adaptation happening"
• "📈 Pattern detected: You naturally eat less sugar after good sleep"
```

#### 3. Celebration Moments (NEW v7.2)
**Frequency:** 1-2/week, unpredictable timing  
**Purpose:** Unexpected positive reinforcement (research shows +40% emotional engagement)

```
Examples:
• "Just checking in — you've been consistent this week! 💪"
• "Fun fact: Your average HRV improved 12% vs last month"
• "Random appreciation: You logged 89% of meals this month. That's exceptional!"
• "Did you know? Your Sunday sleep is consistently your best. Keep protecting it!"
```

**Rules for Celebration Moments:**
- Never tied to goal completion (unexpected = more impactful)
- Vary timing to avoid predictability
- Focus on trends and patterns, not single events
- Use warm, conversational tone

#### 4. Gentle Nudges (0-2/day max)
**Frequency:** Context-dependent  
**Purpose:** Course correction without judgment

```
Examples:
• "🥗 Lunch idea: You're 25g short on protein. Chicken salad would close the gap."
• "☕ Heads up: Late caffeine can reduce sleep quality. Consider an earlier cutoff."
• "🌙 Optimal bedtime in 90 minutes for your target 7.5h sleep"
• "🏋️ Workout in 1h: light carbs + water for better performance"
• "💊 Supplement reminder: Magnesium scheduled at 21:00 (with food)"
```

#### 5. Critical Alerts (Rare)
**Frequency:** Only when truly necessary  
**Purpose:** Protect user from harm

```
Examples:
• "⚠️ Recovery at 22% (Critical). Rest day strongly recommended."
• "⚠️ Sleep debt: 4+ hours accumulated. Priority: early bedtime tonight."
• "⚠️ Training load spike detected (ACWR 1.6). Reduce intensity today."
```

### Notification Timing Rules

| Type | Allowed Hours | Max/Day | Batching |
|------|---------------|---------|----------|
| Morning Brief | 06:00-09:00 | 1 | — |
| Positive | 08:00-21:00 | 3 | Group within 2h |
| Nudges | 10:00-20:00 | 2 | Never back-to-back |
| Critical | Any | 1 | Never batch |

### User Control

```
Settings → Notifications:
├─ Morning Brief: [ON/OFF] Time: [07:00 ▼]
├─ Positive reinforcement: [ON/OFF] (max 3/day)
├─ Gentle nudges: [ON/OFF] (max 2/day)
├─ Critical alerts only: [ON/OFF]
└─ Quiet hours: [22:00] to [07:00]
```

> Morning Brief is exempt from quiet hours suppression and will be delivered within the 06:00–09:00 window regardless of quiet hours setting.

### Global Notification Cap (Hard Rule)

**Maximum total notifications per day:** **6**  
If multiple notifications are eligible, apply priority:
1. Critical alert
2. Morning brief
3. Gentle nudge
4. Positive reinforcement
5. Celebration moment

When the cap is reached, drop the lowest-priority item(s) silently.

---

## USER CONTROL MODEL (NEW)

Life OS must support explicit **Control Level** selection. This makes the “app controls you” vision safe, consented, and legally defensible.

**Control Levels:**
1. **Advisory (default)** — The app recommends; user decides.
2. **Protective** — The app may strongly discourage actions and schedule recovery, but does not block apps.
3. **Guardian** — The app may enforce Focus/Screen Time restrictions if the user explicitly enables Focus Control.

**Rules:**
- Guardian level requires explicit opt-in + system permission (iOS Screen Time/FamilyControls).
- The user can downgrade control level at any time.
- If Focus Control is unavailable or permission is denied, Guardian behaves like Protective and logs a warning.
- All automated “block” actions must be reversible and time-bound.

### Focus Control Integration (iOS)

**Goal:** allow Guardian mode to enforce Focus/Screen Time restrictions safely.

**Rules:**
1. Guardian mode requires explicit consent + Screen Time permission.
2. If permission is denied or restricted, fall back to Protective and show a banner.
3. All restrictions must be time‑bound (max 2 hours per rule).
4. User can “Pause control for today” at any time.
5. Never block core health apps (Health, Emergency, Phone).
6. All blocked apps must be visible in Settings → Control (transparency).

**Consent UX (Mandatory):**
1. Explain what will be blocked and for how long.
2. Require explicit confirm + system permission prompt.
3. Provide “Not now” and “Learn more”.

**Safety Guardrails:**
- Never block when the user is actively logging a health event.
- Never block within 15 minutes of an alarm or scheduled wake‑up.
- Do not block for users who opt into “Critical alerts only”.

### Focus Control Technical Flow (iOS FamilyControls)

**Client flow (high level):**
1. Request Screen Time authorization (FamilyControls).
2. If granted, present app selection UI (user chooses what can be blocked).
3. Store selected apps locally; sync only derived flags (not app list).
4. When Guardian rules trigger, apply Focus restriction for a bounded window (≤ 2h).
5. On window end or user pause, remove restriction.

**Failure behavior:**
- If authorization is revoked later, Guardian downgrades to Protective and shows a banner.
- If applying a restriction fails, log error and skip enforcement for that cycle.

---

## NOTIFICATION ORCHESTRATION (NEW)

**Goal:** maximum relevance with strict respect for user attention.

**Inputs:**
- Notification settings (`/api/settings/notifications`)
- Recovery zone
- Missing data signals
- Upcoming training sessions
- Quiet hours

**Algorithm (Priority Queue):**
```
eligible = generate_candidates()            // by category + triggers
eligible = remove_quiet_hours(eligible)
eligible = enforce_category_limits(eligible) // positive<=3, nudges<=2
eligible = sort_by_priority(eligible)       // critical > morning > nudges > positive > celebration
scheduled = take_first(eligible, max_total=6)
drop_rest(silently=true)
```

**Critical Overrides:**
- Critical alerts may bypass quiet hours **only if** “Critical alerts only” is enabled OR a hard safety rule triggers (e.g., severe recovery deficit).

**Non‑negotiable:**
- Never exceed 6 notifications/day.

### Anti-Patterns to Avoid

❌ **Never:** Guilt-inducing language ("You haven't logged in 3 days!")
❌ **Never:** Fake urgency ("Your streak is about to expire!")
❌ **Never:** Social comparison ("Others are doing better than you")
❌ **Never:** More than 6 notifications in a day
❌ **Never:** Notifications during user's sleep hours

---

## MENTAL HEALTH SUPPORT (NEW v7.3)

> [!IMPORTANT]
> **Research:** Extended periods of low recovery and high stress can indicate need for professional support.
> Life OS provides resources, not diagnosis.

### PSS-4 Stress Assessment

The app includes the validated 4-item Perceived Stress Scale (Cohen, 1983) as an optional weekly check-in:

**Questions (0-4 scale: Never → Very Often):**
1. "In the last week, how often have you felt unable to control important things in your life?"
2. "In the last week, how often have you felt confident about handling your personal problems?" *(reverse)*
3. "In the last week, how often have you felt things were going your way?" *(reverse)*
4. "In the last week, how often have you felt difficulties piling up so high you couldn't overcome them?"

**Score Interpretation (0-16):**
- 0-4: Low stress
- 5-8: Moderate stress
- 9-12: High stress
- 13-16: Very high stress

### Mental Health Resource Triggers

Resources are shown (once, non-intrusively) when:
- PSS-4 score ≥ 12 for 2+ consecutive weeks
- Recovery in Critical zone for 7+ consecutive days
- User reports "feeling ill" + low energy for 5+ days without temperature elevation

### Mental Health Resources

```yaml
RESOURCES:
  crisis_hotlines:
    - name: "Телефон доверия (Россия)"
      number: "8-800-2000-122"
      hours: "24/7, бесплатно"

    - name: "International Association for Suicide Prevention"
      url: "https://www.iasp.info/resources/Crisis_Centres/"
      note: "Ресурсы по странам"

  apps_and_services:
    - name: "Headspace"
      type: "Meditation & mindfulness"
      url: "https://headspace.com"

    - name: "Calm"
      type: "Sleep & relaxation"
      url: "https://calm.com"

    - name: "Woebot"
      type: "CBT-based chatbot"
      url: "https://woebot.io"

  professional_help:
    message: |
      "If you're struggling, speaking with a mental health professional can help.
      Consider reaching out to a psychologist, therapist, or your doctor."

UI_PRINCIPLES:
  - Resources shown once, then accessible via Settings → Support
  - Never alarmist ("You might be depressed!")
  - Always supportive ("We noticed you've been stressed. Here are some resources.")
  - Easy to dismiss without guilt
  - Never blocks app usage
```

---

## RECOVERY ZONES (SIMPLIFIED)

> [!IMPORTANT]
> **v7.1 Update:** Simplified from 6 zones to 4 for instant recognition and reduced cognitive load.

### Previous (v7.0): 6 Zones
- Supercharged, Charged, Moderate, Depleted, Drained, Emergency

### New (v7.1): 4 Zones

| Zone | Score | Color | Icon | User Sees | App Behavior |
|------|-------|-------|------|-----------|--------------|
| **Optimal** | 75-100% | Blue | ✓ | "Ready for anything" | Enable high intensity |
| **Ready** | 50-74% | Green | ↗ | "Good to go" | Normal recommendations |
| **Caution** | 25-49% | Amber / Yellow | ⚠ | "Take it easy" | Suggest light activity |
| **Critical** | 0-24% | Red | ✕ | "Rest required" | Block intense activity |

### Visual Representation (NEW v7.2)

Use gradient transition between zones for natural perception:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Critical    Caution       Ready        Optimal
    🔴 ░░░░░░░ 🟠 ░░░░░░░ 🟢 ░░░░░░░ 🔵
   0%   25%        50%          75%        100%
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

### Optional: Pro/Athlete Micro-Zones (NEW v7.2)

> [!TIP]
> **Research:** Serious athletes prefer more granular feedback in the Optimal zone.

**Settings → Recovery → Show Micro-Zones: [OFF by default]**

When enabled, Optimal zone splits into:

| Micro-Zone | Score | Athlete Sees |
|------------|-------|-------------|
| **Peak** | 90-100% | "Maximum capacity — push hard today" |
| **Strong** | 80-89% | "Very ready — high intensity OK" |
| **Solid** | 75-79% | "Good — moderate-high intensity" |

### Why This Change

1. **Faster recognition:** Traffic light metaphor is universal
2. **Reduced decision fatigue:** Fewer categories = clearer action
3. **Better accessibility:** 4 colors easier to distinguish for color-blind users
4. **Matches competitors:** Whoop/Oura use similar 3-4 zone systems
5. **Pro option available:** Athletes get granular data without overwhelming casual users

---

## ACCESSIBILITY REQUIREMENTS (NEW SECTION)

> [!CRITICAL]
> **Statistic:** 8% of men have red-green color vision deficiency.
> **Requirement:** Color can NEVER be the only way to convey information.

### WCAG 2.2 AA Compliance

| Requirement | Standard | Life OS Implementation |
|-------------|----------|------------------------|
| Color contrast | 4.5:1 minimum | All colors verified (see wireframes) |
| Non-color indicators | Required | Every status has icon + text label |
| Touch targets | 44x44pt minimum | Enforced in design system |
| Text scaling | Up to 200% | Dynamic Type supported |
| Screen reader | Full support | VoiceOver labels required |

### Mandatory Pattern: Status Indicators

Every status MUST include three elements:
1. **Color** (for quick recognition)
2. **Icon** (for color-blind users)
3. **Text label** (for screen readers and clarity)

```swift
// ✅ CORRECT
"✓ Optimal" + Blue color + VoiceOver: "Recovery optimal, 82 percent"

// ❌ WRONG
Blue circle only (no icon, no label)
```

### VoiceOver Labels

All UI elements must have descriptive accessibility labels:

```swift
// Recovery Score
accessibilityLabel: "Recovery score: 73 percent, Ready status. Your body is recovered and ready for moderate intensity."

// Nutrition Card
accessibilityLabel: "Nutrition today: 1420 of 2100 calories, 68 percent complete. Protein 45 of 120 grams."

// Charts
accessibilityLabel: "Recovery trend chart for past 7 days. Average 68 percent, trending upward."
```

### Dynamic Type Support

All text must scale with system settings:
- Use `UIFont.preferredFont(forTextStyle:)`
- Test at AX5 (largest accessibility size)
- Layouts must not break at large sizes

### Color Blindness Safe Palette

For data visualization with multiple categories, use the Okabe-Ito palette:

| Color | Hex | Use |
|-------|-----|-----|
| Orange | #E69F00 | Category 1 |
| Sky Blue | #56B4E9 | Category 2 |
| Bluish Green | #009E73 | Category 3 |
| Yellow | #F0E442 | Category 4 |
| Blue | #0072B2 | Category 5 |
| Vermillion | #D55E00 | Category 6 |

---

## ONBOARDING FLOW SPECIFICATION (UPDATED v7.2)

> [!IMPORTANT]
> **Research:** 77% of daily active users abandon apps in the first 3 days.
> This onboarding is designed to deliver value within 2 minutes.

### Principles

1. **Value before friction:** Show what app can do before asking for data
2. **Max 6 steps** before core app access
3. **Social proof at dropout points** (step 4)
4. **Instant gratification:** First insight immediately after setup
5. **Progress visibility:** Always show user where they are (NEW v7.2)
6. **Delayed notifications:** Ask for permission after value delivery (NEW v7.2)

### Progress Indicator (NEW v7.2)

> [!TIP]
> **Research (2025):** 81% of users prefer step-by-step tours with visible progress indicators.

```
┌─────────────────────────────────────────────────────┐
│                                                     │
│   ━━━━━━━━━━●━━━━━━━━━━   Step 3 of 6               │
│                                                     │
│   ✓ Welcome  ✓ Demo  ● Health  ○ Profile  ○ Insight  ○ Notify │
│                                                     │
└─────────────────────────────────────────────────────┘
```

**Implementation:**
- Horizontal progress bar at top of each screen
- Step labels below bar (responsive, hide on small screens)
- Completed steps show checkmark ✓
- Current step shows filled circle ●
- Future steps show empty circle ○

### Flow Specification (UPDATED v7.2)

| Step | Screen | Goal | Drop-off Mitigation | v7.2 Changes |
|------|--------|------|---------------------|---------------|
| 1 | Value Proposition | Answer "Why should I care?" | Testimonial, clear benefit | — |
| 2 | Quick Win (Photo Demo) | Instant gratification | Show AI power immediately | — |
| 3 | HealthKit Permission | Connect data source | Enhanced privacy messaging (v7.2) | ⭐ Enhanced |
| 4 | Basic Profile | Personalization + preferences | Training level, diet, supplement use | — |
| 5 | First Insight | Deliver value | Show Recovery Score | Moved up |
| 6 | Notifications | Enable engagement | Ask AFTER showing value | ⭐ Delayed |

### Basic Profile Fields (NEW v7.3)

**Required:**
- Age range
- Sex at birth (recommended, skippable)
- Height, weight
- Primary goal (recovery, performance, weight, general health)

**Training:**
- Experience level
- Available days/week
- Session length
- Equipment access

**Nutrition:**
- Diet preference (omnivore, vegetarian, vegan, keto, other)
- Allergies/intolerances

**Supplements + Labs:**
- Supplements currently used (yes/no)
- Interested in lab tracking (yes/no)

### HealthKit Permission Screen (ENHANCED v7.2)

> [!IMPORTANT]
> **Research:** This is the #1 drop-off point. Strong privacy messaging is critical.

```
┌─────────────────────────────────────────────────────┐
│                                                     │
│   ━━━━━━━━━━●━━━━━━━━━━   Step 3 of 6               │
│                                                     │
│   🔒 Connect Apple Health                        │
│                                                     │
│   Life OS needs access to your health data to       │
│   calculate your Recovery Score and provide         │
│   personalized insights.                            │
│                                                     │
│   ┌─────────────────────────────────────────────┐   │
│   │  🔐 YOUR DATA STAYS ON YOUR DEVICE           │   │
│   │                                             │   │
│   │  • We never sell or share your data         │   │
│   │  • Processing happens on your iPhone        │   │
│   │  • You can disconnect anytime               │   │
│   └─────────────────────────────────────────────┘   │
│                                                     │
│   ┌─────────────────────────────────────────────┐   │
│   │  📊 WHAT YOU'LL SEE:                         │   │
│   │                                             │   │
│   │       73% ✓ Ready                           │   │
│   │  "Your body is recovered and ready for     │   │
│   │   moderate intensity training"              │   │
│   │                                             │   │
│   │  (Example based on your connected data)     │   │
│   └─────────────────────────────────────────────┘   │
│                                                     │
│   [  Connect HealthKit  ]                           │
│                                                     │
│   Skip for now (limited features)                   │
│                                                     │
└─────────────────────────────────────────────────────┘
```

**Key changes:**
1. Privacy badge prominent at top
2. Preview of what user will see AFTER connecting
3. "Skip" option clearly available
4. Trust-building language ("your device", "never sell")

### Notification Permission (DELAYED v7.2)

> [!TIP]
> **Research:** Asking for notification permission at onboarding increases immediate uninstall rate.

**Strategy:** Delay notification permission until AFTER first insight is delivered.

```
┌─────────────────────────────────────────────────────┐
│                                                     │
│   ━━━━━━━━━━━━━━━━━━━━●   Step 6 of 6               │
│                                                     │
│   🎉 Your First Insight!                             │
│                                                     │
│            73% ✓ Ready                              │
│                                                     │
│   "Based on last night's 7h 20m sleep and your     │
│    HRV of 54ms, you're recovered and ready for     │
│    moderate intensity today."                       │
│                                                     │
│   ─────────────────────────────────────────────────│
│                                                     │
│   💬 Want insights like this delivered?             │
│                                                     │
│   We'll send your morning brief and gentle         │
│   nudges throughout the day. You control           │
│   frequency and timing.                            │
│                                                     │
│   [  Enable Notifications  ]                        │
│                                                     │
│   Maybe later                                       │
│                                                     │
└─────────────────────────────────────────────────────┘
```

**If skipped:** Re-prompt after Day 3 "aha moment" with contextual value.

### Metrics

- **Target completion rate:** 75%+ reach step 5 (increased from 70%)
- **Time to complete:** < 2.5 minutes
- **First insight delivery:** Step 5 (immediate)
- **Notification opt-in:** Target 60% by Day 7 (delayed strategy)

---

## INFORMATION ARCHITECTURE

### Navigation Philosophy: **Contextual Depth**

Most apps fail with flat navigation. Life OS uses **context-aware surfaces**:

```
┌─────────────────────────────────────────┐
│         ADAPTIVE HOME SCREEN            │
│  (Changes based on time, recovery, etc) │
│                                         │
│  Morning (6-10):                        │
│  ┌─────────────────────────────────┐   │
│  │ 73% ✓ Ready                     │   │
│  │ "Your body is ready. Consider   │   │
│  │  a challenging workout today"   │   │
│  │                                 │   │
│  │ ☕️ First meal timing: 08:30    │   │
│  │ 💡 Take Vitamin D with breakfast│   │
│  └─────────────────────────────────┘   │
│                                         │
│  Pre-Lunch (11-13):                     │
│  ┌─────────────────────────────────┐   │
│  │ 🍽️ Protein deficit: -15g        │   │
│  │ "Next meal should prioritize    │   │
│  │  lean protein + healthy fats"   │   │
│  └─────────────────────────────────┘   │
│                                         │
│  Evening (20-22):                       │
│  ┌─────────────────────────────────┐   │
│  │ 🌙 Sleep prep in 90 minutes     │   │
│  │ • Blue light filter: ON         │   │
│  │ • Social media: BLOCKED (if Focus Control enabled) │   │
│  │ • Magnesium reminder: 21:30     │   │
│  └─────────────────────────────────┘   │
└─────────────────────────────────────────┘
```

### Screen Hierarchy

**Tab Bar (5 items, central Log):**
1. Home
2. Nutrition
3. Log (central quick action)
4. Training
5. Supplements

**Insights:** surfaced on Home and within each module (no dedicated tab).
**Profile/Settings:** accessible via avatar on Home.

**Level 0: Glanceable (Lock Screen Widget)**
```
73% ✓ Ready | 1420/1850 kcal | 💤 7h 20m
```

**Level 1: Actionable (Home Screen)**
- Recovery Score + Status (icon + label)
- Quick food log (camera button)
- Quick workout log (dumbbell button)
- Quick supplement log (pill button)
- Quick lab scan (camera document)
- Critical alerts only

**Level 2: Analytical (Deep Dive)**
- Trends (7/30/90 days)
- Experiments
- Correlations

**Level 3: Educational (Context)**
- "Why does this matter?"
- Scientific explanations
- Personal patterns

---

## UX COPY SOURCE OF TRUTH (NEW v7.7)

All UI copy for core app flows must map to:
`life_os_copy_catalog.md`

Rules:
- No new CTA text without updating the copy catalog
- Core screens use exact copy from the catalog

### Localization & i18n (NEW v7.8)

**String rules:**
- No hardcoded UI strings in code
- All UI strings reference `copy_id` from `life_os_copy_catalog.md`
- Variables use `{variable}` placeholders only

**Length budgets:**
- CTA: 1-3 words
- Title: <= 28 chars (English)
- Helper text: <= 80 chars (English)

**Fallback behavior:**
- If `copy_id` missing, show `global.no_copy_fallback`

---

## SETTINGS & PREFERENCES (NEW v7.8)

**Training**
- Enable training plans (on/off)
- Default rest timer (30s/60s/90s/custom)
- RPE prompts (on/off)
- Auto-adjust plans based on recovery (on/off)

**Supplements**
- Reminder windows (morning/afternoon/evening)
- Skip guilt-free messaging (always on)
- Interaction warnings (on/off)

**Labs**
- OCR auto-save (off by default)
- Require manual verification (on by default)
- Lab trend notifications (on/off)

**Privacy**
- Lab scans stored locally by default (opt-in cloud sync)
- Delete raw scans after 90 days (default on)

---

## USER FLOWS (NEW v7.4)

### 1) Food Photo Log
1. Tap `Log` -> `Food Photo`
2. Capture meal (grid + lighting hints)
3. AI analysis returns items + macros + confidence
4. User edits items if needed
5. Save meal -> update daily targets + insights

### 2) Workout Logging (Strength)
1. Tap `Log` -> `Workout`
2. Select or search exercise
3. Enter sets (weight, reps, RPE)
4. End session -> summary + training load update
5. Recovery forecast updated for next day

### 3) Training Plan Creation
1. Training tab -> `Create Plan`
2. Choose goal, days, duration, equipment
3. Review plan preview
4. Accept -> plan scheduled on calendar
5. Daily auto-adjustments based on recovery + load

### 4) Supplement Stack Setup
1. Supplements tab -> `Add Supplements`
2. Search catalog or custom entry
3. Enter user dose + schedule
4. Timing suggestions (no dosing changes)
5. Daily reminders -> quick log

### 5) Lab Scan & Biomarker Review
1. Supplements tab -> `Labs` -> `Scan`
2. Capture photo / upload PDF
3. OCR extracts values + confidence
4. User verifies or edits
5. Save -> trends + insights update

### 6) Cross-Domain Insight
1. New data triggers background analysis
2. Insight appears on Home and module
3. User taps for details
4. Optional experiment created
5. Results logged and surfaced

### 7) Diaries (Calendar Views)
1. User opens Nutrition or Training
2. Selects a day via week strip or month grid
3. Sees “Day view” summary (totals + entries)
4. Taps an entry to view/edit details
5. Logs new entries for a specific date (supports backfill)

> Notes:
> - Calendar must not require 30 API calls for a month view.
> - Month view uses icons + a11y labels (never color-only).

### Edge Cases & Recovery (NEW v7.5)

**Food**
- Low confidence -> require user confirmation before saving
- No food detected -> retake or manual entry
- Offline -> save locally and sync later
- Duplicate meal time -> suggest merge

**Training**
- Missing sets -> allow quick save as "session without details"
- Wearable import conflict -> show merge vs replace options
- Recovery critical -> recommend mobility instead of plan session

**Training Plan**
- Insufficient data -> request missing profile fields
- Injury conflicts -> replace exercises with alternatives
- Missed sessions -> reschedule, never double next day

**Supplements**
- Interaction warning -> show caution, still allow
- Missed dose -> mark as skipped, no guilt messaging
- New supplement request -> advise clinician, allow catalog view only

**Labs**
- OCR low confidence -> require review before save
- Unit conversion fail -> manual correction
- Duplicate scan -> show duplicate warning

**Navigation rule:** Never more than 2 taps to any action

---

## CORE MODULES

### MODULE 1: RECOVERY ENGINE

#### 1.1 The Recovery Score (Simplified Zones)

**Display:** 72pt hero number with icon + label (accessibility compliant)

```
┌─────────────────────────────────────┐
│                                     │
│            73                       │  72pt Bold
│         ✓ Ready                     │  Icon + Label
│                                     │
│   ████████████████████░░░░░░░░░    │  Color-coded bar
│                                     │
│   "Your body is recovered and       │
│    ready for moderate intensity"    │
│                                     │
│   Contributing factors:             │
│   ↗ Sleep: 7h 23m (good)           │
│   → HRV: 52ms (baseline)            │
│   ↘ RHR: 58bpm (slightly elevated) │
│                                     │
└─────────────────────────────────────┘
```

### MODULE 2: NUTRITION TRACKER

#### 2.1 AI Food Recognition

**Speed requirement:** Photo → Results in < 3 seconds  
**Accuracy target:** 90%+ for common foods

**Display (accessibility compliant):**
```
🥩 Protein   45/120g   ████████░░░░
🥑 Fat       38/70g    █████████░░░
🍞 Carbs     180/250g  ██████████░░
🥬 Fiber     12/30g    ████░░░░░░░░
```

Each macro has:
- Emoji icon (distinguishable)
- Text label
- Number values
- Progress bar

#### 2.2 Multi-Modal Logging

**Supported inputs:**
1. Photo (single plate, multi-plate, meal prep containers)
2. Barcode (packaged foods)
3. Voice ("I had chicken salad with olive oil")
4. Manual entry (full control)
5. Recipe/Batch (meal prep with per-portion macros)

**Rules:**
- Default to photo for speed
- Ask for weight only when confidence < 0.65
- Always allow 1-tap correction

#### 2.3 Micronutrients & Timing

Track:
- Vitamins (A, B-complex, C, D, E, K)
- Minerals (iron, magnesium, zinc, calcium, potassium)
- Special: caffeine, alcohol, omega-3/6 ratio

Timing intelligence:
- Pre-workout and post-workout windows
- Late-night eating warnings
- Caffeine cutoff based on sleep target

#### 2.4 Dynamic Targets

Daily targets adjust based on:
- Training load
- Recovery zone
- Sleep debt
- Goal phase (cut/bulk/maintain)

#### 2.5 Meal Planning

Features:
- Remaining-macro suggestions
- Grocery list (weekly)
- Quick meal templates

---

### MODULE 3: TRAINING SYSTEM

#### 3.1 Workout Logging

Modes:
- Manual strength logging (sets, reps, weight, RPE)
- Wearable-imported cardio
- Template-based logging

Required outcomes:
- Training load update (ACWR)
- Recovery impact prediction

#### 3.2 AI Training Plan

Inputs:
- Experience level
- Available days + session length
- Equipment access
- Injury constraints
- Recovery baseline

Outputs:
- 4-8 week mesocycle
- Weekly split
- Progressive overload rules
- Deload scheduling

#### 3.3 Adaptive Rules

Examples:
- Recovery in Caution zone (25–49): reduce volume 30%
- Recovery in Critical zone (0–24): replace with mobility + walking
- ACWR > 1.5: reduce intensity

---

### MODULE 4: SUPPLEMENTS + LABS

#### 4.1 Supplement Stack

- User-entered stack with schedules
- Timing optimization only (no dosing changes)
- Adherence tracking
- Interaction warnings (e.g., calcium + iron)

#### 4.2 Labs + Biomarkers

- OCR scan of blood tests (photo/PDF)
- Canonical marker normalization
- Trend analysis + comparisons
- Critical flags with clinician reminder

---

### MODULE 5: AI INSIGHTS & EXPERIMENTS

#### 5.1 Insight Generation

Insights follow the structure:
1. **Pattern observed** (data-backed)
2. **Why it matters** (education)
3. **Recommended action** (specific)
4. **Experiment option** (optional)

```
┌─────────────────────────────────────┐
│ 💡 PATTERN DETECTED                 │
│                                     │
│ When you sleep 7.5h+, your recovery │
│ averages 76% vs 58% on short sleep. │
│                                     │
│ Recommendation: Target 23:00        │
│ bedtime for 7.5h sleep.             │
│                                     │
│ [Start Experiment]    [Dismiss]     │
└─────────────────────────────────────┘
```

---

## CONTRAINDICATIONS & LIMITATIONS (NEW v7.3)

> [!WARNING]
> **Medical Safety:** Life OS is a wellness tool, not a medical device.
> Users with certain conditions should consult healthcare providers before relying on app recommendations.

### Conditions Requiring Medical Consultation

| Condition | Limitation | Recommendation |
|-----------|-----------|----------------|
| **Cardiac arrhythmias** (AFib, frequent PVCs) | HRV readings unreliable | Consult cardiologist; HRV features may be disabled |
| **Pacemaker or ICD** | HRV not applicable | Disable HRV scoring; rely on other metrics |
| **Beta-blocker medication** | Artificially lowers HR/HRV | Baseline will adapt, but interpretation differs |
| **Pregnancy** | HRV, temperature, and recovery norms change | Use pregnancy mode (if implemented) or consult OB/GYN |
| **Eating disorders (active)** | Calorie/macro tracking may be triggering | Option to hide numerical nutrition data |
| **Clinical depression/anxiety** | Low scores may worsen mood | Mental health mode with encouraging messaging |
| **Overtraining syndrome** | May require clinical intervention | App detects patterns but cannot diagnose |
| **Chronic fatigue syndrome** | Standard activity recommendations may be harmful | Conservative recommendations mode |
| **Type 1 Diabetes** | Blood glucose affects recovery | Consider integrating CGM data if available |
| **Sleep apnea (untreated)** | Sleep metrics skewed | Recommend sleep study; flag in interpretation |

### App Behavior for At-Risk Users

```typescript
interface UserHealthFlags {
  hasCardiacCondition: boolean;
  hasPacemaker: boolean;
  onBetaBlockers: boolean;
  isPregnant: boolean;
  hasEatingDisorderHistory: boolean;
  hasMentalHealthCondition: boolean;
  hasChronicFatigue: boolean;
}

function adjustAppBehavior(flags: UserHealthFlags): AppMode {
  if (flags.hasPacemaker || flags.hasCardiacCondition) {
    return {
      disableHRV: true,
      disclaimer: 'HRV features disabled due to cardiac condition. Recovery based on sleep and activity only.'
    };
  }

  if (flags.hasEatingDisorderHistory) {
    return {
      hideCalories: true,
      hideMacroNumbers: true,
      showQualitativeOnly: true,
      disclaimer: 'Numerical nutrition data hidden. Focus on balanced eating patterns.'
    };
  }

  if (flags.hasMentalHealthCondition) {
    return {
      gentleMessaging: true,
      noNegativeAlerts: true,
      emphasizeProgress: true
    };
  }

  return { standardMode: true };
}
```

### Onboarding Health Screening

During onboarding, users are asked:
1. "Do you have any heart conditions?" (Yes → cardiac mode)
2. "Do you have a pacemaker or implanted device?" (Yes → disable HRV)
3. "Are you currently pregnant?" (Yes → pregnancy mode)
4. "Have you ever been diagnosed with an eating disorder?" (Yes → hide numbers option)

**Privacy:** These flags are stored locally only and never transmitted.

---

## SUCCESS METRICS

### Phase 0 (Weeks 1-3)

**Primary:**
- [ ] Daily active use: 7/7 days
- [ ] Onboarding completion: 70%+

**Secondary:**
- [ ] Food logs per day: 3+
- [ ] First workout logged: 60%+
- [ ] First supplement log (if enabled): 40%+
- [ ] App opens per day: 5+
- [ ] Crashes: 0

---

### Phase 1 (Weeks 4-8)

**Primary:**
- [ ] 30-day retention: 90%+
- [ ] Notification engagement: 40%+ tap-through

**Secondary:**
- [ ] Macro adherence: 6/7 days hit targets
- [ ] Training adherence: 3/4 planned sessions completed
- [ ] Supplement adherence: 70% of scheduled doses logged
- [ ] User satisfaction: 8/10 (self-reported)

---

### Phase 2 (Weeks 9-16)

**Primary:**
- [ ] Experiments completed: 1+
- [ ] Insights acted upon: 3+

**Secondary:**
- [ ] RAG queries per week: 5+
- [ ] Lab scans uploaded: 30% of users (opt-in)
- [ ] Behavior changes: 2+ (based on AI suggestions)

---

### Phase 3 (Weeks 17-24)

**Primary:**
- [ ] AI interventions accepted: 80%+ (vs ignored)
- [ ] Health improvements: Measurable (sleep +10%, recovery variance -20%)

**Secondary:**
- [ ] Screen time reduction: 30min/day
- [ ] User trust score: 9/10

---

### Phase 4 (Month 7+)

**Primary:**
- [ ] External user retention: 80%+ at 30 days
- [ ] App Store rating: 4.5+ stars

**Secondary:**
- [ ] Referrals: 1+ per user
- [ ] Accessibility audit: Pass WCAG 2.2 AA

---

## ANALYTICS EVENTS (NEW v7.8)

**Rules:**
- All events must include `user_id`, `timestamp`, `session_id`
- Do not log raw health values in analytics (privacy)
- Use derived buckets or booleans (e.g., `recovery_zone`)

### Training
- `training_workout_started` { workout_type, source }
- `training_set_logged` { exercise_id, set_number }
- `training_workout_completed` { duration_minutes, total_volume }
- `training_plan_generated` { goal, days_per_week }
- `training_plan_adjusted` { reason, adjustment }

### Supplements
- `supplement_added` { catalog_id, schedule_count }
- `supplement_logged` { supplement_name, taken_on_time }
- `supplement_warning_shown` { warning_type }

### Labs
- `lab_scan_uploaded` { scan_type, input_method }
- `lab_ocr_review_started` { confidence_bucket }
- `lab_ocr_review_completed` { corrections_count }
- `lab_marker_viewed` { marker_id }

---

## APPENDIX: RESEARCH FOUNDATIONS

### Scientific Basis

This app is built on real science, not bro-science:

**Recovery Science:**
- Heart Rate Variability as autonomic nervous system proxy (Shaffer & Ginsberg, 2017) — [DOI: 10.3389/fpubh.2017.00258](https://doi.org/10.3389/fpubh.2017.00258)
- Allostatic load theory (McEwen & Stellar, 1993)
- Sleep debt accumulation (Van Dongen et al., 2003)
- ACWR training load monitoring with limitations (Gabbett, 2020) — [DOI: 10.1136/bjsports-2019-101402](https://doi.org/10.1136/bjsports-2019-101402)

**Nutrition Science:**
- Nutrient timing for performance (Kerksick et al., 2017)
- Glycemic index and energy regulation (Ludwig, 2002)
- Protein distribution and muscle protein synthesis (Mamerow et al., 2014)

**Behavioral Science:**
- Habit formation (Lally et al., 2010: 66 days to automaticity)
- N-of-1 trials methodology (Duan et al., 2013)
- Implementation intentions (Gollwitzer, 1999)
- Self-Determination Theory (Deci & Ryan, 2000) — [DOI: 10.1207/S15327965PLI1104_01](https://doi.org/10.1207/S15327965PLI1104_01)
- Gottman ratio for engagement (Gottman, 1994) — ISBN: 978-0805814026

**Sleep & Circadian Science:**
- Chronotype assessment (Horne & Östberg, 1976) — PMID: 1027738
- Orthosomnia prevention (Baron et al., 2017) — [DOI: 10.5664/jcsm.6472](https://doi.org/10.5664/jcsm.6472)
- Sleep drives brain metabolite clearance (Xie et al., 2013) — [DOI: 10.1126/science.1241224](https://doi.org/10.1126/science.1241224)

**Digital Wellbeing:**
- Screen time and mental health (Twenge & Campbell, 2018)
- Blue light and circadian disruption (Chang et al., 2015)

**Accessibility Research:**
- Color blindness prevalence (8% of males) — Colour Blind Awareness
- WCAG 2.2 guidelines — W3C
- Mobile health app retention challenges (PMC, 2022)

---

## FINAL THOUGHTS

### What Makes This Different

Most health apps are **data collectors**.  
Life OS is a **decision maker**.

Most apps say: "Here's your data. Good luck."  
Life OS says: "I've analyzed your data. Here's what to do."

Most apps punish missed days.  
Life OS celebrates consistency: "47 out of 50 days — incredible!"

Most apps are tools you use.  
Life OS is a partner you trust.

### The Long-Term Vision

**Year 1:** You use it  
**Year 2:** You can't live without it  
**Year 3:** You evangelize it  
**Year 5:** It's the standard for human optimization

---

---

## LOCALIZATION SCOPE

### V2 Supported Languages

| Language | Code | Priority | Notes |
|----------|------|----------|-------|
| English | `en` | Launch | Default locale. All copy IDs resolve to English. |
| Russian | `ru` | Launch | Primary CIS market. Copy Catalog must include Russian translations for all V2 strings. |

### V3+ Expansion Candidates

| Language | Code | Trigger |
|----------|------|----------|
| Kazakh | `kk` | If Kazakhstan user base > 5% |
| Ukrainian | `uk` | If Ukraine user base > 5% |
| Turkish | `tr` | If Turkey user base > 5% |
| German | `de` | If EU expansion approved |

### RTL Policy
- No RTL languages are supported in V2.
- If RTL support is added in V3+, all SwiftUI layouts must be audited for `flipsForRightToLeftLayoutDirection`.
- Leading/trailing constraints are already used throughout (per Apple HIG), so RTL adaptation is structurally feasible.

### Date & Number Formatting

| Element | Rule | Example (en) | Example (ru) |
|---------|------|--------------|--------------|
| Dates | Use `Date.FormatStyle` with user's locale | "Feb 16, 2026" | "16 февр. 2026 г." |
| Times | Respect 12h/24h system setting | "2:30 PM" | "14:30" |
| Numbers | Use `NumberFormatter` with locale | "1,234.5" | "1 234,5" |
| Weight | kg (default), lb (user preference) | "72.5 kg" | "72,5 кг" |
| Calories | kcal (always) | "2,100 kcal" | "2 100 kcал" |
| Percentages | Use locale-aware formatter | "78%" | "78 %" |

### Localization Rules
1. All user-visible strings use Copy Catalog IDs (see `life_os_copy_catalog.md`).
2. No hardcoded strings in SwiftUI views. All strings are resolved via `String(localized:)` or `LocalizedStringKey`.
3. Plural forms use `stringsdict` or `String(localized:)` with `inflect: true` where applicable.
4. CIS-specific edge cases are documented in `life_os_cis_edge_cases.md`.
5. App Store metadata (title, description, keywords) is localized for both `en` and `ru`.

---

## MONETIZATION & SUBSCRIPTION MODEL

> [!NOTE]
> V1 and V2 are **free** with no monetization. All features are available to all users.
> Premium tier is planned for **V3+** and is explicitly out of scope for current implementation.

### V1/V2: Free Tier (All Features)

| Feature | Access |
|---------|--------|
| Recovery Score + 4-zone model | ✅ Unlimited |
| Food logging (photo AI + manual + barcode) | ✅ Unlimited |
| Workout logging + training load | ✅ Unlimited |
| Supplement tracking | ✅ Unlimited |
| Lab scan OCR + biomarker tracking | ✅ Unlimited |
| Daily wellness checks | ✅ Unlimited |
| AI insights (weekly strategy) | ✅ Rate-limited (see API spec) |
| N-of-1 experiments | ✅ Unlimited |
| watchOS companion | ✅ Unlimited |
| Widgets | ✅ Unlimited |
| Data export (GDPR) | ✅ Unlimited |

> AI endpoint rate limits (50 food analyses/day, 10 insights/hour, etc.) are cost-protection measures, not monetization gates.

### V3+ Premium Tier (Future — Not In Scope)

Potential premium features (subject to validation):

| Feature | Free | Premium |
|---------|------|--------|
| AI food analyses | 50/day | Unlimited |
| AI insights generation | 10/hour | Unlimited |
| Training plan generation | 5/day | Unlimited |
| Medical scan analysis | 10/day | Unlimited |
| Priority AI processing | Standard | Priority queue |
| Advanced trends (90+ days) | ❌ | ✅ |
| Team/Coach sharing | ❌ | ✅ |

**Pricing model:** To be validated through user research. StoreKit 2 integration with server-side receipt validation via Supabase Edge Function.

**Decision rationale:** Monetization is deferred to learn real usage patterns before gating features. This avoids premature optimization of pricing tiers.

---

## APP STORE STRATEGY

### App Store Listing

| Field | Value |
|-------|-------|
| **Category** | Health & Fitness |
| **Subcategory** | — |
| **Age Rating** | 4+ |
| **In-App Purchases** | None (V1/V2) |
| **Languages** | English, Russian |

### Review Prompt Timing

```
Trigger: SKStoreReviewController.requestReview()
Condition: user has completed ≥ 5 successful AI food analyses
           AND app has been used on ≥ 3 unique days
           AND review has not been requested in the last 120 days
Rationale: prompt at a "value delivery moment" — user has experienced
           the core differentiator (AI food analysis) enough to form an opinion.
```

> [!IMPORTANT]
> Apple limits review prompts to 3 per year per user. Do **not** prompt on first launch or during onboarding.

### Privacy Nutrition Labels (App Store Connect)

| Data Type | Collection | Linked to Identity | Tracking |
|-----------|------------|-------------------|----------|
| Health & Fitness | Yes | Yes | No |
| Body (weight, height) | Yes | Yes | No |
| Photos (food images) | Yes | No (processed, not stored) | No |
| Usage Data | Yes | No | No |
| Diagnostics | Yes | No | No |
| Email Address | Yes (auth) | Yes | No |

> Privacy labels must be updated if push notification backend sends remote notifications (device token → "Identifiers" category).

### App Review Preparation

- Demo account credentials in App Store Connect notes
- Test food images pre-loaded for reviewer
- HealthKit entitlement usage description is mandatory
- Camera usage description is mandatory
- If Apple Watch required for full functionality, note this explicitly

---

## CHANGELOG

### v7.13 (February 16, 2026) — Monetization & Distribution
- Added Monetization & Subscription Model section (V1/V2 free, Premium V3+)
- Added App Store Strategy section (category, review prompts, privacy labels, review preparation)

### v7.12 (February 16, 2026) — Localization Scope
- Added Localization Scope section: V2 languages (en + ru), date/number formatting, RTL policy

### v7.9 (February 3, 2026) — Analytics
- Added analytics event taxonomy for Training, Supplements, Labs

### v7.8 (February 3, 2026) — Localization + Settings
- Added localization/i18n rules for new modules
- Added settings/preferences for Training, Supplements, Labs

### v7.7 (February 3, 2026) — Copy Catalog
- Added copy catalog as source of truth for new modules

### v7.6 (February 3, 2026) — Copy Alignment
- Aligned PRD with Design System copy library (Training/Supplements/Labs)

### v7.5 (February 3, 2026) — Edge Cases
- Added edge case handling per module

### v7.4 (February 3, 2026) — Ecosystem Flows
- Added detailed user flows for Food, Training, Supplements, Labs
- Finalized navigation rules for tabs and profile entry

### v7.3 (February 3, 2026) — Ecosystem Expansion
**New Modules:**
- Training system (logging + AI plans + adaptive rules)
- Supplements + Labs (stack, timing, OCR scans, biomarker trends)

**Information Architecture:**
- Added Training and Supplements surfaces
- Insights surfaced inside Home and modules

**Onboarding:**
- Expanded profile fields (training, diet, supplements, labs interest)

**Metrics:**
- Added training and supplement adherence metrics
- Added lab scan adoption metric

### v7.2 (February 1, 2026) — UX Research Update
Based on comprehensive UX analysis using research from NIH, Frontiers in Psychology, Self-Determination Theory Institute, and industry analysis of Whoop/Oura/Apple Health (2024-2026).

**Onboarding Improvements:**
- Added visual Progress Indicator (research: 81% of users prefer visible progress)
- Enhanced HealthKit Permission screen with privacy badge and value preview
- Delayed Notification Permission to post-value-delivery (reduces uninstall rate)
- Reduced steps from 7 to 6 (moved Social Proof, combined with First Insight)

**Self-Determination Theory Enhancements:**
- Added Internalization-Focused Design section
- New copy guidelines: shift from app-dependency to self-awareness language
- Progressive messaging: "You're developing body awareness" vs "AI detected"

**Notification Strategy Updates:**
- Added Celebration Moments (1-2/week, unexpected positive reinforcement)
- Research shows +40% emotional engagement from unpredictable positive notifications

**Recovery Zones Enhancements:**
- Added gradient visual representation for natural zone perception
- Added optional Micro-Zones for Pro/Athlete users (Peak/Strong/Solid)
- Micro-zones off by default, accessible in Settings

**Metrics Updated:**
- Target onboarding completion: 75%+ (was 70%)
- Target time: <2.5 minutes (was <3 minutes)
- New metric: Notification opt-in 60% by Day 7

### v7.1 (January 21, 2026)
- Added Notification Strategy with Gottman 5:1 ratio
- Updated Gamification → Self-Determination Theory approach
- Added Accessibility Requirements section (WCAG 2.2 AA)
- Simplified Recovery Zones from 6 to 4
- Added Onboarding Flow specification
- Added Ethical Streak Design principles
- Updated success metrics to include accessibility audit
