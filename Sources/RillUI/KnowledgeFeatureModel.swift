import Observation

@MainActor
@Observable
public final class KnowledgeFeatureModel {
  public let vocabulary: VocabularyLibraryModel
  public var contextMemory: ContextMemoryModel?

  init(vocabulary: VocabularyLibraryModel) {
    self.vocabulary = vocabulary
  }
}
