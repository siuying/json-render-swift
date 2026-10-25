import Foundation
import JSONRenderSwiftUI

/// An element after state resolution: visible, props resolved, repeats expanded.
struct ResolvedElement: Sendable {
    var key: String
    var type: String
    var props: [String: JSONValue]
    /// The repeat scope the element was resolved in (`nil` outside a repeat).
    var scope: RepeatScope?
    /// Prop name → state pointer for `$state`, `$bindState` and `$bindItem` props.
    var pointers: [String: String] = [:]
    var children: [ResolvedElement]

    func string(_ name: String) -> String? {
        switch props[name] {
        case nil, .null?: nil
        case .string(let value)?: value
        case let value?: value.javaScriptString
        }
    }

    /// A finite number prop, clamped to `range` (non-finite or non-numeric → `nil`).
    func number(_ name: String, in range: ClosedRange<CGFloat> = -100_000...100_000) -> CGFloat? {
        guard let value = props[name]?.doubleValue, value.isFinite else { return nil }
        return min(max(CGFloat(value), range.lowerBound), range.upperBound)
    }

    func bool(_ name: String) -> Bool? {
        props[name]?.boolValue
    }
}

/// Port of react-pdf `renderElement`: evaluates `visible`, resolves props with the
/// repeat scope, expands `repeat` (children once per item) and skips missing children,
/// unknown component types and reference cycles.
///
/// Budgets keep generated specs from exhausting the stack or memory: elements nested
/// deeper than ``maxDepth`` and elements beyond ``maxElements`` are dropped and reported
/// in ``warnings``.
final class SpecResolver {
    static let maxDepth = 32
    static let maxElements = 20_000

    let spec: Spec
    let state: JSONValue
    let knownTypes: Set<String>
    private(set) var warnings: [PDFRenderWarning] = []
    private var elementCount = 0

    init(spec: Spec, state: JSONValue, knownTypes: Set<String>) {
        self.spec = spec
        self.state = state
        self.knownTypes = knownTypes
    }

    func resolveRoot() -> ResolvedElement? {
        guard let root = spec.root else { return nil }
        return resolve(root, scope: nil, ancestors: [])
    }

    private func resolve(_ key: String, scope: RepeatScope?, ancestors: Set<String>) -> ResolvedElement? {
        guard !ancestors.contains(key), let element = spec.elements[key] else { return nil }
        guard ancestors.count < Self.maxDepth else {
            warn(.nestingTooDeep(limit: Self.maxDepth))
            return nil
        }
        guard elementCount < Self.maxElements else {
            warn(.tooManyElements(limit: Self.maxElements))
            return nil
        }
        guard Visibility.evaluate(element.visible, state: state, scope: scope) else { return nil }
        guard knownTypes.contains(element.type) else { return nil }
        elementCount += 1
        let props = Expressions.resolveProps(element.props, state: state, scope: scope)
        let path = ancestors.union([key])
        var children: [ResolvedElement] = []
        if let config = element.repeat {
            // An `$item` statePath outside a repeat scope drops the element (react-pdf).
            guard config.resolvedStatePath(in: scope) != nil else { return nil }
            for itemScope in config.scopes(state: state, in: scope) {
                children += element.children.compactMap { resolve($0, scope: itemScope, ancestors: path) }
            }
        } else {
            children = element.children.compactMap { resolve($0, scope: scope, ancestors: path) }
        }
        var resolved = ResolvedElement(key: key, type: element.type, props: props, scope: scope, children: children)
        resolved.pointers = Self.pointers(in: element.props, scope: scope)
        return resolved
    }

    /// Bound pointers of a prop: `$bindState` / `$bindItem` bindings and `$state` reads.
    private static func pointers(in props: [String: JSONValue], scope: RepeatScope?) -> [String: String] {
        var pointers = Expressions.bindings(in: props, scope: scope)
        for (name, value) in props where pointers[name] == nil {
            if case .string(let pointer)? = value["$state"] { pointers[name] = pointer }
        }
        return pointers
    }

    private func warn(_ warning: PDFRenderWarning) {
        if !warnings.contains(warning) { warnings.append(warning) }
    }
}

extension ResolvedElement {
    /// Every image `src` in the tree (for preloading).
    var imageSources: Set<String> {
        var sources: Set<String> = []
        if type == "Image", let src = string("src"), !src.isEmpty { sources.insert(src) }
        for child in children { sources.formUnion(child.imageSources) }
        return sources
    }
}

/// react-pdf `stripEmoji`: removes emoji (Helvetica has no glyphs), collapses runs of
/// whitespace to one space and trims.
enum EmojiStripper {
    static func strip(_ text: String) -> String {
        var output = String.UnicodeScalarView()
        var whitespaceRun: [Unicode.Scalar] = []
        func flushWhitespace() {
            output.append(contentsOf: whitespaceRun.count >= 2 ? [" "] : whitespaceRun)
            whitespaceRun.removeAll()
        }
        for scalar in text.unicodeScalars where !isEmoji(scalar) {
            if isJSWhitespace(scalar) {
                whitespaceRun.append(scalar)
            } else {
                flushWhitespace()
                output.append(scalar)
            }
        }
        flushWhitespace()
        let result = String(output)
        return result.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\r\u{0B}\u{0C}\u{A0}\u{FEFF}\u{2028}\u{2029}"))
    }

    private static func isEmoji(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1F600...0x1F64F, 0x1F300...0x1F5FF, 0x1F680...0x1F6FF, 0x1F1E0...0x1F1FF,
             0x2600...0x26FF, 0x2700...0x27BF, 0xFE00...0xFE0F, 0x1F900...0x1F9FF,
             0x1FA00...0x1FA6F, 0x1FA70...0x1FAFF, 0x200D, 0x20E3, 0xE0020...0xE007F:
            true
        default:
            false
        }
    }

    private static func isJSWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
            true
        default:
            false
        }
    }
}
