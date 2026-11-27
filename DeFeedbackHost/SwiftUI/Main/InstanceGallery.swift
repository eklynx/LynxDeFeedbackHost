//
//  InstanceGallery.swift
//  DeFeedbackHost
//
//  Created by Edgars Klepers on 9/16/26.
//

import SwiftUI

/// The window's lower area: the instance chooser with the selected instance between paging
/// chevrons, or the notice that stands in for it when there is no plugin or no instance.
struct InstanceGallery: View {

    @Bindable var host: AudioHost

    var body: some View {
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
