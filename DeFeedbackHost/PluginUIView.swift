//
//  PluginUIView.swift
//  DeFeedbackHost
//
//  Created by Edgars Klepers on 9/16/26.
//

import SwiftUI

struct PluginUIView: View {

    let ui: PluginUI

    var body: some View {
        switch ui {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .controller(let controller):
            PluginViewControllerHost(controller: controller)

        case .genericView(let view):
            PluginNSViewHost(view: view)

        case .unavailable(let message):
            VStack(spacing: 8) {
                Image(systemName: "slider.horizontal.below.rectangle")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// AUv3 and AUv2 plugins with a custom Cocoa view, arrive as a view controller.
private struct PluginViewControllerHost: NSViewControllerRepresentable {

    let controller: NSViewController

    func makeNSViewController(context: Context) -> NSViewController {
        controller
    }

    func updateNSViewController(_ nsViewController: NSViewController, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize,
                      nsViewController: NSViewController,
                      context: Context) -> CGSize? {
        // honor the plugin view's size
        let fitting = nsViewController.view.fittingSize
        guard fitting.width > 0, fitting.height > 0 else { return nil }
        return fitting
    }
}

/// Fallback for AUv2 plugins with no custom view, uses `AUGenericView`
private struct PluginNSViewHost: NSViewRepresentable {

    let view: NSView

    func makeNSView(context: Context) -> NSView {
        view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize,
                      nsView: NSView,
                      context: Context) -> CGSize? {
        let fitting = nsView.fittingSize
        guard fitting.width > 0, fitting.height > 0 else { return nil }
        return fitting
    }
}
