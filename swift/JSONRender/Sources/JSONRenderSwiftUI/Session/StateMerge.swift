import Foundation

/// Merges newly streamed `spec.state` into live state without clobbering user edits.
///
/// Policy, applied recursively:
/// - A value the user has not changed (still equal to what was last seeded) takes the
///   new seed wholesale.
/// - Objects merge key by key; keys only present in live state are kept.
/// - Arrays merge by index: positions that were seeded before merge recursively; seed
///   items beyond the previously seeded length (newly streamed appends) are appended
///   after the live items, so items the user added or removed are respected.
/// - Any other edited value keeps the user's version.
enum StateMerge {
    static func merge(current: JSONValue?, oldSeed: JSONValue?, newSeed: JSONValue) -> JSONValue {
        guard let current, current != oldSeed else { return newSeed }
        switch (current, newSeed) {
        case let (.object(currentMembers), .object(seedMembers)):
            var result = currentMembers
            for (key, seedValue) in seedMembers {
                result[key] = merge(current: currentMembers[key], oldSeed: oldSeed?[key], newSeed: seedValue)
            }
            return .object(result)
        case let (.array(currentItems), .array(seedItems)):
            let seededCount = oldSeed?.arrayValue?.count ?? 0
            var result = currentItems.enumerated().map { index, item in
                index < seededCount && index < seedItems.count
                    ? merge(current: item, oldSeed: oldSeed?[index], newSeed: seedItems[index])
                    : item
            }
            if seedItems.count > seededCount {
                result += seedItems[seededCount...]
            }
            return .array(result)
        default:
            return current
        }
    }
}
