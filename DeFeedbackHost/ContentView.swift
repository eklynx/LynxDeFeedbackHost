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

    /// The instance removal confirmation dialog
    @State private var removalRequest: InstanceRemoval?

    /// Pending removal request.
    private struct InstanceRemoval: Identifiable {
        let id: UUID
        let displayName: String
        /// The gallery's 1-based index.
        let number: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            engineControlBar
                .padding(12)

            if let message = host.errorMessage {
                errorBanner(message)
            }

            Divider()
            gallery
        }
        .frame(minWidth: 820, minHeight: 900)
        .task {
            await host.loadApplicationState()
            // make sure application state is loaded first, as it contains the web settings.
            web.reconcile()
        }

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

    // MARK: - Engine

    private var engineControlBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            deviceGrid
            controlRow
        }
    }


    private var deviceGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
            GridRow {
                Text("Input")
                    .gridColumnAlignment(.trailing)
                    .foregroundStyle(.secondary)

                Picker("", selection: $host.selectedInputDeviceUID) {
                    Text("None").tag(String?.none)
                    unavailableDeviceEntry(host.unavailableInputDevice)
                    ForEach(host.inputDevices) { device in
                        Text("\(device.name) (\(device.inputChannelCount) ch)")
                            .tag(String?.some(device.uid))
                    }
                }
                .labelsHidden()
                .frame(width: 280)

                sampleRatePicker(for: .input, selection: $host.selectedInputSampleRate)
            }

            GridRow {
                Text("Output")
                    .gridColumnAlignment(.trailing)
                    .foregroundStyle(.secondary)

                Picker("", selection: $host.selectedOutputDeviceUID) {
                    Text("None").tag(String?.none)
                    unavailableDeviceEntry(host.unavailableOutputDevice)
                    ForEach(host.outputDevices) { device in
                        Text("\(device.name) (\(device.outputChannelCount) ch)")
                            .tag(String?.some(device.uid))
                    }
                }
                .labelsHidden()
                .frame(width: 280)

                sampleRatePicker(for: .output, selection: $host.selectedOutputSampleRate)
            }
        }
        .disabled(host.isRunning)
    }

    @ViewBuilder
    private func unavailableDeviceEntry(_ device: AudioHost.UnavailableDevice?) -> some View {
        if let device {
            Text("(\(device.name))").tag(String?.some(device.uid))
        }
    }

    private func sampleRatePicker(for direction: AudioHost.AudioDirection,
                                  selection: Binding<Double?>) -> some View {
        let rates = host.sampleRates(for: direction)
        return Picker("", selection: selection) {
            if rates.isEmpty {
                Text("—").tag(Double?.none)
            }
            ForEach(rates, id: \.self) { rate in
                Text("\(Int(rate)) Hz").tag(Double?.some(rate))
            }
        }
        .labelsHidden()
        .frame(width: 120)
        .disabled(rates.isEmpty)
    }

    private var controlRow: some View {
        HStack(spacing: 16) {
            Picker("Buffer", selection: $host.bufferSize) {
                ForEach(PluginConfiguration.validBufferSizes, id: \.self) { size in
                    Text("\(size)").tag(size)
                }
            }
            .frame(maxWidth: 140)
            .disabled(host.isRunning)
            .help(bufferSizeHelp)

            Toggle("Multi-core parallel rendering", isOn: $host.parallelRendering)
                .toggleStyle(.checkbox)
                .disabled(host.isRunning)
                .help(parallelRenderingHelp)

            Button(host.isRunning ? "Stop" : "Run") {
                Task { await host.toggleRunning() }
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(!host.isRunning && !host.canStart)
            .help(runButtonHelp)

            if !host.isRunning, let reason = host.startBlockedReason {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            statusReadout

            Spacer()

            instanceStepper
        }
    }

    private var bufferSizeHelp: String {
        var lines = ["Sets the hardware buffer on both input and output devices.  Only changable while stopped."]
        for (label, direction) in [("Input", AudioHost.AudioDirection.input),
                                   ("Output", AudioHost.AudioDirection.output)] {
            if let range = host.bufferSizeRange(for: direction) {
                lines.append("\(label) accepts \(range.lowerBound)–\(range.upperBound)")
            }
        }
        return lines.joined(separator: "\n")
    }


    private var parallelRenderingHelp: String {
        """
        Enable Parallel rendering between multiple worker threads.

        Only takes effect at \(PluginConfiguration.parallelRenderingInstanceThreshold) instances.\
        below that, splitting the work costs more than it saves. Only changeable while stopped.
        """
    }

    private var runButtonHelp: String {
        if host.isRunning { return "Close the audio devices" }
        return host.startBlockedReason ?? "Open the audio devices and start processing"
    }

    @ViewBuilder
    private var statusReadout: some View {
        if host.isRunning {
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                let diagnostics = host.diagnostics
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(Int(host.runningSampleRate)) Hz")
                    Text(loadSummary(diagnostics))
                        .foregroundStyle(loadColor(diagnostics))
                }
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .help(loadHelp(diagnostics))
            }
        }
    }

    private func loadSummary(_ diagnostics: AudioHost.Diagnostics?) -> String {
        guard let diagnostics, diagnostics.hasRendered else {
            return "— CPU · waiting for the device"
        }

        var summary = "\(percent(diagnostics.dspLoad)) DSP Load · \(diagnostics.underruns) underruns"
        // Loud, because audio work off a realtime thread will glitch under any load at all.
        if !diagnostics.audioThreadsAreRealtime {
            summary += " · NOT REALTIME"
        }
        return summary
    }

    /// Warn if DSP load is over 80%.
    private func loadColor(_ diagnostics: AudioHost.Diagnostics?) -> Color {
        guard let diagnostics, diagnostics.hasRendered else { return .secondary }
        if !diagnostics.audioThreadsAreRealtime { return .red }
        if diagnostics.underruns > 0 || diagnostics.dspLoad > 0.8 { return .orange }
        return .secondary
    }

    private func loadHelp(_ diagnostics: AudioHost.Diagnostics?) -> String {
        guard let diagnostics, diagnostics.hasRendered else {
            return "Waiting for the output device's first callback."
        }

        var lines = [
            "DSP load history:",
            "Peak so far: \(percent(diagnostics.peakDspLoad)). Underruns: \(diagnostics.underruns).",
        ]
        if let render = diagnostics.renderThreadPolicy {
            lines.append("Render thread: \(render.summary).")
        }
        if let capture = diagnostics.captureThreadPolicy {
            lines.append("Capture thread: \(capture.summary).")
        }

        if diagnostics.workerThreadPolicies.isEmpty {
            if host.parallelRendering {
                lines.append("Parallel rendering on, but rendering serially on one core.")
            }
        } else {
            let state = diagnostics.parallelRenderingEngaged ? "in use" : "idle, below threshold"
            lines.append("\(diagnostics.workerThreadPolicies.count) render workers (\(state)).")
            // Listed individually rather than summarised: one worker missing its policy is the
            // failure that matters, and a count would hide it.
            for (index, worker) in diagnostics.workerThreadPolicies.enumerated() {
                lines.append("  Worker \(index + 1): \(worker.summary).")
            }
        }

        return lines.joined(separator: "\n")
    }

    private func percent(_ fraction: Double) -> String {
        guard fraction.isFinite, fraction > 0 else { return "0%" }
        if fraction < 0.01 { return "<1%" }
        return "\(Int((fraction * 100).rounded()))%"
    }

    private var instanceStepper: some View {
        HStack(spacing: 8) {
            Button {
                askToRemoveSelectedInstance()
            } label: {
                Image(systemName: "minus")
            }
            .disabled(host.instances.isEmpty)
            .help("Remove the currently shown instance")

            Text("\(host.instances.count)")
                .monospacedDigit()
                .frame(minWidth: 24)

            Button {
                Task { await host.addInstance() }
            } label: {
                Image(systemName: "plus")
            }
            .disabled(!host.canAddInstance)
            .help("Add another plugin instance")
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

    // MARK: - Gallery

    @ViewBuilder
    private var gallery: some View {
        if !host.isPluginInstalled {
            missingPluginNotice
        } else if host.instances.isEmpty {
            ContentUnavailableView {
                Label("No Instances", systemImage: "square.stack.3d.up.slash")
            } description: {
                Text("Press + to add a new plugin instance.")
            }
            .frame(maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                InstanceChooserView(count: host.instances.count,
                                selectedIndex: $host.selectedInstanceIndex)

                HStack(spacing: 0) {
                    galleryChevron(systemImage: "chevron.left",
                                   enabled: host.canShowPreviousInstance) {
                        host.showPreviousInstance()
                    }

                    if let instance = host.selectedInstance {
                        InstanceView(instance: instance,
                                     inputChannelCount: host.inputChannelCount,
                                     outputChannelCount: host.outputChannelCount,
                                     validateName: { host.validateName($0, for: instance) },
                                     rename: { host.rename(instance, to: $0) })
                        .id(instance.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                    galleryChevron(systemImage: "chevron.right",
                                   enabled: host.canShowNextInstance) {
                        host.showNextInstance()
                    }
                }
            }
        }
    }

    private var missingPluginNotice: some View {
        VStack(spacing: 12) {
            Text(PluginConfiguration.notInstalledMessage)
                .font(.title3.bold())
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)

            Link(PluginConfiguration.pluginHomepage.absoluteString,
                 destination: PluginConfiguration.pluginHomepage)
                .font(.callout)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func galleryChevron(systemImage: String,
                                enabled: Bool,
                                action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.title2)
                .frame(width: 36, height: 80)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .padding(.horizontal, 4)
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
