import Foundation

/// Display-only formatting, shared by SwiftUI annotations, accessibility and PDF.
enum ChartValueFormatting {
    static func string(_ value: Double, props: Props) -> String? {
        guard let format = props["valueFormat"], let style = format["style"]?.stringValue else { return nil }
        let locale = format["locale"]?.stringValue.map(Locale.init(identifier:)) ?? .current
        switch style {
        case "currency":
            guard let currency = format["currency"]?.stringValue, currency.count == 3 else { return nil }
            return value.formatted(.currency(code: currency).locale(locale))
        case "percent": return value.formatted(.percent.locale(locale))
        case "number": return value.formatted(.number.locale(locale))
        default: return nil
        }
    }
}
