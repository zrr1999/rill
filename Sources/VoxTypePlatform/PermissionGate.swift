import AppKit
import AVFoundation
import ApplicationServices
import Observation
import VoxTypeCore

@MainActor
@Observable
public final class PermissionGate: @unchecked Sendable {
    public private(set) var accessibility: PermissionState = .unknown
    public private(set) var microphone: PermissionState = .unknown

    public init() {
        refresh()
    }

    public func refresh() {
        accessibility = AXIsProcessTrusted() ? .granted : .denied
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphone = .granted
        case .denied, .restricted:
            microphone = .denied
        case .notDetermined:
            microphone = .unknown
        @unknown default:
            microphone = .unknown
        }
    }

    public var snapshot: PermissionSnapshot {
        PermissionSnapshot(accessibility: accessibility, microphone: microphone)
    }

    public func requestAccessibilityAccess() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refresh()
    }

    public func requestMicrophoneAccess(onUpdate: @escaping @MainActor (PermissionSnapshot) -> Void = { _ in }) {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refresh()
                onUpdate(self.snapshot)
            }
        }
    }

    public func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    public func openMicrophoneSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
