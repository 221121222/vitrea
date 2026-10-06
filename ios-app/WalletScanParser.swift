import Foundation

public enum PaymentNetwork: String, CaseIterable, Codable {
    case visa = "Visa"
    case mastercard = "Mastercard"
    case amex = "American Express"
    case unionPay = "UnionPay"
    case discover = "Discover"
    case jcb = "JCB"
    case appleCard = "Apple Card"
    case transit = "Transit Card"
    case unknown = "Payment Card"

    public var iconName: String {
        switch self {
        case .visa: return "creditcard.fill"
        case .mastercard: return "creditcard.fill"
        case .amex: return "creditcard.fill"
        case .unionPay: return "creditcard.fill"
        case .discover: return "creditcard.fill"
        case .jcb: return "creditcard.fill"
        case .appleCard: return "apple.logo"
        case .transit: return "tram.fill"
        case .unknown: return "creditcard"
        }
    }

    public var displayName: String { rawValue }

    public static func from(activationID: String) -> PaymentNetwork {
        let upper = activationID.uppercased()
        if upper.hasPrefix("A000000003") { return .visa }
        if upper.hasPrefix("A000000004") { return .mastercard }
        if upper.hasPrefix("A000000025") { return .amex }
        if upper.hasPrefix("A000000333") { return .unionPay }
        if upper.hasPrefix("A000000152") { return .discover }
        if upper.hasPrefix("A000000065") { return .jcb }
        return .unknown
    }

    public static func fromAID(_ aid: String) -> PaymentNetwork? {
        let net = from(activationID: aid)
        return net == .unknown ? nil : net
    }
}

public struct ActivationMatch: Equatable {
    public let aid: String
    public let network: PaymentNetwork?
    public let id: String?

    public init(aid: String, network: PaymentNetwork? = nil, id: String? = nil) {
        self.aid = aid
        self.network = network ?? PaymentNetwork.fromAID(aid)
        self.id = id
    }
}

public enum WalletScanParser {
    static let cardReferences: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"/([-A-Za-z0-9_+=]{20,64})\.(?:pkpass|cache|pkcache)(?=[/\s\"'\),]|$)"#),
        try! NSRegularExpression(pattern: #"/(?:Cards|Passes/Cards)/([-A-Za-z0-9_+=]{20,64})(?=[/\s\"'\),]|$)"#, options: .caseInsensitive),
        try! NSRegularExpression(pattern: #"PDCardFileManager:\s*writing card\s+([-A-Za-z0-9_+=]{20,64})(?=[\s\"'\),]|$)"#, options: .caseInsensitive),
        try! NSRegularExpression(pattern: #"PDPassLibrary:\s*wrote pass\s+([-A-Za-z0-9_+=]{20,64})(?=[\s\"'\),]|$)"#, options: .caseInsensitive),
        try! NSRegularExpression(pattern: #"VerificationCheck\.([-A-Za-z0-9_+=]{20,64})(?=[\s\"'\),]|$)"#, options: .caseInsensitive),
        try! NSRegularExpression(pattern: #"selected pass uniqueID\s*:\s*\"?([-A-Za-z0-9_+=]{20,64})\"?"#, options: .caseInsensitive),
        try! NSRegularExpression(pattern: #"Dashboard loading[^:]*:\s*for\s+([-A-Za-z0-9_+=]{20,80})(?=[,\s\"'\)]|$)"#, options: .caseInsensitive),
        try! NSRegularExpression(pattern: #"Dashboard loading[^:]*:\s+([-A-Za-z0-9_+=]{20,80})\s+-"#, options: .caseInsensitive),
    ]

    static let inSessionList = try! NSRegularExpression(
        pattern: #"passIDs\[(?:InSession|global)\]\s*[:=]\s*(?:\{\s*)?\(([^)]*)\)"#,
        options: .caseInsensitive
    )

    static let cardID = try! NSRegularExpression(pattern: #"(?<![-A-Za-z0-9_+=])[-A-Za-z0-9_+=]{20,64}(?![-A-Za-z0-9_+=])"#)

    static let activation = try! NSRegularExpression(
        pattern: #"setActivePaymentApplet.{0,4096}?requestedApplet\s*:.{0,4096}?(?:identifier\s*=\s*|\"identifier\"\s*:\s*\")([A-Fa-f0-9]{10,64})\b"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )

    static let fallbackToken = try! NSRegularExpression(
        pattern: #"(?<![-A-Za-z0-9+/=])([A-Za-z0-9+/_-]{27}=)(?![-A-Za-z0-9+/=])"#
    )

    static let placeholders: Set<String> = [
        "OM6NYhwXMZrAw0sRUjR62wmF4ZQ=",
        "M6nDwZrkYbFlsodLgCbvyFZQ1cc=",
        "kJL-D0rr-SZhbj2c8nK-OQ9hCMY=",
        "hwAtAmHKYwsQrJbT5cTNDsaxVME="
    ]

    public static func cardIDs(in line: String) -> [String] {
        let lineRange = NSRange(line.startIndex..., in: line)
        var seen = Set<String>()
        var result: [String] = []

        func add(_ id: String) {
            guard !placeholders.contains(id), seen.insert(id).inserted else { return }
            result.append(id)
        }

        for pattern in cardReferences {
            for match in pattern.matches(in: line, range: lineRange) {
                guard let range = Range(match.range(at: 1), in: line) else { continue }
                add(String(line[range]))
            }
        }

        for match in inSessionList.matches(in: line, range: lineRange) {
            guard let range = Range(match.range(at: 1), in: line) else { continue }
            let sessionString = String(line[range])
            let sessionRange = NSRange(sessionString.startIndex..., in: sessionString)
            for cardMatch in cardID.matches(in: sessionString, range: sessionRange) {
                guard let cardRange = Range(cardMatch.range, in: sessionString) else { continue }
                add(String(sessionString[cardRange]))
            }
        }

        return result
    }

    public static func fallbackCardIDs(in line: String) -> [String] {
        let lineRange = NSRange(line.startIndex..., in: line)
        var seen = Set<String>()
        return fallbackToken.matches(in: line, range: lineRange).compactMap { match in
            guard let range = Range(match.range(at: 1), in: line) else { return nil }
            let id = String(line[range])
            guard !placeholders.contains(id), seen.insert(id).inserted else { return nil }
            return id
        }
    }

    public static func activationMatches(in line: String) -> [ActivationMatch] {
        var matches: [ActivationMatch] = []
        let lineRange = NSRange(line.startIndex..., in: line)

        // 1. JSON-style activation: {"aid": "...", "passId": "..."}
        let jsonPattern = try! NSRegularExpression(
            pattern: #"\"aid\"\s*:\s*\"([A-Fa-f0-9]{10,64})\"[^}]*\"passId\"\s*:\s*\"([-A-Za-z0-9_+=]{20,64})\""#,
            options: .caseInsensitive
        )
        for match in jsonPattern.matches(in: line, range: lineRange) {
            guard let r1 = Range(match.range(at: 1), in: line),
                  let r2 = Range(match.range(at: 2), in: line) else { continue }
            let aid = String(line[r1]).uppercased()
            let passId = String(line[r2])
            matches.append(ActivationMatch(aid: aid, network: PaymentNetwork.fromAID(aid), id: passId))
        }

        // 2. Stockholm / activation line with pass ID and AID:
        let passAndAidPattern = try! NSRegularExpression(
            pattern: #"(?:activating payment pass ID|pass ID)\s*:\s*([-A-Za-z0-9_+=]{20,64}).*?AID\s*:\s*([A-Fa-f0-9]{10,64})"#,
            options: .caseInsensitive
        )
        for match in passAndAidPattern.matches(in: line, range: lineRange) {
            guard let r1 = Range(match.range(at: 1), in: line),
                  let r2 = Range(match.range(at: 2), in: line) else { continue }
            let passId = String(line[r1])
            let aid = String(line[r2]).uppercased()
            matches.append(ActivationMatch(aid: aid, network: PaymentNetwork.fromAID(aid), id: passId))
        }

        // 3. General activation applet match:
        for match in activation.matches(in: line, range: lineRange) {
            guard let range = Range(match.range(at: 1), in: line) else { continue }
            let aid = String(line[range]).uppercased()
            if !matches.contains(where: { $0.aid == aid }) {
                matches.append(ActivationMatch(aid: aid, network: PaymentNetwork.fromAID(aid), id: nil))
            }
        }

        return matches
    }

    public static func activationIDs(in line: String) -> [ActivationMatch] {
        return activationMatches(in: line)
    }

    public static func activationAIDs(in line: String) -> [String] {
        return activationMatches(in: line).map(\.aid)
    }
}
