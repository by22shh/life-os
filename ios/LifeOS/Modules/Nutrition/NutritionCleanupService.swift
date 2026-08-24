// MARK: - Nutrition Cleanup Service
// Source of truth: implementation_plan.md
// Handles retention policy for local food images (90 days).

import Foundation
import OSLog

private let nutritionCleanupLogger = Logger(subsystem: "LifeOS", category: "NutritionCleanup")

actor NutritionCleanupService {
    
    /// Prunes images in Documents/images older than 90 days.
    /// Should be called on app launch or background refresh.
    static func pruneOldPhotos() async {
        let fileManager = FileManager.default
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let imagesDirectory = documentsURL.appendingPathComponent("images")
        
        // Ensure directory exists
        guard fileManager.fileExists(atPath: imagesDirectory.path) else { return }
        
        do {
            let resourceKeys: [URLResourceKey] = [.creationDateKey, .isDirectoryKey]
            let enumerator = fileManager.enumerator(
                at: imagesDirectory,
                includingPropertiesForKeys: resourceKeys,
                options: [.skipsHiddenFiles]
            )
            
            let cutoffDate = Date().addingTimeInterval(-90 * 24 * 3600) // 90 days ago
            
            while let fileURL = enumerator?.nextObject() as? URL {
                let resourceValues = try fileURL.resourceValues(forKeys: Set(resourceKeys))
                
                // Skip directories
                if resourceValues.isDirectory == true { continue }
                
                if let creationDate = resourceValues.creationDate, creationDate < cutoffDate {
                    try fileManager.removeItem(at: fileURL)
                    nutritionCleanupLogger.debug("Pruned old image at \(fileURL.lastPathComponent, privacy: .private)")
                }
            }
        } catch {
            nutritionCleanupLogger.error("Error pruning photos: \(error.localizedDescription, privacy: .private)")
        }
    }
}
