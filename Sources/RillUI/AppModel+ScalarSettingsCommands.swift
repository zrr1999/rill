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
    public func setClipboardCaptureEnabled(_ isEnabled: Bool) -> Bool {
        guard canMutateScalarSettings(in: .clipboard) else { return false }
        clipboardCaptureEnabled = isEnabled
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
}
