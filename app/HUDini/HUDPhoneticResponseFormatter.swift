import Foundation

enum HUDPhoneticResponseFormatter {
    static func clean(_ response: String) -> String {
        // Trim whitespace/newlines
        var text = response.trimmingCharacters(in: .whitespacesAndNewlines)

        // Take only the first line from multi-line replies
        if let firstLine = text.split(separator: "\n").first {
            text = String(firstLine)
        }

        text = stripListPrefix(from: text)

        // Strip diacritics to keep ASCII only
        let noDiacritics = text.applyingTransform(.stripDiacritics, reverse: false) ?? text

        // Keep only ASCII characters
        let ascii = noDiacritics.filter { $0.isASCII }

        // Collapse whitespace and enforce single spaces
        let collapsed = ascii.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        return collapsed
    }

    private static func stripListPrefix(from text: String) -> String {
        let pattern = "^\\s*(?:[-*•]+|\\d+[.)])\\s*"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }

        let range = NSRange(location: 0, length: text.utf16.count)
        let stripped = regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: ""
        )
        return stripped
    }
}
