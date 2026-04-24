import Foundation

enum JWTHelper {
    static func isExpired(_ token: String, leeway: TimeInterval = 30) -> Bool {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return true }

        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }

        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = json["exp"] as? TimeInterval else {
            return true
        }
        return Date().timeIntervalSince1970 >= (exp - leeway)
    }
}
