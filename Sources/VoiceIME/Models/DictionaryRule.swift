import Foundation

public struct DictionaryRule: Identifiable, Codable, Equatable {
    public var id: UUID
    public var pattern: String
    public var replacement: String
    public var isRegex: Bool
    public var isEnabled: Bool

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
}
