import Foundation

/// Appearance-state names for checkbox and radio export values.
///
/// A button's "on" appearance state is a PDF name; `/Off` is reserved for the off state.
/// Export values are used as state names except when that would be `Off` (or empty) or
/// collide with another option's name: those get a distinct internal name (`Off_1`, …).
/// The writer and ``PDFFormReader`` use the same mapping, so values round-trip.
enum ButtonStates {
    static let off = "Off"

    static func names(for values: [String]) -> [String] {
        var used: Set<String> = [off]
        return values.map { value in
            let candidate = value.isEmpty ? "On" : value
            if used.insert(candidate).inserted { return candidate }
            var index = 1
            while !used.insert("\(candidate)_\(index)").inserted { index += 1 }
            return "\(candidate)_\(index)"
        }
    }

    /// The state name of a checkbox whose export value is `exportValue`.
    static func checkboxOn(_ exportValue: String?) -> String {
        names(for: [exportValue ?? "Yes"])[0]
    }
}
