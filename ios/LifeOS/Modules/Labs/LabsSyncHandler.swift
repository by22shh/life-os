import Foundation

enum LabsSyncHandler: SyncModuleHandler {
    static let ownedTables: [SyncableTable] = [
        .medicalScans,
        .healthMeasurements,
        .healthDiagnoses,
        .healthMarkerCatalog
    ]

    static func pullTables(includeRestrictedMedicalData: Bool) -> [SyncableTable] {
        if includeRestrictedMedicalData {
            return [.healthMeasurements, .medicalScans, .healthDiagnoses]
        }
        return [.healthMeasurements]
    }
}
