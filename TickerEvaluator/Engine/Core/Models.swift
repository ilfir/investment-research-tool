import Foundation

nonisolated enum AssetType: String, Sendable, Codable, CaseIterable {
    case stock = "Stock"
    case etf = "ETF / index fund"
    case mutualFund = "Mutual fund"
    case bondFund = "Bond fund"
    case reit = "REIT"
    case crypto = "Crypto"
    case cryptoETF = "Crypto spot ETF"
    case leveragedOrInverse = "Leveraged / inverse ETF"
    case unknown = "Unknown"

    var isFund: Bool { [.etf, .mutualFund, .bondFund, .cryptoETF, .leveragedOrInverse].contains(self) }
    /// Nash's 1% speculation cap applies to these (approved default).
    var isSpeculation: Bool { [.crypto, .cryptoETF, .leveragedOrInverse].contains(self) }
}

nonisolated enum AccountType: String, Sendable, Codable, CaseIterable {
    case taxable = "Taxable", traditionalIRA = "Traditional IRA", rothIRA = "Roth IRA", k401 = "401(k)", other = "Other"
}

nonisolated enum HoldingRole: String, Sendable, Codable, CaseIterable {
    case core = "Core", satellite = "Satellite", income = "Income", hedge = "Hedge", speculation = "Speculation"
}

nonisolated struct InvestorProfile: Sendable, Codable, Hashable {
    var age: Int? = nil
    var horizonYears: Int? = nil
    var accountType: AccountType? = nil
    var role: HoldingRole? = nil
    var maxDrawdownTolerance: Double? = nil   // fraction, e.g. 0.30
    var plannedAmount: Double? = nil          // USD
}

nonisolated struct Position: Sendable, Codable, Hashable, Identifiable {
    var id = UUID()
    var ticker: String
    var shares: Double? = nil
    var amount: Double? = nil                 // USD market value (used when shares can't be priced)
    var accountType: AccountType = .taxable
    var assetType: AssetType? = nil           // resolved during evaluation
}

/// Your answers to Nash's three judgement steps (nil = not confirmed yet).
nonisolated struct JudgementAnswers: Sendable, Codable, Hashable {
    var moat: Bool? = nil
    var topTierCEO: Bool? = nil
    var recessionProof: Bool? = nil
}

nonisolated struct EvaluationRequest: Sendable {
    var ticker: String
    var profile = InvestorProfile()
    var positions: [Position] = []
    var judgements = JudgementAnswers()
    var asOf: Date = .now
}

nonisolated enum EngineError: Error, LocalizedError {
    case notFound(String), badResponse(String, Int), parse(String), unsupported(String)
    var errorDescription: String? {
        switch self {
        case .notFound(let s): "Not found: \(s)"
        case .badResponse(let u, let c): "HTTP \(c) from \(u)"
        case .parse(let s): "Could not parse: \(s)"
        case .unsupported(let s): "Unsupported: \(s)"
        }
    }
}
