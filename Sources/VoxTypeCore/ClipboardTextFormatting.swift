import Foundation

public enum ClipboardTextFormatting {
    private static func regex(_ pattern: String) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern, options: [])
        } catch {
            preconditionFailure("Invalid regex pattern '\(pattern)': \(error)")
        }
    }

    private static let structuralMarkdownPattern = regex(
        #"(?m)^\s{0,3}(#{1,6}\s+\S+|>\s+\S+|[-*+]\s+\S+|\d+\.\s+\S+|```|~~~|\|.+\|)"#
    )
    private static let linkMarkdownPattern = regex(
        #"\[[^\]]+\]\([^)]+\)"#
    )
    private static let imageMarkdownPattern = regex(
        #"!\[([^\]]*)\]\([^)]+\)"#
    )
    private static let markdownLinkCapturePattern = regex(
        #"\[([^\]]+)\]\([^)]+\)"#
    )
    private static let headingPrefixPattern = regex(
        #"(?m)^\s{0,3}#{1,6}\s*"#
    )
    private static let quotePrefixPattern = regex(
        #"(?m)^\s{0,3}>\s*"#
    )
    private static let unorderedListPrefixPattern = regex(
        #"(?m)^\s{0,3}[-*+]\s*"#
    )
    private static let orderedListPrefixPattern = regex(
        #"(?m)^\s{0,3}\d+\.\s*"#
    )
    private static let codeFencePattern = regex(
        #"(?m)^\s*(```|~~~)\s*"#
    )
    private static let emphasisDelimiterPattern = regex(
        #"(\*\*|__|~~|`|\*|_)"#
    )
    private static let tablePipePattern = regex(
        #"\|"#
    )
    private static let strongEmphasisPattern = regex(
        #"(\*\*|__)[^\n]+?(\*\*|__)"#
    )
    private static let inlineCodePattern = regex(
        #"`[^`\n]+`"#
    )

    public static func normalizedSummary(_ text: String) -> String {
        text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    public static func isLikelyMarkdown(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        var score = 0
        if matches(structuralMarkdownPattern, in: trimmed) {
            score += 2
        }
        if matches(linkMarkdownPattern, in: trimmed) {
            score += 2
        }
        if matches(strongEmphasisPattern, in: trimmed) {
            score += 2
        }
        if matches(inlineCodePattern, in: trimmed) {
            score += 1
        }
        if trimmed.contains("```") || trimmed.contains("~~~") {
            score += 2
        }

        return score >= 2
    }

    public static func renderedMarkdown(_ text: String) -> AttributedString? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isLikelyMarkdown(trimmed) else { return nil }

        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return try? AttributedString(markdown: trimmed, options: options)
    }

    public static func summaryText(_ text: String) -> String {
        guard isLikelyMarkdown(text) else {
            return normalizedSummary(text)
        }

        var stripped = text
        stripped = replacingMatches(of: imageMarkdownPattern, in: stripped, with: "$1")
        stripped = replacingMatches(of: markdownLinkCapturePattern, in: stripped, with: "$1")
        stripped = replacingMatches(of: headingPrefixPattern, in: stripped, with: "")
        stripped = replacingMatches(of: quotePrefixPattern, in: stripped, with: "")
        stripped = replacingMatches(of: unorderedListPrefixPattern, in: stripped, with: "")
        stripped = replacingMatches(of: orderedListPrefixPattern, in: stripped, with: "")
        stripped = replacingMatches(of: codeFencePattern, in: stripped, with: "")
        stripped = replacingMatches(of: emphasisDelimiterPattern, in: stripped, with: "")
        stripped = replacingMatches(of: tablePipePattern, in: stripped, with: " ")

        let summarized = normalizedSummary(stripped)
        return summarized.isEmpty ? normalizedSummary(text) : summarized
    }

    private static func matches(_ expression: NSRegularExpression, in text: String) -> Bool {
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.firstMatch(in: text, options: [], range: fullRange) != nil
    }

    private static func replacingMatches(
        of expression: NSRegularExpression,
        in text: String,
        with template: String
    ) -> String {
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.stringByReplacingMatches(in: text, options: [], range: fullRange, withTemplate: template)
    }
}
