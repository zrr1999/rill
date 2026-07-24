import XCTest
@testable import RillCore

final class VocabularyPromptModelsTests: XCTestCase {
    func testExactPhraseMappingReplacesCaseInsensitiveMatches() {
        let rule = VocabularyRule(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            pattern: "Web coding",
            replacement: "Vibe Coding"
        )

        let result = VocabularyRuleApplicator.apply(
            text: "web coding should become Web coding.",
            rules: [rule]
        )

        XCTAssertEqual(result.text, "Vibe Coding should become Vibe Coding.")
        XCTAssertEqual(result.applications.map(\.ruleID), [rule.id])
        XCTAssertEqual(result.applications.first?.matchCount, 2)
        XCTAssertTrue(result.changed)
        XCTAssertTrue(result.issues.isEmpty)
    }

    func testCaseSensitiveMappingPreservesMismatchedCase() {
        let rule = VocabularyRule(
            pattern: "api",
            replacement: "API",
            caseSensitive: true
        )

        let result = VocabularyRuleApplicator.apply(text: "api Api API", rules: [rule])

        XCTAssertEqual(result.text, "API Api API")
        XCTAssertEqual(result.applications.first?.matchCount, 1)
    }

    func testWordBoundaryMappingDoesNotReplaceInsideWords() {
        let rule = VocabularyRule(
            pattern: "cat",
            replacement: "dog",
            matchMode: .wordBoundary
        )

        let result = VocabularyRuleApplicator.apply(text: "cat scatter cat", rules: [rule])

        XCTAssertEqual(result.text, "dog scatter dog")
        XCTAssertEqual(result.applications.first?.matchCount, 2)
    }

    func testScopeFiltersRulesByBundleAndGroup() {
        let groupID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        let matchingRule = VocabularyRule(
            pattern: "voice group",
            replacement: "语音识别组",
            scope: VocabularyRuleScope(
                bundleIdentifier: "com.apple.Notes",
                clipboardGroupID: groupID,
                locale: "zh-CN"
            )
        )
        let nonMatchingRule = VocabularyRule(
            pattern: "Notes",
            replacement: "Mail",
            scope: VocabularyRuleScope(bundleIdentifier: "com.apple.mail")
        )

        let result = VocabularyRuleApplicator.apply(
            text: "voice group in Notes",
            rules: [matchingRule, nonMatchingRule],
            context: VocabularyRuleContext(
                bundleIdentifier: "com.apple.Notes",
                clipboardGroupID: groupID,
                locale: "zh-CN"
            )
        )

        XCTAssertEqual(result.text, "语音识别组 in Notes")
        XCTAssertEqual(result.applications.map(\.ruleID), [matchingRule.id])
    }

    func testPriorityRunsHigherRulesFirst() {
        let lowPriority = VocabularyRule(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
            pattern: "alpha",
            replacement: "beta",
            priority: 0
        )
        let highPriority = VocabularyRule(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!,
            pattern: "alpha",
            replacement: "gamma",
            priority: 10
        )

        let result = VocabularyRuleApplicator.apply(
            text: "alpha",
            rules: [lowPriority, highPriority]
        )

        XCTAssertEqual(result.text, "gamma")
        XCTAssertEqual(result.applications.map(\.ruleID), [highPriority.id])
    }

    func testInvalidRegexProducesIssueAndLeavesTextUnchanged() {
        let rule = VocabularyRule(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000020")!,
            pattern: "[",
            replacement: "broken",
            matchMode: .regex
        )

        let result = VocabularyRuleApplicator.apply(text: "keep this", rules: [rule])

        XCTAssertEqual(result.text, "keep this")
        XCTAssertEqual(result.issues.map(\.kind), [.invalidRegex])
        XCTAssertFalse(result.changed)
    }

    func testPromptRendererSubstitutesKnownVariables() throws {
        let context = PromptVariableContext(
            text: "polish this",
            rawText: "polish this raw",
            selectedText: "selected text",
            clipboardText: "clipboard text",
            applicationName: "Notes",
            bundleIdentifier: "com.apple.Notes",
            groupIdentifier: "voice"
        )

        let result = try PromptVariableRenderer.render(
            prompt: "{app}/{bundleID}/{group}: {text}; raw={rawText}; "
                + "selected={selected}; clipboard={clipboard}",
            context: context
        )

        XCTAssertEqual(
            result.renderedPrompt,
            "Notes/com.apple.Notes/voice: polish this; raw=polish this raw; "
                + "selected=selected text; clipboard=clipboard text"
        )
        XCTAssertEqual(
            result.usedVariables,
            [.app, .bundleID, .group, .text, .rawText, .selected, .clipboard]
        )
        XCTAssertTrue(result.missingVariables.isEmpty)
        XCTAssertTrue(result.unknownVariables.isEmpty)
    }

    func testPromptRendererReportsMissingKnownVariables() throws {
        let context = PromptVariableContext(text: "dictation", selectedText: "")

        let result = try PromptVariableRenderer.render(
            prompt: "Rewrite {text} around {selected}.",
            context: context
        )

        XCTAssertEqual(result.renderedPrompt, "Rewrite dictation around .")
        XCTAssertEqual(result.usedVariables, [.text, .selected])
        XCTAssertEqual(result.missingVariables, [.selected])
    }

    func testPromptRendererPreservesUnknownVariablesAndEscapedBraces() throws {
        let context = PromptVariableContext(text: "dictation")

        let result = try PromptVariableRenderer.render(
            prompt: "Use {{text}} literally, keep {unknown}, render {text}.",
            context: context
        )

        XCTAssertEqual(
            result.renderedPrompt,
            "Use {text} literally, keep {unknown}, render dictation."
        )
        XCTAssertEqual(result.usedVariables, [.text])
        XCTAssertEqual(result.unknownVariables, ["unknown"])
    }

    func testPromptRendererPreservesPrivateUseCharactersAndUnmatchedBraces() throws {
        let context = PromptVariableContext(text: "dictation")
        let privateOpen = "\u{E000}"
        let privateClose = "\u{E001}"

        let result = try PromptVariableRenderer.render(
            prompt: "\(privateOpen){text}\(privateClose) {9invalid} {unterminated",
            context: context
        )

        XCTAssertEqual(
            result.renderedPrompt,
            "\(privateOpen)dictation\(privateClose) {9invalid} {unterminated"
        )
        XCTAssertEqual(result.usedVariables, [.text])
        XCTAssertTrue(result.unknownVariables.isEmpty)
    }

    func testPromptRenderSummaryIsContentFreeAndCodable() throws {
        let canary = "unknown-private-" + UUID().uuidString
        let result = PromptRenderResult(
            renderedPrompt: "rendered-private-" + UUID().uuidString,
            usedVariables: [.text, .clipboard],
            missingVariables: [.clipboard],
            redactedVariables: [.clipboard],
            unknownVariables: [canary]
        )

        XCTAssertEqual(
            result.summary,
            PromptRenderSummary(
                usedVariables: [.text, .clipboard],
                missingVariables: [.clipboard],
                redactedVariables: [.clipboard],
                unknownVariableCount: 1
            )
        )

        let encoded = try JSONEncoder().encode(result.summary)
        let encodedText = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(encodedText.contains(canary))
        XCTAssertFalse(encodedText.contains(result.renderedPrompt))
        XCTAssertEqual(
            try JSONDecoder().decode(PromptRenderSummary.self, from: encoded),
            result.summary
        )

        let reorderedInput = PromptRenderSummary(
            usedVariables: [.clipboard, .selected, .text],
            missingVariables: [.text],
            redactedVariables: [.selected, .clipboard]
        )
        XCTAssertEqual(reorderedInput.missingVariables, [.clipboard, .selected, .text])
        XCTAssertEqual(reorderedInput.redactedVariables, [.clipboard, .selected])
    }

    func testPromptRendererUsesStableBraceAndNonRecursiveReplacementSemantics() throws {
        let context = PromptVariableContext(text: "{selected}", selectedText: "private")
        let cases: [(String, String)] = [
            ("{{{text}}}", "{{selected}}"),
            ("{text}}}", "{selected}}"),
            ("{bad{text}", "{bad{selected}"),
            ("{}", "{}"),
            ("{text}", "{selected}"),
        ]

        for (prompt, expected) in cases {
            let result = try PromptVariableRenderer.render(prompt: prompt, context: context)
            XCTAssertEqual(result.renderedPrompt, expected, prompt)
        }

        let repeatedUnknown = try PromptVariableRenderer.render(
            prompt: "{unknown}{unknown}{other}",
            context: context
        )
        XCTAssertEqual(repeatedUnknown.unknownVariables, ["unknown", "other"])
    }

    func testPromptRendererRejectsEveryBoundedResourceOverflow() throws {
        let context = PromptVariableContext(text: "value")

        XCTAssertThrowsError(
            try PromptVariableRenderer.render(
                prompt: String(
                    repeating: "{",
                    count: PromptVariableRenderer.maximumTemplateUTF8Count + 1
                ),
                context: context
            )
        ) { error in
            XCTAssertEqual(error as? PromptVariableRenderingError, .templateTooLong)
        }

        XCTAssertThrowsError(
            try PromptVariableRenderer.render(
                prompt: "{" + String(
                    repeating: "a",
                    count: PromptVariableRenderer.maximumIdentifierScalarCount + 1
                ) + "}",
                context: context
            )
        ) { error in
            XCTAssertEqual(error as? PromptVariableRenderingError, .identifierTooLong)
        }

        XCTAssertThrowsError(
            try PromptVariableRenderer.render(
                prompt: "{text}",
                context: PromptVariableContext(
                    text: String(
                        repeating: "x",
                        count: PromptVariableRenderer.maximumVariableValueUTF8Count + 1
                    )
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? PromptVariableRenderingError,
                .variableValueTooLong(.text)
            )
        }

        let maximumValue = String(
            repeating: "x",
            count: PromptVariableRenderer.maximumVariableValueUTF8Count
        )
        XCTAssertThrowsError(
            try PromptVariableRenderer.render(
                prompt: "{text}{text}{text}",
                context: PromptVariableContext(text: maximumValue)
            )
        ) { error in
            XCTAssertEqual(error as? PromptVariableRenderingError, .renderedPromptTooLong)
        }

        let unknownPrompt = (0...PromptRenderSummary.maximumUnknownVariableCount)
            .map { "{unknown\($0)}" }
            .joined()
        XCTAssertThrowsError(
            try PromptVariableRenderer.render(prompt: unknownPrompt, context: context)
        ) { error in
            XCTAssertEqual(error as? PromptVariableRenderingError, .tooManyUnknownVariables)
        }
    }

    func testPromptRendererProcessesMaximumUnclosedBraceInputWithoutRescanning() throws {
        let prompt = String(
            repeating: "{",
            count: PromptVariableRenderer.maximumTemplateUTF8Count
        )

        let result = try PromptVariableRenderer.render(
            prompt: prompt,
            context: PromptVariableContext(text: "value")
        )

        XCTAssertEqual(
            result.renderedPrompt,
            String(repeating: "{", count: prompt.count / 2)
        )
        XCTAssertTrue(result.unknownVariables.isEmpty)
    }

    func testPromptRenderSummaryRejectsNonCanonicalDecodedEvidence() throws {
        let invalidPayloads = [
            #"{"usedVariables":["text","text"],"missingVariables":[],"redactedVariables":[],"unknownVariableCount":0}"#,
            #"{"usedVariables":["text"],"missingVariables":["clipboard"],"redactedVariables":[],"unknownVariableCount":0}"#,
            #"{"usedVariables":["clipboard"],"missingVariables":[],"redactedVariables":["clipboard"],"unknownVariableCount":0}"#,
            #"{"usedVariables":["clipboard","selected"],"missingVariables":["selected","clipboard"],"redactedVariables":[],"unknownVariableCount":0}"#,
            #"{"usedVariables":["clipboard","selected"],"missingVariables":["clipboard","selected"],"redactedVariables":["selected","clipboard"],"unknownVariableCount":0}"#,
            #"{"usedVariables":["text"],"missingVariables":[],"redactedVariables":[],"unknownVariableCount":-1}"#,
            #"{"usedVariables":["text"],"missingVariables":[],"redactedVariables":[],"unknownVariableCount":33}"#,
        ]

        for payload in invalidPayloads {
            XCTAssertThrowsError(
                try JSONDecoder().decode(
                    PromptRenderSummary.self,
                    from: Data(payload.utf8)
                ),
                payload
            )
        }
    }
}
