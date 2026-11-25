//
//  MicrophonePermission.swift
//  DeFeedbackHost
//
//  Microphone (audio input) checker. Contract: PermissionChecking.swift.
//
import AVFoundation

@MainActor
final class MicrophonePermission: PermissionChecker {

    let permission = Permission.microphone

    /// Pure mapping, so it can be tested without the system.
    nonisolated static func state(for status: AVAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        case .denied, .restricted: .denied
        @unknown default: .unknown
        }
    }

    func check() async -> PermissionState {
        Self.state(for: AVCaptureDevice.authorizationStatus(for: .audio))
    }

    func request() async -> PermissionState {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        return granted ? .granted : .denied
    }
}
