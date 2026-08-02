import Foundation
import RillCore
import RillPlatform
import RillRuntime

/// Owns the process-wide lifecycle of the single shared global-input producer.
///
/// Feature controllers may subscribe to `HotkeyEventTap.stream()` and adjust
/// their own routing policy, but only this owner may install, recover, or
/// uninstall the underlying event tap.
actor GlobalInputOwner {
  private let hotkeyTap: HotkeyEventTap
  private let diagnostics: DiagnosticsRecorder?
  private let installTap: @Sendable () -> Bool
  private let uninstallTap: @Sendable () -> Void
  private let permissionChecker: @Sendable () -> Bool
  private let capabilityObserver: @Sendable (GlobalInputCapability) async -> Void
  private let liveAudioCancellationHandler: @Sendable (UUID) async -> Void

  private var started = false
  private var stopped = false
  private var automaticRecoveryArmed = false
  private var eventTask: Task<Void, Never>?
  private var lastCapability: GlobalInputCapability?

  init(
    hotkeyTap: HotkeyEventTap,
    diagnostics: DiagnosticsRecorder? = nil,
    installTap: (@Sendable () -> Bool)? = nil,
    uninstallTap: (@Sendable () -> Void)? = nil,
    permissionChecker: @escaping @Sendable () -> Bool = {
      PermissionGate.hasGlobalInputAccess()
    },
    capabilityObserver: @escaping @Sendable (GlobalInputCapability) async -> Void = { _ in },
    liveAudioCancellationHandler: @escaping @Sendable (UUID) async -> Void = { _ in }
  ) {
    self.hotkeyTap = hotkeyTap
    self.diagnostics = diagnostics
    self.installTap = installTap ?? { hotkeyTap.install() }
    self.uninstallTap = uninstallTap ?? { hotkeyTap.uninstall() }
    self.permissionChecker = permissionChecker
    self.capabilityObserver = capabilityObserver
    self.liveAudioCancellationHandler = liveAudioCancellationHandler
  }

  func start() async {
    guard !started, !stopped else { return }
    started = true

    // Subscribe before installation. An event tap can synchronously emit
    // its first event while installation is completing.
    let stream = hotkeyTap.stream()
    eventTask = Task {
      for await event in stream {
        guard !Task.isCancelled else { break }
        await self.handle(event)
      }
    }

    automaticRecoveryArmed = true
    await publishCapability(installed: installTap())
  }

  /// Re-evaluates the actual event tap after a permission change or an
  /// explicit user retry. TCC preflight alone is never treated as ready.
  func retryInstallation() async {
    guard started, !stopped else { return }
    automaticRecoveryArmed = true
    await publishCapability(installed: installTap())
  }

  func stop() async {
    guard !stopped else {
      await eventTask?.value
      return
    }
    let wasStarted = started
    stopped = true
    started = false
    automaticRecoveryArmed = false

    let eventTask = eventTask
    self.eventTask = nil
    eventTask?.cancel()
    if wasStarted {
      uninstallTap()
    }
    await eventTask?.value
  }

  private func handle(_ event: HotkeyEventTap.Event) async {
    if case .liveAudioCancellationRequested(let runID) = event {
      await liveAudioCancellationHandler(runID)
      return
    }
    guard case .globalInputUnavailable = event else { return }
    guard started, !stopped else { return }
    guard automaticRecoveryArmed else {
      await publishCapability(installed: false)
      return
    }

    automaticRecoveryArmed = false
    let installed = installTap()
    if installed {
      automaticRecoveryArmed = true
    }
    await publishCapability(installed: installed)
  }

  private func publishCapability(installed: Bool) async {
    let capability: GlobalInputCapability
    if installed {
      capability = .available
    } else if permissionChecker() {
      capability = .installationFailed
    } else {
      capability = .permissionRequired
    }
    guard capability != lastCapability else { return }
    lastCapability = capability
    await capabilityObserver(capability)

    guard let diagnostics else { return }
    await diagnostics.record(
      DiagnosticEvent(
        subsystem: .platform,
        level: installed ? .info : .warning,
        event: installed ? "global-input.installed" : "global-input.unavailable",
        message: installed
          ? "The shared global input tap is available."
          : "The shared global input tap is unavailable.",
        metadata: [
          "pushToTalk": installed ? "active" : "unavailable"
        ]
      )
    )
  }
}
