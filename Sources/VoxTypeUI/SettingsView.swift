import SwiftUI
import VoxTypeCore

public struct SettingsView: View {
    @Bindable private var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        Form {
            Section {
                Text(UIStrings.text(.settingsDescription, language: model.language))
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker(UIStrings.text(.language, language: model.language), selection: $model.language) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
            } header: {
                Label(UIStrings.text(.settingsLanguage, language: model.language), systemImage: "globe")
            } footer: {
                Text(UIStrings.text(.settingsLanguageDescription, language: model.language))
            }

            Section {
                HotkeyRecorderView(
                    binding: model.clipboardPanelHotkeyBinding,
                    language: model.language,
                    onRecord: { shortcut in
                        model.setClipboardPanelHotkeyShortcut(shortcut)
                    },
                    onReset: {
                        model.resetClipboardPanelHotkeyBinding()
                    }
                )
            } header: {
                Label(UIStrings.text(.settingsClipboardPanel, language: model.language), systemImage: "doc.on.clipboard")
            } footer: {
                Text(UIStrings.text(.settingsClipboardPanelDescription, language: model.language))
            }

            Section {
                HStack {
                    Spacer()
                    Button(UIStrings.text(.refreshPermissions, language: model.language)) {
                        model.refreshPermissions()
                    }
                }

                permissionRow(
                    title: UIStrings.text(.accessibility, language: model.language),
                    state: model.permissionSnapshot.accessibility,
                    requestAction: model.requestAccessibilityPermission,
                    openSettingsAction: model.openAccessibilitySettings
                )

                permissionRow(
                    title: UIStrings.text(.microphone, language: model.language),
                    state: model.permissionSnapshot.microphone,
                    requestAction: model.requestMicrophonePermission,
                    openSettingsAction: model.openMicrophoneSettings
                )

                if model.permissionSnapshot.accessibility != .granted {
                    Text(UIStrings.text(.appNotListedHint, language: model.language))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Label(UIStrings.text(.permissions, language: model.language), systemImage: "lock.shield")
            } footer: {
                Text(UIStrings.text(.permissionHint, language: model.language))
            }

            speechEngineSection
        }
        .formStyle(.grouped)
        .navigationTitle(UIStrings.text(.settingsTitle, language: model.language))
    }

    private func permissionRow(
        title: String,
        state: PermissionState,
        requestAction: @escaping () -> Void,
        openSettingsAction: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(UIStrings.permissionState(state, language: model.language))
                    .font(.caption)
                    .foregroundStyle(stateColor(state))
            }
            Spacer()
            switch state {
            case .granted:
                EmptyView()
            case .unknown:
                Button(UIStrings.text(.requestAccess, language: model.language)) {
                    requestAction()
                }
            case .denied:
                Button(UIStrings.text(.requestAccess, language: model.language)) {
                    requestAction()
                }
                Button(UIStrings.text(.openSettings, language: model.language)) {
                    openSettingsAction()
                }
            }
        }
    }

    private var speechEngineSection: some View {
        Section {
            Picker(UIStrings.text(.settingsSpeechEngine, language: model.language), selection: $model.preferredSpeechEngine) {
                ForEach(PreferredSpeechEngine.allCases) { engine in
                    Text(UIStrings.speechEngine(engine, language: model.language)).tag(engine)
                }
            }
            .pickerStyle(.segmented)

            if model.preferredSpeechEngine == .local {
                VStack(alignment: .leading, spacing: 8) {
                    Text(UIStrings.text(.settingsWhisperKit, language: model.language))
                        .font(.subheadline.weight(.medium))
                    Text(UIStrings.text(.settingsWhisperKitDescription, language: model.language))
                        .foregroundStyle(.secondary)

                    Picker(
                        UIStrings.text(.whisperKitModel, language: model.language),
                        selection: $model.whisperKitModelOption
                    ) {
                        ForEach(WhisperKitModelOption.allCases) { option in
                            Text(model.whisperKitModelOptionLabel(option))
                                .tag(option)
                        }
                    }
                    .pickerStyle(.menu)

                    if !model.downloadedWhisperKitModels.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(UIStrings.text(.whisperKitDownloadedModels, language: model.language))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(model.downloadedWhisperKitModels, id: \.self) { modelIdentifier in
                                        Button(model.whisperKitModelDisplayName(modelIdentifier, includeStatus: true)) {
                                            model.useDownloadedWhisperKitModel(modelIdentifier)
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                    }
                                }
                            }
                        }
                    }

                    if model.whisperKitModelOption == .custom {
                        VStack(alignment: .leading, spacing: 8) {
                            TextField(
                                UIStrings.text(.whisperKitCustomModel, language: model.language),
                                text: $model.whisperKitCustomModel
                            )
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                model.prepareWhisperKitModel()
                            }

                            HStack(alignment: .center, spacing: 12) {
                                Text(UIStrings.text(.whisperKitCustomModelHint, language: model.language))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button(UIStrings.text(.whisperKitPrepare, language: model.language)) {
                                    model.prepareWhisperKitModel()
                                }
                            }
                        }
                    }

                    if model.whisperKitPreparationState == .preparing {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(UIStrings.text(.whisperKitPreparing, language: model.language))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(model.whisperKitPreparationProgress, format: .percent.precision(.fractionLength(0)))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            ProgressView(value: model.whisperKitPreparationProgress, total: 1)
                                .controlSize(.small)
                                .progressViewStyle(.linear)
                        }
                    } else if model.whisperKitPreparationState == .ready {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(
                                UIStrings.text(.whisperKitPreparationReady, language: model.language),
                                systemImage: "checkmark.circle.fill"
                            )
                            .foregroundStyle(.green)

                            if let preparedModel = model.whisperKitPreparedModelIdentifier {
                                Text(preparedModel)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Text(UIStrings.text(.whisperKitPreparationHint, language: model.language))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let error = model.whisperKitPreparationError, !error.isEmpty {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text(UIStrings.text(.settingsDeepgram, language: model.language))
                        .font(.subheadline.weight(.medium))
                    Text(UIStrings.text(.settingsDeepgramDescription, language: model.language))
                        .foregroundStyle(.secondary)

                    SecureField(
                        UIStrings.text(.deepgramAPIKey, language: model.language),
                        text: $model.deepgramAPIKey
                    )
                    .textFieldStyle(.roundedBorder)

                    TextField(
                        UIStrings.text(.deepgramBaseURL, language: model.language),
                        text: $model.deepgramBaseURL
                    )
                    .textFieldStyle(.roundedBorder)

                    HStack(spacing: 12) {
                        TextField(
                            UIStrings.text(.deepgramModel, language: model.language),
                            text: $model.deepgramModel
                        )
                        .textFieldStyle(.roundedBorder)

                        TextField(
                            UIStrings.text(.deepgramLanguage, language: model.language),
                            text: $model.deepgramLanguage
                        )
                        .textFieldStyle(.roundedBorder)
                    }
                }
            }
        } header: {
            Label(UIStrings.text(.settingsSpeechEngine, language: model.language), systemImage: "waveform.path.ecg")
        } footer: {
            Text(UIStrings.text(.settingsSpeechEngineDescription, language: model.language))
        }
    }

    private func stateColor(_ state: PermissionState) -> Color {
        switch state {
        case .granted: return .green
        case .denied: return .orange
        case .unknown: return .secondary
        }
    }
}
