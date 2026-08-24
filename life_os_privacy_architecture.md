# LIFE OS — PRIVACY & DATA ARCHITECTURE

**Version:** 1.7 (GDPR Export Format)
**Date:** February 16, 2026  
**Purpose:** Data classification, encryption, retention, and compliance strategy

---

## PRIVACY PRINCIPLES

### Core Tenets

1. **Data Minimization** — Collect only what's necessary
2. **Purpose Limitation** — Use data only for stated purposes
3. **Local-First** — Process on-device when possible
4. **Transparency** — User always knows what's collected and why
5. **User Control** — Easy export, deletion, and opt-out

---

## DATA CLASSIFICATION

### Classification Matrix

| Data Type | Classification | Storage | Encryption | Retention | Sync to Cloud |
|-----------|---------------|---------|------------|-----------|---------------|
| Auth credentials | **Critical** | Keychain only | AES-256-GCM | Session | No |
| Health metrics (HRV, RHR) | **Sensitive** | Local + Supabase | At rest + transit | Account lifetime | Yes |
| Sleep data | **Sensitive** | Local + Supabase | At rest + transit | Account lifetime | Yes |
| Food photos | **Personal** | Supabase Storage | At rest + transit | 90 days | Yes |
| Food label photos (OCR fallback) | **Personal** | In-memory only (default) | Transit | Not stored | No |
| Nutrition logs | **Personal** | Local + Supabase | At rest + transit | Account lifetime | Yes |
| Workout logs | **Sensitive** | Local + Supabase | At rest + transit | Account lifetime | Yes |
| Training plans | **Sensitive** | Local + Supabase | At rest + transit | Account lifetime | Yes |
| Supplement logs | **Sensitive** | Local + Supabase | At rest + transit | Account lifetime | Yes |
| Medical scans (raw) | **Sensitive** | Local only (default) | At rest | 90 days | Opt-in |
| Lab markers (derived) | **Sensitive** | Local + Supabase | At rest + transit | Account lifetime | Yes |
| GPS location | **Sensitive** | Local only (default) | Per-session | 24 hours | No (opt‑in only) |
| Menstrual cycle data | **Sensitive** | On‑device by default | Encrypted at rest | User-controlled | No (default, explicit opt-in only) |
| Vector embeddings (derived summaries) | **Sensitive** | External processor (opt‑in) | In transit + at rest | User-controlled | Yes (opt‑in) |
| Device info | **Internal** | Local only | None | Session | No |
| Crash reports | **Internal** | Anonymized cloud | Transit | 30 days | Yes (anon) |
| Focus Control app list | **Sensitive** | Local only | At rest | User-controlled | No |
| Wellness checks | **Sensitive** | Local + Supabase | At rest + transit | Account lifetime | Yes |
| Experiments | **Personal** | Local + Supabase | At rest + transit | Account lifetime | Yes |
| Experiment measurements | **Personal** | Local + Supabase | At rest + transit | Account lifetime | Yes |
| Training templates | **Personal** | Local + Supabase | At rest + transit | Account lifetime | Yes |
| Hydration logs | **Personal** | Local + Supabase | At rest + transit | Account lifetime | Yes |
| Body composition | **Sensitive** | Local + Supabase | At rest + transit | Account lifetime | Yes |
| Health diagnoses | **Restricted** | Local only (default) | At rest | User-controlled | No |

### Classification Definitions

```swift
enum DataClassification {
    case critical   // Auth, payment (if any)
    case sensitive  // Health data, biometrics
    case personal   // User content, preferences
    case `internal` // App operation data
    case `public`   // Non-identifying metadata
}

protocol ClassifiedData {
    var classification: DataClassification { get }
    var encryptionRequired: Bool { get }
    var canExport: Bool { get }
    var canDelete: Bool { get }
    var retentionPeriod: RetentionPeriod { get }
}
```

### On-Device Only (Strict)

These data types are **never** stored in the cloud by default:
- Menstrual cycle data (dates, symptoms, phase detail)
- Raw medical documents and scans (only derived markers may sync if user opts in)
- Precise GPS coordinates (opt‑in required; otherwise local-only)
- Focus Control app selection list (stored locally only)
- User health flags (`user_health_flags`) — local-only by default; cloud backup only when `cloud_backup_enabled = true` (explicit user opt-in). See `life_os_sync_engine_spec.md` for sync behavior.

Menstrual data remains on-device unless the user explicitly disables `menstrual_local_only`; when enabled, sync follows the standard outbox/privacy gates.

---

## ENCRYPTION STRATEGY

### Encryption Layers

```
┌─────────────────────────────────────────────────────────┐
│                    USER DEVICE                          │
│                                                         │
│  ┌─────────────────────────────────────────────────┐   │
│  │  iOS Data Protection (Hardware Encryption)       │   │
│  │                                                   │   │
│  │  ┌───────────────────────────────────────────┐  │   │
│  │  │  Keychain (Face ID / Passcode Protected)  │  │   │
│  │  │  • API keys                                │  │   │
│  │  │  • Auth tokens                             │  │   │
│  │  │  • Encryption keys                         │  │   │
│  │  └───────────────────────────────────────────┘  │   │
│  │                                                   │   │
│  │  ┌───────────────────────────────────────────┐  │   │
│  │  │  SQLite (NSFileProtectionComplete)        │  │   │
│  │  │  • Health metrics                          │  │   │
│  │  │  • Food logs                               │  │   │
│  │  │  • User preferences                        │  │   │
│  │  └───────────────────────────────────────────┘  │   │
│  │                                                   │   │
│  └─────────────────────────────────────────────────┘   │
│                                                         │
└─────────────────────────────────────────────────────────┘
                         │
                         │ TLS 1.3 (in transit)
                         ▼
┌─────────────────────────────────────────────────────────┐
│                    SUPABASE                             │
│                                                         │
│  ┌─────────────────────────────────────────────────┐   │
│  │  PostgreSQL (AES-256 at rest)                   │   │
│  │  • RLS enforced                                  │   │
│  │  • User data isolated by user_id                │   │
│  └─────────────────────────────────────────────────┘   │
│                                                         │
│  ┌─────────────────────────────────────────────────┐   │
│  │  Supabase Storage (S3-compatible, encrypted)    │   │
│  │  • Food photos                                   │   │
│  │  • Medical scans                                 │   │
│  └─────────────────────────────────────────────────┘   │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

### iOS Implementation

```swift
// Keychain access
class SecureStorage {
    private let keychain = KeychainSwift()
    
    func saveCredential(_ key: String, value: String) {
        keychain.set(value, forKey: key, withAccess: .accessibleWhenUnlockedThisDeviceOnly)
    }
    
    func getCredential(_ key: String) -> String? {
        return keychain.get(key)
    }
    
    func deleteCredential(_ key: String) {
        keychain.delete(key)
    }
}

// Database encryption
class SecureDatabase {
    private var db: Connection
    
    init() throws {
        let dbPath = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.lifeos")!
            .appendingPathComponent("lifeOS.sqlite")
        
        // Set file protection
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: dbPath.path
        )
        
        db = try Connection(dbPath.path)
    }
}
```

### Network Security

```swift
// URLSession configuration
let config = URLSessionConfiguration.default
config.tlsMinimumSupportedProtocolVersion = .TLSv13
config.urlCredentialStorage = nil  // Don't cache credentials

// Certificate pinning
class CertificatePinningDelegate: NSObject, URLSessionDelegate {
    private let pinnedCertificates: [Data]
    
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard let serverTrust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate],
              let certificate = chain.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        let serverCertData = SecCertificateCopyData(certificate) as Data
        
        if pinnedCertificates.contains(serverCertData) {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
```

---

## RETENTION POLICIES

### Retention Schedule

| Data Type | Active Retention | Archive | Deletion |
|-----------|------------------|---------|----------|
| User profile | Account lifetime | N/A | On account deletion |
| Health metrics | Account lifetime | N/A | On account deletion or on request |
| Sleep data | Account lifetime | N/A | On account deletion or on request |
| Food logs | Account lifetime | N/A | On account deletion or on request |
| Food photos | 90 days | None | Auto-delete |
| Food label photos (OCR fallback) | Not stored (ephemeral) | N/A | Immediate (never persisted) |
| Medical scans (raw) | 90 days (default) | User-pinned | Auto-delete |
| AI analysis cache | 7 days | None | Auto-delete |
| Crash reports | 30 days | None | Auto-delete |
| Session logs | 7 days | None | Auto-delete |
| Experiment data | Account lifetime | N/A | On account deletion or on request |
| Insights | 1 year | None | Auto-delete (1 year) or on account deletion |
| Workout logs | Account lifetime | N/A | On account deletion |
| Training plans | Account lifetime | N/A | On account deletion |
| Supplement logs | Account lifetime | N/A | On account deletion |
| Lab markers (derived) | Account lifetime | N/A | On account deletion |

**Important (nutrition label OCR):**
- Label photos used for barcode fallback (`analyze-food-label`) must be treated as **ephemeral inputs**.
- Default behavior: process in-memory and do not store in Supabase Storage or DB.
- Persist only structured nutrition values after user review (see `life_os_food_data_strategy.md`).

### Implementation

```swift
class RetentionManager {
    private let database: Database
    
    func enforceRetention() async {
        // Run daily at 3:00 AM local time
        
        // Delete old food photos (90 days)
        let photosCutoff = Calendar.current.date(byAdding: .day, value: -90, to: Date())!
        await deletePhotosOlderThan(photosCutoff)

        // Delete old medical scans (raw) unless user-pinned
        let scansCutoff = Calendar.current.date(byAdding: .day, value: -90, to: Date())!
        await deleteMedicalScansOlderThan(scansCutoff, keepPinned: true)
        
        // Delete old AI cache (7 days)
        let cacheCutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
        await clearCacheOlderThan(cacheCutoff)
        
        // Delete old insights (1 year)
        let insightsCutoff = Calendar.current.date(byAdding: .year, value: -1, to: Date())!
        await deleteInsightsOlderThan(insightsCutoff)
        
        // Focus Control app list is user-controlled and never auto-deleted
        
        // Log retention run
        Logger.shared.log(.info, "Retention enforcement completed")
    }
    
    private func deletePhotosOlderThan(_ date: Date) async {
        // 1. Get list of photo IDs to delete
        // 2. Delete from Supabase Storage
        // 3. Mark food_logs.image_url as null (keep nutritional data)
    }
}
```

---

## GDPR COMPLIANCE

### Data Subject Rights Implementation

#### 1. Right to Access (Article 15)

```swift
class DataExportService {
    func exportAllUserData(userId: UUID) async throws -> URL {
        var exportData = ExportPackage()

        // ── Core profile ──
        exportData.profile = try await fetchProfile(userId)
        exportData.healthFlags = try await fetchHealthFlags(userId)
        exportData.notificationSettings = try await fetchNotificationSettings(userId)

        // ── Health metrics (recovery, HRV, RHR, temperature) ──
        exportData.healthMetrics = try await fetchAllHealthMetrics(userId)
        exportData.healthMeasurements = try await fetchAllHealthMeasurements(userId)
        exportData.bodyComposition = try await fetchAllBodyComposition(userId)

        // ── Nutrition ──
        exportData.foodLogs = try await fetchAllFoodLogs(userId)        // includes food_items
        exportData.mealTemplates = try await fetchAllMealTemplates(userId)
        exportData.batchRecipes = try await fetchAllBatchRecipes(userId) // includes batch_recipe_ingredients
        exportData.userFoodFavorites = try await fetchAllUserFoodFavorites(userId)

        // ── Hydration ──
        exportData.hydrationLogs = try await fetchAllHydrationLogs(userId)

        // ── Training ──
        exportData.workoutSessions = try await fetchAllWorkoutSessions(userId) // includes workout_sets
        exportData.trainingPlans = try await fetchAllTrainingPlans(userId)
        exportData.trainingTemplates = try await fetchAllTrainingTemplates(userId) // V2
        exportData.customExercises = try await fetchAllCustomExercises(userId)

        // ── Supplements ──
        exportData.userSupplements = try await fetchAllUserSupplements(userId)
        exportData.supplementLogs = try await fetchAllSupplementLogs(userId)

        // ── Sleep ──
        exportData.sleepLogs = try await fetchAllSleepLogs(userId)      // V2

        // ── Labs & Medical ──
        exportData.medicalScans = try await fetchAllMedicalScans(userId)
        exportData.labMarkers = try await fetchAllLabMarkers(userId)

        // ── Experiments ──
        exportData.experiments = try await fetchAllExperiments(userId)   // includes experiment_measurements

        // ── Wellness ──
        exportData.wellnessChecks = try await fetchAllWellnessChecks(userId)

        // ── AI-generated ──
        exportData.insights = try await fetchAllInsights(userId)
        exportData.recommendations = try await fetchAllRecommendations(userId)

        // ── Create JSON file ──
        let jsonEncoder = JSONEncoder()
        jsonEncoder.dateEncodingStrategy = .iso8601
        jsonEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let jsonData = try jsonEncoder.encode(exportData)

        // Save to temporary file
        let exportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("life_os_export_\(Date().ISO8601Format()).json")

        try jsonData.write(to: exportURL)

        return exportURL
    }
}
```

**Export Format:**
```json
{
  "export_date": "2026-01-18T12:00:00Z",
  "user_id": "uuid",
  "profile": {
    "display_name": "John",
    "date_of_birth": "1990-01-15",
    "sex": "male",
    "height_cm": 175,
    "weight_kg": 72
  },
  "health_flags": {
    "has_cardiac_condition": false,
    "has_pacemaker": false,
    "is_pregnant": false,
    "has_eating_disorder_history": false
  },
  "health_metrics": [
    {
      "date": "2026-01-18",
      "recovery_score": 78,
      "hrv_ms": 62,
      "sleep_duration_hours": 7.33
    }
  ],
  "health_measurements": [...],
  "body_composition": [...],
  "food_logs": [...],
  "meal_templates": [...],
  "batch_recipes": [...],
  "user_food_favorites": [...],
  "hydration_logs": [...],
  "workout_sessions": [...],
  "training_plans": [...],
  "training_templates": [...],
  "custom_exercises": [...],
  "user_supplements": [...],
  "supplement_logs": [...],
  "sleep_logs": [...],
  "medical_scans": [...],
  "lab_markers": [...],
  "experiments": [...],
  "wellness_checks": [...],
  "insights": [...],
  "recommendations": [...],
  "notification_settings": {
    "morning_brief_enabled": true,
    "quiet_hours_start": "22:00",
    "quiet_hours_end": "07:00",
    "control_level": "advisory"
  }
}
```

#### 1A. GDPR Export Archive Format (Detailed)

**Archive format:** ZIP containing structured JSON files.

**File naming convention:**
```
lifeos_export_{user_id_short}_{YYYYMMDD}.zip
└── metadata.json         ← export metadata
└── profile.json          ← user profile + settings
└── health_metrics.json   ← daily recovery, HRV, RHR, temperature
└── nutrition.json        ← food_logs + food_items + meal_templates + batch_recipes + user_food_favorites
└── hydration.json        ← hydration_logs
└── training.json         ← workout_sessions + workout_sets + training_plans + templates + custom_exercises
└── supplements.json      ← user_supplements + supplement_logs
└── sleep.json            ← sleep_logs (V2)
└── labs.json             ← medical_scans + lab_markers
└── experiments.json      ← experiments + experiment_measurements
└── wellness.json         ← wellness_checks
└── ai_outputs.json       ← insights + recommendations
└── body_composition.json ← body_composition measurements
```

**`metadata.json` structure:**
```json
{
  "export_version": "1.0",
  "export_date": "2026-01-18T12:00:00Z",
  "user_id": "uuid",
  "data_range": {
    "earliest_record": "2025-11-01T00:00:00Z",
    "latest_record": "2026-01-18T12:00:00Z"
  },
  "record_counts": {
    "health_metrics": 78,
    "food_logs": 234,
    "workout_sessions": 45,
    "supplement_logs": 156
  },
  "excluded_data": [
    "vector_embeddings (derived, not raw data)",
    "notification_delivery_logs (system logs)",
    "sync_state (internal system state)"
  ]
}
```

**What is EXCLUDED from export (with rationale):**

| Data | Reason |
|------|--------|
| Vector embeddings (Pinecone) | Derived data, not user-created content. Generated from user data that IS exported. Cannot be meaningfully interpreted outside Life OS. |
| Outbox events | Internal sync queue, not user-facing data. |
| Sync state / watermarks | Internal system state. |
| Push notification delivery logs | System logs, not user content. |
| Audit trail (deletion confirmations) | System compliance records, not user data. |

**Vector embedding handling (opt-in users):**
- If user has opted into vector-powered insights: export includes a `vector_summary.json` containing a human-readable list of what data was vectorized (e.g., "234 food log summaries, 45 workout summaries"), but NOT the raw vectors.
- User can request vector deletion separately via the deletion flow (Article 17).

**Delivery mechanism:**
1. `POST /api/user/export` initiates export (Edge Function). Returns `export_id`.
2. Edge Function gathers data, creates ZIP, uploads to temporary Supabase Storage location.
3. `GET /api/user/export/{export_id}/status` for polling (returns `pending | processing | ready | expired`).
4. `GET /api/user/export/{export_id}/download` returns a time-limited signed URL (expires after 24h).
5. After 24 hours, the export file is automatically deleted from storage.
6. Maximum one active export per user. Consecutive requests within 24h return the existing export.

#### 2. Right to Erasure (Article 17)

```swift
class DataDeletionService {
    func deleteAllUserData(userId: UUID, confirmation: String) async throws {
        // Require confirmation code
        guard confirmation == "DELETE-MY-DATA" else {
            throw PrivacyError.confirmationRequired
        }
        
        // Transaction to ensure atomic deletion
        try await database.transaction { db in
            // Delete in dependency order (children first)
            try await db.delete(ExperimentMeasurement.self)
                .where("user_id", .equals, userId)
            
            try await db.delete(Experiment.self)
                .where("user_id", .equals, userId)
            
            try await db.delete(FoodItem.self)
                .join(FoodLog.self, on: "food_log_id")
                .where("user_id", .equals, userId)
            
            try await db.delete(FoodLog.self)
                .where("user_id", .equals, userId)
            
            // ... delete all other user data ...
            
            // Finally, delete user profile
            try await db.delete(User.self)
                .where("id", .equals, userId)
        }
        
        // Delete from Supabase Storage
        try await deleteUserStorage(userId)
        
        // Delete from Pinecone (vector embeddings)
        try await deleteVectorNamespace(userId)
        
        // Delete auth user
        let authId = try await fetchAuthId(for: userId)
        try await supabaseAuth.admin.deleteUser(authId)
        
        // Log deletion (anonymized)
        Logger.shared.log(.info, "User data deleted", context: [
            "timestamp": Date().ISO8601Format()
        ])
    }
}
```

#### 3. Right to Rectification (Article 16)

```swift
// All user data is editable through normal app flows
// Historical health metrics can be marked as "corrected"

struct DataCorrection {
    let originalValue: Any
    let correctedValue: Any
    let correctedAt: Date
    let reason: String?
}
```

#### 4. Right to Data Portability (Article 20)

```swift
// Export in machine-readable formats
enum ExportFormat {
    case json       // Primary
    case csv        // For spreadsheets
    case healthKit  // Re-import to Apple Health
}

func exportInFormat(_ format: ExportFormat) async throws -> URL {
    switch format {
    case .json:
        return try await exportAsJSON()
    case .csv:
        return try await exportAsCSV()
    case .healthKit:
        return try await exportAsHealthKitCompatible()
    }
}
```

### Consent Management

```swift
struct ConsentRecord: Codable {
    let userId: UUID
    let consentType: ConsentType
    let granted: Bool
    let timestamp: Date
    let version: String  // Privacy policy version
    let ipAddress: String? // Optional, for audit
}

enum ConsentType: String, Codable {
    case termsOfService
    case privacyPolicy
    case healthDataProcessing
    case analyticsTracking
    case marketingEmails
    case thirdPartySharing  // Currently always false
}

class ConsentManager {
    func recordConsent(_ type: ConsentType, granted: Bool) async {
        let record = ConsentRecord(
            userId: currentUserId,
            consentType: type,
            granted: granted,
            timestamp: Date(),
            version: PrivacyPolicy.currentVersion,
            ipAddress: nil  // Don't store IP
        )
        
        await database.insert(record)
    }
    
    func hasValidConsent(for type: ConsentType) async -> Bool {
        guard let record = await database.fetchLatestConsent(type: type) else {
            return false
        }
        
        return record.granted && record.version == PrivacyPolicy.currentVersion
    }
}
```

---

## DATA ANONYMIZATION FOR ANALYTICS

### Anonymization Strategy

To enable product improvement while preserving privacy, we use k-anonymity bucketing.

**Additional rules for new modules (Training/Supplements/Labs):**
- Never log raw lab values in analytics events
- Use buckets or status labels (e.g., "low/optimal/high")
- Do not include supplement dose amounts in analytics

```swift
struct AnonymizedAnalytics {
    // User demographics (bucketed, not exact)
    let ageGroup: String        // "18-24", "25-34", "35-44", etc.
    let sexCategory: String     // "male", "female", "other"
    let goalType: String        // "weight_loss", "muscle_gain", etc.
    let activityLevel: String   // "sedentary", "moderate", "active"
    
    // Usage metrics (bucketed)
    let daysActive: String      // "1-7", "8-30", "31-90", "90+"
    let mealsLoggedBucket: String // "0-10", "11-50", "51-200", "200+"
    let recoveryScoreBucket: String // "0-39", "40-59", "60-79", "80-100"
    
    // Feature usage (boolean only)
    let usesExperiments: Bool
    let usesAIFoodAnalysis: Bool
    let usesSupplementTracking: Bool
    
    // No identifiers
    // NO: userId, deviceId, ipAddress, exact timestamps
}
```

### Bucketing Functions

```swift
class AnonymizationService {
    func bucketAge(_ dob: Date) -> String {
        let age = Calendar.current.dateComponents([.year], from: dob, to: Date()).year ?? 0
        switch age {
        case 0..<18: return "under_18"
        case 18..<25: return "18-24"
        case 25..<35: return "25-34"
        case 35..<45: return "35-44"
        case 45..<55: return "45-54"
        case 55..<65: return "55-64"
        default: return "65+"
        }
    }
    
    func bucketRecoveryScore(_ score: Double?) -> String {
        guard let score = score else { return "unknown" }
        switch score {
        case 0..<40: return "0-39"
        case 40..<60: return "40-59"
        case 60..<80: return "60-79"
        default: return "80-100"
        }
    }
}
```

### Aggregate Analytics Only

```swift
// All metrics aggregated across 100+ users minimum (k-anonymity)
// No individual user can be identified from these metrics
struct AggregateMetrics {
    let totalActiveUsers: Int
    let averageRecoveryScoreByAgeGroup: [String: Double]
    let featureAdoptionRates: [String: Double]
    let retentionByWeek: [Int: Double]
}
```

---

## DATA PROCESSING INVENTORY

### Processing Activities (Article 30)

| Activity | Purpose | Legal Basis | Data Categories | Recipients | Transfers |
|----------|---------|-------------|-----------------|------------|-----------|
| Recovery calculation | Core service | Consent + Legitimate interest | Health metrics | None | No |
| Food analysis | Core service | Consent | Photos, macros | OpenRouter (processor; model providers as subprocessors) | Varies (by provider) |
| Pattern detection | Core service | Consent | Derived summaries + minimal context | OpenRouter (processor; model providers as subprocessors) | Varies (by provider) |
| Vector search (opt‑in) | Personalization | Explicit consent | Derived summaries only | Pinecone (processor) | US |
| Crash reporting | App improvement | Legitimate interest | Anonymized technical | Sentry (optional) | US |
| Email notifications | Service delivery | Consent | Email address | Supabase | EU |

### OpenRouter Data Processing Agreement (Gateway)

```markdown
## Third-Party Processor: OpenRouter (AI Gateway)

**Purpose:** Food image analysis, pattern detection, insight generation

**Data Shared:**
- Food photos (temporary; minimize and redact where possible)
- Derived summaries and non‑identifying context (no direct PII in prompts)

**Safeguards:**
- Use provider settings/modes that minimize retention and training where supported
- Data minimization and redaction before requests
- No direct identifiers sent to API

**Subprocessors:**
- OpenRouter may route requests to third-party model providers. Treat the routed model provider(s) as subprocessors.
- Maintain a living subprocessor list in the product privacy policy (model provider + region + retention posture).

**User Controls:**
- Can disable AI features (uses local Core ML model instead)
- Can delete AI analysis history
```

## Third-Party Processor: Pinecone (Vector DB)

**Purpose:** Optional semantic search for user memory and insights (opt‑in only)

**Data Shared:**
- Only derived, non‑identifying summaries (no raw health metrics, no menstrual data, no medical documents)

**Safeguards:**
- User‑scoped namespaces
- Deletion of vectors during account deletion
- Data minimization and redaction before embedding

**User Controls:**
- Explicit opt‑in required
- Full opt‑out removes all vectors
- Access to export and deletion flows

> [!IMPORTANT]
> **DPA Requirement:** A signed Data Processing Agreement (DPA) with Pinecone is **required before launch** for GDPR compliance when processing EU user data. Track in legal pre-launch checklist. Pinecone's standard DPA covers GDPR Article 28 obligations (data processing instructions, sub-processor management, data deletion, audit rights).

---

## AUDIT LOGGING

### What We Log

```swift
enum AuditEvent: String, Codable {
    // Data access
    case dataExported
    case dataDeleted
    case dataViewed  // Sensitive screens only
    
    // Authentication
    case loginSuccess
    case loginFailed
    case logoutRequested
    case sessionExpired
    case passwordChanged
    
    // Consent
    case consentGranted
    case consentRevoked
    
    // Admin actions
    case accountSuspended
    case accountReactivated
}

struct AuditLog: Codable {
    let id: UUID
    let timestamp: Date
    let userId: UUID?  // Null for anonymous events
    let event: AuditEvent
    let details: [String: String]
    let ipAddress: String?  // Optional
    let userAgent: String?
}
```

### What We DON'T Log

```swift
// Never logged:
// - Actual health metric values
// - Food photo contents
// - Passwords (even hashed)
// - Precise GPS coordinates
// - Full device identifiers
```

### Audit Log Retention

- Audit logs retained for 2 years
- Anonymized after 1 year
- User can request audit log export

---

## BREACH RESPONSE

### Incident Classification

| Level | Description | Response Time | Notification |
|-------|-------------|---------------|--------------|
| 1 - Critical | Auth system breach, data exfiltration | 1 hour | All users + authorities |
| 2 - High | Unauthorized access to user data | 4 hours | Affected users + authorities |
| 3 - Medium | Potential vulnerability discovered | 24 hours | Internal only |
| 4 - Low | Minor security improvement needed | 7 days | Internal only |

### Response Procedure

```swift
struct BreachResponse {
    func handleBreach(_ incident: SecurityIncident) async {
        // 1. Contain
        await containIncident(incident)
        
        // 2. Assess
        let assessment = await assessImpact(incident)
        
        // 3. Notify (if required)
        if assessment.requiresUserNotification {
            await notifyAffectedUsers(assessment.affectedUserIds)
        }
        
        if assessment.requiresAuthorityNotification {
            await notifyDataProtectionAuthority(assessment)
        }
        
        // 4. Remediate
        await remediateVulnerability(incident)
        
        // 5. Document
        await documentIncident(incident, assessment)
    }
}
```

---

## PRIVACY UI

### Settings Screen

```
┌─────────────────────────────────────────┐
│  [← Back]      PRIVACY & DATA           │
├─────────────────────────────────────────┤
│                                         │
│  DATA COLLECTION                        │
│  ┌───────────────────────────────────┐ │
│  │ Health Data               [ON]    │ │
│  │ Required for recovery score       │ │
│  ├───────────────────────────────────┤ │
│  │ Location Context          [OFF]   │ │
│  │ Restaurant detection              │ │
│  ├───────────────────────────────────┤ │
│  │ Analytics                 [ON]    │ │
│  │ Helps improve the app             │ │
│  └───────────────────────────────────┘ │
│                                         │
│  AI PROCESSING                          │
│  ┌───────────────────────────────────┐ │
│  │ Use AI for food analysis  [ON]   │ │
│  │ When off, uses local model        │ │
│  │ (less accurate)                   │ │
│  └───────────────────────────────────┘ │
│                                         │
│  YOUR DATA                              │
│  ┌───────────────────────────────────┐ │
│  │ [↓] Export All Data               │ │
│  ├───────────────────────────────────┤ │
│  │ [🗑️] Delete All Data              │ │
│  │     This cannot be undone         │ │
│  └───────────────────────────────────┘ │
│                                         │
│  DOCUMENTS                              │
│  ┌───────────────────────────────────┐ │
│  │ Privacy Policy            [→]     │ │
│  ├───────────────────────────────────┤ │
│  │ Terms of Service          [→]     │ │
│  ├───────────────────────────────────┤ │
│  │ Data Processing Info      [→]     │ │
│  └───────────────────────────────────┘ │
│                                         │
└─────────────────────────────────────────┘
```

### Delete Data Confirmation

```
┌────────────────────────────────────┐
│                                    │
│     ⚠️ Delete All Your Data?       │
│                                    │
│  This will permanently delete:     │
│                                    │
│  • All health metrics              │
│  • All food logs and photos        │
│  • All experiments and insights    │
│  • All account information         │
│                                    │
│  Type DELETE-MY-DATA to confirm:   │
│  ┌─────────────────────────────┐   │
│  │                             │   │
│  └─────────────────────────────┘   │
│                                    │
│  [CANCEL]  [DELETE FOREVER]        │
│                                    │
└────────────────────────────────────┘
```

---

## COMPLIANCE CHECKLIST

### GDPR (EU)

- [x] Lawful basis for processing (consent)
- [x] Privacy by design
- [x] Data minimization
- [x] Right to access
- [x] Right to erasure
- [x] Right to portability
- [x] Breach notification procedure
- [x] Processing records (Article 30)
- [ ] DPO appointment (required if >10M users)

### CCPA (California)

- [x] Right to know
- [x] Right to delete
- [x] Right to opt-out (no sale of data)
- [x] Non-discrimination

### HIPAA (US Healthcare)

- [ ] Not applicable (consumer app, not covered entity)
- [ ] Consider if partnering with healthcare providers

### Apple App Store

- [x] Privacy nutrition labels
- [x] ATT compliance (no tracking)
- [x] HealthKit guidelines compliance

### App Tracking Transparency (ATT)

Life OS **does not** use IDFA, advertising identifiers, or any cross-app/cross-site tracking. Therefore:
- **ATT prompt is NOT required.** The app does not trigger the `ATTrackingManager.requestTrackingAuthorization()` dialog.
- **Privacy Nutrition Label:** "Data Not Used to Track You" for all collected data types.
- If future analytics or attribution SDKs are integrated, re-evaluate ATT obligation before submission.

### Data Residency

| Service | Region | Notes |
|---------|--------|-------|
| **Supabase** (database + auth + storage) | **EU (Frankfurt, `eu-central-1`)** | Primary project region. All user PII and health data resides in EU by default. |
| **Supabase Edge Functions** | Edge network (closest region) | Stateless compute; no data persisted. |
| **OpenRouter** | Varies by routed model provider | No PII in prompts; derived summaries only. See DPA section above. |
| **Pinecone** | US (opt-in only) | Only derived, non-identifying vectors. Explicit user consent required for cross-border transfer. |

> [!IMPORTANT]
> For CIS users: Supabase EU region minimizes latency while maintaining GDPR compliance. If a dedicated RU region is later required, a separate Supabase project can be created with data migration tooling.

---

### CIS Regional Availability & Sanctions Considerations

> [!WARNING]
> This section addresses legal and technical risks for CIS market launch. Legal counsel review is **required** before public release in affected jurisdictions.

**App Store availability:**
- Apple App Store is available in Russia, Kazakhstan, Ukraine, Uzbekistan, Georgia, and most CIS countries.
- App Store in Russia has payment restrictions: In-App Purchases and subscriptions may not process via Apple Pay in sanctioned regions. Monitor Apple's developer documentation for current restrictions.
- **Action required:** Verify subscription billing flow works for each target CIS country before launch.

**API provider access from CIS:**

| Provider | CIS Access | Risk | Mitigation |
|----------|-----------|------|-----------|
| **OpenRouter** | ✅ Accessible | Low | Route through EU Edge Functions (user never calls OpenRouter directly) |
| **Pinecone** | ✅ Accessible | Low | Opt-in only; EU Edge Functions proxy all calls |
| **Supabase** | ✅ Accessible (EU region) | Low | Direct client connection to EU Frankfurt |
| **Apple HealthKit** | ✅ On-device | None | No network dependency |

**Key mitigations:**
1. All third-party API calls flow through Supabase Edge Functions (EU). **CIS users never directly call OpenRouter or Pinecone** — the Edge Function is the client, not the user's device.
2. Supabase EU (Frankfurt) provides good latency for CIS users (~40–80ms RTT from Moscow).
3. If Apple Pay restrictions affect subscription billing, implement alternative payment methods (bank card via Stripe, or local payment processors) as a fallback.

**Data sovereignty:**
- No user data is stored in or routed through US infrastructure by default (except Pinecone vectors, which are opt-in and non-identifying).
- If Russian data localization law (Federal Law 242-FZ) applies, a dedicated Supabase project in an RU-compliant region may be required. Plan for data migration tooling.

**Pre-launch legal checklist (CIS-specific):**
- [ ] Verify App Store In-App Purchase availability in target CIS markets
- [ ] Confirm OpenRouter ToS permits serving CIS users via EU proxy
- [ ] Confirm Pinecone ToS permits processing derived (non-PII) data for CIS users
- [ ] Assess Federal Law 242-FZ (Russia) applicability — requires legal counsel
- [ ] Test payment flows in each target CIS market

---

This privacy architecture ensures robust data protection while maintaining full app functionality. All components are designed for user control and regulatory compliance.
