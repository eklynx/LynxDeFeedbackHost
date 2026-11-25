//
//  TestTraits.swift
//  DeFeedbackHostTests
//
//  Shared Swift Testing traits.
//
//  - Tests initially created with AI with human edits, but all reviewed by human

import Testing

@testable import DeFeedbackHost

extension Trait where Self == ConditionTrait {

    /// For tests that need the real DeFeedback Audio Unit registered on this machine. They run on a
    /// Mac that has it and show as SKIPPED (not failed) where it doesn't, such as GitHub's hosted
    /// runners. Giving them a simulated plugin instead is tracked in its own issue.
    static var requiresPlugin: Self {
        .enabled(if: PluginConfiguration.isInstalled,
                 "needs the configured Audio Unit registered on this machine")
    }
}
