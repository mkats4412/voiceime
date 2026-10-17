import Foundation

public struct DictionaryRule: Identifiable, Codable, Equatable {
    public var id: UUID
    public var pattern: String
    public var replacement: String
    public var isRegex: Bool
    public var isEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case id, pattern, replacement, isRegex, isEnabled
    }

    public init(
        id: UUID = UUID(),
        pattern: String,
        replacement: String,
        isRegex: Bool = false,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.pattern = pattern
        self.replacement = replacement
        self.isRegex = isRegex
        self.isEnabled = isEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.pattern = try container.decode(String.self, forKey: .pattern)
        self.replacement = try container.decode(String.self, forKey: .replacement)
        self.isRegex = try container.decodeIfPresent(Bool.self, forKey: .isRegex) ?? false
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
}
