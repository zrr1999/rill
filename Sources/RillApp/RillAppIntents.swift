import AppIntents
import Foundation
import RillCore
import RillUI
import RillWorkflows

@MainActor
enum RillIntentBridge {
  static var model: AppModel?
  static var recording: RecordingSessionManager?

  static func install(model: AppModel, recording: RecordingSessionManager) {
    self.model = model
    self.recording = recording
  }
}

enum RillIntentText {
  static func lastTranscription(in text: String?) -> String? {
    let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }
}

struct RillIntentFailure: Error, CustomLocalizedStringResourceConvertible {
  var localizedStringResource: LocalizedStringResource
}

struct ToggleVoiceInputIntent: AppIntent {
  static let title: LocalizedStringResource = "intent.toggleVoiceInput.title"
  static let description = IntentDescription("intent.toggleVoiceInput.description")
  static let openAppWhenRun = false

  func perform() async throws -> some IntentResult {
    guard let recording = await MainActor.run(body: { RillIntentBridge.recording }) else {
      throw RillIntentFailure(localizedStringResource: "intent.error.unavailable")
    }
    guard await recording.toggleLongRecording() else {
      throw RillIntentFailure(localizedStringResource: "intent.error.voiceInputNotAccepted")
    }
    return .result()
  }
}

struct CopyLastTranscriptionIntent: AppIntent {
  static let title: LocalizedStringResource = "intent.copyLastTranscription.title"
  static let description = IntentDescription("intent.copyLastTranscription.description")
  static let openAppWhenRun = false

  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    let text = try await MainActor.run { () throws -> String in
      guard let model = RillIntentBridge.model else {
        throw RillIntentFailure(localizedStringResource: "intent.error.unavailable")
      }
      guard let text = RillIntentText.lastTranscription(in: model.voice.lastCompletedText) else {
        throw RillIntentFailure(localizedStringResource: "intent.error.noTranscription")
      }
      model.copyTextToClipboard(text)
      return text
    }
    return .result(value: text)
  }
}

struct RillWorkflowEntity: AppEntity {
  static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "intent.workflow.type")
  static let defaultQuery = RillWorkflowQuery()

  var id: UUID
  var name: String

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: "\(name)")
  }
}

struct RillWorkflowQuery: EntityQuery {
  func entities(for identifiers: [RillWorkflowEntity.ID]) async throws -> [RillWorkflowEntity] {
    try await workflows().filter { identifiers.contains($0.id) }
  }

  func suggestedEntities() async throws -> [RillWorkflowEntity] {
    try await workflows()
  }

  private func workflows() async throws -> [RillWorkflowEntity] {
    await MainActor.run {
      guard let model = RillIntentBridge.model else { return [] }
      return model.enabledWorkflows(for: .manual).map { workflow in
        RillWorkflowEntity(
          id: workflow.id,
          name: L10n.workflowName(
            WorkflowPresentation(fallbackName: workflow.name, titleKey: workflow.titleKey),
            language: model.settings.language
          )
        )
      }
    }
  }
}

struct RunWorkflowIntent: AppIntent {
  static let title: LocalizedStringResource = "intent.runWorkflow.title"
  static let description = IntentDescription("intent.runWorkflow.description")
  static let openAppWhenRun = false

  @Parameter(title: "intent.runWorkflow.parameter")
  var workflow: RillWorkflowEntity

  func perform() async throws -> some IntentResult {
    let definitionID = workflow.id
    try await MainActor.run {
      guard let model = RillIntentBridge.model else {
        throw RillIntentFailure(localizedStringResource: "intent.error.unavailable")
      }
      guard let definition = model.enabledWorkflows(for: .manual).first(where: { $0.id == definitionID })
      else {
        throw RillIntentFailure(localizedStringResource: "intent.error.workflowUnavailable")
      }
      guard model.runWorkflow(definition) else {
        throw RillIntentFailure(localizedStringResource: "intent.error.workflowNotStarted")
      }
    }
    return .result()
  }
}

struct RillAppShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: ToggleVoiceInputIntent(),
      phrases: [
        "Start voice input in \(.applicationName)",
        "Stop voice input in \(.applicationName)",
        "用 \(.applicationName) 开始语音输入",
        "用 \(.applicationName) 停止语音输入",
      ],
      shortTitle: "intent.toggleVoiceInput.shortTitle",
      systemImageName: "mic"
    )
    AppShortcut(
      intent: CopyLastTranscriptionIntent(),
      phrases: [
        "Copy the last transcription in \(.applicationName)",
        "复制 \(.applicationName) 的上次转写",
      ],
      shortTitle: "intent.copyLastTranscription.shortTitle",
      systemImageName: "doc.on.clipboard"
    )
    AppShortcut(
      intent: RunWorkflowIntent(),
      phrases: [
        "Run \(\.$workflow) in \(.applicationName)",
        "用 \(.applicationName) 运行 \(\.$workflow)",
      ],
      shortTitle: "intent.runWorkflow.shortTitle",
      systemImageName: "play"
    )
  }
}
