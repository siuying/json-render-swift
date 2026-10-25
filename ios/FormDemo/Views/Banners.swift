import JSONRenderSwiftUI
import SwiftUI

/// A dismissible message card shown above the prompt bar.
struct MessageBanner: View {
    enum Style {
        case error, warning, success

        var tint: Color {
            switch self {
            case .error: .red
            case .warning: .orange
            case .success: .green
            }
        }

        var systemImage: String {
            switch self {
            case .error: "exclamationmark.octagon.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .success: "checkmark.seal.fill"
            }
        }
    }

    let style: Style
    let title: String
    var message: String?
    var actionTitle: String?
    var action: () -> Void = {}
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: style.systemImage)
                .foregroundStyle(style.tint)
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(6)
                        .textSelection(.enabled)
                }
                if let actionTitle {
                    Button(actionTitle, action: action)
                        .font(.footnote.weight(.semibold))
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            DismissButton(action: onDismiss)
        }
        .padding(14)
        .glassEffect(.regular.tint(style.tint.opacity(0.12)), in: .rect(cornerRadius: 20))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// Validation warnings and errors for the latest spec, expandable.
struct IssuesBanner: View {
    let issues: [SpecValidation.Issue]
    let didAutoFix: Bool
    let onDismiss: () -> Void

    @State private var isExpanded = false

    private var errorCount: Int { issues.filter(\.isError).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: errorCount > 0 ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(errorCount > 0 ? .red : .orange)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    if didAutoFix {
                        Text("The spec was repaired with autoFixSpec.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !issues.isEmpty {
                    Button(isExpanded ? "Hide" : "Show") {
                        withAnimation(.snappy) { isExpanded.toggle() }
                    }
                    .font(.footnote.weight(.semibold))
                }
                DismissButton(action: onDismiss)
            }
            if isExpanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(issue.message)
                                    .font(.footnote)
                                if let path = issue.path {
                                    Text(path)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
            }
        }
        .padding(14)
        .glassEffect(.regular.tint(Color.orange.opacity(0.12)), in: .rect(cornerRadius: 20))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var title: String {
        if issues.isEmpty { return "Spec fixed automatically" }
        let warnings = issues.count - errorCount
        var parts: [String] = []
        if errorCount > 0 { parts.append(errorCount == 1 ? "1 error" : "\(errorCount) errors") }
        if warnings > 0 { parts.append(warnings == 1 ? "1 warning" : "\(warnings) warnings") }
        return "Spec validation: " + parts.joined(separator: ", ")
    }
}

private struct DismissButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dismiss")
    }
}
