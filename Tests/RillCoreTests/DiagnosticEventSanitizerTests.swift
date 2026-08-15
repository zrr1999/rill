import XCTest

@testable import RillCore

final class DiagnosticEventSanitizerTests: XCTestCase {
  func testAudioProcessingLaneRetainsOnlyClosedRuntimeValues() {
    for lane in ["assistant", "interactive"] {
      let sanitized = DiagnosticEventSanitizer.sanitize(
        DiagnosticEvent(
          subsystem: .session,
          level: .debug,
          event: "audio-processing.enqueued",
          message: "Queued audio.",
          metadata: ["lane": lane]
        )
      )

      XCTAssertEqual(sanitized.metadata["lane"], lane)
    }

    let rejected = DiagnosticEventSanitizer.sanitize(
      DiagnosticEvent(
        subsystem: .session,
        level: .debug,
        event: "audio-processing.enqueued",
        message: "Queued audio.",
        metadata: ["lane": "background-canary"]
      )
    )
    XCTAssertNil(rejected.metadata["lane"])
  }

  func testSanitizeRetainsWakeWordRuntimeCoordinatesWithoutUserContent() {
    for eventCode in [
      "wake-word.detected",
      "wake-word.run-rejected",
      "wake-word.start-failed",
    ] {
      let event = DiagnosticEvent(
        subsystem: .providers,
        level: .info,
        event: eventCode,
        message: "private wake phrase must not persist",
        metadata: ["reason": "request-failed"]
      )

      let sanitized = DiagnosticEventSanitizer.sanitize(event)

      XCTAssertEqual(sanitized.event, eventCode)
      XCTAssertEqual(sanitized.message, DiagnosticEventSanitizer.sanitizedMessage)
      XCTAssertEqual(sanitized.metadata, ["reason": "request-failed"])
    }
  }

  func testSanitizeRetainsClosedGlobalInputRouteMetadata() {
    let event = DiagnosticEvent(
      subsystem: .platform,
      level: .info,
      event: "global-input.installed",
      message: "runtime state",
      metadata: [
        "pushToTalk": "active",
        "recordPanelShortcut": "disabled-by-preference",
        "commandVInterception": "disabled-by-preference",
      ]
    )

    XCTAssertEqual(
      DiagnosticEventSanitizer.sanitize(event).metadata,
      event.metadata
    )
  }

  func testSanitizeRetainsWorkflowAudioTerminalReasonsAndRejectsUnknownReason() {
    for reason in [
      "initialSilenceTimedOut",
      "speechEnded",
      "maximumDurationReached",
      "inputEndedUnexpectedly",
    ] {
      let event = DiagnosticEvent(
        subsystem: .session,
        level: .info,
        event: "workflow.audio-recording.terminal-signal",
        message: "safe",
        metadata: ["reason": reason]
      )

      let sanitized = DiagnosticEventSanitizer.sanitize(event)

      XCTAssertEqual(sanitized.event, "workflow.audio-recording.terminal-signal")
      XCTAssertEqual(sanitized.metadata, ["reason": reason])
    }

    let unknownReason = DiagnosticEvent(
      subsystem: .session,
      level: .info,
      event: "workflow.audio-recording.terminal-signal",
      message: "safe",
      metadata: ["reason": "private-reason-canary"]
    )

    let sanitizedUnknownReason = DiagnosticEventSanitizer.sanitize(unknownReason)
    XCTAssertEqual(
      sanitizedUnknownReason.event,
      "workflow.audio-recording.terminal-signal"
    )
    XCTAssertTrue(sanitizedUnknownReason.metadata.isEmpty)
  }

  func testSanitizeRetainsOnlyIntegerAcousticSummaryMetadata() {
    let event = DiagnosticEvent(
      subsystem: .session,
      level: .info,
      event: "workflow.audio-recording.terminal-signal",
      message: "must be replaced",
      metadata: [
        "reason": "speechEnded",
        "acousticObservedSegmentCount": "5",
        "acousticObservedDurationMilliseconds": "750",
        "acousticAboveThresholdDurationMilliseconds": "600",
        "acousticPeakLevelPercentBucket": "50",
        "acousticMaximumConsecutiveAboveThresholdDurationMilliseconds": "350",
        "audioSamples": "private-raw-audio-canary",
        "deviceName": "private-device-canary",
        "transcript": "private-transcript-canary",
      ]
    )

    XCTAssertEqual(
      DiagnosticEventSanitizer.sanitize(event).metadata,
      [
        "reason": "speechEnded",
        "acousticObservedSegmentCount": "5",
        "acousticObservedDurationMilliseconds": "750",
        "acousticAboveThresholdDurationMilliseconds": "600",
        "acousticPeakLevelPercentBucket": "50",
        "acousticMaximumConsecutiveAboveThresholdDurationMilliseconds": "350",
      ]
    )

    let invalidIntegers = DiagnosticEvent(
      subsystem: .session,
      level: .info,
      event: "workflow.audio-recording.terminal-signal",
      message: "unsafe",
      metadata: [
        "acousticObservedSegmentCount": "-1",
        "acousticObservedDurationMilliseconds": "1.5",
        "acousticAboveThresholdDurationMilliseconds": "01",
        "acousticPeakLevelPercentBucket": "50%",
        "acousticMaximumConsecutiveAboveThresholdDurationMilliseconds": "private",
      ]
    )
    XCTAssertTrue(DiagnosticEventSanitizer.sanitize(invalidIntegers).metadata.isEmpty)
  }

  func testSanitizeRetainsDiagnosticCoordinatesAndOnlyAllowlistedMetadata() {
    let timestamp = Date(timeIntervalSince1970: 123)
    let runID = UUID()
    let event = DiagnosticEvent(
      timestamp: timestamp,
      runID: runID,
      subsystem: .providers,
      level: .error,
      event: "provider.request.failed",
      message: "recognized-body-canary",
      metadata: [
        "Authorization": "Bearer authorization-canary",
        "apiKey": "api-key-canary",
        "count": "3",
        "diagnosticRemovedCount": "7",
        "endpoint": "https://example.com/listen?token=query-canary",
        "path": "/Users/alice/private/audio.wav",
        "reason": "transport-failed",
        "responseBody": #"{"transcript":"response-body-canary"}"#,
        "runReceiptRemovedCount": "11",
        "statusCode": "401",
        "transcript": "recognized-body-canary",
      ]
    )

    let sanitized = DiagnosticEventSanitizer.sanitize(event)

    XCTAssertEqual(sanitized.timestamp, timestamp)
    XCTAssertEqual(sanitized.runID, runID)
    XCTAssertEqual(sanitized.subsystem, .providers)
    XCTAssertEqual(sanitized.level, .error)
    XCTAssertEqual(sanitized.event, "provider.request.failed")
    XCTAssertEqual(sanitized.message, DiagnosticEventSanitizer.sanitizedMessage)
    XCTAssertEqual(
      sanitized.metadata,
      [
        "count": "3",
        "diagnosticRemovedCount": "7",
        "reason": "transport-failed",
        "runReceiptRemovedCount": "11",
        "statusCode": "401",
      ]
    )
  }

  func testSanitizeRejectsSensitiveSyntaxEvenForAllowlistedKeys() {
    let event = DiagnosticEvent(
      subsystem: .providers,
      level: .error,
      event: "provider.request.failed",
      message: "unsafe",
      metadata: [
        "actionID": "Bearer action-secret",
        "provider.model": "https://example.com/model?api_key=secret",
        "reason": "/Users/alice/private/reason.txt",
        "source": "file:///Users/alice/private/source.txt",
      ]
    )

    XCTAssertTrue(DiagnosticEventSanitizer.sanitize(event).metadata.isEmpty)
  }

  func testSanitizeRejectsCodeShapedSecretsAndRetainsOnlyClosedBuiltinCoordinates() {
    let alphanumericCanary = "CANARYSECRET123456789"
    let base64Canary = "Q0FOQVJZU0VDUkVUMTIzNDU2Nzg5"
    let hexadecimalCanary = "43414e415259534543524554313233343536373839"
    let event = DiagnosticEvent(
      subsystem: .providers,
      level: .error,
      event: "session.action",
      message: "unsafe",
      metadata: [
        "actionID": alphanumericCanary,
        "provider.model": base64Canary,
        "recognizerID": hexadecimalCanary,
        "reason": "transport-failed",
        "resultCode": "failed",
      ]
    )

    XCTAssertEqual(
      DiagnosticEventSanitizer.sanitize(event).metadata,
      [
        "reason": "transport-failed",
        "resultCode": "failed",
      ]
    )

    let builtinEvent = DiagnosticEvent(
      subsystem: .session,
      level: .info,
      event: "session.action",
      message: "safe",
      metadata: [
        "actionID": "focused-application.insert",
        "provider": "sherpa-onnx.local",
        "provider.kind": "sherpa-onnx",
        "provider.model": "qwen3-asr-0.6b-int8",
        "recognizerID": "sherpa-onnx.local",
        "transformerID": "transformer.normalize",
      ]
    )

    XCTAssertEqual(
      DiagnosticEventSanitizer.sanitize(builtinEvent).metadata,
      builtinEvent.metadata
    )
  }

  func testSanitizeRejectsUnknownValueInsideOtherwiseClosedCodeList() {
    let event = DiagnosticEvent(
      subsystem: .systemClipboard,
      level: .warning,
      event: "clipboard.capture.skipped",
      message: "unsafe",
      metadata: [
        "decisions": "skipClipboardCapture,CANARYSECRET123",
        "protections": "concealed,transient",
      ]
    )

    XCTAssertEqual(
      DiagnosticEventSanitizer.sanitize(event).metadata,
      ["protections": "concealed,transient"]
    )
  }

  func testSanitizeRetainsRecognitionWorkTemporaryArtifactKind() {
    let event = DiagnosticEvent(
      subsystem: .platform,
      level: .warning,
      event: "temporary-files.cleanup.pending",
      message: "safe",
      metadata: [
        "temporaryFileFailureArtifactKinds": "recognition-work,recovery-audio"
      ]
    )

    XCTAssertEqual(
      DiagnosticEventSanitizer.sanitize(event).metadata,
      event.metadata
    )
  }

  func testSanitizeRetainsCurrentSherpaAndHistoricalWhisperCoordinates() {
    for model in ["qwen3-asr-0.6b-int8", "sense-voice-small-int8"] {
      let currentEvent = DiagnosticEvent(
        subsystem: .providers,
        level: .info,
        event: "provider.recognition.completed",
        message: "safe",
        metadata: [
          "provider": "sherpa-onnx.local",
          "provider.kind": "sherpa-onnx",
          "provider.model": model,
          "recognizerID": "sherpa-onnx.local",
        ]
      )

      XCTAssertEqual(
        DiagnosticEventSanitizer.sanitize(currentEvent).metadata,
        currentEvent.metadata
      )
    }

    for kind in ["whisperkit", "whisperkit.live"] {
      for model in [
        "distil-whisper_distil-large-v3_594MB",
        "openai_whisper-large-v3-v20240930_626MB",
        "openai_whisper-tiny",
      ] {
        let historicalEvent = DiagnosticEvent(
          subsystem: .providers,
          level: .info,
          event: "provider.recognition.completed",
          message: "safe",
          metadata: [
            "provider": "whisperkit.stream",
            "provider.kind": kind,
            "provider.model": model,
          ]
        )

        XCTAssertEqual(
          DiagnosticEventSanitizer.sanitize(historicalEvent).metadata,
          historicalEvent.metadata
        )
      }
    }
  }

  func testSanitizeRetainsSherpaStartupStateAndRejectsRetiredWhisperEvents() {
    let startupStates: [(event: String, level: DiagnosticLevel, metadata: [String: String])] = [
      (
        event: "provider.sherpa-onnx.available",
        level: .info,
        metadata: [
          "recognizerID": "sherpa-onnx.local",
          "modelCount": "2",
          "defaultModel": "qwen3-asr-0.6b-int8",
          "vadModel": "silero-vad-v4",
        ]
      ),
      (
        event: "provider.sherpa-onnx.unavailable",
        level: .warning,
        metadata: [
          "recognizerID": "sherpa-onnx.local",
          "reason": "trust-material-unavailable",
          "vadModel": "silero-vad-v4",
        ]
      ),
    ]

    for state in startupStates {
      var metadata = state.metadata
      metadata["transcript"] = "private-transcript-canary"
      let event = DiagnosticEvent(
        subsystem: .providers,
        level: state.level,
        event: state.event,
        message: "must be replaced",
        metadata: metadata
      )

      let sanitized = DiagnosticEventSanitizer.sanitize(event)
      XCTAssertEqual(sanitized.event, state.event)
      XCTAssertEqual(sanitized.metadata, state.metadata)
    }

    for retiredEvent in [
      "provider.whisperkit.available",
      "provider.whisperkit.preload.failed",
      "provider.whisperkit.trust-material-unavailable",
      "provider.whisperkit.trusted-model.available",
      "provider.whisperkit.unavailable",
    ] {
      XCTAssertEqual(
        DiagnosticEventSanitizer.sanitizeEventCode(retiredEvent),
        DiagnosticEventSanitizer.invalidEventCode
      )
    }
  }

  func testSanitizeDropsExactApplicationAndProcessIdentifiers() {
    let event = DiagnosticEvent(
      subsystem: .systemClipboard,
      level: .warning,
      event: "clipboard.inject.focus.changed",
      message: "unsafe",
      metadata: [
        "bundleID": "com.example.private-app",
        "frontmostBundleIdentifier": "com.example.frontmost",
        "frontmostProcessIdentifier": "123",
        "targetBundleIdentifier": "com.example.target",
        "targetProcessIdentifier": "456",
        "targetFocusActivationAttempted": "true",
        "targetFocusActivationSucceeded": "false",
        "targetFocusInitiallyMatched": "false",
        "targetFocusProvided": "true",
        "targetFocusVerified": "false",
      ]
    )

    XCTAssertEqual(
      DiagnosticEventSanitizer.sanitize(event).metadata,
      [
        "targetFocusActivationAttempted": "true",
        "targetFocusActivationSucceeded": "false",
        "targetFocusInitiallyMatched": "false",
        "targetFocusProvided": "true",
        "targetFocusVerified": "false",
      ]
    )
  }

  func testSanitizeDropsLinkableIdentifiersAndExactContentMeasurements() {
    let event = DiagnosticEvent(
      subsystem: .session,
      level: .info,
      event: "session.stage",
      message: "unsafe",
      metadata: [
        "audio.durationSeconds": "1.25",
        "groupID": UUID().uuidString,
        "plainTextLength": "3",
        "sourceGroupID": UUID().uuidString,
        "sourceItemID": UUID().uuidString,
        "stepID": UUID().uuidString,
        "textLength": "3",
        "workflowID": UUID().uuidString,
        "stage": "delivering",
      ]
    )

    XCTAssertEqual(
      DiagnosticEventSanitizer.sanitize(event).metadata,
      ["stage": "delivering"]
    )
  }

  func testSanitizeReplacesFreeFormPathAndTokenEventValues() {
    let unsafeEventCodes = [
      "diagnostic private content",
      "diagnostic.canarysecret123",
      "diagnostic.43414e415259534543524554",
      "/Users/alice/private/event.txt",
      "token=private-event-token",
      "diagnostic.Event.Uppercase",
      "diagnostic..empty-segment",
    ]

    for eventCode in unsafeEventCodes {
      let event = DiagnosticEvent(
        subsystem: .session,
        level: .warning,
        event: eventCode,
        message: "unsafe"
      )

      XCTAssertEqual(
        DiagnosticEventSanitizer.sanitize(event).event,
        DiagnosticEventSanitizer.invalidEventCode
      )
    }
  }

  func testSanitizeRetainsOnlyCataloguedEventAndEventMetadataCoordinates() {
    XCTAssertEqual(
      DiagnosticEventSanitizer.sanitizeEventCode("session.stage"),
      "session.stage"
    )
    XCTAssertEqual(
      DiagnosticEventSanitizer.sanitizeEventCode("session.canarysecret123"),
      DiagnosticEventSanitizer.invalidEventCode
    )
    XCTAssertEqual(
      DiagnosticEventSanitizer.sanitizeEventCode(
        "markdown-append.cleanup-retry-pending"
      ),
      "markdown-append.cleanup-retry-pending"
    )
    XCTAssertEqual(
      DiagnosticEventSanitizer.sanitizeEventCode(
        "markdown-append.cleanup-indeterminate"
      ),
      "markdown-append.cleanup-indeterminate"
    )
    XCTAssertEqual(
      DiagnosticEventSanitizer.sanitizeEventCode(
        "persistence.keychain.temporarily-unavailable"
      ),
      "persistence.keychain.temporarily-unavailable"
    )

    let event = DiagnosticEvent(
      subsystem: .session,
      level: .error,
      event: "diagnostics.repository.save.failed",
      message: "safe",
      metadata: ["event": "session.canarysecret123"]
    )
    XCTAssertTrue(DiagnosticEventSanitizer.sanitize(event).metadata.isEmpty)
  }

  func testSanitizeRetainsClosedCancellationCoordinates() {
    let event = DiagnosticEvent(
      subsystem: .session,
      level: .info,
      event: "session.cancelled",
      message: "safe",
      metadata: [
        "outcome": "cancelled",
        "resultCode": "cancelled",
        "stage": "delivering",
      ]
    )

    let sanitized = DiagnosticEventSanitizer.sanitize(event)

    XCTAssertEqual(sanitized.event, "session.cancelled")
    XCTAssertEqual(sanitized.metadata, event.metadata)
  }

  func testSanitizeRetainsContentFreeRecognitionTimeoutCoordinates() {
    let event = DiagnosticEvent(
      subsystem: .session,
      level: .error,
      event: "session.recognition.timeout",
      message: "private provider response canary",
      metadata: [
        "recognizerID": "sherpa-onnx.local",
        "text": "private transcript canary",
        "file": "/private/audio.wav",
      ]
    )

    let sanitized = DiagnosticEventSanitizer.sanitize(event)

    XCTAssertEqual(sanitized.event, "session.recognition.timeout")
    XCTAssertEqual(sanitized.message, DiagnosticEventSanitizer.sanitizedMessage)
    XCTAssertEqual(sanitized.metadata, ["recognizerID": "sherpa-onnx.local"])
  }

  func testSanitizeRetainsOnlyClosedKeychainStateCoordinates() {
    for state in [
      "single-key",
      "matching-key-retained",
      "alternate-key-retained",
    ] {
      let event = DiagnosticEvent(
        subsystem: .session,
        level: .info,
        event: "persistence.sqlite.ready",
        message: "safe",
        metadata: ["keychainKeyState": state]
      )

      XCTAssertEqual(
        DiagnosticEventSanitizer.sanitize(event).metadata,
        ["keychainKeyState": state]
      )
    }

    let unknown = DiagnosticEvent(
      subsystem: .session,
      level: .info,
      event: "persistence.sqlite.ready",
      message: "unsafe",
      metadata: ["keychainKeyState": "PRIVATE-CONTENT-CANARY"]
    )
    XCTAssertTrue(DiagnosticEventSanitizer.sanitize(unknown).metadata.isEmpty)
  }

  func testSanitizeRetainsOnlyClosedClipboardTriggerDecisionCoordinates() {
    let runID = UUID()
    let event = DiagnosticEvent(
      runID: runID,
      subsystem: .systemClipboard,
      level: .info,
      event: "clipboard.trigger.loop-prevented",
      message: "private clipboard body canary",
      metadata: [
        "eventKind": "recordEdited",
        "groupID": UUID().uuidString,
        "itemID": UUID().uuidString,
        "outcome": "skipped",
        "prompt": "private prompt canary",
        "reason": "loopPrevented",
        "tag": "user-controlled-tag-canary",
        "text": "private clipboard body canary",
        "workflowID": UUID().uuidString,
      ]
    )

    let sanitized = DiagnosticEventSanitizer.sanitize(event)

    XCTAssertEqual(sanitized.runID, runID)
    XCTAssertEqual(sanitized.event, "clipboard.trigger.loop-prevented")
    XCTAssertEqual(
      sanitized.metadata,
      [
        "eventKind": "recordEdited",
        "outcome": "skipped",
        "reason": "loopPrevented",
      ]
    )
    XCTAssertFalse(String(describing: sanitized).contains("private clipboard body canary"))
    XCTAssertFalse(String(describing: sanitized).contains("private prompt canary"))
  }

  func testSanitizeRejectsUnknownClipboardTriggerDecisionValues() {
    let event = DiagnosticEvent(
      subsystem: .systemClipboard,
      level: .warning,
      event: "clipboard.trigger.skipped",
      message: "unsafe",
      metadata: [
        "eventKind": "itemRenamed",
        "outcome": "maybe",
        "reason": "user-controlled-reason",
      ]
    )

    XCTAssertTrue(DiagnosticEventSanitizer.sanitize(event).metadata.isEmpty)
  }

  func testEveryWorkflowSkipCodeIsAClosedDiagnosticReason() {
    for reason in WorkflowRunSkipCode.allCases {
      let event = DiagnosticEvent(
        subsystem: .systemClipboard,
        level: .info,
        event: "clipboard.trigger.skipped",
        message: "safe",
        metadata: ["reason": reason.rawValue]
      )

      XCTAssertEqual(
        DiagnosticEventSanitizer.sanitize(event).metadata,
        ["reason": reason.rawValue],
        "Missing diagnostic reason contract for \(reason.rawValue)."
      )
    }
  }

  func testOpenAIDiagnosticsRetainOnlyClosedOperationalCoordinates() {
    let event = DiagnosticEvent(
      subsystem: .providers,
      level: .error,
      event: "provider.openai.rewrite.failed",
      message: "secret-key transcript-canary provider-body-canary",
      metadata: [
        "provider": "openai.responses",
        "provider.kind": "openai",
        "provider.model": "gpt-5.6-terra",
        "transformerID": "transformer.openai.responses.rewrite",
        "stage": "transforming",
        "outcome": "authentication-failed",
        "durationMillis": "42",
        "httpStatusClass": "4xx",
        "apiKey": "secret-key",
        "input": "transcript-canary",
        "output": "provider-body-canary",
      ]
    )

    let sanitized = DiagnosticEventSanitizer.sanitize(event)

    XCTAssertEqual(sanitized.event, "provider.openai.rewrite.failed")
    XCTAssertEqual(sanitized.message, DiagnosticEventSanitizer.sanitizedMessage)
    XCTAssertEqual(
      sanitized.metadata,
      [
        "provider": "openai.responses",
        "provider.kind": "openai",
        "provider.model": "gpt-5.6-terra",
        "transformerID": "transformer.openai.responses.rewrite",
        "stage": "transforming",
        "outcome": "authentication-failed",
        "durationMillis": "42",
        "httpStatusClass": "4xx",
      ]
    )
    XCTAssertFalse(String(describing: sanitized).contains("secret-key"))
    XCTAssertFalse(String(describing: sanitized).contains("transcript-canary"))
    XCTAssertFalse(String(describing: sanitized).contains("provider-body-canary"))
  }

  func testOpenAILifecycleEventCodesRemainAddressable() {
    for eventCode in [
      "provider.openai.rewrite.started",
      "provider.openai.rewrite.completed",
      "provider.openai.rewrite.failed",
      "provider.openai.verification.completed",
      "provider.openai.verification.failed",
    ] {
      let event = DiagnosticEvent(
        subsystem: .providers,
        level: .info,
        event: eventCode,
        message: "provider lifecycle detail"
      )

      XCTAssertEqual(DiagnosticEventSanitizer.sanitize(event).event, eventCode)
    }
  }

  func testCursorPreviewDiagnosticRetainsOnlyClosedCoordinates() {
    let event = DiagnosticEvent(
      subsystem: .platform,
      level: .warning,
      event: "accessibility.cursor-preview",
      message: "private target detail",
      metadata: [
        "resultCode": "blocked",
        "textLengthBucket": "1-16",
        "reason": "target-content-changed",
        "targetText": "private text",
      ]
    )

    let sanitized = DiagnosticEventSanitizer.sanitize(event)

    XCTAssertEqual(sanitized.event, "accessibility.cursor-preview")
    XCTAssertEqual(
      sanitized.metadata,
      [
        "resultCode": "blocked",
        "textLengthBucket": "1-16",
        "reason": "target-content-changed",
      ]
    )
  }

  func testSherpaRecognitionRecoveryDiagnosticsRetainOnlyClosedCoordinates() {
    for outcome in ["pending", "completed", "failed"] {
      let event = DiagnosticEvent(
        subsystem: .providers,
        level: .warning,
        event: "provider.sherpa-onnx.recognition.retry",
        message: "private worker detail",
        metadata: [
          "provider": "sherpa-onnx.local",
          "provider.kind": "sherpa-onnx",
          "recognizerID": "sherpa-onnx.local",
          "stage": "recognizing",
          "outcome": outcome,
          "failureCode": "recognitionFailed",
          "stderr": "private worker detail",
        ]
      )

      let sanitized = DiagnosticEventSanitizer.sanitize(event)

      XCTAssertEqual(sanitized.event, "provider.sherpa-onnx.recognition.retry")
      XCTAssertEqual(sanitized.message, DiagnosticEventSanitizer.sanitizedMessage)
      XCTAssertEqual(
        sanitized.metadata,
        [
          "provider": "sherpa-onnx.local",
          "provider.kind": "sherpa-onnx",
          "recognizerID": "sherpa-onnx.local",
          "stage": "recognizing",
          "outcome": outcome,
          "failureCode": "recognitionFailed",
        ]
      )
    }
  }
}
