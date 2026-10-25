/// The main screen's tabs.
enum ViewMode: String, CaseIterable, Identifiable {
    case ui, json, jsonl

    var id: Self { self }

    var title: String {
        switch self {
        case .ui: "UI"
        case .json: "JSON"
        case .jsonl: "JSONL"
        }
    }
}
