import Foundation
import RillCore
import TOML

/// TOML-backed user workflow storage rooted at the XDG configuration directory.
///
/// The default directory is `$XDG_CONFIG_HOME/rill/workflows`, falling back to
/// `$HOME/.config/rill/workflows` exactly as specified by the XDG Base Directory
/// specification. Files are deliberately independent so they remain easy to
/// hand-author, diff, copy and remove with ordinary tools.
public struct XDGWorkflowFileStore: WorkflowFileStore, Sendable {
  public static let currentSchemaVersion = 2
  public static let maximumFileCount = 256
  public static let maximumFileSize = 1_048_576

  public let configurationDirectoryURL: URL
  public let stateDirectoryURL: URL
  private static let writer = WorkflowFileWriter()

  public init() {
    self.init(
      environment: ProcessInfo.processInfo.environment,
      homeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser
    )
  }

  public init(
    environment: [String: String],
    homeDirectoryURL: URL
  ) {
    let stateBase = environment["XDG_STATE_HOME"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil } ?? homeDirectoryURL.appendingPathComponent(".local/state", isDirectory: true)
    stateDirectoryURL = stateBase.appendingPathComponent("rill/workflows", isDirectory: true)
    let baseURL: URL
    if let configuredPath = environment["XDG_CONFIG_HOME"],
      !configuredPath.isEmpty,
      configuredPath.hasPrefix("/")
    {
      baseURL = URL(fileURLWithPath: configuredPath, isDirectory: true)
    } else {
      baseURL = homeDirectoryURL
        .appendingPathComponent(".config", isDirectory: true)
    }
    configurationDirectoryURL = baseURL
      .appendingPathComponent("rill", isDirectory: true)
      .appendingPathComponent("workflows", isDirectory: true)
      .standardizedFileURL
  }

  public init(configurationDirectoryURL: URL) {
    self.configurationDirectoryURL = configurationDirectoryURL.standardizedFileURL
    self.stateDirectoryURL = configurationDirectoryURL.deletingLastPathComponent().appendingPathComponent(".workflow-state", isDirectory: true)
  }

  public func load() async -> WorkflowFileLoadResult {
    let fileManager = FileManager.default
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: configurationDirectoryURL.path, isDirectory: &isDirectory) else {
      return WorkflowFileLoadResult()
    }
    guard isDirectory.boolValue else {
      return WorkflowFileLoadResult(issues: [WorkflowFileIssue(filename: configurationDirectoryURL.lastPathComponent, message: "The workflow configuration path is not a directory.")])
    }

    let entries: [URL]
    do {
      entries = try fileManager.contentsOfDirectory(
        at: configurationDirectoryURL,
        includingPropertiesForKeys: [
          .isRegularFileKey,
          .isSymbolicLinkKey,
          .fileSizeKey,
        ],
        options: [.skipsHiddenFiles]
      )
      .filter { $0.pathExtension.lowercased() == "toml" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
    } catch {
      return WorkflowFileLoadResult(
        issues: [
          WorkflowFileIssue(
            filename: configurationDirectoryURL.lastPathComponent,
            message: "The workflow configuration directory could not be read."
          )
        ]
      )
    }

    var records: [WorkflowFileRecord] = []
    var issues: [WorkflowFileIssue] = []
    let acceptedEntries = entries.prefix(Self.maximumFileCount)
    if entries.count > Self.maximumFileCount {
      issues.append(
        WorkflowFileIssue(
          filename: configurationDirectoryURL.lastPathComponent,
          message: "Only the first \(Self.maximumFileCount) TOML files were loaded."
        )
      )
    }

    for fileURL in acceptedEntries {
      var identifiedID: UUID?
      do {
        let values = try fileURL.resourceValues(forKeys: [
          .isRegularFileKey,
          .isSymbolicLinkKey,
          .fileSizeKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
          throw WorkflowFileStoreError.unsupportedFile
        }
        guard (values.fileSize ?? 0) <= Self.maximumFileSize else {
          throw WorkflowFileStoreError.fileTooLarge
        }
        let source = try String(contentsOf: fileURL, encoding: .utf8)
        identifiedID = Self.identifyWorkflow(source)
        let record = try Self.decode(source, fileURL: fileURL)
        records.append(record)
      } catch {
        issues.append(
          WorkflowFileIssue(
            filename: fileURL.lastPathComponent,
            message: Self.safeMessage(for: error),
            workflowID: identifiedID ?? UUID(uuidString: String(fileURL.deletingPathExtension().lastPathComponent.suffix(36)))
          )
        )
      }
    }

    let duplicatedIDs = Dictionary(grouping: records, by: \.workflow.id)
      .filter { $0.value.count > 1 }
      .keys
    if !duplicatedIDs.isEmpty {
      let duplicatedIDSet = Set(duplicatedIDs)
      for record in records where duplicatedIDSet.contains(record.workflow.id) {
        issues.append(
          WorkflowFileIssue(
            filename: record.fileURL.lastPathComponent,
            message: "The workflow ID is also declared by another TOML file.",
            workflowID: record.workflow.id
          )
        )
      }
      records.removeAll { duplicatedIDSet.contains($0.workflow.id) }
    }

    return WorkflowFileLoadResult(
      discoveredFileCount: entries.count,
      records: records,
      issues: issues
    )
  }

  @discardableResult
  public func save(
    workflow: WorkflowDefinition,
    isEnabled: Bool,
    replacing fileURL: URL?
  ) async throws -> URL {
    try await saveDocument(WorkflowDocument(workflow: workflow, isEnabled: isEnabled), replacing: fileURL, expected: fileURL == nil ? .missing : .overwrite).fileURL
  }

  public func decodeDocument(_ source: String) throws -> WorkflowDocument { try WorkflowDocumentCodec().decode(source) }
  public func encodeDocument(_ document: WorkflowDocument) throws -> String { try WorkflowDocumentCodec().encode(document) }

  public func readSource(at fileURL: URL) async throws -> String {
    let url = try validatedDirectChild(fileURL)
    let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true else { throw WorkflowFileStoreError.unsupportedFile }
    guard values.fileSize ?? 0 <= Self.maximumFileSize else { throw WorkflowFileStoreError.fileTooLarge }
    return try String(contentsOf: url, encoding: .utf8)
  }

  public func saveDocument(_ document: WorkflowDocument, replacing fileURL: URL?, expected: WorkflowFileExpectation) async throws -> WorkflowFileRecord {
    let source = try encodeDocument(document)
    let destination = try fileURL.map(validatedDirectChild) ?? configurationDirectoryURL.appendingPathComponent(Self.filename(for: document.workflow))
    try await Self.writer.save(source: source, to: destination, expected: expected, historyDirectory: stateDirectoryURL.appendingPathComponent(document.workflow.id.uuidString))
    return WorkflowFileRecord(workflow: document.workflow, isEnabled: document.isEnabled, fileURL: destination, source: source)
  }

  public func changes() async -> AsyncStream<Void> {
    await WorkflowDirectoryObserver.changes(in: configurationDirectoryURL)
  }

  public func versions(for workflowID: UUID) async throws -> [WorkflowFileVersion] {
    try await Self.writer.versions(in: stateDirectoryURL.appendingPathComponent(workflowID.uuidString))
  }

  public func delete(fileURL: URL) async throws {
    let source = try await readSource(at: fileURL)
    try await delete(fileURL: fileURL, expected: .source(source))
  }

  public func delete(fileURL: URL, expected: WorkflowFileExpectation) async throws {
    let destination = try validatedDirectChild(fileURL)
    let source = try await readSource(at: destination)
    guard let id = Self.identifyWorkflow(source) else { throw WorkflowFileConflict.changed }
    try await Self.writer.delete(at: destination, expected: expected,
      historyDirectory: stateDirectoryURL.appendingPathComponent(id.uuidString))
  }

  public static func encode(
    workflow: WorkflowDefinition,
    isEnabled: Bool
  ) throws -> Data {
    Data(try WorkflowDocumentCodec().encode(WorkflowDocument(workflow: workflow, isEnabled: isEnabled)).utf8)
  }

  public static func decode(_ source: String, fileURL: URL = URL(fileURLWithPath: "workflow.toml")) throws -> WorkflowFileRecord {
    let document = try WorkflowDocumentCodec().decode(source)
    return WorkflowFileRecord(workflow: document.workflow, isEnabled: document.isEnabled, fileURL: fileURL, source: source)
  }

  private func validatedDirectChild(_ fileURL: URL) throws -> URL {
    let standardized = fileURL.standardizedFileURL
    let actualParent = standardized.deletingLastPathComponent().resolvingSymlinksInPath()
    let actualConfigurationDirectory = configurationDirectoryURL.resolvingSymlinksInPath()
    guard
      actualParent == actualConfigurationDirectory,
      standardized.pathExtension.lowercased() == "toml"
    else {
      throw WorkflowFileStoreError.fileOutsideConfigurationDirectory
    }
    return standardized
  }

  static func validate(_ workflow: WorkflowDefinition) throws {
    let name = workflow.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name.unicodeScalars.count <= 160 else {
      throw WorkflowFileStoreError.invalidWorkflow("The workflow name is empty or too long.")
    }
    guard workflow.titleKey == nil else {
      throw WorkflowFileStoreError.invalidWorkflow(
        "User workflow files cannot reference built-in localized titles."
      )
    }
    let input: WorkflowInputKind = workflow.inputKind
    do {
      try WorkflowPlanValidator.validate(workflow.plan, input: input)
    } catch {
      throw WorkflowFileStoreError.invalidWorkflow(error.localizedDescription)
    }
    for action in workflow.plan.output.actions {
      if action.id == ExternalOutputActionID.shortcutsRun {
        guard let name = action.configuration[ExternalOutputActionConfigurationKey.shortcutName],
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          throw WorkflowDocumentError("output.actions.config.shortcuts.name", "A Shortcut name is required.")
        }
      }
      if action.id == ExternalOutputActionID.markdownAppend {
        guard let path = action.configuration[ExternalOutputActionConfigurationKey.markdownAppendPath], path.hasPrefix("/") else {
          throw WorkflowDocumentError("output.actions.config.markdown.append.path", "An absolute Markdown file path is required.")
        }
      }
      guard action.id != ExternalOutputActionID.webhookPost else {
        throw WorkflowFileStoreError.invalidWorkflow(
          "Plaintext webhook workflows are not accepted."
        )
      }
      guard !action.configuration.keys.contains(
        ExternalOutputActionConfigurationKey.webhookURL
      ), !action.configuration.keys.contains(
        ExternalOutputActionConfigurationKey.webhookHeadersJSON
      ) else {
        throw WorkflowFileStoreError.invalidWorkflow(
          "Plaintext webhook configuration is not accepted."
        )
      }
    }
  }

  private static func identifyWorkflow(_ source: String) -> UUID? {
    // Read only the root header; a malformed later step must not reactivate a built-in override.
    for line in source.split(separator: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("[") { break }
      guard let match = trimmed.range(of: #"^id\s*=\s*["'][0-9A-Fa-f-]{36}["']"#, options: .regularExpression) else { continue }
      let declaration = String(trimmed[match])
      guard let quote = declaration.firstIndex(where: { $0 == "\"" || $0 == "'" }) else { continue }
      return UUID(uuidString: String(declaration[declaration.index(after: quote)...].prefix(36)))
    }
    return nil
  }

  private static func filename(for workflow: WorkflowDefinition) -> String {
    let folded = workflow.name
      .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
      .lowercased()
    let slug = folded.unicodeScalars.reduce(into: "") { result, scalar in
      if CharacterSet.alphanumerics.contains(scalar) {
        result.unicodeScalars.append(scalar)
      } else if !result.hasSuffix("-") {
        result.append("-")
      }
    }
    .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    let prefix = slug.isEmpty ? "workflow" : String(slug.prefix(64))
    return "\(prefix)--\(workflow.id.uuidString.lowercased()).toml"
  }

  private static func safeMessage(for error: Error) -> String {
    switch error {
    case let error as WorkflowFileStoreError:
      return error.localizedDescription
    default:
      return "The TOML document could not be parsed. \(error.localizedDescription)"
    }
  }
}

enum WorkflowFileStoreError: Error, LocalizedError {
  case configurationPathIsNotDirectory
  case fileOutsideConfigurationDirectory
  case unsupportedFile
  case fileTooLarge
  case unsupportedSchema(Int)
  case invalidWorkflow(String)

  var errorDescription: String? {
    switch self {
    case .configurationPathIsNotDirectory:
      "The workflow configuration path is not a directory."
    case .fileOutsideConfigurationDirectory:
      "The workflow file is outside the configured workflow directory."
    case .unsupportedFile:
      "Only regular, non-symbolic-link TOML files are accepted."
    case .fileTooLarge:
      "The TOML file exceeds the 1 MiB size limit."
    case .unsupportedSchema(let version):
      "Unsupported workflow schema version \(version); expected \(XDGWorkflowFileStore.currentSchemaVersion)."
    case .invalidWorkflow(let message):
      "The workflow is invalid: \(message)"
    }
  }
}

struct WorkflowTOMLDocument: Codable {
  var schemaVersion: Int
  var enabled: Bool
  var id: UUID
  var name: String
  var trigger: String
  var ui: WorkflowTOMLUI
  var setup: WorkflowTOMLSetup
  var process: [WorkflowTOMLProcessStep]
  var output: WorkflowTOMLOutput
  var metadata: [String: String]

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case enabled
    case id
    case name
    case trigger
    case ui
    case setup
    case process
    case output
    case metadata
  }

  init(workflow: WorkflowDefinition, enabled: Bool) {
    schemaVersion = 1
    self.enabled = enabled
    id = workflow.id
    name = workflow.name
    trigger = workflow.trigger.tomlValue
    ui = WorkflowTOMLUI(config: workflow.ui)
    setup = WorkflowTOMLSetup(
      phase: workflow.plan.setup,
      metadata: workflow.metadata
    )
    process = workflow.plan.process.steps.map(WorkflowTOMLProcessStep.init)
    output = WorkflowTOMLOutput(phase: workflow.plan.output)
    metadata = Self.canonicalMetadata(workflow.metadata)
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    id = try container.decode(UUID.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    trigger = try container.decode(String.self, forKey: .trigger)
    ui = try container.decode(WorkflowTOMLUI.self, forKey: .ui)
    setup = try container.decode(WorkflowTOMLSetup.self, forKey: .setup)
    process = try container.decode([WorkflowTOMLProcessStep].self, forKey: .process)
    output = try container.decode(WorkflowTOMLOutput.self, forKey: .output)
    metadata = try container.decodeIfPresent(
      [String: String].self,
      forKey: .metadata
    ) ?? [:]
  }

  func workflow() throws -> WorkflowDefinition {
    guard let trigger = TriggerBinding(tomlValue: trigger) else {
      throw WorkflowFileStoreError.invalidWorkflow("Unknown trigger '\(trigger)'.")
    }
    var normalizedMetadata = metadata
    normalizedMetadata = Self.canonicalMetadata(normalizedMetadata)
    try setup.speech?.applyMetadata(to: &normalizedMetadata)
    return try WorkflowDefinition(
      id: id,
      name: name,
      titleKey: nil,
      trigger: trigger,
      plan: WorkflowPlan(
        setup: setup.phase(),
        process: WorkflowProcessPhase(steps: try process.map { try $0.step() }),
        output: try output.phase()
      ),
      ui: ui.config,
      metadata: normalizedMetadata
    )
  }

  private static func canonicalMetadata(_ metadata: [String: String]) -> [String: String] {
    var metadata = metadata
    if metadata[WorkflowMetadataKey.targetRecordCollectionIDs] == nil,
      let legacyID = metadata[WorkflowMetadataKey.legacyTargetRecordCollectionID]
    {
      metadata[WorkflowMetadataKey.targetRecordCollectionIDs] = legacyID
    }
    if metadata[WorkflowMetadataKey.excludeOutputFromRecordCapture] == nil,
      let legacyValue = metadata[WorkflowMetadataKey.excludeOutputFromWorkflowCapture]
    {
      metadata[WorkflowMetadataKey.excludeOutputFromRecordCapture] = legacyValue
    }
    metadata.removeValue(forKey: WorkflowMetadataKey.legacyTargetRecordCollectionID)
    metadata.removeValue(forKey: WorkflowMetadataKey.excludeOutputFromWorkflowCapture)
    return metadata
  }
}

struct WorkflowTOMLUI: Codable {
  var symbol: String
  var accent: String

  init(config: WorkflowUIConfig) {
    symbol = config.symbolName
    accent = config.accentColorName
  }

  var config: WorkflowUIConfig {
    WorkflowUIConfig(symbolName: symbol, accentColorName: accent)
  }
}

struct WorkflowTOMLSetup: Codable {
  var speech: WorkflowTOMLSpeechRoute?
  var vocabulary: [WorkflowTOMLVocabularyBinding]
  var wakeWord: WorkflowTOMLWakeWord?

  enum CodingKeys: String, CodingKey {
    case speech
    case vocabulary
    case wakeWord = "wake_word"
  }

  init(phase: WorkflowSetupPhase, metadata: [String: String]) {
    speech = phase.speechRoute.map(WorkflowTOMLSpeechRoute.init)
    speech?.livePreview = metadata[WorkflowMetadataKey.livePreviewEnabled].flatMap {
      switch $0.lowercased() {
      case "true", "yes", "1", "on": true
      case "false", "no", "0", "off": false
      default: nil
      }
    }
    speech?.streamingProfile = metadata[WorkflowMetadataKey.streamingProfile]
    speech?.livePreviewPlacement =
      metadata[WorkflowMetadataKey.livePreviewPlacement]
    vocabulary = phase.vocabularyBindings.map(WorkflowTOMLVocabularyBinding.init)
    wakeWord = phase.wakeWord.map(WorkflowTOMLWakeWord.init)
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    speech = try container.decodeIfPresent(
      WorkflowTOMLSpeechRoute.self,
      forKey: .speech
    )
    vocabulary = try container.decodeIfPresent(
      [WorkflowTOMLVocabularyBinding].self,
      forKey: .vocabulary
    ) ?? []
    wakeWord = try container.decodeIfPresent(
      WorkflowTOMLWakeWord.self,
      forKey: .wakeWord
    )
  }

  func phase() throws -> WorkflowSetupPhase {
    WorkflowSetupPhase(
      speechRoute: try speech?.route(),
      vocabularyBindings: try vocabulary.map { try $0.binding() },
      wakeWord: wakeWord?.configuration
    )
  }
}

struct WorkflowTOMLSpeechRoute: Codable {
  var selection: String
  var recognizer: String
  var language: String?
  var localModel: String?
  var providerModel: String?
  var livePreview: Bool?
  var livePreviewPlacement: String?
  var streamingProfile: String?

  enum CodingKeys: String, CodingKey {
    case selection
    case recognizer
    case language
    case localModel = "local_model"
    case providerModel = "provider_model"
    case livePreview = "live_preview"
    case livePreviewPlacement = "live_preview_placement"
    case streamingProfile = "streaming_profile"
  }

  init(route: WorkflowSpeechRoute) {
    selection = route.selection.rawValue
    recognizer = route.recognizerID
    language = route.language
    localModel = route.localModel
    providerModel = route.providerModel
    livePreview = nil
    livePreviewPlacement = nil
    streamingProfile = nil
  }

  func route() throws -> WorkflowSpeechRoute {
    guard let selection = SpeechRouteSelection(rawValue: selection) else {
      throw WorkflowFileStoreError.invalidWorkflow(
        "Unknown speech selection '\(selection)'."
      )
    }
    let normalizedRecognizer: String
    switch recognizer.lowercased() {
    case "auto", "sherpa-onnx.local", "sherpa-onnx.streaming":
      normalizedRecognizer = "local-speech"
    default:
      normalizedRecognizer = recognizer
    }
    return WorkflowSpeechRoute(
      selection: selection,
      recognizerID: normalizedRecognizer,
      language: language,
      localModel: localModel.map { modelID in
        switch modelID.lowercased() {
        case "auto", "sherpa-onnx-qwen3-asr-0.6b-int8-2026-03-25":
          "qwen3-asr-0.6b-mlx-8bit"
        default:
          modelID
        }
      },
      providerModel: providerModel
    )
  }

  func applyMetadata(to metadata: inout [String: String]) throws {
    if let livePreview {
      metadata[WorkflowMetadataKey.livePreviewEnabled] = livePreview ? "true" : "false"
    }
    if let livePreviewPlacement {
      guard LivePreviewPlacement(rawValue: livePreviewPlacement) != nil else {
        throw WorkflowFileStoreError.invalidWorkflow(
          "Unknown live preview placement '\(livePreviewPlacement)'."
        )
      }
      metadata[WorkflowMetadataKey.livePreviewPlacement] = livePreviewPlacement
    }
    if let streamingProfile {
      metadata[WorkflowMetadataKey.streamingProfile] = streamingProfile
    }
  }
}

struct WorkflowTOMLVocabularyBinding: Codable {
  var id: UUID
  var collection: UUID
  var uses: [String]
  var when: WorkflowTOMLBindingCondition?

  init(binding: VocabularyCollectionBinding) {
    id = binding.id
    collection = binding.collectionID
    uses = binding.uses.map(\.tomlValue).sorted()
    when = binding.condition == .any
      ? nil
      : WorkflowTOMLBindingCondition(condition: binding.condition)
  }

  func binding() throws -> VocabularyCollectionBinding {
    let parsedUses = try uses.map { value -> VocabularyBindingUse in
      guard let use = VocabularyBindingUse(tomlValue: value) else {
        throw WorkflowFileStoreError.invalidWorkflow(
          "Unknown vocabulary use '\(value)'."
        )
      }
      return use
    }
    return VocabularyCollectionBinding(
      id: id,
      collectionID: collection,
      uses: Set(parsedUses),
      condition: when?.condition ?? .any
    )
  }
}

struct WorkflowTOMLBindingCondition: Codable {
  var appBundleID: String?
  var clipboardGroup: UUID?
  var locale: String?

  enum CodingKeys: String, CodingKey {
    case appBundleID = "app_bundle_id"
    case clipboardGroup = "clipboard_group"
    case locale
  }

  init(condition: WorkflowBindingCondition) {
    appBundleID = condition.bundleIdentifier
    clipboardGroup = condition.recordCollectionID
    locale = condition.locale
  }

  var condition: WorkflowBindingCondition {
    WorkflowBindingCondition(
      bundleIdentifier: appBundleID,
      recordCollectionID: clipboardGroup,
      locale: locale
    )
  }
}

struct WorkflowTOMLWakeWord: Codable {
  var phrases: [String]

  init(configuration: WakeWordConfiguration) {
    phrases = configuration.phrases
  }

  var configuration: WakeWordConfiguration {
    WakeWordConfiguration(phrases: phrases)
  }
}

struct WorkflowTOMLProcessStep: Codable {
  var id: UUID
  var kind: String
  var prompt: String?
  var uncertainty: WorkflowTOMLUncertainty?

  init(step: WorkflowProcessStep) {
    id = step.id
    kind = step.kind.tomlValue
    prompt = step.prompt
    uncertainty = step.uncertaintyPolicy.map(WorkflowTOMLUncertainty.init)
  }

  func step() throws -> WorkflowProcessStep {
    guard let kind = WorkflowProcessStepKind(tomlValue: kind) else {
      throw WorkflowFileStoreError.invalidWorkflow(
        "Unknown process step '\(kind)'."
      )
    }
    return try WorkflowProcessStep(
      id: id,
      kind: kind,
      prompt: prompt,
      uncertaintyPolicy: uncertainty?.policy()
    )
  }
}

struct WorkflowTOMLUncertainty: Codable {
  var mode: String
  var confidenceThreshold: Double
  var timeoutSeconds: Double

  enum CodingKeys: String, CodingKey {
    case mode
    case confidenceThreshold = "confidence_threshold"
    case timeoutSeconds = "timeout_seconds"
  }

  init(policy: UncertaintyPolicy) {
    mode = policy.mode.tomlValue
    confidenceThreshold = policy.confidenceThreshold
    timeoutSeconds = policy.timeoutSeconds
  }

  func policy() throws -> UncertaintyPolicy {
    guard let mode = ResolutionMode(tomlValue: mode) else {
      throw WorkflowFileStoreError.invalidWorkflow(
        "Unknown uncertainty mode '\(mode)'."
      )
    }
    return UncertaintyPolicy(
      mode: mode,
      confidenceThreshold: confidenceThreshold,
      timeoutSeconds: timeoutSeconds
    )
  }
}

struct WorkflowTOMLOutput: Codable {
  var strategy: String
  var actions: [WorkflowTOMLAction]

  init(phase: WorkflowOutputPhase) {
    strategy = phase.deliveryPolicy.strategy.tomlValue
    actions = phase.actions.map(WorkflowTOMLAction.init)
  }

  func phase() throws -> WorkflowOutputPhase {
    guard let strategy = DeliveryStrategy(tomlValue: strategy) else {
      throw WorkflowFileStoreError.invalidWorkflow(
        "Unknown delivery strategy '\(strategy)'."
      )
    }
    return WorkflowOutputPhase(
      actions: actions.map(\.action),
      deliveryPolicy: DeliveryPolicy(strategy: strategy)
    )
  }
}

struct WorkflowTOMLAction: Codable {
  var id: String
  var config: [String: String]

  init(action: OutputActionReference) {
    id = Self.canonicalActionID(action.id)
    config = action.configuration
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    config = try container.decodeIfPresent(
      [String: String].self,
      forKey: .config
    ) ?? [:]
  }

  var action: OutputActionReference {
    OutputActionReference(id: Self.canonicalActionID(id), configuration: config)
  }

  private static func canonicalActionID(_ id: String) -> String {
    switch id {
    case "stack.push": "record.store"
    case "clipboard.copy": "system-clipboard.copy"
    case "inject.text": "focused-application.insert"
    default: id
    }
  }
}

extension TriggerBinding {
  var tomlValue: String {
    switch self {
    case .manual: "manual"
    case .hotkey: "hotkey"
    case .menuBar: "menu-bar"
    case .wakeWord: "wake-word"
    }
  }

  init?(tomlValue: String) {
    switch tomlValue {
    case "manual": self = .manual
    case "hotkey": self = .hotkey
    case "menu-bar": self = .menuBar
    case "wake-word": self = .wakeWord
    default: return nil
    }
  }
}

extension VocabularyBindingUse {
  var tomlValue: String {
    switch self {
    case .recognitionHints: "recognition-hints"
    case .textReplacement: "text-replacement"
    }
  }

  init?(tomlValue: String) {
    switch tomlValue {
    case "recognition-hints": self = .recognitionHints
    case "text-replacement": self = .textReplacement
    default: return nil
    }
  }
}

extension WorkflowProcessStepKind {
  var tomlValue: String {
    switch self {
    case .recognizeSpeech: "recognize-speech"
    case .resolveUncertainty: "resolve-uncertainty"
    case .applyVocabulary: "apply-vocabulary"
    case .snippetReplacement: "snippet-replacement"
    case .llmRewrite: "llm-rewrite"
    case .llmAnswer: "llm-answer"
    case .normalizeWhitespace: "normalize-whitespace"
    case .conditional: "if"
    }
  }

  init?(tomlValue: String) {
    switch tomlValue {
    case "recognize-speech": self = .recognizeSpeech
    case "resolve-uncertainty": self = .resolveUncertainty
    case "apply-vocabulary": self = .applyVocabulary
    case "snippet-replacement": self = .snippetReplacement
    case "llm-rewrite": self = .llmRewrite
    case "llm-answer": self = .llmAnswer
    case "normalize-whitespace": self = .normalizeWhitespace
    case "if": self = .conditional
    default: return nil
    }
  }
}

extension ResolutionMode {
  var tomlValue: String {
    switch self {
    case .off: "off"
    case .nonBlocking: "non-blocking"
    case .blocking: "blocking"
    }
  }

  init?(tomlValue: String) {
    switch tomlValue {
    case "off": self = .off
    case "non-blocking": self = .nonBlocking
    case "blocking": self = .blocking
    default: return nil
    }
  }
}

extension DeliveryStrategy {
  var tomlValue: String {
    switch self {
    case .immediate: "immediate"
    case .collectionFirst: "collection-first"
    case .systemClipboardOnly: "system-clipboard-only"
    }
  }

  init?(tomlValue: String) {
    switch tomlValue {
    case "immediate": self = .immediate
    case "stack-first", "collection-first": self = .collectionFirst
    case "clipboard-only", "system-clipboard-only": self = .systemClipboardOnly
    default: return nil
    }
  }
}
