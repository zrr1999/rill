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

enum LiveSubtitleSurfaceMaterial: Equatable {
  case thin
  case regular
}

struct LiveSubtitleSurfaceStyle: Equatable {
  let material: LiveSubtitleSurfaceMaterial
  let tintOpacity: Double

  static func resolve(
    reduceTransparency: Bool,
    increasedContrast: Bool
  ) -> LiveSubtitleSurfaceStyle {
    if reduceTransparency {
      return LiveSubtitleSurfaceStyle(material: .regular, tintOpacity: 0.28)
    }
    return LiveSubtitleSurfaceStyle(
      material: .thin,
      tintOpacity: increasedContrast ? 0.16 : 0.08
    )
  }
}

public struct LiveSubtitleOverlay: View {
  @Environment(\.accessibilityReduceTransparency) private var accessibilityReduceTransparency
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast

  public let snapshot: LiveSubtitleSnapshot
  public let language: AppLanguage
  private let includesShadow: Bool
  private let meterModel: VoiceActivityMeterModel?

  public init(
    snapshot: LiveSubtitleSnapshot,
    language: AppLanguage,
    includesShadow: Bool = true,
    meterModel: VoiceActivityMeterModel? = nil
  ) {
    self.snapshot = snapshot
    self.language = language
    self.includesShadow = includesShadow
    self.meterModel = meterModel
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
    .background { surfaceBackground }
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .strokeBorder(borderColor, lineWidth: 0.75)
    )
  }

  @ViewBuilder
  private var surfaceBackground: some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    let style = LiveSubtitleSurfaceStyle.resolve(
      reduceTransparency: accessibilityReduceTransparency,
      increasedContrast: colorSchemeContrast == .increased
    )

    switch style.material {
    case .thin:
      shape
        .fill(.thinMaterial)
        .overlay(shape.fill(surfaceTint.opacity(style.tintOpacity)))
    case .regular:
      shape
        .fill(.regularMaterial)
        .overlay(shape.fill(surfaceTint.opacity(style.tintOpacity)))
    }
  }

  private var compactBody: some View {
    HStack(spacing: 6) {
      networkUsageDisclosure
      waveform
      Spacer(minLength: 2)
      recordingTimer
      if isAudioCaptureActive {
        escapeHint
      }
    }
    .padding(.horizontal, 12)
    .frame(
      width: LiveSubtitleOverlayMetrics.compactSurfaceWidth,
      height: LiveSubtitleOverlayMetrics.compactSurfaceHeight
    )
  }

  private var expandedBody: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        networkUsageDisclosure
        waveform
        Spacer(minLength: 2)
        recordingTimer
        if isAudioCaptureActive {
          escapeHint
        }
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

  @ViewBuilder
  private var waveform: some View {
    if let meterModel {
      LiveSubtitleObservedWaveform(
        meterModel: meterModel,
        isActive: isAudioCaptureActive,
        accentColor: meterColor
      )
    } else {
      VoiceActivityIndicator(
        levelMeter: snapshot.levelMeter,
        isActive: isAudioCaptureActive,
        accentColor: meterColor,
        barCount: 12,
        barWidth: 2,
        barSpacing: 2,
        minHeight: 3,
        maxHeight: 20
      )
    }
  }

  private var networkUsageDisclosure: some View {
    let usage = snapshot.networkUsage ?? .unknown
    let showsTitle = LiveSubtitlePresentationPolicy.usesExpandedLayout(snapshot)
    let tint = networkUsageTint(usage)
    return HStack(spacing: 4) {
      Image(systemName: LiveSubtitleInteractionPolicy.networkDisclosureSymbolName(usage))
        .font(.system(size: 10, weight: .semibold))
      if showsTitle {
        Text(
          LiveSubtitleInteractionPolicy.networkDisclosureShortTitle(
            usage,
            language: language
          )
        )
        .font(.caption2.weight(.medium))
      }
    }
    .foregroundStyle(tint)
    .padding(.horizontal, showsTitle ? 6 : 0)
    .frame(minWidth: 20, minHeight: 20)
    .fixedSize()
    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: RillRadius.chip, style: .continuous))
    .help(
      LiveSubtitleInteractionPolicy.networkDisclosureTitle(
        usage,
        language: language
      )
    )
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      Text(
        LiveSubtitleInteractionPolicy.networkDisclosureTitle(
          usage,
          language: language
        )
      )
    )
  }

  private func networkUsageTint(_ usage: LiveSubtitleNetworkUsage) -> Color {
    // Four-color status semantics (docs/ui-direction.md §4): offline is a
    // caution, online is ready, unknown stays neutral.
    switch usage {
    case .offline:
      .orange
    case .online:
      .green
    case .unknown:
      secondaryTextColor
    }
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
              Image(systemName: RillSystemSymbol.infinity.rawValue)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .foregroundStyle(timerColor(state))
            .background(timerColor(state).opacity(0.1), in: Circle())
            .help(
              L10n.overlayText(.liveSubtitleContinueWithoutLimitHelp, language: language)
            )
            .accessibilityLabel(
              Text(L10n.overlayText(.liveSubtitleContinueNoTimeLimit, language: language))
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
      return L10n.overlayText(.liveSubtitleRecordingJustStarted, language: language)
    }
    if state.isNearLimit, let remainingSeconds = state.remainingSeconds {
      let remaining = LiveSubtitlePresentationPolicy.formattedDuration(remainingSeconds)
      return L10n.liveSubtitleRemaining(remaining, language: language)
    }
    let elapsed = LiveSubtitlePresentationPolicy.formattedDuration(state.elapsedSeconds)
    return L10n.liveSubtitleRecorded(elapsed, language: language)
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

  private var escapeHint: some View {
    Text("esc")
      .font(.caption2.monospaced().weight(.medium))
      .foregroundStyle(secondaryTextColor)
      .padding(.horizontal, 6)
      .frame(height: 20)
      .background(
        Color(nsColor: .controlBackgroundColor).opacity(0.42),
        in: RoundedRectangle(cornerRadius: RillRadius.chip)
      )
      .overlay(
        RoundedRectangle(cornerRadius: RillRadius.chip)
          .strokeBorder(borderColor.opacity(0.55), lineWidth: 0.75)
      )
      .accessibilityLabel(
        Text(L10n.overlayText(.liveSubtitleEscapeHint, language: language))
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

  private var surfaceTint: Color { Color(nsColor: .windowBackgroundColor) }
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

  private static let removeDurationLimitRequestedNotification = Notification.Name(
    "works.earendil.rill.live-subtitle.remove-duration-limit-requested"
  )
}

private struct LiveSubtitleObservedWaveform: View {
  @ObservedObject var meterModel: VoiceActivityMeterModel
  let isActive: Bool
  let accentColor: Color

  var body: some View {
    VoiceActivityIndicator(
      levelMeter: meterModel.levels,
      isActive: isActive,
      accentColor: accentColor,
      barCount: 12,
      barWidth: 2,
      barSpacing: 2,
      minHeight: 3,
      maxHeight: 20
    )
  }
}

enum LiveSubtitleInteractionPolicy {
  static func networkDisclosureTitle(
    _ usage: LiveSubtitleNetworkUsage,
    language: AppLanguage
  ) -> String {
    switch (usage, language) {
    case (.offline, .english):
      "Offline — processed entirely on this Mac"
    case (.offline, .simplifiedChinese):
      "离线 — 全程在本机处理"
    case (.online, .english):
      "Online — this workflow uses a network service"
    case (.online, .simplifiedChinese):
      "联网 — 此工作流会使用网络服务"
    case (.unknown, .english):
      "Network use could not be determined"
    case (.unknown, .simplifiedChinese):
      "联网状态无法确定"
    }
  }

  static func networkDisclosureShortTitle(
    _ usage: LiveSubtitleNetworkUsage,
    language: AppLanguage
  ) -> String {
    switch (usage, language) {
    case (.offline, .english): "Offline"
    case (.offline, .simplifiedChinese): "离线"
    case (.online, .english): "Online"
    case (.online, .simplifiedChinese): "联网"
    case (.unknown, .english): "Unknown"
    case (.unknown, .simplifiedChinese): "未知"
    }
  }

  static func networkDisclosureSymbolName(_ usage: LiveSubtitleNetworkUsage) -> String {
    switch usage {
    case .offline: RillSystemSymbol.lockFill.rawValue
    case .online: RillSystemSymbol.network.rawValue
    case .unknown: RillSystemSymbol.questionmark.rawValue
    }
  }
}

public enum LiveSubtitlePresentationPolicy {
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

  static let standardLiveTextLineLimit = 2
  static let standardLiveTextPreservesLatestContent = true

  public static func usesExpandedLayout(_ snapshot: LiveSubtitleSnapshot) -> Bool {
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

  public static func isAudioCaptureActive(phase: LiveSubtitlePhase) -> Bool {
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

}
