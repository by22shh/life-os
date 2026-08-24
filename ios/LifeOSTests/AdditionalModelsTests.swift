import Foundation
import XCTest
@testable import LifeOS

final class AdditionalModelsTests: XCTestCase {

    func testRecommendationClinicianDisclaimerAndNeedsReview() {
        let userId = UUID()
        let disclaimer = String(localized: "clinician_disclaimer")

        let health = Recommendation(
            userId: userId,
            recommendationDate: "2026-02-24",
            category: "health",
            priority: "critical",
            title: "Hydration",
            description: "Drink water",
            reasoning: "Low hydration"
        )
        XCTAssertTrue(health.description.contains(disclaimer))
        XCTAssertTrue(health.needsReview)
        XCTAssertEqual(health.descriptionWithClinicianCaveat, health.description)

        let neutral = Recommendation(
            userId: userId,
            recommendationDate: "2026-02-24",
            category: "productivity",
            priority: "low",
            title: "Focus",
            description: "Use pomodoro",
            reasoning: "Routine"
        )
        XCTAssertEqual(neutral.description, "Use pomodoro")
        XCTAssertFalse(neutral.needsReview)
        XCTAssertEqual(neutral.descriptionWithClinicianCaveat, neutral.description)

        let alreadyTagged = Recommendation(
            userId: userId,
            recommendationDate: "2026-02-24",
            category: "sleep",
            priority: "normal",
            title: "Sleep",
            description: "Wind down. \(disclaimer)",
            reasoning: "Sleep debt"
        )
        XCTAssertEqual(alreadyTagged.descriptionWithClinicianCaveat, alreadyTagged.description)

        var recoveryNeedsAppend = Recommendation(
            userId: userId,
            recommendationDate: "2026-02-24",
            category: "recovery",
            priority: "normal",
            title: "Recovery",
            description: "Do a short walk",
            reasoning: "Light movement"
        )
        recoveryNeedsAppend.description = "Do a short walk"
        XCTAssertEqual(
            recoveryNeedsAppend.descriptionWithClinicianCaveat,
            "Do a short walk \(disclaimer)"
        )
    }

    func testWeeklyReportAndCatalogAndDiagnosisDefaults() {
        let userId = UUID()
        let summary = Data("{\"ok\":true}".utf8)
        let report = WeeklyStrategyReport(
            userId: userId,
            weekStart: "2026-02-17",
            weekEnd: "2026-02-24",
            summaryStats: summary,
            reportMarkdown: "Weekly summary"
        )
        XCTAssertTrue(report.reportMarkdownWithClinicianCaveat.contains("Weekly summary"))

        let reportWithDisclaimer = WeeklyStrategyReport(
            userId: userId,
            weekStart: "2026-02-17",
            weekEnd: "2026-02-24",
            summaryStats: summary,
            reportMarkdown: "Summary\n\n\(String(localized: "clinician_disclaimer"))"
        )
        XCTAssertEqual(
            reportWithDisclaimer.reportMarkdownWithClinicianCaveat,
            reportWithDisclaimer.reportMarkdown
        )

        let marker = HealthMarkerCatalogEntry(
            id: "vitamin_d",
            category: "labs",
            displayName: "Vitamin D",
            standardUnit: "ng/mL"
        )
        XCTAssertEqual(marker.aliases, "[]")
        XCTAssertFalse(marker.affectsRecovery)

        let diagnosis = HealthDiagnosis(
            userId: userId,
            originalText: "Mild deficiency"
        )
        XCTAssertFalse(diagnosis.isResolved)
    }

    func testAdditionalModelsInitializersCoverDefaults() {
        let userId = UUID()
        let sourceId = UUID()

        let memory = VectorMemoryEntry(
            userId: userId,
            vectorId: "v1",
            sourceType: "insight",
            sourceId: sourceId,
            eventDate: "2026-02-24"
        )
        XCTAssertEqual(memory.tags, "[]")

        let analytics = AnalyticsEvent(
            userId: userId,
            eventName: "event.test"
        )
        XCTAssertEqual(String(data: analytics.properties, encoding: .utf8), "{}")

        let template = TrainingTemplate(
            userId: userId,
            name: "Upper",
            templateExercises: Data("[]".utf8)
        )
        XCTAssertEqual(template.timesUsed, 0)
        XCTAssertFalse(template.archived)

        let audit = DeletionAuditLog(userIdDeleted: userId)
        XCTAssertFalse(audit.postgresDeleted)
        XCTAssertFalse(audit.vectorsDeleted)
        XCTAssertFalse(audit.complianceVerified)

        let failure = DeletionFailure(
            userId: userId,
            failureType: "network",
            error: "timeout"
        )
        XCTAssertFalse(failure.resolved)

        let consent = ConsentRecord(
            userId: userId,
            consentType: .privacyPolicy,
            granted: true,
            version: "1.0"
        )
        XCTAssertEqual(consent.consentType, .privacyPolicy)
        XCTAssertTrue(consent.granted)

        let expiresAt = Date().addingTimeInterval(60)
        let cache = AICacheEntry(
            cacheKey: "key",
            payload: Data("{}".utf8),
            expiresAt: expiresAt
        )
        XCTAssertEqual(cache.cacheKey, "key")
        XCTAssertEqual(cache.expiresAt, expiresAt)
    }

    func testNutritionDraftPayloadCarriesAIMetadata() {
        let draft = NutritionLogDraft(
            method: .photo,
            confidence: 0.84,
            loggedAt: Date(timeIntervalSince1970: 1_710_414_000),
            loggedDate: "2024-03-14",
            summary: "Balanced high-protein meal.",
            sourceText: "chicken bowl",
            analysisSource: .aiVision,
            totalMacros: NutritionDraftMacroSummary(
                calories: 520,
                proteinG: 45,
                fatG: 18,
                carbsG: 39,
                fiberG: 6
            ),
            suggestions: ["Add another serving of vegetables"],
            warnings: ["Portion size estimated from photo"],
            mealType: .lunch,
            recognizedBarcodes: ["4601234567890"],
            candidateItems: [
                NutritionDraftCandidateItem(
                    name: "Chicken breast",
                    category: .protein,
                    notes: "Visible grill marks",
                    weightG: 160,
                    calories: 260,
                    proteinG: 48,
                    fatG: 5,
                    carbsG: 0,
                    fiberG: 0,
                    confidence: 0.91
                )
            ]
        )

        let payload = draft.aiDetectedPayload
        XCTAssertTrue(draft.hasStructuredContent)
        XCTAssertEqual(payload.analysisSource, .aiVision)
        XCTAssertEqual(payload.totalMacros?.calories, 520)
        XCTAssertEqual(payload.suggestions, ["Add another serving of vegetables"])
        XCTAssertEqual(payload.warnings, ["Portion size estimated from photo"])
        XCTAssertEqual(payload.mealType, .lunch)
        XCTAssertEqual(payload.recognizedBarcodes, ["4601234567890"])
        XCTAssertEqual(payload.candidateItems.first?.category, .protein)
        XCTAssertEqual(payload.candidateItems.first?.notes, "Visible grill marks")
    }

    func testNutritionDraftCandidateItemPersistableRequiresPositiveStructuredMacros() {
        let incomplete = NutritionDraftCandidateItem(
            name: "Mystery bowl",
            weightG: 0,
            calories: 400,
            proteinG: 20,
            fatG: 10,
            carbsG: 45
        )
        XCTAssertFalse(incomplete.isPersistable)

        let complete = NutritionDraftCandidateItem(
            name: "Rice bowl",
            weightG: 350,
            calories: 520,
            proteinG: 25,
            fatG: 14,
            carbsG: 61
        )
        XCTAssertTrue(complete.isPersistable)
    }
}
