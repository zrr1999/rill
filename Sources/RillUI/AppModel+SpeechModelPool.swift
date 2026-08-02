import Foundation
import RillCore

extension AppModel {
  public func updateSpeechModelPoolMemoryPressureDegradation(_ isDegraded: Bool) {
    speechModelPoolDegradedByMemoryPressure = isDegraded
  }

  public func recordMeasuredSpeechModelPeak(
    modelID: String,
    peakByteCount: UInt64
  ) {
    guard peakByteCount > 0,
      speechModelResourceCatalog.contains(where: { $0.id == modelID }),
      peakByteCount > (measuredSpeechModelPeakByteCounts[modelID] ?? 0)
    else { return }

    measuredSpeechModelPeakByteCounts[modelID] = peakByteCount
    if residentSpeechModelIDs.contains(modelID) {
      residentSpeechBudgetConfirmation = nil
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(measuredSpeechModelPeakByteCounts),
      let value = String(data: data, encoding: .utf8)
    else { return }
    persistStringSetting(value, for: .speechModelMeasuredPeaks)
  }

  func synchronizeResidentSpeechModels(from previousModelIDs: Set<String>) {
    guard !isLoadingSettings, !isRestoringSettings, !hasBegunApplicationShutdown else {
      return
    }

    let desiredModelIDs = residentSpeechModelIDs.intersection(enabledSpeechModelIDs)
    let addedModelIDs = desiredModelIDs.subtracting(previousModelIDs)
    let removedModelIDs = previousModelIDs.subtracting(desiredModelIDs)
    guard !addedModelIDs.isEmpty || !removedModelIDs.isEmpty else { return }

    let previousTask = residentSpeechModelSynchronizationTask
    let taskID = UUID()
    let task = Task { [weak self, synchronizeResidentSpeechModelsAction] in
      await previousTask?.value
      guard !Task.isCancelled else { return }
      await synchronizeResidentSpeechModelsAction(addedModelIDs, removedModelIDs)
      _ = await MainActor.run {
        self?.residentSpeechModelSynchronizationTasks.removeValue(forKey: taskID)
      }
    }
    residentSpeechModelSynchronizationTasks[taskID] = task
    residentSpeechModelSynchronizationTask = task
  }

  func cancelResidentSpeechModelSynchronizationForApplicationShutdown() {
    for task in residentSpeechModelSynchronizationTasks.values {
      task.cancel()
    }
    residentSpeechModelSynchronizationTasks.removeAll()
    residentSpeechModelSynchronizationTask = nil
    for task in enabledSpeechModelPreparationTasks.values {
      task.cancel()
    }
    enabledSpeechModelPreparationTasks.removeAll()
  }

  private func prepareEnabledSpeechModel(_ modelID: String) {
    enabledSpeechModelPreparationTasks.removeValue(forKey: modelID)?.cancel()
    enabledSpeechModelPreparationTasks[modelID] = Task {
      [weak self, prepareEnabledSpeechModelAction] in
      await prepareEnabledSpeechModelAction(modelID)
      _ = await MainActor.run {
        self?.enabledSpeechModelPreparationTasks.removeValue(forKey: modelID)
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
        measuredPeakByteCount: measuredSpeechModelPeakByteCounts[$0.id]
      )
    }
    let textToSpeech = ttsModelOptions.map {
      SpeechModelResourceDescriptor(
        id: $0.id,
        capability: .textToSpeech,
        downloadByteCount: $0.approximateDownloadByteCount,
        measuredPeakByteCount: measuredSpeechModelPeakByteCounts[$0.id]
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
    pendingResidentSpeechModelIDs.map {
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
      let inserted = enabledSpeechModelIDs.insert(modelID).inserted
      if inserted { prepareEnabledSpeechModel(modelID) }
    } else {
      enabledSpeechModelPreparationTasks.removeValue(forKey: modelID)?.cancel()
      enabledSpeechModelIDs.remove(modelID)
      residentSpeechModelIDs.remove(modelID)
      pendingResidentSpeechModelIDs?.remove(modelID)
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
      pendingResidentSpeechModelIDs = proposed
      return
    }
    pendingResidentSpeechModelIDs = nil
    residentSpeechModelIDs = proposed
  }

  public func confirmPendingResidentSpeechModels() {
    guard let proposed = pendingResidentSpeechModelIDs else { return }
    let budget = SpeechModelResourceBudget(
      residentModelIDs: proposed,
      catalog: speechModelResourceCatalog,
      physicalMemoryByteCount: UInt64(max(localSpeechPhysicalMemoryGiB, 0))
        * 1_073_741_824
    )
    residentSpeechBudgetConfirmation = budget.confirmationFingerprint
    residentSpeechModelIDs = proposed
    pendingResidentSpeechModelIDs = nil
  }

  public func cancelPendingResidentSpeechModels() {
    pendingResidentSpeechModelIDs = nil
  }
}
