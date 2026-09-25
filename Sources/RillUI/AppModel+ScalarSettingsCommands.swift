import RillCore

extension AppModel {
    public func canMutateScalarSettings(in domain: ScalarSettingsDomain) -> Bool {
        !hasBegunApplicationShutdown && !hasUnavailableScalarSettings(in: domain)
    }

    @discardableResult
    public func setInterfaceLanguage(_ newLanguage: AppLanguage) -> Bool {
        guard canMutateScalarSettings(in: .interface) else { return false }
        applyLanguage(newLanguage)
        return true
    }

    @discardableResult
    public func setSystemClipboardCaptureEnabled(_ isEnabled: Bool) -> Bool {
        guard canMutateScalarSettings(in: .systemClipboard) else { return false }
        applySystemClipboardCaptureEnabled(isEnabled)
        return true
    }

    @discardableResult
    public func setPreferredSpeechEngine(_ engine: PreferredSpeechEngine) -> Bool {
        guard canMutateScalarSettings(in: .speechRoute),
              engine != .local || localSpeechTrustMaterialAvailable else {
            return false
        }
        applyPreferredSpeechEngine(engine)
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
                applyLocalSpeechModel(modelIdentifier)
            }
            applyPreferredSpeechEngine(.local)
        }
        return true
    }

    @discardableResult
    public func setPreferredTTSModel(_ modelIdentifier: String) -> Bool {
        guard ttsModelOptions.contains(where: { $0.id == modelIdentifier }) else {
            return false
        }
        applyTTSModelIdentifier(modelIdentifier)
        return true
    }

    @discardableResult
    public func setBuiltinPushToTalkOutputMode(
        _ mode: BuiltinPushToTalkOutputMode
    ) -> Bool {
        guard canMutateScalarSettings(in: .input) else { return false }
        applyBuiltinPushToTalkOutputMode(mode)
        return true
    }

    @discardableResult
    public func setLongRecordingModeEnabled(_ isEnabled: Bool) -> Bool {
        guard canMutateScalarSettings(in: .input) else { return false }
        applyLongRecordingModeEnabled(isEnabled)
        return true
    }

    @discardableResult
    public func setRecordingDurationLimit(_ limit: RecordingDurationLimit) -> Bool {
        guard canMutateScalarSettings(in: .input) else { return false }
        applyRecordingDurationLimit(limit)
        return true
    }
}


extension AppModel {
    public func setOpenAIAPIKey(_ value: String) {
        guard !hasBegunApplicationShutdown,
              settings.openAICredentialAvailability != .inaccessible else { return }
        applyOpenAIAPIKey(value)
    }

    public func setOpenAIBaseURL(_ value: String) {
        guard canMutateScalarSettings(in: .openAI) else { return }
        applyOpenAIBaseURL(value)
    }

    public func setOpenAIModel(_ value: String) {
        guard canMutateScalarSettings(in: .openAI) else { return }
        applyOpenAIModel(value)
    }
}
