import Foundation

extension KeyedDecodingContainer {
    /// A string that tolerates a missing key, null, or a wrong type ("").
    func lenientString(_ key: Key) -> String {
        (try? decodeIfPresent(String.self, forKey: key)) ?? ""
    }

    /// An optional value that tolerates a missing key, null, or a wrong type
    /// (nil) instead of failing the enclosing object.
    func lenientOptional<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }

    /// Decodes an array element by element, skipping elements that fail and
    /// noting how many were skipped. Returns nil when the key is absent or
    /// is not an array at all.
    func lossyArray<T: Decodable>(_ type: T.Type, _ key: Key, noun: String, notes: inout [String]) -> [T]? {
        guard contains(key), (try? decodeNil(forKey: key)) == false,
              var array = try? nestedUnkeyedContainer(forKey: key) else {
            return nil
        }
        var items: [T] = []
        var skipped = 0
        while !array.isAtEnd {
            if let item = try? array.decode(T.self) {
                items.append(item)
            } else {
                skipped += 1
                // Consume the bad element so decoding can continue.
                _ = try? array.decode(DiscardedElement.self)
            }
        }
        if skipped > 0 {
            notes.append("Skipped \(skipped) malformed \(noun)\(skipped == 1 ? "" : "s") in the snapshot")
        }
        return items
    }
}

/// Decodes and discards any JSON value.
private struct DiscardedElement: Decodable {
    init(from decoder: Decoder) throws {}
}
