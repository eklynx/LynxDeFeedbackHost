//
//  InstanceChooserView.swift
//  DeFeedbackHost
//
//  Created by Edgars Klepers on 9/17/26.
//

import SwiftUI

/// Gallery style view of plugin instances.
struct InstanceChooserView: View {

    let count: Int
    @Binding var selectedIndex: Int

    var body: some View {
        VStack(spacing: 6) {
            Text("Instance \(selectedIndex + 1) of \(count)")
                .font(.headline)
                .monospacedDigit()

            HStack(spacing: 10) {
                skipButton(systemImage: "backward.end.fill",
                           target: 0,
                           enabled: selectedIndex > 0,
                           help: "Go to the first instance")

                numbers

                skipButton(systemImage: "forward.end.fill",
                           target: count - 1,
                           enabled: selectedIndex < count - 1,
                           help: "Go to the last instance")
            }
        }
        .padding(.top, 4)
    }

    private var numbers: some View {
        ViewThatFits(in: .horizontal) {
            numberRow

            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    numberRow
                }
                .scrollIndicators(.never)
                .onAppear {
                    proxy.scrollTo(selectedIndex, anchor: .center)
                }
                .onChange(of: selectedIndex) { _, index in
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(index, anchor: .center)
                    }
                }
            }
        }
    }

    private var numberRow: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                if index > 0 {
                    Text("•")
                        .foregroundStyle(.tertiary)
                }
                numberButton(index)
            }
        }
        .padding(.horizontal, 2)
    }

    private func numberButton(_ index: Int) -> some View {
        let isSelected = index == selectedIndex
        return Button {
            selectedIndex = index
        } label: {
            Text("\(index + 1)")
                .font(isSelected ? .body.weight(.bold) : .body)
                .monospacedDigit()
                .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(.tint.opacity(0.15))
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .id(index)
        .help("Show instance \(index + 1)")
        .accessibilityLabel("Instance \(index + 1)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func skipButton(systemImage: String,
                            target: Int,
                            enabled: Bool,
                            help: String) -> some View {
        Button {
            selectedIndex = target
        } label: {
            Image(systemName: systemImage)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .help(help)
    }
}

#Preview("Many instances") {
    @Previewable @State var index = 4
    return InstanceChooserView(count: 12, selectedIndex: $index)
        .padding()
        .frame(width: 700)
}

#Preview("Single instance") {
    @Previewable @State var index = 0
    return InstanceChooserView(count: 1, selectedIndex: $index)
        .padding()
        .frame(width: 700)
}

#Preview("Maximum instances") {
    @Previewable @State var index = 20
    return InstanceChooserView(count: PluginConfiguration.maximumInstanceCount,
                           selectedIndex: $index)
        .padding()
        .frame(width: 700)
}
