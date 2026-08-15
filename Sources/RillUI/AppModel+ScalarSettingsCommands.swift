import RillCore

extension AppModel {
    public func canMutateScalarSettings(in domain: ScalarSettingsDomain) -> Bool {
        !hasBegunApplicationShutdown && !hasUnavailableScalarSettings(in: domain)
    }

    @discardableResult
    public func setInterfaceLanguage(_ newLanguage: AppLanguage) -> Bool {
        guard canMutateScalarSettings(in: .interface) else { return false }
        language = newLanguage
        return true
    }

    @discardableResult
    public func setSystemClipboardCaptureEnabled(_ isEnabled: Bool) -> Bool {
        guard canMutateScalarSettings(in: .systemClipboard) else { return false }
        systemClipboardCaptureEnabled = isEnabled
        return true
    }

    @discardableResult
    public func setPreferredSpeechEngine(_ engine: PreferredSpeechEngine) -> Bool {
        guard canMutateScalarSettings(in: .speechRoute),
              engine != .local || localSpeechTrustMaterialAvailable else {
            return false
        }
        preferredSpeechEngine = engine
        return true
    }

    @discardableResult
    public func setPreferredLocalSpeechModel(_ modelIdentifier: String) -> Bool {
        guard canMutateScalarSettings(in: .speechRoute),
              canMutateScalarSettings(in: .localSpeech),
              localSpeechTrustMaterialAvailable,
              trustedLocalSpeechModels.contains(where: { $0.id == modelIdentifier }) else {
            return false
        }

        if preferredSpeechEngine == .local {
            selectTrustedLocalSpeechModel(modelIdentifier)
        } else {
            // Set the exact model before enabling the local route so the route
            // transition prepares only the newly selected backend.
            if localSpeechModel != modelIdentifier {
                localSpeechModel = modelIdentifier
            }
            preferredSpeechEngine = .local
        }
        return true
    }

    @discardableResult
    public func setPreferredTTSModel(_ modelIdentifier: String) -> Bool {
        guard ttsModelOptions.contains(where: { $0.id == modelIdentifier }) else {
            return false
        }
        ttsModelIdentifier = modelIdentifier
        return true
    }

    @discardableResult
    public func setBuiltinPushToTalkOutputMode(
        _ mode: BuiltinPushToTalkOutputMode
    ) -> Bool {
        guard canMutateScalarSettings(in: .input) else { return false }
        builtinPushToTalkOutputMode = mode
        return true
    }

    @discardableResult
    public func setLongRecordingModeEnabled(_ isEnabled: Bool) -> Bool {
        guard canMutateScalarSettings(in: .input) else { return false }
        longRecordingModeEnabled = isEnabled
        return true
    }

    @discardableResult
    public func setRecordingDurationLimit(_ limit: RecordingDurationLimit) -> Bool {
        guard canMutateScalarSettings(in: .input) else { return false }
        recordingDurationLimit = limit
        return true
    }
}
