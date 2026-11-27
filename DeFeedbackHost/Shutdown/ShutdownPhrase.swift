//
//  ShutdownPhrase.swift
//  DeFeedbackHost
//
//  The one definition of the shutdown phrase rules. The contract is in ShutdownSettings.swift and
//  spec rules SH2 and SH3 in docs/shutdown-spec.md. The web page and the Stream Deck plugin repeat
//  the same exact-match rule in their own languages; keep them identical.
//
import Foundation

enum ShutdownPhrase {

    /// The phrase of a fresh install, and what an empty stored value reads as.
    static let defaultPhrase = "shutdown now"

    /// A phrase may be saved only if it has something in it.
    static func isValid(_ phrase: String) -> Bool {
        !phrase.isEmpty
    }

    /// Exact comparison: case-sensitive, no trimming, no normalisation.
    static func matches(_ submitted: String, expected: String) -> Bool {
        submitted == expected
    }
}
