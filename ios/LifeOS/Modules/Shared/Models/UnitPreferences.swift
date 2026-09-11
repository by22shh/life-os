import Foundation

/// Conversions and display formatting for the user's chosen unit system.
/// Canonical storage stays metric (`kg`, `cm`, `ml`); conversion happens only
/// at the display/entry boundary.
enum UnitPreferences {
    static let poundsPerKilogram = 2.2046226218
    static let centimetersPerInch = 2.54
    static let millilitersPerFluidOunce = 29.5735295625

    // MARK: - Mass

    static func weightValue(fromKilograms kilograms: Double, units: UnitSystem) -> Double {
        switch units {
        case .metric: return kilograms
        case .imperial: return kilograms * poundsPerKilogram
        }
    }

    static func kilograms(fromDisplayedWeight value: Double, units: UnitSystem) -> Double {
        switch units {
        case .metric: return value
        case .imperial: return value / poundsPerKilogram
        }
    }

    static func weightUnitLabel(_ units: UnitSystem) -> String {
        switch units {
        case .metric: return String(localized: "unit_kg")
        case .imperial: return String(localized: "unit_lb")
        }
    }

    static func formatWeight(
        kilograms: Double,
        units: UnitSystem,
        decimals: Int = 1
    ) -> String {
        let value = weightValue(fromKilograms: kilograms, units: units)
        return "\(formattedDecimal(value, maxDecimals: decimals)) \(weightUnitLabel(units))"
    }

    // MARK: - Height

    static func heightValue(fromCentimeters centimeters: Double, units: UnitSystem) -> Double {
        switch units {
        case .metric: return centimeters
        case .imperial: return centimeters / centimetersPerInch
        }
    }

    static func centimeters(fromDisplayedHeight value: Double, units: UnitSystem) -> Double {
        switch units {
        case .metric: return value
        case .imperial: return value * centimetersPerInch
        }
    }

    static func heightUnitLabel(_ units: UnitSystem) -> String {
        switch units {
        case .metric: return String(localized: "unit_cm")
        case .imperial: return String(localized: "unit_in")
        }
    }

    static func formatHeight(centimeters: Double, units: UnitSystem) -> String {
        switch units {
        case .metric:
            return "\(formattedDecimal(centimeters, maxDecimals: 1)) \(heightUnitLabel(units))"
        case .imperial:
            let totalInches = centimeters / centimetersPerInch
            let feet = Int(totalInches / 12)
            let inches = totalInches - Double(feet * 12)
            return "\(feet)′\(Int(inches.rounded()))″"
        }
    }

    // MARK: - Volume

    static func volumeValue(fromMilliliters milliliters: Double, units: UnitSystem) -> Double {
        switch units {
        case .metric: return milliliters
        case .imperial: return milliliters / millilitersPerFluidOunce
        }
    }

    static func milliliters(fromDisplayedVolume value: Double, units: UnitSystem) -> Double {
        switch units {
        case .metric: return value
        case .imperial: return value * millilitersPerFluidOunce
        }
    }

    static func volumeUnitLabel(_ units: UnitSystem) -> String {
        switch units {
        case .metric: return String(localized: "unit_ml")
        case .imperial: return String(localized: "unit_fl_oz")
        }
    }

    static func formatVolume(
        milliliters: Double,
        units: UnitSystem,
        maxDecimals: Int = 1
    ) -> String {
        let value = volumeValue(fromMilliliters: milliliters, units: units)
        return "\(formattedDecimal(value, maxDecimals: maxDecimals)) \(volumeUnitLabel(units))"
    }

    // MARK: - Shared

    static func formattedDecimal(_ value: Double, maxDecimals: Int) -> String {
        let rounded = (value * pow(10, Double(maxDecimals))).rounded() / pow(10, Double(maxDecimals))
        if rounded.rounded(.towardZero) == rounded {
            return String(Int(rounded))
        }
        return String(format: "%.\(maxDecimals)f", rounded)
    }
}
