//
//  PluginUI.swift
//  DeFeedbackHost
//
//  Created by Edgars Klepers on 9/17/26.
//

import AppKit

/// Plugin UI view possibilities.
enum PluginUI {
    case loading
    /// AUv3 units, and AUv2 units with a custom Cocoa view, gives us a view controller.
    case controller(NSViewController)
    /// Fallback for AUv2 units with no custom view.
    case genericView(NSView)
    case unavailable(String)
}

/// Lets a non-`Sendable` AppKit object ride back from the audio unit's private callback thread.
nonisolated final class UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
