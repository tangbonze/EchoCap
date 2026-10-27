import Foundation

/// Reads the model list an OpenAI-compatible endpoint returns.
///
/// The shape is `{"data": [{"id": "gpt-4o-mini", ...}, ...]}` for every
/// provider worth supporting, but some hand back a bare array, and a few wrap
/// the ids in `models`. All three are accepted so the picker fills in either
/// way instead of silently staying empty.
public enum CloudModelList {
    public static func parse(_ data: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }

        if let object = root as? [String: Any] {
            if let items = object["data"] as? [[String: Any]] {
                return ids(from: items)
            }
            if let items = object["models"] as? [[String: Any]] {
                return ids(from: items)
            }
            if let names = object["models"] as? [String] {
                return names.sorted()
            }
            return []
        }

        if let items = root as? [[String: Any]] {
            return ids(from: items)
        }
        if let names = root as? [String] {
            return names.sorted()
        }
        return []
    }

    private static func ids(from items: [[String: Any]]) -> [String] {
        let names = items.compactMap { $0["id"] as? String ?? $0["name"] as? String }
        return Array(Set(names)).sorted()
    }
}
