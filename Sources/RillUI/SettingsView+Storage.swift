import AppKit
import SwiftUI
import RillCore

extension SettingsView {
  var localDataAndRetentionSection: some View {
    settingsDisclosure(.storage) {
      Picker(
        L10n.historySettingsText(.recordRetention, language: model.language),
        selection: Binding(
          get: { model.recordRetentionPeriod },
          set: { model.setRecordRetentionPeriod($0) }
        )
      ) {
        ForEach(HistoryRetentionPeriod.allCases) { period in
          Text(L10n.historyRetentionPeriod(period, language: model.language)).tag(period)
        }
      }
      .pickerStyle(.menu)
      .disabled(localHistoryControlsDisabled)

      Picker(
        L10n.historySettingsText(.runRetention, language: model.language),
        selection: Binding(
          get: { model.runHistoryRetentionPeriod },
          set: { model.setRunHistoryRetentionPeriod($0) }
        )
      ) {
        ForEach(HistoryRetentionPeriod.allCases) { period in
          Text(L10n.historyRetentionPeriod(period, language: model.language)).tag(period)
        }
      }
      .pickerStyle(.menu)
      .disabled(localHistoryControlsDisabled)

      Divider()

      Toggle(
        L10n.string(.settingsFailedAudioRecovery, language: model.language),
        isOn: Binding(
          get: { model.failedAudioRecoveryEnabled },
          set: { model.setFailedAudioRecoveryEnabled($0) }
        )
      )
      .disabled(
        model.settings.isLoading
          || model.isUpdatingFailedAudioRecovery
          || !model.retryingFailedAudioRecoveryIDs.isEmpty
      )

      Text(
        L10n.string(
          .settingsFailedAudioRecoveryDescription,
          language: model.language
        )
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      HStack {
        Button(
          L10n.string(
            .settingsFailedAudioRecoveryClear,
            language: model.language
          ),
          role: .destructive
        ) {
          destructiveConfirmation = .failedAudioRecovery
        }
        .disabled(
          model.failedAudioRecoveryReceipts.isEmpty
            || model.isUpdatingFailedAudioRecovery
            || !model.retryingFailedAudioRecoveryIDs.isEmpty
        )
        Spacer()
        if !model.failedAudioRecoveryReceipts.isEmpty {
          Text(
            L10n.settingsFailedAudioEncryptedCount(
              model.failedAudioRecoveryReceipts.count,
              language: model.language
            )
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }

      if let error = model.failedAudioRecoveryError {
        Label(error, systemImage: RillSystemSymbol.exclamationmarkTriangle.rawValue)
          .font(.caption)
          .foregroundStyle(.red)
      }

      Divider()

      Toggle(
        L10n.string(.settingsBenchmarkRecordingArchive, language: model.language),
        isOn: Binding(
          get: { model.benchmarkRecordingArchiveEnabled },
          set: { model.setBenchmarkRecordingArchiveEnabled($0) }
        )
      )
      .disabled(
        model.settings.isLoading
          || model.isUpdatingBenchmarkRecordingArchive
      )

      Text(
        L10n.string(
          .settingsBenchmarkRecordingArchiveDescription,
          language: model.language
        )
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      Button(
        L10n.string(
          .settingsBenchmarkRecordingArchiveClear,
          language: model.language
        ),
        role: .destructive
      ) {
        destructiveConfirmation = .benchmarkRecordingArchive
      }
      .disabled(model.isUpdatingBenchmarkRecordingArchive)

      if let error = model.benchmarkRecordingArchiveError {
        Label(error, systemImage: RillSystemSymbol.exclamationmarkTriangle.rawValue)
          .font(.caption)
          .foregroundStyle(.red)
      }

      Divider()

      RecordCapacityView(capacity: model.recordWorkspace.snapshot.capacity, language: model.language) {
        model.clearRecordHistory()
      }
      .sheet(isPresented: Binding(get: { model.recordWorkspace.cleanup.plan != nil }, set: { if !$0 { model.recordWorkspace.cleanup.cancel() } })) {
        RecordCleanupSheet(model: model.recordWorkspace.cleanup, language: model.language)
      }
      if model.recordWorkspace.cleanup.plan == nil, let message = model.recordWorkspace.cleanup.message {
        Text(L10n.quickRecord(message, language: model.language))
          .font(.caption).foregroundStyle(.orange)
      }
      if model.recordWorkspace.retentionSuggestionCount > 0 {
        Button(L10n.quickRecord(.expiredRecords, language: model.language) + " (\(model.recordWorkspace.retentionSuggestionCount))") {
          Task { await model.recordWorkspace.cleanup.request(olderThan: model.recordRetentionPeriod.cutoffDate(relativeTo: Date()) ?? .distantPast) }
        }
      }

      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Button(
            L10n.historySettingsText(.clearRun, language: model.language),
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
            language: model.language
          )
        )
        .font(.caption)
        .foregroundStyle(.secondary)

        if model.hasActiveOrQueuedVoiceRun {
          Text(L10n.historySettingsText(.runActiveHint, language: model.language))
            .font(.caption)
            .foregroundStyle(.orange)
        }
      }

      if let error = model.historyRetentionSettingsError {
        Label(error, systemImage: RillSystemSymbol.exclamationmarkTriangle.rawValue)
          .font(.caption)
          .foregroundStyle(.red)
      }

      if model.isLocalHistoryMaintenanceRunning {
        Label(
          L10n.historySettingsText(.maintenanceRunning, language: model.language),
          systemImage: RillSystemSymbol.arrowTriangle2Circlepath.rawValue
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      } else if let pendingReason = model.localHistoryMaintenancePendingReason {
        VStack(alignment: .leading, spacing: 6) {
          Label(pendingReason, systemImage: RillSystemSymbol.clockBadgeExclamationmark.rawValue)
            .font(.caption)
            .foregroundStyle(.orange)
          retryLocalHistoryMaintenanceButton
        }
      } else if let blockedReason = model.localHistoryMaintenanceBlockedReason {
        VStack(alignment: .leading, spacing: 6) {
          Label(blockedReason, systemImage: RillSystemSymbol.exclamationmarkOctagon.rawValue)
            .font(.caption)
            .foregroundStyle(.red)
          retryLocalHistoryMaintenanceButton
        }
      } else if model.lastLocalHistoryRemovedCount > 0
        || model.lastPreservedActiveRecordCount > 0
      {
        Label(
          L10n.historyMaintenanceResult(
            removedCount: model.lastLocalHistoryRemovedCount,
            preservedActiveRecordCount: model.lastPreservedActiveRecordCount,
            language: model.language
          ),
          systemImage: RillSystemSymbol.checkmarkCircle.rawValue
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Text(L10n.historySettingsText(.description, language: model.language))
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  var localHistoryControlsDisabled: Bool {
    model.settings.isLoading || model.isUpdatingHistoryRetentionSettings
      || model.isLocalHistoryMaintenanceRunning
  }

  var retryLocalHistoryMaintenanceButton: some View {
    Button(L10n.historySettingsText(.retry, language: model.language)) {
      model.retryPendingLocalHistoryMaintenance()
    }
    .buttonStyle(.bordered)
    .disabled(
      localHistoryControlsDisabled || !model.isLocalHistoryMaintenanceAvailable
    )
  }

}
