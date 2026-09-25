import Foundation
import RillCore

extension AppModel {
  public func updateSpeechModelPoolMemoryPressureDegradation(_ isDegraded: Bool) {
    self.voice.speechModelPoolDegradedByMemoryPressure = isDegraded
  }

  public func recordMeasuredSpeechModelPeak(
    modelID: String,
    peakByteCount: UInt64
  ) {
    guard peakByteCount > 0,
      speechModelResourceCatalog.contains(where: { $0.id == modelID }),
      peakByteCount > (self.voice.measuredSpeechModelPeakByteCounts[modelID] ?? 0)
    else { return }

    self.voice.measuredSpeechModelPeakByteCounts[modelID] = peakByteCount
    if residentSpeechModelIDs.contains(modelID) {
      applyResidentSpeechBudgetConfirmation(nil)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(self.voice.measuredSpeechModelPeakByteCounts),
      let value = String(data: data, encoding: .utf8)
    else { return }
    persistStringSetting(value, for: .speechModelMeasuredPeaks)
  }

  func synchronizeResidentSpeechModels(from previousModelIDs: Set<String>) {
    guard !self.settings.isLoading, !self.settings.isRestoringSettings, !hasBegunApplicationShutdown else {
      return
    }

    let desiredModelIDs = residentSpeechModelIDs.intersection(enabledSpeechModelIDs)
    let addedModelIDs = desiredModelIDs.subtracting(previousModelIDs)
    let removedModelIDs = previousModelIDs.subtracting(desiredModelIDs)
    guard !addedModelIDs.isEmpty || !removedModelIDs.isEmpty else { return }

    let previousTask = self.voice.residentSpeechModelSynchronizationTask
    let taskID = UUID()
    let task = Task { [weak self, synchronizeResidentSpeechModelsAction] in
      await previousTask?.value
      guard !Task.isCancelled else { return }
      await synchronizeResidentSpeechModelsAction(addedModelIDs, removedModelIDs)
      _ = await MainActor.run {
        self?.voice.residentSpeechModelSynchronizationTasks.removeValue(forKey: taskID)
      }
    }
    self.voice.residentSpeechModelSynchronizationTasks[taskID] = task
    self.voice.residentSpeechModelSynchronizationTask = task
  }

  func cancelResidentSpeechModelSynchronizationForApplicationShutdown() {
    for task in self.voice.residentSpeechModelSynchronizationTasks.values {
      task.cancel()
    }
    self.voice.residentSpeechModelSynchronizationTasks.removeAll()
    self.voice.residentSpeechModelSynchronizationTask = nil
    for task in self.voice.enabledSpeechModelPreparationTasks.values {
      task.cancel()
    }
    self.voice.enabledSpeechModelPreparationTasks.removeAll()
  }

  private func prepareEnabledSpeechModel(_ modelID: String) {
    self.voice.enabledSpeechModelPreparationTasks.removeValue(forKey: modelID)?.cancel()
    self.voice.enabledSpeechModelPreparationTasks[modelID] = Task {
      [weak self, prepareEnabledSpeechModelAction] in
      await prepareEnabledSpeechModelAction(modelID)
      _ = await MainActor.run {
        self?.voice.enabledSpeechModelPreparationTasks.removeValue(forKey: modelID)
      }
    }
  }

  public var speechModelResourceCatalog: [SpeechModelResourceDescriptor] {
    let speechToText = trustedLocalSpeechModels.map {
      SpeechModelResourceDescriptor(
        id: $0.id,
        capability: .speechToText,
        downloadByteCount: $0.approximateDownloadByteCount,
        conservativeRuntimePeakByteCount: $0.conservativeRuntimePeakByteCount,
        measuredPeakByteCount: self.voice.measuredSpeechModelPeakByteCounts[$0.id]
      )
    }
    let textToSpeech = ttsModelOptions.map {
      SpeechModelResourceDescriptor(
        id: $0.id,
        capability: .textToSpeech,
        downloadByteCount: $0.approximateDownloadByteCount,
        measuredPeakByteCount: self.voice.measuredSpeechModelPeakByteCounts[$0.id]
      )
    }
    return speechToText + textToSpeech
  }

  public var residentSpeechModelBudget: SpeechModelResourceBudget {
    SpeechModelResourceBudget(
      residentModelIDs: residentSpeechModelIDs,
      catalog: speechModelResourceCatalog,
      physicalMemoryByteCount: UInt64(max(localSpeechPhysicalMemoryGiB, 0))
        * 1_073_741_824
    )
  }

  public var pendingResidentSpeechModelBudget: SpeechModelResourceBudget? {
    self.voice.pendingResidentSpeechModelIDs.map {
      SpeechModelResourceBudget(
        residentModelIDs: $0,
        catalog: speechModelResourceCatalog,
        physicalMemoryByteCount: UInt64(max(localSpeechPhysicalMemoryGiB, 0))
          * 1_073_741_824
      )
    }
  }

  public func setSpeechModelEnabled(_ modelID: String, enabled: Bool) {
    guard speechModelResourceCatalog.contains(where: { $0.id == modelID }) else { return }
    if enabled {
      let inserted = !enabledSpeechModelIDs.contains(modelID)
      applyEnabledSpeechModelIDs(enabledSpeechModelIDs.union([modelID]))
      if inserted { prepareEnabledSpeechModel(modelID) }
    } else {
      self.voice.enabledSpeechModelPreparationTasks.removeValue(forKey: modelID)?.cancel()
      applyEnabledSpeechModelIDs(enabledSpeechModelIDs.subtracting([modelID]))
      applyResidentSpeechModelIDs(residentSpeechModelIDs.subtracting([modelID]))
      self.voice.pendingResidentSpeechModelIDs?.remove(modelID)
    }
  }

  public func setSpeechModelResident(_ modelID: String, resident: Bool) {
    guard enabledSpeechModelIDs.contains(modelID) else { return }
    var proposed = residentSpeechModelIDs
    if resident {
      proposed.insert(modelID)
    } else {
      proposed.remove(modelID)
    }
    let budget = SpeechModelResourceBudget(
      residentModelIDs: proposed,
      catalog: speechModelResourceCatalog,
      physicalMemoryByteCount: UInt64(max(localSpeechPhysicalMemoryGiB, 0))
        * 1_073_741_824
    )
    if budget.requiresConfirmation,
      residentSpeechBudgetConfirmation != budget.confirmationFingerprint
    {
      self.voice.pendingResidentSpeechModelIDs = proposed
      return
    }
    self.voice.pendingResidentSpeechModelIDs = nil
    applyResidentSpeechModelIDs(proposed)
  }

  public func confirmPendingResidentSpeechModels() {
    guard let proposed = self.voice.pendingResidentSpeechModelIDs else { return }
    let budget = SpeechModelResourceBudget(
      residentModelIDs: proposed,
      catalog: speechModelResourceCatalog,
      physicalMemoryByteCount: UInt64(max(localSpeechPhysicalMemoryGiB, 0))
        * 1_073_741_824
    )
    applyResidentSpeechBudgetConfirmation(budget.confirmationFingerprint)
    applyResidentSpeechModelIDs(proposed)
    self.voice.pendingResidentSpeechModelIDs = nil
  }

  public func cancelPendingResidentSpeechModels() {
    self.voice.pendingResidentSpeechModelIDs = nil
  }
}
