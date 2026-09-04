import Foundation

public struct FoldRecoveryState: Codable, Equatable, Sendable {
    public static let maximumContractedHeaderCount = 10_000

    public let contractedHeaderLines: [Int]

    public init(contractedHeaderLines: [Int] = []) {
        self.contractedHeaderLines = Array(
            Set(contractedHeaderLines.lazy.filter { $0 >= 0 })
        ).sorted().prefix(Self.maximumContractedHeaderCount).map { $0 }
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.singleValueContainer().decode([Int].self)
        guard values.count <= Self.maximumContractedHeaderCount,
              values.allSatisfy({ $0 >= 0 }) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Fold headers must be nonnegative and bounded"
            ))
        }
        contractedHeaderLines = Array(Set(values)).sorted()
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(contractedHeaderLines)
    }
}
