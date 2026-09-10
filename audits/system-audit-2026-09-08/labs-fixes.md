# Labs fixes — 2026-09-09

Addresses F09, IOS-DATA-01/08 and raw-asset backup exclusion in IOS-DATA-09.

## Changes

- Decimal commas are preserved; Unicode/Cyrillic marker aliases and unit spellings are recognized. Exact alias matching avoids substring collisions (e.g. glycated hemoglobin vs hemoglobin).
- No units or medical reference intervals are guessed from a marker name. The original numeric magnitude is retained. Only spelling aliases of equivalent units are normalized; no medical conversion factors or new norms are introduced.
- A laboratory-supplied range drives status. Missing range means unknown, never normal. Edited values recalculate status; changing the unit in review clears the old range. Malformed/nonfinite values and invalid ranges block the entire save rather than silently dropping rows. Inequality qualifiers remain visible and require correction; they are never stripped to an exact number.
- The OCR API exposes text, not calibrated confidence. Capture no longer displays a fabricated accuracy percentage; persisted confidence fields are NULL. Manual verification requires the explicit review toggle, reset after edits.
- Labelled collection/test/report dates are extracted, validated and editable. Birth dates are not selected. The selected date is persisted in scan_date, measured_date and measured_at; created_at remains the import timestamp.
- The insertion transaction checks current-user live scans for matching file hash or same-day marker overlap >=60% (intersection divided by the smaller distinct marker set). It throws before committing if a duplicate has not been acknowledged. Review offers keeping existing results/cancelling import, or explicitly saving a separate study. Works in local-only/offline storage; no server connection needed.
- MedicalScans directory and new raw assets receive complete file protection and backup exclusion. If exclusion fails after writing, the file is removed and saving fails.

## Regression coverage

Existing LabsViewCoverageTests.swift now covers all four original parser reproductions, Cyrillic unit/name aliases, matching document ranges, edited values, missing units, censored/nonfinite values, invalid dates, birth-date rejection, the 60% boundary, local-only persistence of a historical date, confidence/manual-review separation, same-day/hash duplicate blocking, explicit keep-both, atomic invalid import and unknown status, asset backup exclusion/file protection. Previous coverage tests were corrected to stop expecting silent invalid-row omission and automatic manual verification.

Standalone Swift execution of the actual production ExtractedLabMarker/LabsMarkerCatalog passed all four audit examples, explicit range/edit behavior, date cases and the existing parser fixture. Swift syntax parsing passed for modified Labs source and test files. Xcode build/unit execution is centrally owned by the parent; this report does not claim simulator/device test execution.

## Files

- ios/LifeOS/Modules/Labs/LabsView.swift
- ios/LifeOS/Modules/Labs/LabScanDetailView.swift (asset store only)
- ios/LifeOSTests/LabsViewCoverageTests.swift
- ios/LifeOSTests/CoverageFinalPushTests.swift (Labs fixtures/expectations only)

No new Swift files or project-file integration required. Review labels currently use Russian string literals (SwiftUI localization keys); Localizable.xcstrings was not edited concurrently. Physical iCloud/Finder backup extraction remains a device-level validation item.
