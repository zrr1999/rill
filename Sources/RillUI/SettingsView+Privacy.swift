import AppKit
import SwiftUI
import RillCore

extension SettingsView {
  var privacySection: some View {
    settingsDisclosure(.privacy) {
      if model.isLoadingPrivacySettings {
        Label(
          L10n.privacyText(.loading, language: model.language),
          systemImage: RillSystemSymbol.hourglass.rawValue
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      if let loadError = model.privacySettingsLoadError {
        VStack(alignment: .leading, spacing: 6) {
          Label(loadError, systemImage: RillSystemSymbol.exclamationmarkShield.rawValue)
            .font(.caption)
            .foregroundStyle(.red)
          HStack {
            Button(L10n.privacyText(.retryLoad, language: model.language)) {
              model.retryPrivacySettingsLoad()
            }
            Button(
              L10n.privacyText(.resetSafeDefaults, language: model.language),
              role: .destructive
            ) {
              model.resetPrivacySettingsToSafeDefaults()
            }
          }
          .buttonStyle(.bordered)
          .disabled(model.isLoadingPrivacySettings)
        }
      }

      if let saveError = model.privacySettingsSaveError {
        VStack(alignment: .leading, spacing: 6) {
          Label(saveError, systemImage: RillSystemSymbol.exclamationmarkTriangle.rawValue)
            .font(.caption)
            .foregroundStyle(.red)
          Button(L10n.privacyText(.retrySave, language: model.language)) {
            model.retryPrivacySettingsSave()
          }
          .buttonStyle(.bordered)
        }
      } else if model.isSavingPrivacySettings {
        Label(
          L10n.privacyText(.saving, language: model.language),
          systemImage: RillSystemSymbol.arrowTriangle2Circlepath.rawValue
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Text(L10n.privacyText(PrivacySettingsTextKey.description, language: model.language))
        .font(.caption)
        .foregroundStyle(.secondary)

      VStack(alignment: .leading, spacing: 6) {
        Button {
          guard let privacyNoticeDocument else { return }
          presentedSheet = .privacyNotice(privacyNoticeDocument)
        } label: {
          Label(
            L10n.privacyText(.technicalNotice, language: model.language),
            systemImage: RillSystemSymbol.handRaisedSquare.rawValue
          )
        }
        .disabled(privacyNoticeDocument == nil)
        .accessibilityIdentifier("settings.privacy.technical-notice")

        Text(
          L10n.privacyText(
            privacyNoticeDocument == nil
              ? .technicalNoticeUnavailable
              : .technicalNoticeDescription,
            language: model.language
          )
        )
        .font(.caption)
        .foregroundStyle(privacyNoticeDocument == nil ? .red : .secondary)
      }

      Toggle(
        L10n.privacyText(PrivacySettingsTextKey.cloudConfirmation, language: model.language),
        isOn: Binding(
          get: { model.privacyPolicySettings.cloudConfirmationRequired },
          set: { model.setPrivacyCloudConfirmationRequired($0) }
        )
      )
      .disabled(privacySettingsControlsDisabled)
      Text(
        L10n.privacyText(
          PrivacySettingsTextKey.cloudConfirmationDescription, language: model.language)
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      if !model.privacyPolicySettings.cloudProcessingAuthorizations.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text(
              L10n.privacyText(.cloudAlwaysAllowed, language: model.language)
            )
            .font(.callout.weight(.medium))
            Spacer()
            Button(
              L10n.privacyText(.revokeAllAuthorizations, language: model.language)
            ) {
              model.revokeAllCloudProcessingAuthorizations()
            }
            .disabled(privacySettingsControlsDisabled)
          }

          ForEach(
            model.privacyPolicySettings.cloudProcessingAuthorizations.sorted {
              $0.grantedAt > $1.grantedAt
            }
          ) { authorization in
            HStack {
              Label(authorization.workflowName, systemImage: RillSystemSymbol.cloud.rawValue)
                .lineLimit(1)
              Spacer()
              Button(
                L10n.privacyText(.revokeAuthorization, language: model.language)
              ) {
                model.revokeCloudProcessingAuthorization(authorization.id)
              }
              .buttonStyle(.borderless)
              .disabled(privacySettingsControlsDisabled)
            }
          }

          Text(
            L10n.privacyText(.cloudAlwaysAllowedDescription, language: model.language)
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        .padding(10)
        // RillCard prominent-tier fill at badge radius; padding stays manual.
        .background(
          .quaternary.opacity(RillCardProminence.prominent.fillOpacity),
          in: RoundedRectangle(cornerRadius: RillRadius.badge, style: .continuous)
        )
      }

      Toggle(
        L10n.privacyText(
          PrivacySettingsTextKey.secureInputConservativeMode, language: model.language),
        isOn: Binding(
          get: { model.privacyPolicySettings.secureInputConservativeMode },
          set: { model.setPrivacySecureInputConservativeMode($0) }
        )
      )
      .disabled(privacySettingsControlsDisabled)
      Text(
        L10n.privacyText(
          PrivacySettingsTextKey.secureInputConservativeDescription, language: model.language)
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      Picker(
        L10n.privacyText(PrivacySettingsTextKey.historyPreviewMode, language: model.language),
        selection: Binding(
          get: { model.privacyPolicySettings.historyPreviewMode },
          set: { model.setPrivacyHistoryPreviewMode($0) }
        )
      ) {
        ForEach(PrivacyHistoryPreviewMode.allCases, id: \.rawValue) { mode in
          Text(L10n.privacySettingsHistoryPreviewMode(mode, language: model.language)).tag(mode)
        }
      }
      .pickerStyle(.menu)
      .disabled(privacySettingsControlsDisabled)
      Text(
        L10n.privacyText(PrivacySettingsTextKey.historyPreviewDescription, language: model.language)
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      Divider()

      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text(L10n.privacyText(PrivacySettingsTextKey.sensitiveApps, language: model.language))
            .font(.subheadline.weight(.medium))
          Spacer()
          Button(L10n.privacyText(.restoreRecommended, language: model.language)) {
            restoreRecommendedSensitiveAppRules()
          }
          .buttonStyle(.bordered)
          .disabled(privacySettingsControlsDisabled)
        }
        Text(
          L10n.privacyText(
            PrivacySettingsTextKey.sensitiveAppsDescription, language: model.language)
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      sensitiveAppRuleEditor
        .disabled(privacySettingsControlsDisabled)

      if model.privacyPolicySettings.sensitiveAppRules.isEmpty {
        Text(L10n.settingsText(.settingsSensitiveAppRulesEmpty, language: model.language))
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        ForEach(model.privacyPolicySettings.sensitiveAppRules) { rule in
          sensitiveAppRuleRow(rule)
            .disabled(privacySettingsControlsDisabled)
        }
      }
    }
  }

  var privacySettingsControlsDisabled: Bool {
    model.isLoadingPrivacySettings || model.privacySettingsLoadError != nil
  }

  var sensitiveAppRuleEditor: some View {
    VStack(alignment: .leading, spacing: RillSpacing.row) {
      TextField(
        L10n.privacyText(.bundleIdentifier, language: model.language),
        text: $sensitiveAppBundleIdentifier
      )
      .textFieldStyle(.roundedBorder)
      .monospaced()

      TextField(
        L10n.privacyText(.applicationNameOptional, language: model.language),
        text: $sensitiveAppApplicationName
      )
      .textFieldStyle(.roundedBorder)

      if let sensitiveAppRuleError {
        Label(sensitiveAppRuleError, systemImage: RillSystemSymbol.exclamationmarkCircle.rawValue)
          .font(.caption)
          .foregroundStyle(.red)
      }

      HStack {
        Spacer()
        if editingSensitiveAppRuleID != nil {
          Button(L10n.privacyText(.cancelEdit, language: model.language)) {
            resetSensitiveAppRuleEditor()
          }
        }
        Button(
          L10n.privacyText(
            editingSensitiveAppRuleID == nil ? .addRule : .saveRule,
            language: model.language
          )
        ) {
          saveSensitiveAppRule()
        }
        .buttonStyle(.borderedProminent)
      }
    }
    .padding(.vertical, 4)
  }

  func sensitiveAppRuleRow(_ rule: SensitiveAppRule) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Toggle(
        L10n.privacyText(PrivacySettingsTextKey.ruleEnabled, language: model.language),
        isOn: Binding(
          get: { sensitiveAppRule(rule.id)?.enabled ?? rule.enabled },
          set: { model.setSensitiveAppRuleEnabled(rule.id, isEnabled: $0) }
        )
      )
      .font(.subheadline.weight(.medium))

      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 3) {
          Text(rule.displayName)
            .font(.subheadline.weight(.medium))
          Text(rule.bundleIdentifier)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
        }
        Spacer()
        if rule.isRecommended {
          Text(L10n.privacyText(.recommendedRule, language: model.language))
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          Button(L10n.privacyText(.editRule, language: model.language)) {
            beginEditingSensitiveAppRule(rule)
          }
          .buttonStyle(.borderless)
          Button(role: .destructive) {
            destructiveConfirmation = .sensitiveAppRule(rule.id)
          } label: {
            Text(L10n.privacyText(.deleteRule, language: model.language))
          }
          .buttonStyle(.borderless)
        }
      }

      VStack(alignment: .leading, spacing: 6) {
        Toggle(
          L10n.privacyText(PrivacySettingsTextKey.ruleBlocksClipboard, language: model.language),
          isOn: Binding(
            get: {
              sensitiveAppRule(rule.id)?.blocksClipboardHistory ?? rule.blocksClipboardHistory
            },
            set: { model.setSensitiveAppRuleBlocksClipboardHistory(rule.id, blocks: $0) }
          )
        )
        Toggle(
          L10n.privacyText(PrivacySettingsTextKey.ruleBlocksWorkflow, language: model.language),
          isOn: Binding(
            get: { sensitiveAppRule(rule.id)?.blocksWorkflowCapture ?? rule.blocksWorkflowCapture },
            set: { model.setSensitiveAppRuleBlocksWorkflowCapture(rule.id, blocks: $0) }
          )
        )
        Toggle(
          L10n.privacyText(PrivacySettingsTextKey.ruleBlocksSelectedText, language: model.language),
          isOn: Binding(
            get: { sensitiveAppRule(rule.id)?.blocksSelectedText ?? rule.blocksSelectedText },
            set: { model.setSensitiveAppRuleBlocksSelectedText(rule.id, blocks: $0) }
          )
        )
        Toggle(
          L10n.privacyText(PrivacySettingsTextKey.ruleBlocksCloud, language: model.language),
          isOn: Binding(
            get: { sensitiveAppRule(rule.id)?.blocksCloudProcessing ?? rule.blocksCloudProcessing },
            set: { model.setSensitiveAppRuleBlocksCloudProcessing(rule.id, blocks: $0) }
          )
        )
      }
      .toggleStyle(.checkbox)
      .font(.caption)
    }
    .padding(.vertical, 4)
  }

  func sensitiveAppRule(_ ruleID: UUID) -> SensitiveAppRule? {
    model.privacyPolicySettings.sensitiveAppRules.first { $0.id == ruleID }
  }

  func saveSensitiveAppRule() {
    do {
      let name = trimmedOptional(sensitiveAppApplicationName)
      if let editingSensitiveAppRuleID {
        try model.editSensitiveAppRule(
          editingSensitiveAppRuleID,
          bundleIdentifier: sensitiveAppBundleIdentifier,
          applicationName: name
        )
      } else {
        try model.addSensitiveAppRule(
          bundleIdentifier: sensitiveAppBundleIdentifier,
          applicationName: name
        )
      }
      resetSensitiveAppRuleEditor()
    } catch {
      sensitiveAppRuleError = localizedSensitiveAppRuleError(error)
    }
  }

  func beginEditingSensitiveAppRule(_ rule: SensitiveAppRule) {
    editingSensitiveAppRuleID = rule.id
    sensitiveAppBundleIdentifier = rule.bundleIdentifier
    sensitiveAppApplicationName = rule.applicationName ?? ""
    sensitiveAppRuleError = nil
  }

  func deleteSensitiveAppRule(_ rule: SensitiveAppRule) {
    do {
      try model.deleteSensitiveAppRule(rule.id)
      if editingSensitiveAppRuleID == rule.id {
        resetSensitiveAppRuleEditor()
      }
    } catch {
      sensitiveAppRuleError = localizedSensitiveAppRuleError(error)
    }
  }

  func restoreRecommendedSensitiveAppRules() {
    do {
      try model.restoreRecommendedSensitiveAppRules()
      sensitiveAppRuleError = nil
    } catch {
      sensitiveAppRuleError = localizedSensitiveAppRuleError(error)
    }
  }

  func resetSensitiveAppRuleEditor() {
    editingSensitiveAppRuleID = nil
    sensitiveAppBundleIdentifier = ""
    sensitiveAppApplicationName = ""
    sensitiveAppRuleError = nil
  }

  func localizedSensitiveAppRuleError(_ error: Error) -> String {
    guard let validationError = error as? SensitiveAppRuleValidationError else {
      return L10n.settingsText(.settingsPrivacyRuleUpdateFailed, language: model.language)
    }
    let key: PrivacySettingsTextKey
    switch validationError {
    case .missingBundleIdentifier:
      key = .missingBundleIdentifier
    case .invalidBundleIdentifier:
      key = .invalidBundleIdentifier
    case .duplicateBundleIdentifier, .duplicateRuleIdentifier:
      key = .duplicateBundleIdentifier
    case .recommendedRuleCannotBeEdited:
      key = .recommendedRuleCannotBeEdited
    case .ruleNotFound:
      key = .ruleNotFound
    }
    return L10n.privacyText(key, language: model.language)
  }

}
