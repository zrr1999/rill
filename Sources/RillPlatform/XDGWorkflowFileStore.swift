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
  public static let currentSchemaVersion = 1
  public static let maximumFileCount = 256
  public static let maximumFileSize = 1_048_576

  public let configurationDirectoryURL: URL

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
  }

  public func load() async -> WorkflowFileLoadResult {
    let fileManager = FileManager.default
    do {
      try prepareConfigurationDirectory(fileManager: fileManager)
    } catch {
      return WorkflowFileLoadResult(
        issues: [
          WorkflowFileIssue(
            filename: configurationDirectoryURL.lastPathComponent,
            message: "The workflow configuration directory could not be prepared."
          )
        ]
      )
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
        let record = try Self.decode(source, fileURL: fileURL)
        records.append(record)
      } catch {
        issues.append(
          WorkflowFileIssue(
            filename: fileURL.lastPathComponent,
            message: Self.safeMessage(for: error)
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
            message: "The workflow ID is also declared by another TOML file."
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
    try Self.validate(workflow)
    let fileManager = FileManager.default
    try prepareConfigurationDirectory(fileManager: fileManager)

    let destinationURL: URL
    if let fileURL {
      destinationURL = try validatedDirectChild(fileURL)
    } else {
      destinationURL = configurationDirectoryURL.appendingPathComponent(
        Self.filename(for: workflow),
        isDirectory: false
      )
    }
    let data = try Self.encode(workflow: workflow, isEnabled: isEnabled)
    try data.write(to: destinationURL, options: [.atomic])
    try fileManager.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: destinationURL.path
    )
    return destinationURL
  }

  public func delete(fileURL: URL) async throws {
    let destinationURL = try validatedDirectChild(fileURL)
    let values = try destinationURL.resourceValues(forKeys: [
      .isRegularFileKey,
      .isSymbolicLinkKey,
    ])
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
      throw WorkflowFileStoreError.unsupportedFile
    }
    try FileManager.default.removeItem(at: destinationURL)
  }

  public static func encode(
    workflow: WorkflowDefinition,
    isEnabled: Bool
  ) throws -> Data {
    try validate(workflow)
    let encoder = TOMLEncoder()
    encoder.outputFormatting = .sortedKeys
    return try encoder.encode(WorkflowTOMLDocument(workflow: workflow, enabled: isEnabled))
  }

  public static func decode(
    _ source: String,
    fileURL: URL = URL(fileURLWithPath: "workflow.toml")
  ) throws -> WorkflowFileRecord {
    guard source.utf8.count <= maximumFileSize else {
      throw WorkflowFileStoreError.fileTooLarge
    }
    let decoder = TOMLDecoder()
    decoder.limits.maxInputSize = maximumFileSize
    decoder.limits.maxDepth = 32
    decoder.limits.maxTableKeys = 1_024
    decoder.limits.maxArrayLength = 1_024
    let document = try decoder.decode(WorkflowTOMLDocument.self, from: source)
    guard document.schemaVersion == currentSchemaVersion else {
      throw WorkflowFileStoreError.unsupportedSchema(document.schemaVersion)
    }
    let workflow = try document.workflow()
    try validate(workflow)
    return WorkflowFileRecord(
      workflow: workflow,
      isEnabled: document.enabled,
      fileURL: fileURL
    )
  }

  private func prepareConfigurationDirectory(fileManager: FileManager) throws {
    var isDirectory: ObjCBool = false
    if fileManager.fileExists(
      atPath: configurationDirectoryURL.path,
      isDirectory: &isDirectory
    ) {
      guard isDirectory.boolValue else {
        throw WorkflowFileStoreError.configurationPathIsNotDirectory
      }
    } else {
      try fileManager.createDirectory(
        at: configurationDirectoryURL,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
    }
    try fileManager.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: configurationDirectoryURL.path
    )
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

  private static func validate(_ workflow: WorkflowDefinition) throws {
    let name = workflow.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name.unicodeScalars.count <= 160 else {
      throw WorkflowFileStoreError.invalidWorkflow("The workflow name is empty or too long.")
    }
    guard workflow.titleKey == nil else {
      throw WorkflowFileStoreError.invalidWorkflow(
        "User workflow files cannot reference built-in localized titles."
      )
    }
    let input: WorkflowPlanInput = workflow.plan.setup.speechRoute == nil ? .text : .audio
    do {
      try WorkflowPlanValidator.validate(workflow.plan, input: input)
    } catch {
      throw WorkflowFileStoreError.invalidWorkflow(error.localizedDescription)
    }
    for action in workflow.plan.output.actions {
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

private enum WorkflowFileStoreError: Error, LocalizedError {
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

private struct WorkflowTOMLDocument: Codable {
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
    schemaVersion = XDGWorkflowFileStore.currentSchemaVersion
    self.enabled = enabled
    id = workflow.id
    name = workflow.name
    trigger = workflow.trigger.tomlValue
    ui = WorkflowTOMLUI(config: workflow.ui)
    setup = WorkflowTOMLSetup(phase: workflow.plan.setup)
    process = workflow.plan.process.steps.map(WorkflowTOMLProcessStep.init)
    output = WorkflowTOMLOutput(phase: workflow.plan.output)
    metadata = workflow.metadata
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
      metadata: metadata
    )
  }
}

private struct WorkflowTOMLUI: Codable {
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

private struct WorkflowTOMLSetup: Codable {
  var speech: WorkflowTOMLSpeechRoute?
  var vocabulary: [WorkflowTOMLVocabularyBinding]
  var wakeWord: WorkflowTOMLWakeWord?

  enum CodingKeys: String, CodingKey {
    case speech
    case vocabulary
    case wakeWord = "wake_word"
  }

  init(phase: WorkflowSetupPhase) {
    speech = phase.speechRoute.map(WorkflowTOMLSpeechRoute.init)
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

private struct WorkflowTOMLSpeechRoute: Codable {
  var selection: String
  var recognizer: String
  var language: String?
  var localModel: String?
  var providerModel: String?

  enum CodingKeys: String, CodingKey {
    case selection
    case recognizer
    case language
    case localModel = "local_model"
    case providerModel = "provider_model"
  }

  init(route: WorkflowSpeechRoute) {
    selection = route.selection.rawValue
    recognizer = route.recognizerID
    language = route.language
    localModel = route.localModel
    providerModel = route.providerModel
  }

  func route() throws -> WorkflowSpeechRoute {
    guard let selection = SpeechRouteSelection(rawValue: selection) else {
      throw WorkflowFileStoreError.invalidWorkflow(
        "Unknown speech selection '\(selection)'."
      )
    }
    return WorkflowSpeechRoute(
      selection: selection,
      recognizerID: recognizer,
      language: language,
      localModel: localModel,
      providerModel: providerModel
    )
  }
}

private struct WorkflowTOMLVocabularyBinding: Codable {
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

private struct WorkflowTOMLBindingCondition: Codable {
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
    clipboardGroup = condition.clipboardGroupID
    locale = condition.locale
  }

  var condition: WorkflowBindingCondition {
    WorkflowBindingCondition(
      bundleIdentifier: appBundleID,
      clipboardGroupID: clipboardGroup,
      locale: locale
    )
  }
}

private struct WorkflowTOMLWakeWord: Codable {
  var phrases: [String]

  init(configuration: WakeWordConfiguration) {
    phrases = configuration.phrases
  }

  var configuration: WakeWordConfiguration {
    WakeWordConfiguration(phrases: phrases)
  }
}

private struct WorkflowTOMLProcessStep: Codable {
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

private struct WorkflowTOMLUncertainty: Codable {
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

private struct WorkflowTOMLOutput: Codable {
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

private struct WorkflowTOMLAction: Codable {
  var id: String
  var config: [String: String]

  init(action: OutputActionReference) {
    id = action.id
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
    OutputActionReference(id: id, configuration: config)
  }
}

private extension TriggerBinding {
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

private extension VocabularyBindingUse {
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

private extension WorkflowProcessStepKind {
  var tomlValue: String {
    switch self {
    case .recognizeSpeech: "recognize-speech"
    case .resolveUncertainty: "resolve-uncertainty"
    case .applyVocabulary: "apply-vocabulary"
    case .snippetReplacement: "snippet-replacement"
    case .llmRewrite: "llm-rewrite"
    case .normalizeWhitespace: "normalize-whitespace"
    }
  }

  init?(tomlValue: String) {
    switch tomlValue {
    case "recognize-speech": self = .recognizeSpeech
    case "resolve-uncertainty": self = .resolveUncertainty
    case "apply-vocabulary": self = .applyVocabulary
    case "snippet-replacement": self = .snippetReplacement
    case "llm-rewrite": self = .llmRewrite
    case "normalize-whitespace": self = .normalizeWhitespace
    default: return nil
    }
  }
}

private extension ResolutionMode {
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

private extension DeliveryStrategy {
  var tomlValue: String {
    switch self {
    case .immediate: "immediate"
    case .stackFirst: "stack-first"
    case .clipboardOnly: "clipboard-only"
    }
  }

  init?(tomlValue: String) {
    switch tomlValue {
    case "immediate": self = .immediate
    case "stack-first": self = .stackFirst
    case "clipboard-only": self = .clipboardOnly
    default: return nil
    }
  }
}
