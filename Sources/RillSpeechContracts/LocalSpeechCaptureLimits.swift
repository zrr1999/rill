package enum LocalSpeechCaptureLimits {
  package static let sampleRateHz = 16_000.0
  package static let maximumRequestedDurationSeconds = 120.0
  package static let startupToleranceSeconds = 3.1
  package static let maximumAcceptedDurationSeconds =
    maximumRequestedDurationSeconds + startupToleranceSeconds
  package static let maximumAcceptedFrameCount = Int(
    (maximumAcceptedDurationSeconds * sampleRateHz).rounded(.down)
  )
}
