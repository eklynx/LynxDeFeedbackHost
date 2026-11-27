//
//  InstanceView.swift
//  DeFeedbackHost
//
//  Created by Edgars Klepers on 9/17/26.
//

import SwiftUI

struct InstanceView: View {

    @Bindable var instance: PluginInstance
    let inputChannelCount: Int
    let outputChannelCount: Int
    let validateName: (String) -> InstanceNameError?
    let rename: (String) -> InstanceNameError?

    @State private var draftName = ""
    @State private var nameError: InstanceNameError?
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        VStack(spacing: 12) {
            nameControl
            routingControls
            Divider()

            PluginUIView(ui: instance.pluginUI)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(8)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))

            Divider()
            stateControls
        }
        .padding(12)
    }

    private var nameControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Name") {
                TextField("Name", text: $draftName, prompt: Text("Instance name"))
                    .labelsHidden()
                    .lineLimit(1)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                    .focused($nameFieldFocused)
                    .onSubmit { commitName() }
                    .help("A unique name for this instance (max length \(InstanceName.maxLength) characters). The web API uses it to identify the instance.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let nameError {
                Text(nameError.localizedDescription)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onAppear { draftName = instance.name }
        .onChange(of: draftName) { _, newValue in
            let sanitized = InstanceName.sanitized(newValue)
            if sanitized != newValue {
                draftName = sanitized
                return
            }
            // Live feedback (empty / duplicate) only while the user is editing.
            if nameFieldFocused {
                nameError = validateName(sanitized)
            }
        }
        .onChange(of: nameFieldFocused) { _, focused in
            if focused {
                nameError = validateName(draftName)
            } else {
                commitName(revertOnFailure: true)
            }
        }
        .onChange(of: instance.name) { _, newName in
            // Renamed elsewhere (e.g. the web UI); don't clobber an edit in progress.
            if !nameFieldFocused {
                draftName = newName
                nameError = nil
            }
        }
    }

    private func commitName(revertOnFailure: Bool = false) {
        if let error = rename(draftName) {
            nameError = error
            if revertOnFailure {
                draftName = instance.name
            }
        } else {
            nameError = nil
            draftName = instance.name
        }
    }

    private var routingControls: some View {
        HStack(spacing: 16) {
            channelPicker("Input channel",
                          selection: $instance.inputChannel,
                          available: inputChannelCount)

            channelPicker("Output channel",
                          selection: $instance.outputChannel,
                          available: outputChannelCount)

            Spacer()

            Text(instance.displayName)
                .font(.headline)
                .foregroundStyle(.secondary)
        }
    }

    private func channelPicker(_ label: String,
                               selection: Binding<Int>,
                               available: Int) -> some View {
        let selectedChannel = selection.wrappedValue
        let isUnavailable = selectedChannel < 0 || selectedChannel >= available

        return Picker(label, selection: selection) {
            if isUnavailable {
                Text("(Channel \(selectedChannel + 1))").tag(selectedChannel)
            }
            ForEach(0..<available, id: \.self) { channel in
                Text("Channel \(channel + 1)").tag(channel)
            }
        }

        .frame(maxWidth: 230)
        .disabled(available == 0)
        .help(isUnavailable
              ? "Channel \(selectedChannel + 1) isn't available on the currently selected device. Please choose a differnt device or channel."
              : "Which channel of the selected device this instance uses")
    }

    private var stateControls: some View {
        HStack(spacing: 12) {
            Toggle("Bypass", isOn: $instance.isBypassed)
                .toggleStyle(.button)
                .help("Bypass the plugin and pass the input through to the output directly")

            Toggle("Mute", isOn: $instance.isMuted)
                .toggleStyle(.button)
                .help("Mute sound from the plugin")

            Spacer()

            if instance.busChannelCount == 2 {
                Text("Stereo buses")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("This plugin did not allow a mono signal; duplicating sound across both channels")
            }

            if let error = instance.loadError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}
