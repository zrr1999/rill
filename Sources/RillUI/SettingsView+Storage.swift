import AppKit
import SwiftUI
import RillCore

extension SettingsView {
  var localDataAndRetentionSection: some View {
    settingsDisclosure(.storage) {
      Picker(
        L10n.historySettingsText(.recordRetention, language: model.settings.language),
        selection: Binding(
          get: { model.recordRetentionPeriod },
          set: { model.setRecordRetentionPeriod($0) }
        )
      ) {
        ForEach(HistoryRetentionPeriod.allCases) { period in
          Text(L10n.historyRetentionPeriod(period, language: model.settings.language)).tag(period)
        }
      }
      .pickerStyle(.menu)
      .disabled(localHistoryControlsDisabled)

      Picker(
        L10n.historySettingsText(.runRetention, language: model.settings.language),
        selection: Binding(
          get: { model.runHistoryRetentionPeriod },
          set: { model.setRunHistoryRetentionPeriod($0) }
        )
      ) {
        ForEach(HistoryRetentionPeriod.allCases) { period in
          Text(L10n.historyRetentionPeriod(period, language: model.settings.language)).tag(period)
        }
      }
      .pickerStyle(.menu)
      .disabled(localHistoryControlsDisabled)

      Divider()

      Toggle(
        L10n.string(.settingsFailedAudioRecovery, language: model.settings.language),
        isOn: Binding(
          get: { model.voice.failedAudioRecoveryEnabled },
          set: { model.setFailedAudioRecoveryEnabled($0) }
        )
      )
      .disabled(
        model.settings.isLoading
          || model.voice.isUpdatingFailedAudioRecovery
          || !model.voice.retryingFailedAudioRecoveryIDs.isEmpty
      )

      Text(
        L10n.string(
          .settingsFailedAudioRecoveryDescription,
          language: model.settings.language
        )
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      HStack {
        Button(
          L10n.string(
            .settingsFailedAudioRecoveryClear,
            language: model.settings.language
          ),
          role: .destructive
        ) {
          destructiveConfirmation = .failedAudioRecovery
        }
        .disabled(
          model.voice.failedAudioRecoveryReceipts.isEmpty
            || model.voice.isUpdatingFailedAudioRecovery
            || !model.voice.retryingFailedAudioRecoveryIDs.isEmpty
        )
        Spacer()
        if !model.voice.failedAudioRecoveryReceipts.isEmpty {
          Text(
            L10n.settingsFailedAudioEncryptedCount(
              model.voice.failedAudioRecoveryReceipts.count,
              language: model.settings.language
            )
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }

      if let error = model.voice.failedAudioRecoveryError {
        Label(error, systemImage: RillSystemSymbol.exclamationmarkTriangle.rawValue)
          .font(.caption)
          .foregroundStyle(.red)
      }

      Divider()

      Toggle(
        L10n.string(.settingsBenchmarkRecordingArchive, language: model.settings.language),
        isOn: Binding(
          get: { model.benchmarkArchive.isEnabled },
          set: { model.benchmarkArchive.setEnabled($0) }
        )
      )
      .disabled(
        model.settings.isLoading
          || model.benchmarkArchive.isUpdating
      )

      Text(
        L10n.string(
          .settingsBenchmarkRecordingArchiveDescription,
          language: model.settings.language
        )
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      Button(
        L10n.string(
          .settingsBenchmarkRecordingArchiveClear,
          language: model.settings.language
        ),
        role: .destructive
      ) {
        destructiveConfirmation = .benchmarkRecordingArchive
      }
      .disabled(model.benchmarkArchive.isUpdating)

      Button(L10n.benchmarkArchive(.title, language: model.settings.language)) {
        presentedSheet = .benchmarkArchive
      }
      .disabled(model.benchmarkArchive.isUpdating)

      if let error = model.benchmarkArchive.error {
        Label(error, systemImage: RillSystemSymbol.exclamationmarkTriangle.rawValue)
          .font(.caption)
          .foregroundStyle(.red)
      }

      Divider()

      RecordCapacityView(capacity: model.recordWorkspace.snapshot.capacity, language: model.settings.language) {
        model.clearRecordHistory()
      }
      .sheet(isPresented: Binding(get: { model.recordWorkspace.cleanup.plan != nil }, set: { if !$0 { model.recordWorkspace.cleanup.cancel() } })) {
        RecordCleanupSheet(model: model.recordWorkspace.cleanup, language: model.settings.language)
      }
      if model.recordWorkspace.cleanup.plan == nil, let message = model.recordWorkspace.cleanup.message {
        Text(L10n.quickRecord(message, language: model.settings.language))
          .font(.caption).foregroundStyle(.orange)
      }
      if model.recordWorkspace.retentionSuggestionCount > 0 {
        Button(L10n.quickRecord(.expiredRecords, language: model.settings.language) + " (\(model.recordWorkspace.retentionSuggestionCount))") {
          Task { await model.recordWorkspace.cleanup.request(olderThan: model.recordRetentionPeriod.cutoffDate(relativeTo: Date()) ?? .distantPast) }
        }
      }

      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Button(
            L10n.historySettingsText(.clearRun, language: model.settings.language),
            role: .destructive
          ) {
            destructiveConfirmation = .runHistory
          }
          .disabled(!model.canClearRunHistory || !model.isLocalHistoryMaintenanceAvailable)
          Spacer()
        }
        Text(
          L10n.historySettingsText(
            .preservedRunDetail,
            language: model.settings.language
          )
        )
        .font(.caption)
        .foregroundStyle(.secondary)

        if model.hasActiveOrQueuedVoiceRun {
          Text(L10n.historySettingsText(.runActiveHint, language: model.settings.language))
            .font(.caption)
            .foregroundStyle(.orange)
        }
      }

      if let error = model.history.historyRetentionSettingsError {
        Label(error, systemImage: RillSystemSymbol.exclamationmarkTriangle.rawValue)
          .font(.caption)
          .foregroundStyle(.red)
      }

      if model.history.isLocalHistoryMaintenanceRunning {
        Label(
          L10n.historySettingsText(.maintenanceRunning, language: model.settings.language),
          systemImage: RillSystemSymbol.arrowTriangle2Circlepath.rawValue
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      } else if let pendingReason = model.history.localHistoryMaintenancePendingReason {
        VStack(alignment: .leading, spacing: 6) {
          Label(pendingReason, systemImage: RillSystemSymbol.clockBadgeExclamationmark.rawValue)
            .font(.caption)
            .foregroundStyle(.orange)
          retryLocalHistoryMaintenanceButton
        }
      } else if let blockedReason = model.history.localHistoryMaintenanceBlockedReason {
        VStack(alignment: .leading, spacing: 6) {
          Label(blockedReason, systemImage: RillSystemSymbol.exclamationmarkOctagon.rawValue)
            .font(.caption)
            .foregroundStyle(.red)
          retryLocalHistoryMaintenanceButton
        }
      } else if model.history.lastLocalHistoryRemovedCount > 0
        || model.history.lastPreservedActiveRecordCount > 0
      {
        Label(
          L10n.historyMaintenanceResult(
            removedCount: model.history.lastLocalHistoryRemovedCount,
            preservedActiveRecordCount: model.history.lastPreservedActiveRecordCount,
            language: model.settings.language
          ),
          systemImage: RillSystemSymbol.checkmarkCircle.rawValue
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Text(L10n.historySettingsText(.description, language: model.settings.language))
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  var localHistoryControlsDisabled: Bool {
    model.settings.isLoading || model.history.isUpdatingHistoryRetentionSettings
      || model.history.isLocalHistoryMaintenanceRunning
  }

  var retryLocalHistoryMaintenanceButton: some View {
    Button(L10n.historySettingsText(.retry, language: model.settings.language)) {
      model.retryPendingLocalHistoryMaintenance()
    }
    .buttonStyle(.bordered)
    .disabled(
      localHistoryControlsDisabled || !model.isLocalHistoryMaintenanceAvailable
    )
  }

}
