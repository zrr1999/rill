import AppKit
import SwiftUI
import RillCore

public enum LiveSubtitleOverlayMetrics {
  public static let minimumSurfaceWidth: CGFloat = 340
  public static let maximumSurfaceWidth: CGFloat = 720
  public static let minimumSurfaceHeight: CGFloat = 96
  public static let standardCornerRadius: CGFloat = 18
  public static let compactCornerRadius: CGFloat = 16
  public static let shadowRadius: CGFloat = 16
  public static let shadowOffsetY: CGFloat = 6
  public static let shadowInsets = EdgeInsets(
    top: 20,
    leading: 20,
    bottom: 26,
    trailing: 20
  )
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

  @ViewBuilder
  public var body: some View {
    if includesShadow {
      surface
        .compositingGroup()
        .shadow(
          color: shadowColor,
          radius: LiveSubtitleOverlayMetrics.shadowRadius,
          y: LiveSubtitleOverlayMetrics.shadowOffsetY
        )
        .padding(LiveSubtitleOverlayMetrics.shadowInsets)
        .animation(
          accessibilityReduceMotion ? nil : .easeInOut(duration: 0.18),
          value: snapshot.phase
        )
        .accessibilityElement(children: .contain)
    } else {
      surface
        .animation(
          accessibilityReduceMotion ? nil : .easeInOut(duration: 0.18),
          value: snapshot.phase
        )
        .accessibilityElement(children: .contain)
    }
  }

  private var surface: some View {
    Group {
      if snapshot.prefersCompactLayout {
        compactBody
      } else {
        standardBody
      }
    }
    .background(
      Color(nsColor: .windowBackgroundColor),
      in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    )
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .strokeBorder(borderColor)
    )
  }

  private var standardBody: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        HStack(spacing: 8) {
          Circle()
            .fill(accentColor)
            .frame(width: 8, height: 8)
          Image(systemName: statusSymbol.rawValue)
            .font(.caption.weight(.semibold))
            .foregroundStyle(accentColor)
        }

        if let workflow = snapshot.workflow {
          Text(UIStrings.workflowName(workflow, language: language))
            .font(.caption.weight(.semibold))
            .foregroundStyle(secondaryTextColor)
        } else {
          Text(statusTitle)
            .font(.caption.weight(.semibold))
            .foregroundStyle(secondaryTextColor)
        }

        if let providerDisclosureTitle {
          Label(providerDisclosureTitle, systemImage: providerDisclosureSymbol.rawValue)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(providerDisclosureForegroundColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(providerDisclosureBackgroundColor, in: Capsule())
            .overlay(Capsule().strokeBorder(providerDisclosureBorderColor))
            .accessibilityLabel(Text(providerDisclosureTitle))
        }

        Spacer(minLength: 0)

        if snapshot.queuedRunCount > 0 {
          queueBadge
        }

        recordingTimer

        Text(statusTitle)
          .font(.caption.weight(.semibold))
          .foregroundStyle(accentColor)

        controlButton
      }

      if snapshot.displayText.isEmpty {
        Text(snapshot.statusText ?? statusMessage)
          .font(.title3.weight(.medium))
          .foregroundStyle(primaryTextColor)
          .lineLimit(3)
      } else {
        liveText
          .font(.title3.weight(.semibold))
          .lineLimit(LiveSubtitlePresentationPolicy.standardLiveTextLineLimit)
          .truncationMode(
            LiveSubtitlePresentationPolicy.standardLiveTextPreservesLatestContent ? .head : .tail
          )
          .multilineTextAlignment(.leading)
      }

      if showsActivityIndicator {
        VoiceActivityIndicator(
          levelMeter: snapshot.levelMeter,
          isActive: isAudioCaptureActive,
          accentColor: accentColor,
          barCount: 14,
          barWidth: 4,
          minHeight: 6,
          maxHeight: 30
        )
      }
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 16)
    .frame(
      minWidth: LiveSubtitleOverlayMetrics.minimumSurfaceWidth,
      maxWidth: LiveSubtitleOverlayMetrics.maximumSurfaceWidth,
      alignment: .leading
    )
  }

  private var compactBody: some View {
    HStack(spacing: 12) {
      ProgressView()
        .controlSize(.small)
        .tint(accentColor)

      VStack(alignment: .leading, spacing: 4) {
        Text(workflowTitle)
          .font(.caption.weight(.semibold))
          .foregroundStyle(secondaryTextColor)
          .lineLimit(1)

        Text(snapshot.statusText ?? statusMessage)
          .font(.callout.weight(.medium))
          .foregroundStyle(primaryTextColor)
          .lineLimit(2)
      }

      Spacer(minLength: 0)

      if snapshot.queuedRunCount > 0 {
        queueBadge
      }

      recordingTimer

      controlButton
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .frame(minWidth: 240, maxWidth: 360, alignment: .leading)
  }

  private var liveText: Text {
    let confirmed = snapshot.confirmedText
    let hypothesis = snapshot.hypothesisText

    if confirmed.isEmpty {
      return Text(hypothesis).foregroundStyle(primaryTextColor)
        + trailingCursor
    }

    if hypothesis.isEmpty {
      return Text(confirmed).foregroundStyle(primaryTextColor)
        + trailingCursor
    }

    return Text(confirmed).foregroundStyle(primaryTextColor)
      + Text(" ").foregroundStyle(primaryTextColor)
      + Text(hypothesis).foregroundStyle(secondaryTextColor)
      + trailingCursor
  }

  private var trailingCursor: Text {
    guard isAudioCaptureActive else { return Text("") }
    return Text(" ▍").foregroundStyle(accentColor.opacity(0.95))
  }

  private var accentColor: Color {
    switch snapshot.phase {
    case .failed:
      return .red
    case .preparing:
      return Color(nsColor: .secondaryLabelColor)
    case .finalizing, .processing:
      return Color(nsColor: .tertiaryLabelColor)
    case .recording, .listening, .transcribing:
      return Color(nsColor: .labelColor)
    case .hidden:
      return .gray
    }
  }

  private var primaryTextColor: Color {
    Color(nsColor: .labelColor)
  }

  private var secondaryTextColor: Color {
    Color(nsColor: .secondaryLabelColor)
  }

  private var borderColor: Color {
    Color(nsColor: .separatorColor)
      .opacity(colorSchemeContrast == .increased ? 1 : 0.9)
  }

  private var shadowColor: Color {
    .black.opacity(colorSchemeContrast == .increased ? 0.22 : 0.16)
  }

  private var isAudioCaptureActive: Bool {
    LiveSubtitlePresentationPolicy.isAudioCaptureActive(phase: snapshot.phase)
  }

  private var showsActivityIndicator: Bool {
    isAudioCaptureActive
  }

  private var statusTitle: String {
    switch snapshot.phase {
    case .hidden:
      return language == .english ? "Hidden" : "已隐藏"
    case .preparing:
      return language == .english ? "Preparing" : "准备中"
    case .recording, .listening:
      return language == .english ? "Listening" : "聆听中"
    case .transcribing:
      return language == .english ? "Live" : "实时"
    case .finalizing:
      return language == .english ? "Finalizing" : "收尾中"
    case .processing:
      return language == .english ? "Processing" : "处理中"
    case .failed:
      return language == .english ? "Unavailable" : "不可用"
    }
  }

  private var statusSymbol: RillSystemSymbol {
    LiveSubtitlePresentationPolicy.statusSymbol(for: snapshot.phase)
  }

  private var statusMessage: String {
    switch snapshot.phase {
    case .hidden:
      return statusTitle
    case .preparing:
      return language == .english ? "Preparing live subtitles…" : "正在准备实时字幕…"
    case .recording, .listening:
      return language == .english ? "Listening…" : "正在聆听…"
    case .transcribing:
      return language == .english ? "Transcribing…" : "正在转写…"
    case .finalizing:
      return language == .english ? "Finalizing…" : "正在收尾…"
    case .processing:
      return snapshot.statusText ?? (language == .english ? "Processing in background…" : "后台处理中…")
    case .failed:
      return snapshot.statusText
        ?? (language == .english
          ? "Live transcription is unavailable. Check speech settings and retry."
          : "实时转写不可用。请检查语音设置后重试。")
    }
  }

  private var workflowTitle: String {
    if let workflow = snapshot.workflow {
      return UIStrings.workflowName(workflow, language: language)
    }
    return statusTitle
  }

  private var queueBadge: some View {
    Text(queueBadgeTitle)
      .font(.caption2.weight(.semibold))
      .foregroundStyle(accentColor)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(accentColor.opacity(0.08), in: Capsule())
  }

  private var queueBadgeTitle: String {
    if language == .english {
      return snapshot.queuedRunCount > 1
        ? "\(snapshot.queuedRunCount) in background" : "1 in background"
    }
    return "后台 \(snapshot.queuedRunCount)"
  }

  @ViewBuilder
  private var recordingTimer: some View {
    if isAudioCaptureActive,
      snapshot.recordingStartedAt != nil
    {
      TimelineView(.periodic(from: .now, by: 1)) { context in
        if let state = LiveSubtitlePresentationPolicy.recordingTimerState(
          for: snapshot,
          now: context.date
        ) {
          HStack(spacing: 6) {
            Text(recordingTimerTitle(state))
              .font(.caption2.monospacedDigit().weight(.semibold))
              .foregroundStyle(state.isNearLimit ? Color.red : secondaryTextColor)
              .padding(.horizontal, 7)
              .padding(.vertical, 3)
              .background(
                (state.isNearLimit ? Color.red : secondaryTextColor).opacity(0.09),
                in: Capsule()
              )
              .overlay(
                Capsule()
                  .strokeBorder(
                    (state.isNearLimit ? Color.red : borderColor).opacity(
                      state.isNearLimit ? 0.8 : 0.7
                    )
                  )
              )
              .accessibilityLabel(Text(recordingTimerAccessibilityLabel(state)))

            if state.isNearLimit, snapshot.canRemoveRecordingDurationLimit == true {
              Button(action: requestUnlimitedRecording) {
                Text(language == .english ? "No limit" : "不限时")
                  .font(.caption2.weight(.semibold))
                  .padding(.horizontal, 7)
                  .padding(.vertical, 3)
              }
              .buttonStyle(.plain)
              .foregroundStyle(Color.red)
              .background(Color.red.opacity(0.12), in: Capsule())
              .overlay(Capsule().strokeBorder(Color.red.opacity(0.8)))
              .help(
                language == .english
                  ? "Continue without Rill's automatic recording limit"
                  : "继续录音，并解除 Rill 的自动停止上限"
              )
              .accessibilityLabel(
                Text(language == .english ? "Continue with no time limit" : "继续且不限时")
              )
            }
          }
        }
      }
    }
  }

  private func recordingTimerTitle(
    _ state: LiveSubtitlePresentationPolicy.RecordingTimerState
  ) -> String {
    let elapsed = LiveSubtitlePresentationPolicy.formattedDuration(state.elapsedSeconds)
    if state.isUnlimited {
      return language == .english ? "\(elapsed) · No limit" : "\(elapsed) · 不限时"
    }
    guard let maximumSeconds = state.maximumSeconds else { return elapsed }
    return "\(elapsed) / \(LiveSubtitlePresentationPolicy.formattedDuration(maximumSeconds))"
  }

  private func recordingTimerAccessibilityLabel(
    _ state: LiveSubtitlePresentationPolicy.RecordingTimerState
  ) -> String {
    let elapsed = LiveSubtitlePresentationPolicy.formattedDuration(state.elapsedSeconds)
    if state.isUnlimited {
      return language == .english
        ? "Recorded \(elapsed). No time limit."
        : "已录制 \(elapsed)，不限时。"
    }
    guard let maximumSeconds = state.maximumSeconds,
      let remainingSeconds = state.remainingSeconds
    else {
      return language == .english ? "Recorded \(elapsed)." : "已录制 \(elapsed)。"
    }
    let maximum = LiveSubtitlePresentationPolicy.formattedDuration(maximumSeconds)
    let remaining = LiveSubtitlePresentationPolicy.formattedDuration(remainingSeconds)
    if language == .english {
      return "Recorded \(elapsed) of \(maximum). \(remaining) remaining."
    }
    return "已录制 \(elapsed)，上限 \(maximum)，剩余 \(remaining)。"
  }

  private var controlButton: some View {
    let stopsCapture = LiveSubtitleInteractionPolicy.showsStopControl(for: snapshot.phase)
    let title =
      stopsCapture
      ? (language == .english ? "Stop recording" : "停止录音")
      : UIStrings.text(.liveSubtitleClose, language: language)
    return Button(action: requestControlAction) {
      Image(
        systemName: stopsCapture
          ? RillSystemSymbol.stopFill.rawValue
          : RillSystemSymbol.xmark.rawValue
      )
      .font(.system(size: 10, weight: .bold))
      .foregroundStyle(stopsCapture ? Color.red : secondaryTextColor)
      .frame(width: 22, height: 22)
      .background(
        Color(nsColor: .controlBackgroundColor).opacity(0.72),
        in: Circle()
      )
      .overlay(Circle().strokeBorder(borderColor.opacity(0.7)))
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

  private var providerDisclosureTitle: String? {
    LiveSubtitleInteractionPolicy.providerDisclosureTitle(
      providerID: snapshot.providerID,
      language: language
    )
  }

  private var providerDisclosureSymbol: RillSystemSymbol {
    LiveSubtitleInteractionPolicy.isCloudProvider(snapshot.providerID)
      ? .cloudFill
      : .laptopcomputer
  }

  private var providerDisclosureForegroundColor: Color {
    if providerDisclosureStyle == .highContrast {
      return primaryTextColor
    }
    return LiveSubtitleInteractionPolicy.isCloudProvider(snapshot.providerID)
      ? .orange : secondaryTextColor
  }

  private var providerDisclosureBackgroundColor: Color {
    if providerDisclosureStyle == .highContrast {
      return Color(nsColor: .controlBackgroundColor)
    }
    return providerDisclosureForegroundColor.opacity(0.1)
  }

  private var providerDisclosureBorderColor: Color {
    providerDisclosureStyle == .highContrast
      ? Color(nsColor: .separatorColor) : .clear
  }

  private var providerDisclosureStyle: LiveSubtitlePresentationPolicy.ProviderDisclosureStyle {
    LiveSubtitlePresentationPolicy.providerDisclosureStyle(
      providerID: snapshot.providerID,
      increasedContrast: colorSchemeContrast == .increased
    )
  }

  private var cornerRadius: CGFloat {
    snapshot.prefersCompactLayout
      ? LiveSubtitleOverlayMetrics.compactCornerRadius
      : LiveSubtitleOverlayMetrics.standardCornerRadius
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

  static func isCloudProvider(_ providerID: String?) -> Bool {
    false
  }

  static func providerDisclosureTitle(
    providerID: String?,
    language: AppLanguage
  ) -> String? {
    guard let providerID else { return nil }
    if providerID.lowercased().hasPrefix("sherpa-onnx.") {
      return language == .english ? "On-device" : "本机处理"
    }
    return nil
  }
}

enum LiveSubtitlePresentationPolicy {
  struct RecordingTimerState: Equatable {
    let elapsedSeconds: Int
    let maximumSeconds: Int?
    let remainingSeconds: Int?
    let isNearLimit: Bool
    let isUnlimited: Bool
  }

  enum ProviderDisclosureStyle: Equatable {
    case tinted
    case highContrast
  }

  static let standardLiveTextLineLimit = 4
  static let standardLiveTextPreservesLatestContent = true

  static func recordingTimerState(
    for snapshot: LiveSubtitleSnapshot,
    now: Date
  ) -> RecordingTimerState? {
    guard let startedAt = snapshot.recordingStartedAt else { return nil }
    let rawElapsed = now.timeIntervalSince(startedAt)
    guard rawElapsed.isFinite, rawElapsed <= Double(Int.max) else { return nil }
    let unboundedElapsedSeconds = max(0, Int(floor(rawElapsed)))
    guard let maximumDurationSeconds = snapshot.maximumRecordingDurationSeconds else {
      guard snapshot.recordingDurationIsUnlimited == true else { return nil }
      return RecordingTimerState(
        elapsedSeconds: unboundedElapsedSeconds,
        maximumSeconds: nil,
        remainingSeconds: nil,
        isNearLimit: false,
        isUnlimited: true
      )
    }
    guard maximumDurationSeconds.isFinite,
      maximumDurationSeconds > 0,
      maximumDurationSeconds <= Double(Int.max)
    else {
      return nil
    }
    let maximumSeconds = max(1, Int(ceil(maximumDurationSeconds)))
    let elapsedSeconds = min(
      maximumSeconds,
      unboundedElapsedSeconds
    )
    let remainingSeconds = maximumSeconds - elapsedSeconds
    let warningWindowSeconds = min(
      15,
      max(5, Int(ceil(maximumDurationSeconds * 0.1)))
    )
    return RecordingTimerState(
      elapsedSeconds: elapsedSeconds,
      maximumSeconds: maximumSeconds,
      remainingSeconds: remainingSeconds,
      isNearLimit: remainingSeconds <= warningWindowSeconds,
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
    case .preparing, .recording, .listening, .transcribing:
      .waveform
    case .finalizing:
      .forwardEnd
    case .processing:
      .textAlignLeft
    case .failed:
      .exclamationmarkCircleFill
    case .hidden:
      .circle
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
