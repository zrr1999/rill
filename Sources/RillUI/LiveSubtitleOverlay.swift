import AppKit
import RillCore
import SwiftUI

public enum LiveSubtitleOverlayMetrics {
  public static let minimumSurfaceWidth: CGFloat = 184
  public static let maximumSurfaceWidth: CGFloat = 360
  public static let minimumSurfaceHeight: CGFloat = 48
  public static let compactSurfaceWidth: CGFloat = 184
  public static let compactSurfaceHeight: CGFloat = 48
  public static let expandedSurfaceWidth: CGFloat = 360
  public static let expandedSurfaceHeight: CGFloat = 96
  // Compatibility aliases for callers that still describe the text layout as standard.
  public static let standardSurfaceWidth = expandedSurfaceWidth
  public static let standardSurfaceHeight = expandedSurfaceHeight
  public static let compactCornerRadius: CGFloat = 24
  public static let standardCornerRadius: CGFloat = 20
  public static let shadowRadius: CGFloat = 12
  public static let shadowOffsetY: CGFloat = 4
  public static let shadowInsets = EdgeInsets(top: 16, leading: 16, bottom: 20, trailing: 16)
}

public struct LiveSubtitleOverlay: View {
  @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast

  public let snapshot: LiveSubtitleSnapshot
  public let language: AppLanguage
  private let includesShadow: Bool

  public init(
    snapshot: LiveSubtitleSnapshot,
    language: AppLanguage,
    includesShadow: Bool = true
  ) {
    self.snapshot = snapshot
    self.language = language
    self.includesShadow = includesShadow
  }

  public var body: some View {
    Group {
      if includesShadow {
        surface
          .compositingGroup()
          .shadow(
            color: shadowColor,
            radius: LiveSubtitleOverlayMetrics.shadowRadius,
            y: LiveSubtitleOverlayMetrics.shadowOffsetY
          )
          .padding(LiveSubtitleOverlayMetrics.shadowInsets)
      } else {
        surface
      }
    }
    .animation(
      accessibilityReduceMotion ? nil : .easeInOut(duration: 0.16),
      value: LiveSubtitlePresentationPolicy.usesExpandedLayout(snapshot)
    )
    .accessibilityElement(children: .contain)
  }

  private var surface: some View {
    Group {
      if LiveSubtitlePresentationPolicy.usesExpandedLayout(snapshot) {
        expandedBody
      } else {
        compactBody
      }
    }
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .strokeBorder(borderColor, lineWidth: 0.75)
    )
  }

  private var compactBody: some View {
    HStack(spacing: 8) {
      waveform
      Spacer(minLength: 2)
      recordingTimer
      controlButton
    }
    .padding(.horizontal, 12)
    .frame(
      width: LiveSubtitleOverlayMetrics.compactSurfaceWidth,
      height: LiveSubtitleOverlayMetrics.compactSurfaceHeight
    )
  }

  private var expandedBody: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        waveform
        Spacer(minLength: 2)
        recordingTimer
        controlButton
      }

      liveText
        .font(.callout.weight(.medium))
        .lineLimit(LiveSubtitlePresentationPolicy.standardLiveTextLineLimit)
        .truncationMode(
          LiveSubtitlePresentationPolicy.standardLiveTextPreservesLatestContent ? .head : .tail
        )
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .frame(
      width: LiveSubtitleOverlayMetrics.expandedSurfaceWidth,
      height: LiveSubtitleOverlayMetrics.expandedSurfaceHeight,
      alignment: .topLeading
    )
  }

  private var waveform: some View {
    VoiceActivityIndicator(
      levelMeter: snapshot.levelMeter,
      isActive: isAudioCaptureActive,
      accentColor: meterColor,
      barCount: 12,
      barWidth: 2,
      minHeight: 3,
      maxHeight: 20
    )
  }

  private var liveText: Text {
    let confirmed = snapshot.confirmedText.trimmingCharacters(in: .whitespacesAndNewlines)
    let hypothesis = snapshot.hypothesisText.trimmingCharacters(in: .whitespacesAndNewlines)
    if confirmed.isEmpty {
      return Text(hypothesis).foregroundStyle(primaryTextColor)
    }
    if hypothesis.isEmpty {
      return Text(confirmed).foregroundStyle(primaryTextColor)
    }
    return Text(confirmed).foregroundStyle(primaryTextColor)
      + Text(" ").foregroundStyle(primaryTextColor)
      + Text(hypothesis).foregroundStyle(secondaryTextColor)
  }

  @ViewBuilder
  private var recordingTimer: some View {
    if isAudioCaptureActive {
      TimelineView(.periodic(from: .now, by: 1)) { context in
        let state = LiveSubtitlePresentationPolicy.recordingTimerState(
          for: snapshot,
          now: context.date
        )
        HStack(spacing: 5) {
          Text(recordingTimerTitle(state))
            .font(.caption.monospacedDigit().weight(.semibold))
            .foregroundStyle(timerColor(state))
            .accessibilityLabel(Text(recordingTimerAccessibilityLabel(state)))

          if let state,
            state.isNearLimit,
            snapshot.canRemoveRecordingDurationLimit == true
          {
            Button(action: requestUnlimitedRecording) {
              Image(systemName: "infinity")
                .font(.system(size: 10, weight: .bold))
                .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .foregroundStyle(timerColor(state))
            .background(timerColor(state).opacity(0.1), in: Circle())
            .help(
              language == .english
                ? "Continue without the automatic recording limit"
                : "继续录音并解除自动时限"
            )
            .accessibilityLabel(
              Text(language == .english ? "Continue with no time limit" : "继续且不限时")
            )
          }
        }
      }
    }
  }

  private func recordingTimerTitle(
    _ state: LiveSubtitlePresentationPolicy.RecordingTimerState?
  ) -> String {
    guard let state else { return "0:00" }
    if state.isNearLimit, let remainingSeconds = state.remainingSeconds {
      return "−\(LiveSubtitlePresentationPolicy.formattedDuration(remainingSeconds))"
    }
    return LiveSubtitlePresentationPolicy.formattedDuration(state.elapsedSeconds)
  }

  private func recordingTimerAccessibilityLabel(
    _ state: LiveSubtitlePresentationPolicy.RecordingTimerState?
  ) -> String {
    guard let state else {
      return language == .english ? "Recording just started." : "录音刚刚开始。"
    }
    if state.isNearLimit, let remainingSeconds = state.remainingSeconds {
      let remaining = LiveSubtitlePresentationPolicy.formattedDuration(remainingSeconds)
      return language == .english ? "\(remaining) remaining." : "剩余 \(remaining)。"
    }
    let elapsed = LiveSubtitlePresentationPolicy.formattedDuration(state.elapsedSeconds)
    return language == .english ? "Recorded \(elapsed)." : "已录制 \(elapsed)。"
  }

  private func timerColor(
    _ state: LiveSubtitlePresentationPolicy.RecordingTimerState?
  ) -> Color {
    switch state?.warningLevel ?? .normal {
    case .normal:
      secondaryTextColor
    case .warning:
      .orange
    case .critical:
      .red
    }
  }

  private var controlButton: some View {
    let cancelsCapture = LiveSubtitleInteractionPolicy.showsStopControl(for: snapshot.phase)
    let title = cancelsCapture
      ? (language == .english ? "Cancel and discard" : "取消并丢弃")
      : UIStrings.text(.liveSubtitleClose, language: language)
    return Button(action: requestControlAction) {
      Image(systemName: "xmark")
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(secondaryTextColor)
        .frame(width: 22, height: 22)
        .contentShape(Circle())
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5), in: Circle())
        .overlay(Circle().strokeBorder(borderColor.opacity(0.65), lineWidth: 0.75))
    }
    .buttonStyle(.plain)
    .help(title)
    .accessibilityLabel(Text(title))
  }

  private func requestControlAction() {
    NotificationCenter.default.post(
      name: LiveSubtitleInteractionPolicy.showsStopControl(for: snapshot.phase)
        ? Self.stopRequestedNotification
        : Self.closeRequestedNotification,
      object: snapshot.runID
    )
  }

  private func requestUnlimitedRecording() {
    NotificationCenter.default.post(
      name: Self.removeDurationLimitRequestedNotification,
      object: snapshot.runID
    )
  }

  private var isAudioCaptureActive: Bool {
    LiveSubtitlePresentationPolicy.isAudioCaptureActive(phase: snapshot.phase)
  }

  private var meterColor: Color {
    snapshot.phase == .failed ? .red : Color(nsColor: .labelColor)
  }

  private var primaryTextColor: Color { Color(nsColor: .labelColor) }
  private var secondaryTextColor: Color { Color(nsColor: .secondaryLabelColor) }
  private var borderColor: Color {
    Color(nsColor: .separatorColor).opacity(colorSchemeContrast == .increased ? 0.9 : 0.55)
  }
  private var shadowColor: Color {
    .black.opacity(colorSchemeContrast == .increased ? 0.2 : 0.13)
  }
  private var cornerRadius: CGFloat {
    LiveSubtitlePresentationPolicy.usesExpandedLayout(snapshot)
      ? LiveSubtitleOverlayMetrics.standardCornerRadius
      : LiveSubtitleOverlayMetrics.compactCornerRadius
  }

  private static let closeRequestedNotification = Notification.Name(
    "works.earendil.rill.live-subtitle.close-requested"
  )
  private static let stopRequestedNotification = Notification.Name(
    "works.earendil.rill.live-subtitle.stop-requested"
  )
  private static let removeDurationLimitRequestedNotification = Notification.Name(
    "works.earendil.rill.live-subtitle.remove-duration-limit-requested"
  )
}

enum LiveSubtitleInteractionPolicy {
  static func showsStopControl(for phase: LiveSubtitlePhase) -> Bool {
    LiveSubtitlePresentationPolicy.isAudioCaptureActive(phase: phase)
  }

  static func isCloudProvider(_ providerID: String?) -> Bool { false }

  static func providerDisclosureTitle(
    providerID: String?,
    language: AppLanguage
  ) -> String? {
    guard let providerID else { return nil }
    if providerID.lowercased() == "local-speech"
      || providerID.lowercased().hasPrefix("local-speech.")
      || providerID.lowercased().hasPrefix("sherpa-onnx.")
    {
      return language == .english ? "On-device" : "本机处理"
    }
    return nil
  }
}

enum LiveSubtitlePresentationPolicy {
  enum RecordingTimerWarningLevel: Equatable {
    case normal
    case warning
    case critical
  }

  struct RecordingTimerState: Equatable {
    let elapsedSeconds: Int
    let maximumSeconds: Int?
    let remainingSeconds: Int?
    let warningLevel: RecordingTimerWarningLevel
    let isUnlimited: Bool

    var isNearLimit: Bool { warningLevel != .normal }
  }

  enum ProviderDisclosureStyle: Equatable {
    case tinted
    case highContrast
  }

  static let standardLiveTextLineLimit = 2
  static let standardLiveTextPreservesLatestContent = true

  static func usesExpandedLayout(_ snapshot: LiveSubtitleSnapshot) -> Bool {
    snapshot.livePreviewPlacement == .overlay
      && isAudioCaptureActive(phase: snapshot.phase)
      && !snapshot.displayText.isEmpty
  }

  static func recordingTimerState(
    for snapshot: LiveSubtitleSnapshot,
    now: Date
  ) -> RecordingTimerState? {
    guard let startedAt = snapshot.recordingStartedAt else { return nil }
    let rawElapsed = now.timeIntervalSince(startedAt)
    guard rawElapsed.isFinite, rawElapsed <= Double(Int.max) else { return nil }
    let unboundedElapsedSeconds = max(0, Int(floor(rawElapsed)))
    guard let maximumDurationSeconds = snapshot.maximumRecordingDurationSeconds else {
      guard snapshot.recordingDurationIsUnlimited == true else {
        return RecordingTimerState(
          elapsedSeconds: unboundedElapsedSeconds,
          maximumSeconds: nil,
          remainingSeconds: nil,
          warningLevel: .normal,
          isUnlimited: false
        )
      }
      return RecordingTimerState(
        elapsedSeconds: unboundedElapsedSeconds,
        maximumSeconds: nil,
        remainingSeconds: nil,
        warningLevel: .normal,
        isUnlimited: true
      )
    }
    guard maximumDurationSeconds.isFinite,
      maximumDurationSeconds > 0,
      maximumDurationSeconds <= Double(Int.max)
    else { return nil }

    let maximumSeconds = max(1, Int(ceil(maximumDurationSeconds)))
    let elapsedSeconds = min(maximumSeconds, unboundedElapsedSeconds)
    let remainingSeconds = maximumSeconds - elapsedSeconds
    let warningWindowSeconds = min(30, max(10, Int(ceil(maximumDurationSeconds * 0.1))))
    let warningLevel: RecordingTimerWarningLevel
    if remainingSeconds <= 5 {
      warningLevel = .critical
    } else if remainingSeconds <= warningWindowSeconds {
      warningLevel = .warning
    } else {
      warningLevel = .normal
    }
    return RecordingTimerState(
      elapsedSeconds: elapsedSeconds,
      maximumSeconds: maximumSeconds,
      remainingSeconds: remainingSeconds,
      warningLevel: warningLevel,
      isUnlimited: false
    )
  }

  static func formattedDuration(_ totalSeconds: Int) -> String {
    let clampedSeconds = max(0, totalSeconds)
    let hours = clampedSeconds / 3_600
    let minutes = (clampedSeconds % 3_600) / 60
    let seconds = clampedSeconds % 60
    if hours > 0 {
      return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }
    return String(format: "%d:%02d", minutes, seconds)
  }

  static func isAudioCaptureActive(phase: LiveSubtitlePhase) -> Bool {
    switch phase {
    case .preparing, .recording, .listening, .transcribing:
      true
    case .hidden, .finalizing, .processing, .failed:
      false
    }
  }

  static func statusSymbol(for phase: LiveSubtitlePhase) -> RillSystemSymbol {
    switch phase {
    case .preparing, .recording, .listening, .transcribing: .waveform
    case .finalizing: .forwardEnd
    case .processing: .textAlignLeft
    case .failed: .exclamationmarkCircleFill
    case .hidden: .circle
    }
  }

  static func providerDisclosureStyle(
    providerID: String?,
    increasedContrast: Bool
  ) -> ProviderDisclosureStyle {
    increasedContrast && LiveSubtitleInteractionPolicy.isCloudProvider(providerID)
      ? .highContrast : .tinted
  }
}
