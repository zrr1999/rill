import RillWorkflows
import Foundation
import RillPlatform

actor CursorTextPreviewLifecycleCoordinator {
  private let eventBus: EventBus
  private let coordinator: CursorTextPreviewCoordinator
  private var eventTask: Task<Void, Never>?

  init(eventBus: EventBus, coordinator: CursorTextPreviewCoordinator) {
    self.eventBus = eventBus
    self.coordinator = coordinator
  }

  func start() async {
    guard eventTask == nil else { return }
    let stream = await eventBus.stream()
    eventTask = Task { [coordinator] in
      for await event in stream {
        guard !Task.isCancelled else { break }
        switch event {
        case .runCompleted(let summary):
          await coordinator.finish(runID: summary.runID)
        case .runCancelled(let summary):
          await coordinator.finish(runID: summary.runID)
        case .runFailed(let runID, _, _):
          if let runID {
            await coordinator.finish(runID: runID)
          }
        default:
          break
        }
      }
    }
  }

  func shutdown() async {
    eventTask?.cancel()
    await eventTask?.value
    eventTask = nil
    await coordinator.shutdown()
  }
}
