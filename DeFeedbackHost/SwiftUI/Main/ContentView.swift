//
//  ContentView.swift
//  DeFeedbackHost
//
//  Created by Edgars Klepers on 9/16/26.
//

import CoreAudio
import SwiftUI

struct ContentView: View {

    @Bindable var host: AudioHost
    let web: WebControlService

    @Environment(PermissionService.self) private var permissions: PermissionService?

    /// The instance removal confirmation dialog
    @State private var removalRequest: InstanceRemoval?

    private var microphoneNeedsPermission: Bool {
        permissions?.problems.contains(.microphone) == true
    }

    /// The error banner's text, or nil when it would only repeat the permissions banner.
    /// A denied microphone is already explained (with a button to fix it) by `PermissionsBanner`,
    /// so a second bar saying the same thing is noise.
    static func visibleError(_ message: String?, microphoneNeedsPermission: Bool) -> String? {
        guard let message else { return nil }
        if microphoneNeedsPermission,
           message == AudioHostError.microphoneAccessDenied.localizedDescription {
            return nil
        }
        return message
    }

    /// Pending removal request.
    private struct InstanceRemoval: Identifiable {
        let id: UUID
        let displayName: String
        /// The gallery's 1-based index.
        let number: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            EngineControlBar(host: host, onRemoveInstance: askToRemoveSelectedInstance)
                .padding(12)

            if let message = Self.visibleError(host.errorMessage,
                                               microphoneNeedsPermission: microphoneNeedsPermission) {
                errorBanner(message)
            }

            Divider()
            InstanceGallery(host: host)
        }
        // The minimum height is for the controls and gallery only. The update and permission banners sit in a
        // top inset so its height is ADDED to the window's required size instead of being taken
        // out of the gallery (which cut off the mute/bypass row at the bottom).
        .frame(minWidth: 820, minHeight: 900)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                PermissionsBanner()
                StreamDeckPluginBanner()
                UpdateBanner()
            }
        }
        // Once the microphone is allowed, drop the stale "access denied" error so it can't reappear.
        .onChange(of: microphoneNeedsPermission) { _, needs in
            if !needs, host.errorMessage == AudioHostError.microphoneAccessDenied.localizedDescription {
                host.errorMessage = nil
            }
        }
        // Application state is loaded by AppDelegate so it doesn't depend on this window existing.

        // instance removal confirmation dialog.
        .confirmationDialog(
            Text(removalRequest.map { "Remove \($0.displayName) (#\($0.number))?" } ?? ""),
            item: $removalRequest
        ) { request in
            Button("Remove", role: .destructive) {
                // By id, never by the position the button was pressed at — see `InstanceRemoval`.
                host.removeInstance(id: request.id)
            }
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: { _ in
            Text("Are you sure you want to remove this instance? Settings will not be saved")
        }
    }

    private func askToRemoveSelectedInstance() {
        guard let instance = host.selectedInstance else { return }

        removalRequest = InstanceRemoval(id: instance.id,
                                         displayName: instance.name,
                                         number: host.selectedInstanceIndex + 1)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Dismiss") { host.errorMessage = nil }
                .buttonStyle(.borderless)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.15))
    }
}

#Preview {
    let host = AudioHost()
    return ContentView(host: host, web: WebControlService(host: host))
}

#Preview("No plugin installed") {
    let host = AudioHost(pluginInstalled: false)
    return ContentView(host: host, web: WebControlService(host: host))
}

#Preview("Device not connected") {
    let defaults = UserDefaults(suiteName: "DeFeedbackHost.Preview.MissingDevice")!
    var settings = HostSettings()
    settings.inputDeviceUID = "a-device-that-is-not-here"
    settings.inputDeviceName = "Studio Interface"
    settings.instances = [InstanceSettings(inputChannel: 7, outputChannel: 7)]
    SettingsStore.save(settings, to: defaults)

    let host = AudioHost(defaults: defaults)
    return ContentView(host: host, web: WebControlService(host: host))
}
