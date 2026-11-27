//
//  EngineControlBar.swift
//  DeFeedbackHost
//
//  Created by Edgars Klepers on 9/16/26.
//

import SwiftUI

/// The strip across the top of the window: device and sample-rate pickers, buffer size, the
/// parallel-rendering switch, Run/Stop, the engine readout and the instance +/- stepper.
///
/// Everything here is locked while the engine runs. Removing an instance needs a confirmation the
/// window owns, so the minus button reports through `onRemoveInstance` instead of acting itself.
struct EngineControlBar: View {

    @Bindable var host: AudioHost
    let onRemoveInstance: () -> Void

    var body: some View {
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

            StatusReadout(host: host)

            Spacer()

            instanceStepper
        }
    }

    private var bufferSizeHelp: String {
        var lines = ["Sets the hardware buffer on both input and output devices.  Only changable while stopped.",
                     "At \(Int(PluginConfiguration.highSampleRateThreshold)) Hz and above the plugin needs at least "
                     + "\(PluginConfiguration.minimumBufferAtHighSampleRate) samples."]
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

    private var instanceStepper: some View {
        HStack(spacing: 8) {
            Button {
                onRemoveInstance()
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
}
