//
//  InstanceName.swift
//  DeFeedbackHost
//
//  Created by Edgars Klepers on 9/17/26.
//

import Foundation

enum InstanceNameError: LocalizedError, Equatable {
    case empty
    case tooLong
    case invalidCharacters
    case duplicate(String)

    var errorDescription: String? {
        switch self {
        case .empty:
            return "The instance name cannot be empty."
        case .tooLong:
            return "The instance name max length is \(InstanceName.maxLength) characters."
        case .invalidCharacters:
            return "The instance name cannot contain control characters or \"/\"."
        case .duplicate(let name):
            return "The instance name \"\(name)\" is already taken."
        }
    }
}

nonisolated enum InstanceName {

    static let maxLength = 32

    static let defaultPrefix = "Instance "

    private static let disallowed = CharacterSet.controlCharacters
        .union(CharacterSet(charactersIn: "/"))

    static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func sanitized(_ name: String) -> String {
        let allowed = String(name.unicodeScalars.filter { !disallowed.contains($0) })
        return String(allowed.prefix(maxLength))
    }

    static func matches(_ lhs: String, _ rhs: String) -> Bool {
        lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }

    static func validate(_ name: String, among others: [String]) -> InstanceNameError? {
        if name.isEmpty { return .empty }
        if name.count > maxLength { return .tooLong }
        if name.unicodeScalars.contains(where: { disallowed.contains($0) }) {
            return .invalidCharacters
        }
        if let clash = others.first(where: { matches($0, name) }) {
            return .duplicate(clash)
        }
        return nil
    }

    static func defaultName(among names: [String]) -> String {
        var number = 1
        while names.contains(where: { matches($0, defaultPrefix + String(number)) }) {
            number += 1
        }
        return defaultPrefix + String(number)
    }
}
